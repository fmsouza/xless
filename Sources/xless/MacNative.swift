import Foundation
import XlessAssets
import XlessBuild
import XlessCore
import XlessSDK

/// A native build on a Mac: the Xcode that is installed there, found and checked once per command, and what of xless's own goes with
/// it. Off a Mac there is none (`here` is nil): xless.yml projects build there as they always did.
struct MacNative: Sendable {
    let xcode: InstalledXcode
    let meta: ToolchainMeta
    /// `swift --version`'s first line.
    let compiler: String
    let tools: NativeTools

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private static let found = Found()

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var native: MacNative?
        func value(_ make: () throws -> MacNative) throws -> MacNative {
            try lock.withLock {
                if let native { return native }
                let made = try make()
                native = made
                return made
            }
        }
    }

    /// The one for an xless.yml project, whose overlays build in the images; nil off a Mac. It says once which Xcode and tools it is.
    static func here(for ctx: Context, stage: Stage) throws -> MacNative? {
        guard isMac, !ctx.hasPrepare else { return nil }
        return try found.value {
            let native = try find(pin: ctx.config.xcode, stage: stage)
            say("\(native.xcode.summary); \(native.tools.summary(of: native.xcode))")
            return native
        }
    }

    static func find(pin: String?, stage: Stage, env: [String: String] = ProcessInfo.processInfo.environment) throws -> MacNative {
        let tools = try NativeTools(setting: env["XLESS_TOOLS"])
        let xcode = try XcodeFinder(environment: env).find(pin: pin, stage: stage)
        do {
            let os = try Shell.run("/usr/bin/sw_vers", ["-buildVersion"], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = try ToolchainMetaCollector.collect(xcodeApp: xcode.app, buildMachineOSBuild: os)
            let swift = try xcode.require("swift", stage: .sdk)
            let compiler = try Shell.run(swift.path, ["--version"], env: xcode.environment(env), baseEnvironment: env, stage: .sdk).stdout
            return MacNative(xcode: xcode, meta: meta, compiler: compiler.split(separator: "\n").first.map(String.init) ?? "", tools: tools)
        } catch let e as XlessError {
            throw XlessError(stage, "\(xcode.summary) cannot build: \(e.cause)",
                             fix: "open that Xcode once (it installs what is missing and asks for its license), or choose another one with DEVELOPER_DIR")
        }
    }

    /// What the app was built with, for finalize (`BuildSDKRecord`).
    func record(pin: String?) -> BuildSDKRecord {
        let swift = meta.swiftVersion.map { BuildSwiftRecord(version: $0, root: xcode.toolchain.path, compiler: compiler, xcodeSwiftVersion: $0) }
        return BuildSDKRecord(pin: pin, toolchain: meta, swift: swift)
    }

    func assets(simulator: Bool, env: [String: String] = ProcessInfo.processInfo.environment) throws -> XcodeAssets {
        XcodeAssets(actool: try tools.program(.actool, of: xcode, stage: .assets), ibtool: try tools.program(.ibtool, of: xcode, stage: .assets),
                    environment: xcode.environment(env), simulator: simulator)
    }

    /// The whole simulator build: the app with its assets, signed ad hoc (no identity, no key, no keychain), as the simulator asks of an
    /// arm64 app.
    func buildForSimulator(_ ctx: Context) async throws -> URL {
        let app = try XcodePackageBuilder.build(project: ctx.project, config: ctx.config, paths: ctx.paths, destination: .simulator, xcode: xcode)
        try await AssetsStage.compile(into: app, platform: .ios, config: ctx.config, project: ctx.project, xcode: assets(simulator: true),
                                      profile: { try XcodeToolsProfile.forImage(meta: meta, stage: .assets) })
        let nested = (try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Frameworks"), includingPropertiesForKeys: nil)) ?? []
        for code in nested.sorted(by: { $0.path < $1.path }) + [app] {
            try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", code.path], stage: .build)
        }
        return app
    }

    /// What `xless run` needs, before it asks anything or builds.
    @Sendable static func prepare(pin: String?, signs: Bool) throws {
        _ = try XcodeFinder().find(pin: pin, stage: .build)
        if signs { try prepareSigner() }
    }

    // MARK: - The signer

    /// rcodesign, as on Linux: it signs with the key of the secret store from a file that only this user can read and that is gone
    /// seconds later. (`codesign` takes a key from a keychain only, where every program of this user could use it.) It is fetched by
    /// the first command that needs it, checked against its pin, and first on PATH from here on; another one on PATH is not used.
    static func prepareSigner(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard isMac else { return }
        let layout = NativeLayout(env: env)
        let signer = try signer(env: env, layout: layout)
        let program = signer.final.appendingPathComponent("rcodesign")
        if !FileManager.default.isExecutableFile(atPath: program.path) {
            try withLock(layout.tools.appendingPathComponent("rcodesign.lock")) { // another run's fetch, waited for
                guard !FileManager.default.isExecutableFile(atPath: program.path) else { return }
                say("fetching rcodesign (\(signer.url.lastPathComponent)), which signs, once, into \(signer.final.path)")
                try SetupCommand.install(signer, layout: layout, again: "run it again")
            }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if path != signer.final.path, !path.hasPrefix(signer.final.path + ":") { setenv("PATH", "\(signer.final.path):\(path)", 1) }
    }

    private static func withLock(_ file: URL, _ body: () throws -> Void) throws {
        #if os(macOS)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw XlessError(.sdk, "cannot open \(file.path): \(String(cString: strerror(errno)))", fix: "check the directory's permissions") }
        defer { close(fd) } // which unlocks it
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        #endif
        try body()
    }

    static func signer(env: [String: String], layout: NativeLayout) throws -> NativeDownload {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let table = KnownXcodes.parseEnv((try? String(contentsOf: XlessShare.root(env: env, executable: exe).appendingPathComponent("versions.env"), encoding: .utf8)) ?? "")
        return try NativeSetupPlan.rcodesign(arch: SetupCommand.hostArch, mac: true, table: table, layout: layout)
    }

    private static func say(_ line: String) { FileHandle.standardError.write(Data("xless: \(line)\n".utf8)) }
}
