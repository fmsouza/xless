import Foundation
import XlessAssets
import XlessBuild
import XlessCore
import XlessSDK
import XlessSign

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

    /// The one for an xless.yml project or, in its sandbox, an overlay's (`NativeOverlay`); nil off a Mac. It says once which Xcode and
    /// tools it is.
    static func here(for ctx: Context, stage: Stage) throws -> MacNative? {
        guard isMac, try !ctx.hasPrepare || NativeOverlay.isInside() else { return nil }
        return try found.value {
            let native = try find(pin: ctx.config.xcode, stage: stage)
            if !ctx.hasPrepare { say("\(native.xcode.summary); \(native.tools.summary(of: native.xcode))") }
            return native
        }
    }

    static func find(pin: String?, stage: Stage, env: [String: String] = ProcessInfo.processInfo.environment) throws -> MacNative {
        let tools = try NativeTools(setting: env["XLESS_TOOLS"])
        let xcode = try XcodeFinder(environment: env).find(pin: pin, stage: stage)
        do {
            let os = try Shell.run("/usr/bin/sw_vers", ["-buildVersion"], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = try ToolchainMetaCollector.collect(xcodeApp: xcode.app, buildMachineOSBuild: os, environment: xcode.environment(env))
            let swift = try xcode.require(.swift, stage: .sdk)
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
    @Sendable static func prepare(pin: String?, builds: Bool, signs: Bool) throws {
        if builds { _ = try XcodeFinder().find(pin: pin, stage: .build) }
        if signs { try prepareSigner() }
    }

    // MARK: - The signer

    /// rcodesign, as on Linux: it signs with the key of the secret store from a file that only this user can read and that is gone
    /// seconds later. (`codesign` takes a key from a keychain only, where every program of this user could use it.) It is fetched by
    /// the first command that needs it, and checked by each (`MacSigner`).
    static func prepareSigner(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard isMac else { return }
        let signer = try signer(env: env)
        RCodesign.use(try signer.prepare { url, file in
            say("fetching rcodesign (\(url.lastPathComponent)), which signs, once, into \(signer.download.final.path)")
            do {
                try Shell.run("/usr/bin/curl", ["-fsSL", "--retry", "3", "--proto", "=https", "-o", file.path, url.absoluteString], stage: .sdk)
            } catch let e as XlessError {
                throw XlessError(.sdk, "cannot download \(url.absoluteString): \(e.cause)", fix: "check the network, then run it again")
            }
        })
    }

    static func signer(env: [String: String]) throws -> MacSigner {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let table = KnownXcodes.parseEnv((try? String(contentsOf: XlessShare.root(env: env, executable: exe).appendingPathComponent("versions.env"), encoding: .utf8)) ?? "")
        return try MacSigner(env: env, arch: SetupCommand.hostArch, table: table)
    }

    private static func say(_ line: String) { FileHandle.standardError.write(Data("xless: \(line)\n".utf8)) }
}
