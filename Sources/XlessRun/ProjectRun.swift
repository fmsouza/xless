import Foundation
import XlessCore

/// What `xless run` is started with, besides its arguments.
public struct RunContext: Sendable {
    /// This process's environment.
    public var environment: [String: String]
    /// The xless that the steps run.
    public var xless: String
    /// This command again, for a run that starts anew inside `xless session`.
    public var again: [String]
    /// xless's share directory.
    public var share: String
    /// `1`: in the images; `0`: natively; `auto`: in the images, unless an SDK is installed natively.
    public var useDocker: String
    /// The session this run is in (XLESS_SESSION): for the steps that read the store, and for nothing else.
    public var session: String?
    /// This is the start inside `xless session`.
    public var unlocked: Bool

    public init(environment: [String: String], xless: String, again: [String], share: String, useDocker: String, session: String?, unlocked: Bool) {
        self.environment = environment
        self.xless = xless
        self.again = again
        self.share = share
        self.useDocker = useDocker
        self.session = session
        self.unlocked = unlocked
    }
}

/// A run of a project: its build, signature and upload.
///
/// The app's build runs third-party code (npm scripts, build.rs, proc-macros, CocoaPods, Xcode build phases), so an overlay's
/// never runs next to a secret. Three steps, each its own container (or process, natively):
///   1. xless next-build            with the App Store Connect key only: the next dated build number (read-only).
///   2. xless ship --to finalize    WITHOUT any secret mount or variable: prepare, build, assets, finalize.
///   3. xless ship --from sign      with the secrets: sign, package, upload (no build code runs here).
/// The secrets a step needs are required only when that step runs. A project directory is one `xless ship`, with the secrets
/// unless it stops before sign. docs/signing-and-testflight.md has the rest.
public final class ProjectRun {
    let host: any RunHost
    let context: RunContext
    let arguments: [String]
    let cleanup: RunCleanup
    let files: RunFiles

    var request = RunRequest(target: .project("."))
    var environment: [String: String]
    /// Where the settings of `environment` may come from, for the messages.
    let environmentFile: String
    var dryRun = false
    var docker = false
    var xself: String
    var secrets = RunSecrets()
    var lock: WorkCopyLock?

    // in containers
    var dockerCLI = ["docker"]
    var dockerRun: [String] = []
    var architecture = ""
    /// The host folders that the build container (step 2) mounts: no secret may be inside one.
    var buildMounts: [String] = []

    var xcodePin: String?
    var xcodeTag: String?
    var pinFile = ""
    /// What `pinFile` held when the run began.
    private var pinned = Data()

    public init(_ arguments: [String], context: RunContext, host: any RunHost) {
        self.arguments = arguments
        self.context = context
        self.host = host
        cleanup = RunCleanup(host)
        environment = context.environment
        for name in ["XLESS_RUN_UNLOCKED", "XLESS_RUN_AS_SCRIPT", ChildProcess.session] { environment[name] = nil }
        environment["XLESS_USE_DOCKER"] = context.useDocker
        environment["XLESS_SHARE"] = context.share
        environment["XLESS_SELF"] = context.xless
        xself = context.xless
        let home = environment["HOME"] ?? NSHomeDirectory()
        files = RunFiles(host: host, home: home)
        environmentFile = Self.environmentFile(context.environment)
    }

    /// $XLESS_TESTFLIGHT_ENV, else ~/.config/xless/testflight.env.
    public static func environmentFile(_ environment: [String: String]) -> String {
        value(of: "XLESS_TESTFLIGHT_ENV", in: environment) ?? "\(environment["HOME"] ?? NSHomeDirectory())/.config/xless/testflight.env"
    }

    /// Runs it, to its exit code: xless's (2 for a usage or configuration error of the run itself).
    public func run() throws -> Int32 {
        let code: Int32
        do {
            try host.onStop { [cleanup] code in cleanup.stop(code) }
            code = try start()
        } catch let stop as RunStop {
            if let message = stop.message { host.say(message) }
            code = stop.code
        } catch {
            cleanup.finish()
            throw error
        }
        cleanup.finish()
        return code
    }

