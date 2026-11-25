import ArgumentParser
import Foundation
import XlessCargo
import XlessCore
import XlessTauri
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The build of an overlay's app on a Mac. Its code (npm scripts, build.rs, gems, pods, Xcode's build phases) is not looked at, so
/// `prepare` to `finalize` run in an xless of their own that is in the sandbox (`BuildSandbox`) with all that it starts; what that one
/// does for the build (it copies files, follows links, reads records) it does in there as well. The xless outside checks what goes in,
/// passes on what is printed, and signs.
struct NativeOverlay {
    /// Given by the xless outside, which sets the rest of the environment too; believed only where the sandbox is (`isInside`).
    static let told = "XLESS_BUILD_SANDBOX"
    /// More for the build to read (absolute paths, with : between them), of what is closed.
    static let readVariable = "XLESS_BUILD_READ"

    /// Whether this is the xless in the sandbox. Told so where there is none, it goes no further.
    static func isInside(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        guard MacNative.isMac, env[told] == "1" else { return false }
        guard BuildSandbox.isInForce() else {
            throw XlessError(.prepare, "the sandbox that the app's build code runs in is not in force", fix: "unset \(told), or build in Docker: add --docker")
        }
        return true
    }

    /// What a stage builds with on a Mac: nil off a Mac and for an xless.yml project. Outside the sandbox an overlay's code never runs.
    static func xcode(for ctx: Context, stage: Stage) throws -> InstalledXcode? {
        guard MacNative.isMac, ctx.hasPrepare else { return nil }
        guard try isInside() else {
            throw XlessError(stage, "the app's build code does not run outside the sandbox", fix: "report this as an xless bug")
        }
        return try MacNative.here(for: ctx, stage: stage)?.xcode
    }

    let source: URL, overlay: URL, work: URL, paths: StagePaths
    /// Of the checkout that the source is in, and where its git keeps what it has.
    var checkout: [String]
    var inputs: [(name: String, path: String)] = []
    var xcode: InstalledXcode
    /// As this process has it, with its secrets: nothing of it but what `environment` takes goes inside.
    var env: [String: String]
    let home: String
    let cache: URL

