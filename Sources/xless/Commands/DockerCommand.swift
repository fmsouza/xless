import ArgumentParser
import Foundation
import XlessCore

/// `xless run`: a project's build, sign and upload by running the share's scripts/testflight.sh, natively (what
/// `xless setup` installed) or, with `--docker`, in the local images (`xless setup --docker`). The other arguments go
/// to the script unchanged. The process is replaced (execvp), so the script's exit code is the user's and its
/// environment (the App Store Connect variables, which `Shell.run` would scrub) reaches it as the user set it.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build, sign and ship a project natively, or in the local xless images with --docker.",
        discussion: """
        Usage: xless run [--docker] [<project-dir> | --config <overlay.yml>] [testflight.sh options …] [-- xless ship args]

        Runs <share>/scripts/testflight.sh with the other arguments unchanged, XLESS_SHARE set to the share directory and \
        XLESS_SELF to this xless executable, and XLESS_USE_DOCKER=1 with --docker, else 0 (an XLESS_USE_DOCKER already \
        set wins over the default, not over --docker). Natively on Linux it builds xless.yml projects; Tauri, plain Cargo \
        and React Native overlays (--config) build in the images: add --docker. \
        Example: xless run MyApp --build-number 1 --to finalize
        """)

    @Argument(parsing: .allUnrecognized, help: "--docker, a project directory or --config <overlay.yml>, then testflight.sh's options.")
    var arguments: [String] = []

    func run() throws {
        let (docker, rest) = Self.split(arguments)
        let env = ProcessInfo.processInfo.environment
        let useDocker = docker ? "1" : env["XLESS_USE_DOCKER"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        #if os(Linux)
        if useDocker == "0", Self.namesOverlay(rest) {
            throw XlessError(.config, "a --config overlay (Tauri, plain Cargo, React Native) builds in the xless images, not natively",
                             fix: "add --docker (after building the images once: xless setup --docker --xcode <Xcode.xip>)")
        }
        #endif
        try TestflightScript.exec(rest, useDocker: useDocker)
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
        try TestflightScript.exec(arguments, useDocker: env["XLESS_USE_DOCKER"].flatMap { $0.isEmpty ? nil : $0 } ?? "1")
    }
}

enum TestflightScript {
    /// Replaces this process with `bash <share>/scripts/testflight.sh <arguments>`.
    static func exec(_ arguments: [String], useDocker: String) throws {
        let env = ProcessInfo.processInfo.environment
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let share = try XlessShare.root(env: env, executable: exe)
        let script = share.appendingPathComponent("scripts/testflight.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            throw XlessError(.sdk, "\(script) does not exist", fix: "reinstall xless (see README) or set XLESS_SHARE")
        }
        setenv("XLESS_USE_DOCKER", useDocker, 1)
        setenv("XLESS_SHARE", share.path, 1)
        // The script runs xless (natively, and host-side helpers like `"$XLESS_SELF" cargo inputs`) as the one that started it.
        setenv("XLESS_SELF", exe.path, 1)
        let argv = ["bash", script] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        execvp("bash", cArgs)
        throw XlessError(.sdk, "cannot run bash: \(String(cString: strerror(errno)))", fix: "install bash")
    }
}
