import ArgumentParser
import Foundation
import XlessCore
import XlessXcode

struct XcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode", abstract: "Download Xcode .xips from Apple, and Xcode project helpers (React Native / CocoaPods workspaces).",
        subcommands: [XcodeDownloadCommand.self, XcodePIFCommand.self, XcodeSwbuildCommand.self, XcodePackagesCommand.self])
}

struct XcodePIFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pif",
        abstract: "Write a workspace's Swift Build PIF and the build request for a scheme (for swbuild --buildRequestFile).")
    @Argument(help: "The .xcworkspace or .xcodeproj.") var workspace: String
    @Option(help: "Shared scheme whose build action to build.") var scheme: String
    @Option(help: "Build configuration.") var configuration = "Release"
    @Option(help: "Output directory: <workspace>.pif and request.json.") var out: String
    @Option(name: .customLong("override"), help: "Build setting override NAME=VALUE (repeatable).") var overrides: [String] = []
    @Option(name: .customLong("package"), help: "Resolved Swift package IDENTITY=<dump-pif JSON> (repeatable).") var packages: [String] = []
    @Flag(help: "Add the overrides Swift Build needs on Linux (xless-rn image) and write its toolset.json to --out; --override wins.")
    var linux = false

    func run() throws {
        let ws = try XcodeWorkspace.load(URL(fileURLWithPath: workspace))
        var table: [String: String] = [:]
        for o in overrides {
            guard let eq = o.firstIndex(of: "="), eq != o.startIndex else {
                throw XlessError(.prepare, "--override \(o) is not NAME=VALUE", fix: "e.g. --override CODE_SIGNING_ALLOWED=NO")
            }
            table[String(o[..<eq])] = String(o[o.index(after: eq)...])
        }
        let resolved = try packages.map { spec -> ResolvedPackage in
            guard let eq = spec.firstIndex(of: "=") else {
                throw XlessError(.prepare, "--package \(spec) is not IDENTITY=FILE", fix: "e.g. --package greetingkit=pif.json")
            }
            let file = String(spec[spec.index(after: eq)...])
            guard let data = FileManager.default.contents(atPath: file) else {
                throw XlessError(.prepare, "cannot read \(file)", fix: "check the path")
            }
            return try ResolvedPackage(identity: String(spec[..<eq]), dumpPIF: data)
        }
        let dir = URL(fileURLWithPath: out)
        if linux {
            table = try SwiftBuildRunner.prepareOverrides(try SwiftBuildEnvironment.fromProcess(stage: .prepare), directory: dir,
                                                          extra: table, stage: .prepare)
        }
        let pif = try PIFWriter.write(ws, to: dir, packages: resolved)
        let request = try BuildRequest.make(workspace: ws, scheme: ws.scheme(named: scheme), configuration: configuration, overrides: table)
        let requestURL = dir.appendingPathComponent("request.json")
        do { try request.write(to: requestURL) } catch {
            throw XlessError(.prepare, "cannot write \(requestURL.path): \(error.localizedDescription)", fix: "check the output directory")
        }
        print(pif.path)
        print(requestURL.path)
    }
}

struct XcodeSwbuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuild",
        abstract: "Run swbuild on a PIF and build request in the Linux Swift Build environment (xless-rn image); summarises the result.")
    @Argument(help: "The PIF (xless xcode pif).") var pif: String
    @Option(help: "The build request (request.json).") var request: String
    @Option(name: .customLong("derived-data"), help: "Derived data directory.") var derivedData: String
    @Option(help: "Where swbuild's JSON message stream goes (default: <derived-data>/xless/swbuild.log).") var log: String?

    func run() throws {
        let dd = URL(fileURLWithPath: derivedData)
        let logURL = log.map { URL(fileURLWithPath: $0) } ?? dd.appendingPathComponent("xless/swbuild.log")
        let s = try SwiftBuildRunner.build(pif: URL(fileURLWithPath: pif), request: URL(fileURLWithPath: request), derivedData: dd,
                                           environment: try SwiftBuildEnvironment.fromProcess(stage: .build), log: logURL, stage: .build)
        for w in s.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
        for e in s.errors { FileHandle.standardError.write(Data("error: \(e)\n".utf8)) }
        for t in s.failedTasks { FileHandle.standardError.write(Data("failed: \(t)\n".utf8)) }
        for c in s.commandsNotFound { FileHandle.standardError.write(Data("warning: a build phase ran a missing command: \(c)\n".utf8)) }
        for r in s.shimRefusals { FileHandle.standardError.write(Data("warning: a shim refused a call: \(r)\n".utf8)) }
        print("\(s.succeeded ? "succeeded" : "failed"): \(s.tasks) tasks, \(s.failedTasks.count) failed, \(s.errors.count) errors, \(s.warnings.count) warnings (log: \(logURL.path))")
        if !s.succeeded {
            throw XlessError(.build, "swbuild failed (\(s.failedTasks.first ?? s.errors.first ?? "no failed task reported"))", fix: "see the errors above and \(logURL.path)")
        }
    }
}

struct XcodePackagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packages",
        abstract: "List the workspace's Swift package references as IDENTITY<tab>URL-or-path<tab>revision (to clone and dump-pif).")
    @Argument(help: "The .xcworkspace or .xcodeproj.") var workspace: String

    func run() throws {
        let ws = try XcodeWorkspace.load(URL(fileURLWithPath: workspace))
        for line in try XcodePackageList.lines(ws) { print(line) }
    }
}