    private func start() throws -> Int32 {
        request = try RunRequest.parse(arguments)
        switch request.target {
        case .project(let given):
            guard files.isFile("\(given)/xless.yml") else { throw RunStop.usage("\(given)/xless.yml not found (is '\(given)' an xless project?)") }
            let project = files.absolute(given)
            pinFile = "\(project)/xless.yml"
            try readEnvironmentFile()
            return try run(project: project, top: try readTop())
        case .overlay(let given):
            let path = files.expanded(given) // e.g. `make testflight CONFIG=~/…` under zsh
            guard files.isFile(path) else { throw RunStop.usage("overlay \(path) not found") }
            pinFile = files.absolute(path)
            try readEnvironmentFile()
            return try run(overlay: pinFile, top: try readTop())
        }
    }

    // MARK: - The environment and the configuration

    /// testflight.env: data, never run. What it names wins over the environment.
    private func readEnvironmentFile() throws {
        if files.isFile(environmentFile) {
            let text: String
            do { text = try String(contentsOfFile: environmentFile, encoding: .utf8) } catch { throw RunStop.usage("cannot read \(environmentFile)") }
            do {
                for (name, value) in try EnvFile.parse(text, environment: environment) where name != ChildProcess.session { environment[name] = value }
            } catch let problem as EnvFile.Problem {
                throw RunStop.usage("\(environmentFile), line \(problem.line) \(problem.what): the file is read as NAME=value lines, and nothing in it is run")
            }
            // Once per run: not again in its start inside a session.
            if !context.unlocked {
                host.say("note: \(environmentFile) still works, but xless.yml (teamID) and the secret store hold all of it now: move it with `xless secrets import-env`")
            }
        }
        xself = setting("XLESS_SELF") ?? "xless"
        dryRun = request.dryRun || environment["XLESS_TESTFLIGHT_DRY_RUN"] == "1"
    }

    /// The value of a variable that is set to something.
    func setting(_ name: String) -> String? { value(of: name, in: environment) }

    private func readTop() throws -> RunTop {
        let top: RunTop
        do {
            pinned = try Data(contentsOf: URL(fileURLWithPath: pinFile))
            guard let text = String(data: pinned, encoding: .utf8) else { throw RunStop.usage("\(pinFile) is not UTF-8 text") }
            top = try RunTop(yaml: text)
        } catch let stop as RunStop { throw stop } catch {
            throw XlessError(.config, "\(pinFile) is not valid YAML: \(error)", fix: "fix it (docs/configuration.md)")
        }
        xcodePin = top["xcode"]
        if let pin = xcodePin {
            xcodeTag = RunText.xcodeTag(pin)
            if xcodeTag == nil { throw RunStop.usage("xcode: '\(pin)' in \(pinFile) is not an Xcode version (e.g. xcode: \"26.2\")") }
        }
        return top
    }

    /// Where it runs: in the images, or natively.
    func chooseDocker() throws {
        switch environment["XLESS_USE_DOCKER"].flatMap({ $0.isEmpty ? nil : $0 }) ?? "auto" {
        case "1": docker = true
        case "0": docker = false
        case "auto":
            let meta = setting("XLESS_TOOLCHAIN_META") ?? "\(setting("XDG_CONFIG_HOME") ?? "\(files.home)/.config")/xless/toolchain-meta.json"
            docker = !FileManager.default.fileExists(atPath: meta) || !has(xself)
        default: throw RunStop.usage("XLESS_USE_DOCKER must be 0, 1 or unset")
        }
    }

    func has(_ program: String) -> Bool { host.program(program, path: environment["PATH"]) != nil }

    // MARK: - Processes

    /// What a step sees of the environment: nothing secret, unless it is the one that uses it.
    enum Sees {
        case nothing
        /// The two IDs of the App Store Connect key, for `docker run -e NAME`.
        case identifiers
        case everything
    }

    /// The variables that hold a secret, or the path of one: xless's own, and the passwords the configuration names.
    var secretVariables: [String] {
        SecretEnvironment.names + secrets.demoNames.flatMap { name in
            let base = name.prefix { $0 != "@" }
            return [name, "\(name)_FILE", "\(base)", "\(base)_FILE"]
        }
    }

    func environment(_ sees: Sees, told: Bool = false) -> [String: String] {
        var out = environment
        if sees != .everything {
            for name in secretVariables where sees != .identifiers || !["ASC_KEY_ID", "ASC_ISSUER_ID"].contains(name) { out[name] = nil }
        }
        if told { out[ChildProcess.session] = context.session }
        return out
    }

    /// Asks a program something: its exit code and what it printed. Not a step of the run.
    func ask(_ words: [String], quiet: Bool = false) -> (code: Int32, output: String) {
        guard let started = try? cleanup.start(RunStep(words, environment: environment(.nothing), output: .captured, quiet: quiet)) else { return (127, "") }
        let answer = host.finish(started)
        cleanup.change { $0.job = nil }
        return answer
    }

