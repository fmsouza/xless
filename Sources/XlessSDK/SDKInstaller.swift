import Foundation
import XlessCore

/// `xless sdk install` and a native `xless setup`: the Darwin SDK into xtool's config directory (`DarwinSDKLocator`) and
/// its toolchain-meta.json to `ToolchainMeta.defaultLocation`. Everything is staged next to the destinations (same
/// filesystem) and swapped in only after it all succeeded, so a failure leaves any existing SDK and metadata untouched.
public enum SDKInstaller {
    /// `populate` fills the two staging paths (the bundle directory and the metadata file) and returns the staged
    /// `darwin.artifactbundle`. Returns where the SDK and the metadata now are.
    @discardableResult
    public static func install(env: [String: String] = ProcessInfo.processInfo.environment,
                               populate: (_ sdkStage: URL, _ metaStage: URL) throws -> URL) throws -> (sdk: URL, meta: URL) {
        let fm = FileManager.default
        let metaDest = ToolchainMeta.defaultLocation(env: env)
        let sdkDest = DarwinSDKLocator.bundle(env: env)
        let id = UUID().uuidString
        let sdkStage = sdkDest.deletingLastPathComponent().appendingPathComponent(".xless-staging-\(id)")
        let metaStage = metaDest.deletingLastPathComponent().appendingPathComponent(".xless-staging-\(id).json")
        defer { try? fm.removeItem(at: sdkStage); try? fm.removeItem(at: metaStage) }
        try fm.createDirectory(at: sdkDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: metaDest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let stagedBundle = try populate(sdkStage, metaStage)
        _ = try ToolchainMeta.load(from: metaStage)
        guard fm.fileExists(atPath: stagedBundle.path) else {
            throw XlessError(.sdk, "no darwin.artifactbundle was produced", fix: "check the SDK source and rerun")
        }
        try swap(stagedBundle, into: sdkDest)
        try swap(metaStage, into: metaDest)
        return (sdkDest, metaDest)
    }

    /// From an export: `xtool sdk install <darwin.xtoolsdk>` against a private config root (it deletes an existing SDK
    /// before installing), and a copy of the metadata. `xtool`: the xtool to run (a native setup's own, by path).
    /// `toolchain`: a Swift toolchain root (a native setup's own, `<root>/usr/bin/swiftc`) put first on xtool's PATH, as
    /// xtool runs `swiftc` from PATH and a native setup's toolchain is on no PATH yet.
    @discardableResult
    public static func install(xtoolsdk: URL, meta: URL, xtool: String = "xtool", toolchain: URL? = nil,
                               env: [String: String] = ProcessInfo.processInfo.environment) throws -> (sdk: URL, meta: URL) {
        _ = try ToolchainMeta.load(from: meta)
        var xtoolEnv: [String: String?] = [:]
        if let toolchain { xtoolEnv["PATH"] = path(toolchain: toolchain, env: env) }
        return try install(env: env) { sdkStage, metaStage in
            xtoolEnv["XDG_CONFIG_HOME"] = sdkStage.path
            try Shell.run(xtool, ["sdk", "install", xtoolsdk.path], env: xtoolEnv, baseEnvironment: env, stage: .sdk, passthrough: true)
            try FileManager.default.copyItem(at: meta, to: metaStage)
            return DarwinSDKLocator.bundle(env: ["XDG_CONFIG_HOME": sdkStage.path])
        }
    }

    /// `env`'s PATH with the toolchain's `usr/bin` first.
    static func path(toolchain: URL, env: [String: String]) -> String {
        let bin = toolchain.appendingPathComponent("usr/bin").path
        guard let rest = env["PATH"], !rest.isEmpty else { return "\(bin):/usr/local/bin:/usr/bin:/bin" }
        return "\(bin):\(rest)"
    }

    private static func swap(_ staged: URL, into dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: dest)
        }
    }
}
