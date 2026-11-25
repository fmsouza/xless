import ArgumentParser
import Foundation
import XlessCore
import XlessRun

/// `xless run`: a project's build, sign and upload, natively (what `xless setup` installed) or, with `--docker`, in the local
/// images (`xless setup --docker`).
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build, sign and ship a project natively, or in the local xless images with --docker.",
        discussion: """
        Usage: xless run [--docker] [<project-dir> | --config <overlay.yml>] [testflight.sh options …] [-- xless ship args]

        Runs <share>/scripts/testflight.sh with the other arguments unchanged, XLESS_SHARE set to the share directory and \
        XLESS_SELF to this xless executable, and XLESS_USE_DOCKER=1 with --docker, else 0 (an XLESS_USE_DOCKER already \
        set wins over the default, not over --docker). Natively on Linux it builds xless.yml projects; Tauri, plain Cargo \
        and React Native overlays (--config) build in the images: add --docker. Secrets not set in the environment or \
        ~/.config/xless/testflight.env come from the secret store (`xless secrets`); with --docker they are written to \
        a tmpfs for the run (--allow-disk-secrets where there is none, as on macOS). \
        Example: xless run MyApp --build-number 1 --to finalize
        """)

    @Argument(parsing: .allUnrecognized, help: "--docker, a project directory or --config <overlay.yml>, then testflight.sh's options.")
    var arguments: [String] = []

    func run() throws {
        let (docker, rest) = Self.split(arguments)
        let env = ProcessInfo.processInfo.environment
        let useDocker = docker ? "1" : env["XLESS_USE_DOCKER"].flatMap { $0.isEmpty ? nil : $0 } ?? (ProjectRunner.isScript(env) ? "auto" : "0")
        #if os(Linux)
        if useDocker == "0", !ProjectRunner.isScript(env), Self.namesOverlay(rest) {
            throw XlessError(.config, "a --config overlay (Tauri, plain Cargo, React Native) builds in the xless images, not natively",
                             fix: "add --docker (after building the images once: xless setup --docker --xcode <Xcode.xip>)")
        }
        #endif
        try ProjectRunner.run(rest, useDocker: useDocker)
    }

    /// `--docker` taken out of the arguments before a `--` (after it, the arguments are `xless ship`'s).
    static func split(_ arguments: [String]) -> (docker: Bool, rest: [String]) {
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        let head = arguments[..<end]
        return (head.contains("--docker"), head.filter { $0 != "--docker" } + arguments[end...])
    }

    /// The script's arguments name an overlay (`--config`), before any `--`.
    static func namesOverlay(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains { $0 == "--config" || $0.hasPrefix("--config=") }
    }
}

/// `xless docker`: `xless run --docker`, kept for scripts written before `xless run` (an XLESS_USE_DOCKER already set
/// still wins, as it always did).
struct DockerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docker",
        abstract: "Build, sign and ship a project in the local xless images (the same as xless run --docker).",
        discussion: """
        Usage: xless docker [<project-dir> | --config <overlay.yml>] [testflight.sh options …] [-- xless ship args]

        Runs <share>/scripts/testflight.sh with the arguments unchanged, with XLESS_USE_DOCKER=1 unless you set it, \
        XLESS_SHARE set to the share directory and XLESS_SELF to this xless executable. Example: xless docker MyApp --build-number 1 --to finalize
        """)

    @Argument(parsing: .allUnrecognized, help: "A project directory or --config <overlay.yml>, then testflight.sh's options.")
    var arguments: [String] = []

    func run() throws {
        let env = ProcessInfo.processInfo.environment
        try ProjectRunner.run(arguments, useDocker: env["XLESS_USE_DOCKER"].flatMap { $0.isEmpty ? nil : $0 } ?? "1")
    }
}

/// What `xless run` and `xless docker` do: the steps of the run as processes of their own (`XlessRun`), each with nothing secret
/// that it does not use.
enum ProjectRunner {
    /// Set by scripts/testflight.sh, kept for those who call it: the run is in the images unless an SDK is installed natively
    /// (XLESS_USE_DOCKER unset), and the steps run $XLESS_SELF, as that script's always did.
    static let asScript = "XLESS_RUN_AS_SCRIPT"

    static func isScript(_ env: [String: String]) -> Bool { env[asScript] == "1" }

    /// Runs it; ends with its exit code.
    static func run(_ arguments: [String], useDocker: String) throws {
        let env = ProcessInfo.processInfo.environment
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let share = try XlessShare.root(env: env, executable: exe)
        // It reads no secret's value, but passes some on (from its environment to the step that uses them).
        SecretScope.enter()
        let context = RunContext(environment: env, xless: isScript(env) ? env["XLESS_SELF"].flatMap { $0.isEmpty ? nil : $0 } ?? "xless" : exe.path,
                                 again: [exe.path] + CommandLine.arguments.dropFirst(), share: share.path, useDocker: useDocker,
                                 session: XlessSession.agent, unlocked: !(env["XLESS_RUN_UNLOCKED"] ?? "").isEmpty)
        let code = try ProjectRun(arguments, context: context, host: PosixRunHost()).run()
        if code != 0 { throw ExitCode(code) }
    }
}