    /// A step: to its exit code, and what it printed when that is `captured` or `both`. A dry run prints it instead.
    @discardableResult
    func step(_ words: [String], _ sees: Sees, told: Bool = false, directory: String? = nil, output: RunStep.Output = .shown, shown: [String]? = nil,
              adding: [String: String] = [:], without: [String] = []) -> (code: Int32, output: String) {
        if dryRun {
            host.show(RunText.commandLine(shown ?? words))
            return (0, "")
        }
        let environment = environment(sees, told: told).merging(adding) { $1 }.filter { !without.contains($0.key) }
        let step = RunStep(words, environment: environment, directory: directory, output: output)
        let started: StartedStep
        do { started = try cleanup.start(step) } catch {
            host.say("testflight: cannot run \(words[0]): \(error)")
            return (127, "")
        }
        lock?.note(job: started.pid)
        let result = host.finish(started)
        cleanup.change { $0.job = nil }
        return result
    }

    func finished(_ code: Int32) -> Int32 {
        host.say(code == 0 ? "==> TestFlight delivery finished" : "==> xless exited with code \(code)")
        return code
    }

    func require(_ code: Int32, _ what: String = "") throws {
        if code != 0 { throw RunStop(code: code, message: "==> xless exited with code \(code)\(what)") }
    }

    /// Takes the lock of the work copy. In containers they carry its name, for the run that takes over if this one is killed.
    func holdWorkCopy(_ key: String) throws {
        if docker { dockerRun += ["--label", "xless.work=\(WorkCopyLock.hash(of: key))"] }
        guard !dryRun else { return }
        lock = try WorkCopyLock(key, home: files.home, docker: docker ? (dockerCLI, environment(.nothing)) : nil, host: host, cleanup: cleanup)
    }

    // MARK: - Containers

    func prepareDocker() throws {
        guard has("docker") else { throw RunStop.usage("docker is not installed (and no native xless is on PATH)") }
        var name = setting("DOCKER_CONTEXT")
        if name == nil, RunText.lines(ask(["docker", "context", "ls", "--format", "{{.Name}}"], quiet: true).output).contains("colima-xless") { name = "colima-xless" }
        architecture = host.architecture
        if let name { dockerCLI += ["--context", name] }
        // --pull=never: an image is one of this machine (chooseImages says which is missing), never a registry's.
        // --init: an init process forwards the stop signal docker run proxies to xless (which, as PID 1, would ignore it).
        // The label lets the clean-up find this run's containers.
        let label = "xless.run=\(host.processID).\(Int(host.now.timeIntervalSince1970))"
        dockerRun = dockerCLI + ["run", "--rm", "--pull=never", "--init", "--label", label]
        if !dryRun {
            let cli = dockerCLI, environment = environment(.nothing)
            cleanup.change { $0.containers = (cli, environment, label) }
        }
    }

    /// Where the overlay, or the project, is on this machine, for a container that uploads: the command it prints after that
    /// names it.
    func origin(_ path: String) -> [String] { ["-e", "XLESS_PROJECT_ORIGIN=\(path)"] }

    // MARK: - A project directory