    init(source: URL, overlay: URL, work: URL, paths: StagePaths, checkout: [String], xcode: InstalledXcode, env: [String: String]) {
        self.source = source; self.overlay = overlay; self.work = work; self.paths = paths; self.checkout = checkout; self.xcode = xcode; self.env = env
        home = env["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
        cache = env["XLESS_CACHE"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? URL(fileURLWithPath: home).appendingPathComponent(".cache/xless")
    }

    /// The home directory that the builds have: package managers keep what they fetched in it from one build to the next.
    var buildHome: URL { cache.appendingPathComponent("build-home", isDirectory: true) }
    var temporary: URL { buildHome.appendingPathComponent("tmp/\(work.lastPathComponent)", isDirectory: true) }

    // MARK: - The sandbox

    func sandbox(executable: URL, reads more: [String]) throws -> BuildSandbox {
        let closed = BuildSandbox.privatePlaces + [home, BuildSandbox.userHome, env["TMPDIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }].compactMap { $0 }
        let given = (env[Self.readVariable] ?? "").split(separator: ":").map(String.init)
        let opened = [("the app source", checkout), ("the overlay's directory", [overlay.deletingLastPathComponent().path]), (Self.readVariable, given)]
            + inputs.map { ("the path input '\($0.name)'", [$0.path]) }
        var reads: [String] = []
        for (what, paths) in opened {
            for path in paths {
                guard path.hasPrefix("/") else { throw XlessError(.config, "\(what) has \(path), which is not an absolute path", fix: "write the whole path") }
                guard !BuildPlaces.isBroad(BuildSandbox.real(path), home: home), !BuildPlaces.isBroad(BuildSandbox.real(path), home: BuildSandbox.userHome ?? home) else {
                    throw XlessError(.config, "\(what) is \(path), which would open a home directory to the app's build code", fix: "keep the overlay in its own directory and point source: at the app's checkout")
                }
                reads.append(path)
            }
        }
        reads += [executable.path, xcode.app.path] + more
        let stages = [paths.signed, paths.out, paths.uploadRecord].flatMap { [$0.path, $0.path + ".partial"] }
        return BuildSandbox(reads: reads, writes: writes.map(\.path), readOnly: stages, fixed: fixed.map(\.path), secrets: BuildPlaces.secrets(env, home: home), closed: closed)
    }

    private var writes: [URL] {
        [work, buildHome, cache.appendingPathComponent("downloads"), cache.appendingPathComponent("inputs"), work.deletingLastPathComponent().appendingPathComponent(".pnpm-store")]
    }

    /// Of the work copy, what the xless outside goes through.
    private var fixed: [URL] {
        let own = work.appendingPathComponent(".xless", isDirectory: true)
        return [own, own.appendingPathComponent("build", isDirectory: true), paths.root]
    }

    /// Makes those directories, as directories of this user's own.
    func makeDirectories() throws {
        for url in writes + fixed + [buildHome.appendingPathComponent("tmp"), temporary] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(url.path, url == work || url == paths.root || fixed.contains(url) ? 0o755 : 0o700) == 0 || errno == EEXIST else {
                throw XlessError(.prepare, "cannot make \(url.path): \(String(cString: strerror(errno)))", fix: "check the permissions of \(url.deletingLastPathComponent().path)")
            }
            var about = stat()
            guard lstat(url.path, &about) == 0, about.st_mode & S_IFMT == S_IFDIR, about.st_uid == geteuid() else {
                throw XlessError(.prepare, "\(url.path) is not a directory of yours", fix: "remove it: xless makes it again")
            }
        }
    }

    // MARK: - Its environment

    func environment(buildNumber: String?) throws -> (variables: [String: String], reads: [String]) {
        let tools = BuildPlaces.tools(env, home: home, closed: BuildSandbox.privatePlaces + [home])
        var out = BuildPlaces.environment(env, home: buildHome.path, temporary: temporary.path)
        out.merge(tools.variables) { $1 }
        // Xcode's own programs (git among them) before the stand-ins for them in /usr/bin, which look for them over again.
        let developer = xcode.developer.appendingPathComponent("usr/bin").path
        var path = (out["PATH"] ?? "").split(separator: ":").map(String.init)
        path.insert(developer, at: path.firstIndex(of: "/usr/bin") ?? path.endIndex)
        out["PATH"] = path.joined(separator: ":")
        for (name, value) in xcode.environment(out) { out[name] = value }
        out["xcrun_db"] = temporary.appendingPathComponent("xcrun_db").path // its cache, which the user's own commands believe
        out["XLESS_TOOLS"] = try ownTools()
        out[OverlayPaths.homeVariable] = home
        out["XLESS_WORK_ROOT"] = work.deletingLastPathComponent().path
        out["XLESS_CACHE"] = cache.path
        out["XLESS_BUILD_NUMBER"] = buildNumber
        out[Self.told] = "1"
        return (out, tools.reads)
    }

    /// Xcode's actool and ibtool use services and directories that programs outside the sandbox share, so it has neither.
    private func ownTools() throws -> String {
        if try NativeTools(setting: env["XLESS_TOOLS"]).forced.values.contains(.xcode) {
            throw XlessError(.config, "XLESS_TOOLS asks for Xcode's actool or ibtool, which do not work in the sandbox that the app's build code runs in", fix: "unset it: xless's own compile this app's catalogs and storyboards")
        }
        return NativeTools.Choice.xless.rawValue
    }

    // MARK: - The run

    /// Runs `stages` inside; what it prints to its output goes to `output`. Its failure is this command's, with its exit code.
    func run(_ words: [String], buildNumber: String?, output: FileHandle) throws {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        try makeDirectories()
        let (variables, reads) = try environment(buildNumber: buildNumber)
        let command = try sandbox(executable: executable, reads: reads).command(executable.path, words)
        Self.say("\(xcode.summary)\nxless: the app's build code runs in a sandbox: it reads \(checkout.first ?? source.path) and \(overlay.deletingLastPathComponent().path), writes \(work.path) and \(buildHome.path), and nothing else of yours (docs/security.md)")
        let out = try OutputRelay(to: output), err = try OutputRelay(to: FileHandle.standardError)
        let status: Int32
        do {
            defer { for relay in [out, err] { relay.finish() } }
            status = try ChildProcess.start(command.program, command.arguments, environment: ChildProcess.environment(variables), cwd: URL(fileURLWithPath: "/"),
                                            stdout: out.input, stderr: err.input, stage: .prepare).wait()
        }
        if status != 0 { throw ExitCode(status) } // it said why
    }

    private static func say(_ line: String) { FileHandle.standardError.write(Data("xless: \(line)\n".utf8)) }
}

/// Passes on what a program writes: the program has a pipe, not this process's terminal or file. What it leaves running can write on
/// for as long as it likes; that goes nowhere once `finish` was called.
final class OutputRelay: @unchecked Sendable {
    private let pipe: Pipe, done = DispatchSemaphore(value: 0)
    private let ended = NSLock()
    private var isEnded = false

    var input: Int32 { pipe.fileHandleForWriting.fileDescriptor }

    init(to output: FileHandle) throws {
        pipe = Pipe()
        let from = pipe.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            var buffer = [UInt8](repeating: 0, count: 1 << 16), until: Date?
            while true {
                if until == nil, ended.withLock({ isEnded }) { until = Date().addingTimeInterval(2) }
                if let until, Date() > until { return }
                var poll = pollfd(fd: from, events: Int16(POLLIN), revents: 0)
                let ready = Self.poll(&poll)
                if ready == 0, until != nil { return }
                guard ready != 0 else { continue }
                guard ready > 0 || errno == EINTR else { return }
                let count = read(from, &buffer, buffer.count)
                if count == 0 || (count < 0 && errno != EINTR) { return }
                if count > 0 { output.write(Data(buffer[..<count])) }
            }
        }
    }

    private static func poll(_ what: inout pollfd) -> Int32 {
        #if canImport(Glibc)
        Glibc.poll(&what, 1, 100)
        #elseif canImport(Musl)
        Musl.poll(&what, 1, 100)
        #else
        Darwin.poll(&what, 1, 100)
        #endif
    }

    /// The program ended: what it wrote is passed on, and no more.
    func finish() {
        try? pipe.fileHandleForWriting.close()
        ended.withLock { isEnded = true }
        done.wait()
        try? pipe.fileHandleForReading.close()
    }
}

extension NativeOverlay {
    /// Inside: nothing of earlier builds is in the directory for temporary files. (In the sandbox: the build's code put there what it liked.)
    static func clearTemporary(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard try isInside(env), let path = env["TMPDIR"], path.hasPrefix("/") else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { try? FileManager.default.removeItem(atPath: "\(path)/\(name)") }
    }

    /// Whether `ctx` is an overlay's that is built on this Mac, and this xless the one outside.
    static func isOutside(_ ctx: Context) throws -> Bool {
        guard MacNative.isMac, ctx.hasPrepare else { return false }
        return try !isInside()
    }

    /// Of `ctx`, with what the sandbox is for.
    init(_ ctx: Context, stage: Stage, env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let overlay = ctx.configFile, let source = ctx.sourceRoot, let work = ctx.workRoot else {
            throw XlessError(stage, "not an overlay", fix: "report this as an xless bug")
        }
        self.init(source: source, overlay: overlay, work: work, paths: ctx.paths, checkout: Self.checkout(of: source, env: env),
                  xcode: try XcodeFinder(environment: env).find(pin: ctx.config.xcode, stage: stage), env: env)
        inputs = ctx.cargo.map { CargoInputs.hostMounts($0.inputs, sourceRoot: source, env: env).map { ($0.name, $0.path.path) } } ?? []
    }

    /// Runs `stages` inside.
    static func build(_ ctx: Context, options: ProjectOptions, distribution: Distribution? = nil, stages: [Stage], output: FileHandle) async throws {
        guard let first = stages.first, let last = stages.last else { return }
        let native = try await withStage(first) {
            let native = try NativeOverlay(ctx, stage: first)
            if stages.contains(.prepare) { try native.prepareRust(ctx) }
            return native
        }
        var words = ["ship", "--platform", ctx.platform.rawValue, "--config", native.overlay.path, "--source", native.source.path,
                     "--destination", options.destination.rawValue, "--from", first.rawValue, "--to", last.rawValue]
        if let distribution { words += ["--distribution", distribution.rawValue] }
        try native.run(words, buildNumber: ctx.buildOverride ?? (ctx.config.buildScheme == .dated ? ctx.config.build : nil), output: output)
    }

    /// The user's own rustup gets the targets that it lacks: in the sandbox nothing can write there.
    private func prepareRust(_ ctx: Context) throws {
        let targets: [String], directory: URL
        if let cargo = ctx.cargoBuild { (targets, directory) = (cargo.rustTargets, source) }
        else if let mac = ctx.tauriMac { (targets, directory) = (TauriMacEnvironment.targets, source.appendingPathComponent(mac.tauriDir)) }
        else if let tauri = ctx.tauri { (targets, directory) = ([TauriEnvironment.target], source.appendingPathComponent(tauri.tauriDir)) }
        else { return }
        try RustApple.prepareNative(source: source, searchFrom: directory, toolchain: ctx.cargo?.toolchain, targets: targets, env: env, log: Self.say)
    }

    /// The top of the git checkout that `source` is in, and its git directory where that is elsewhere (a worktree's).
    static func checkout(of source: URL, env: [String: String]) -> [String] {
        func ask(_ word: String) -> String? {
            let answer = (try? WorkCopy.git(source, ["rev-parse", word], baseEnvironment: env, stage: .prepare))?.trimmingCharacters(in: .newlines)
            return answer.flatMap { $0.isEmpty ? nil : $0.hasPrefix("/") ? $0 : source.appendingPathComponent($0).standardizedFileURL.path }.map(BuildSandbox.real)
        }
        let top = ask("--show-toplevel") ?? BuildSandbox.real(source.path)
        return [top] + [ask("--git-common-dir")].compactMap { $0 }.filter { !BuildSandbox.isBelow($0, top) }
    }
}
