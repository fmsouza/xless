import Foundation
import XlessCore

/// How a run ends before its steps do: an exit code, and what to say (nil: it has been said). 2 is a usage or
/// configuration error of the run itself; a step's own exit code is passed on.
public struct RunStop: Error, Equatable {
    public let code: Int32
    public let message: String?

    public init(code: Int32, message: String? = nil) { self.code = code; self.message = message }

    static func usage(_ message: String) -> RunStop { RunStop(code: 2, message: "testflight: \(message)") }
}

/// The stages of `xless ship`, as `--from` and `--to` name them.
enum RunStage: Int, CaseIterable, Comparable {
    case prepare, build, assets, finalize, sign, package, upload

    var name: String { "\(self)" }

    static func < (a: RunStage, b: RunStage) -> Bool { a.rawValue < b.rawValue }

    static func named(_ name: String) throws -> RunStage {
        guard let stage = allCases.first(where: { $0.name == name }) else {
            throw RunStop.usage("unknown stage '\(name)' (use one of: \(allCases.map(\.name).joined(separator: " ")))")
        }
        return stage
    }
}

/// What a run is asked for: its own options taken out of the arguments, and the rest, which go to `xless ship`.
public struct RunRequest: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A directory with an xless.yml, as given.
        case project(String)
        /// An overlay file, as given.
        case overlay(String)
    }

    public var target: Target
    public var platform = Platform.ios
    public var simulator = false
    public var dryRun = false
    public var allowDisk = false
    /// `xless ship`'s arguments, without the `--` that may introduce them.
    public var rest: [String] = []

    static let usage = "usage: xless run [--docker] <project-dir> [extra xless ship args...]   or   xless run [--docker] --config <overlay.yml> "
        + "[--platform ios|macos] [--destination device|simulator] [--dry-run] [--allow-disk-secrets] [extra args...]"

    public static func parse(_ arguments: [String]) throws -> RunRequest {
        guard !arguments.isEmpty else { throw RunStop.usage(usage) }
        var platform = "ios", destination = "device", dryRun = false, allowDisk = false
        var words: [String] = []
        var i = arguments.startIndex
        /// The value of the option at `i`: after its `=`, else the next argument.
        func value(_ option: String, _ what: String) throws -> String {
            if let value = RunText.value(of: option + "=", in: arguments[i]) { return value }
            guard i + 1 < arguments.endIndex else { throw RunStop.usage("\(option) needs \(what)") }
            i += 1
            return arguments[i]
        }
        func isOption(_ option: String) -> Bool { arguments[i] == option || RunText.has(option + "=", before: arguments[i]) }
        while i < arguments.endIndex {
            if isOption("--platform") { platform = try value("--platform", "ios or macos") }
            else if isOption("--destination") { destination = try value("--destination", "device or simulator") }
            else if arguments[i] == "--dry-run" { dryRun = true }
            else if arguments[i] == "--allow-disk-secrets" { allowDisk = true }
            else { words.append(arguments[i]) }
            i += 1
        }
        guard platform == "ios" || platform == "macos" else { throw RunStop.usage("--platform must be ios or macos") }
        guard destination == "device" || destination == "simulator" else { throw RunStop.usage("--destination must be device or simulator") }
        guard let first = words.first else { throw RunStop.usage(usage) }
        var request: RunRequest
        if first == "--config" {
            guard words.count >= 2 else { throw RunStop.usage(usage) }
            request = RunRequest(target: .overlay(words[1]))
            words.removeFirst(2)
            if let next = words.first, !RunText.has("-", before: next) { throw RunStop.usage("--config replaces <project-dir>; give one or the other") }
        } else {
            request = RunRequest(target: .project(first))
            words.removeFirst()
            if words.contains(where: { $0 == "--config" || RunText.has("--config=", before: $0) }) { throw RunStop.usage("--config replaces <project-dir>; give one or the other") }
            if destination == "simulator" { throw RunStop.usage("--destination simulator needs --config <overlay.yml> (a React Native app)") }
            if platform == "macos" { throw RunStop.usage("--platform macos needs --config <overlay.yml> (a Tauri or cargo app)") }
        }
        // `--` introduces ship's arguments; ship itself would take what follows it as operands, and has none.
        if let end = words.firstIndex(of: "--") { words.remove(at: end) }
        request.platform = platform == "macos" ? .macos : .ios
        request.simulator = destination == "simulator"
        request.dryRun = dryRun
        request.allowDisk = allowDisk
        request.rest = words
        return request
    }
}

/// Which stages an overlay's run goes through, and which of its three steps.
struct RunSpan: Equatable {
    var from: RunStage
    var to: RunStage
    var buildNumberGiven = false
    /// The arguments without `--from` and `--to`, which the run places itself.
    var extra: [String] = []

    static func overlay(_ request: RunRequest) throws -> RunSpan {
        var from = "build", to = request.simulator ? "build" : request.platform == .macos ? "package" : "upload"
        var fromGiven = false
        var span = RunSpan(from: .build, to: .upload)
        var i = request.rest.startIndex
        while i < request.rest.endIndex {
            let word = request.rest[i]
            if word == "--from" || word == "--to" {
                guard i + 1 < request.rest.endIndex else { throw RunStop.usage("\(word) needs a stage") }
                i += 1
                if word == "--from" { from = request.rest[i]; fromGiven = true } else { to = request.rest[i] }
            } else if let stage = RunText.value(of: "--from=", in: word) { from = stage; fromGiven = true }
            else if let stage = RunText.value(of: "--to=", in: word) { to = stage }
            else {
                if word == "--build-number" || RunText.has("--build-number=", before: word) { span.buildNumberGiven = true }
                span.extra.append(word)
            }
            i += 1
        }
        span.from = try RunStage.named(from)
        span.to = try RunStage.named(to)
        // `--to prepare` alone: the run starts at prepare (the default --from is build, which includes prepare)
        if !fromGiven, span.to < span.from { span.from = .prepare }
        guard span.from <= span.to else { throw RunStop.usage("--to \(to) comes before --from \(from)") }
        if request.simulator, span.to > .build { throw RunStop.usage("--destination simulator builds stop at build (--to \(to))") }
        return span
    }

    /// A project directory is one `xless ship`, which places its own stages: only where it stops matters here.
    static func project(_ request: RunRequest) throws -> RunSpan {
        var to = "upload", previous = ""
        var span = RunSpan(from: .build, to: .upload, extra: request.rest)
        for word in request.rest {
            if previous == "--to" { to = word }
            if let stage = RunText.value(of: "--to=", in: word) { to = stage }
            if word == "--build-number" || RunText.has("--build-number=", before: word) { span.buildNumberGiven = true }
            previous = word
        }
        span.to = try RunStage.named(to)
        return span
    }
}