    /// One `xless ship`. Secrets are mounted, and xless scrubs them from the environment of the tools it runs, but the files stay
    /// readable to package code (SwiftPM plugins and macros) built in the same container. In containers, with an image of the
    /// project's own (`image:`, XLESS_IMAGE), it is two: the build in that one without a secret, the rest in xless's own.
    private func run(project: String, top: RunTop) throws -> Int32 {
        let span = try RunSpan.project(request)
        let signs = span.to >= .sign
        try chooseDocker()
        try findSecrets(RunSecrets.Needs(next: false, signs: signs, uploads: span.to >= .upload), top: top)
        if setting("XLESS_BUILD_NUMBER") == nil { environment["XLESS_BUILD_NUMBER"] = "\(Int(host.now.timeIntervalSince1970) / 60)" }
        var images = RunImages.none, split = span
        if docker {
            try prepareDocker()
            try mountFiles(platform: .ios)
            split = try RunSpan.overlay(request)
            images = try chooseImages(top, builds: split.from <= .finalize, other: signs)
            if images.areTwo { try refuseSecretsInBuild(project) }
        } else { try unlockStore() }

        try holdWorkCopy(host.realPath(project) ?? project) // the project is its own work copy
        host.say("==> TestFlight: build number " + (span.buildNumberGiven ? "from --build-number" : environment["XLESS_BUILD_NUMBER"] ?? ""))
        var code: Int32 = 0
        if docker {
            if images.areTwo { buildMounts = [try files.real(project)] }
            try materialize()
            let configuration = try keepConfiguration(of: project, images)
            let run = dockerRun + ["--mount", RunText.bind(project, "/work")] + configuration, number = ["-e", "XLESS_BUILD_NUMBER"], platform = ["--platform", "ios"]
            let given = secrets.api + secrets.sign + storeMounts("sign") + origin(project)
            if images.areTwo {
                func stages(_ from: RunStage, _ to: RunStage) -> [String] { ["--from", from.name, "--to", to.name] + split.extra }
                if split.from <= .finalize {
                    code = step(run + ["-w", "/work"] + number + [images.build.reference, "xless", "ship"] + platform + stages(split.from, min(split.to, .finalize)), .nothing).code
                    if !configuration.isEmpty { sayChangedConfiguration() }
                }
                // in no directory that the build can write, and so with none of its files as a tool's configuration
                if code == 0, signs {
                    code = step(run + given + ["-w", "/"] + number + [images.secrets.reference, "xless", "ship", "--project", "/work"] + platform + stages(max(split.from, .sign), split.to), .identifiers).code
                }
            } else {
                code = step(run + given + ["-w", "/work"] + number + [images.secrets.reference, "xless", "ship"] + platform + span.extra, signs ? .identifiers : .nothing).code
                if !configuration.isEmpty { sayChangedConfiguration() }
            }
        } else if signs {
            code = step([xself, "ship", "--platform", "ios"] + span.extra, .everything, told: true, directory: project).code
        } else {
            code = step([xself, "ship", "--platform", "ios"] + span.extra, .nothing, directory: project, adding: ["XLESS_NO_SECRET_STORE": "1"]).code
        }
        if code == 0, !signs {
            host.say("==> TestFlight: stopped after \(span.to.name) (--to), nothing delivered")
            return 0
        }
        return finished(code)
    }

    /// The container that builds it without the secrets mounts the whole project.
    private func refuseSecretsInBuild(_ project: String) throws {
        let directory = try files.real(project)
        guard try !files.isBroad(directory) else {
            throw RunStop.usage("\(directory) would be mounted into the build container, and it is / or holds your home directory; keep the project in its own directory")
        }
        for (name, path) in secretFiles() where try files.file(path, isIn: directory) {
            throw RunStop.usage("\(name) (\(path)) is inside the project \(project), which is mounted into the build container; keep secrets out of it")
        }
    }
}

extension ProjectRun {
    /// The words that give a project's container its xless.yml as it was when the run began, read-only: the build's code can write
    /// everything else that is mounted, and the configuration decides what is signed for whom. It is kept in a directory of the run's
    /// own, outside of the project. (One container for all, with a project that holds that directory: there is nothing to keep apart.)
    private func keepConfiguration(of project: String, _ images: RunImages) throws -> [String] {
        func words(_ directory: String) -> [String] { ["--mount", RunText.bind("\(directory)/xless.yml", "/work/xless.yml", readOnly: true)] }
        let base = "\(files.home)/.cache/xless/run"
        var here = base
        while !FileManager.default.fileExists(atPath: here), here != "/" { here = RunFiles.parent(here) }
        guard try !files.directory(here, isIn: project) else {
            guard images.areTwo else { return [] }
            throw RunStop.usage("\(base), which holds the xless.yml of this run, is inside the project \(project), which is mounted into the build container; keep the project in its own directory")
        }
        if dryRun { return words("\(base)/<run>") }
        let directory = "\(base)/\((0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())"
        do {
            try cleanup.change { state in
                state.trees.append(directory)
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = "\(directory)/xless.yml"
                try pinned.write(to: URL(fileURLWithPath: file))
                // (a docker whose root is another user reads it)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file)
            }
        } catch { throw RunStop.usage("cannot write this run's copy of xless.yml in \(directory): \(error.localizedDescription)") }
        return words(directory)
    }

    private func sayChangedConfiguration() {
        guard !dryRun, (try? Data(contentsOf: URL(fileURLWithPath: pinFile))) != pinned else { return }
        host.say("==> warning: \(pinFile) is not what it was when this run began. The run keeps to what it was; look at what changed it before you run this project again")
    }
}

private func value(of name: String, in environment: [String: String]) -> String? {
    environment[name].flatMap { $0.isEmpty ? nil : $0 }
}
