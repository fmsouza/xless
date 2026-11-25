import Foundation
import XlessCargo
import XlessCore
import XlessTauri

/// What `xless next-build --config` (and `xless tauri next-build`) print: the build number the next run of an overlay
/// would use. `compute(version, bundleID)` is the dated App Store Connect query (`DatedBuildNumber.compute`); it is
/// called only for `build: dated`, and a fixed build is returned as it is.
public enum NextBuild {
    public typealias Compute = @Sendable (_ version: String, _ bundleID: String) async throws -> String

    /// Dispatches on the overlay's `type:` (`OverlayKind`): `react-native`, `cargo`, anything else as a Tauri overlay.
    public static func forOverlay(at url: URL, sourceOverride: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                                  compute: Compute) async throws -> String {
        switch try OverlayKind.of(url) {
        case .reactNative:
            let (overlay, source, work) = try ReactNativeOverlay.load(from: url, sourceOverride: sourceOverride, env: env)
            return try await ReactNativeProject.nextBuild(overlay: overlay, source: source, work: work, compute: compute)
        case .cargo:
            return try await cargo(at: url, sourceOverride: sourceOverride, env: env, compute: compute)
        case .tauri:
            return try await tauri(at: url, sourceOverride: sourceOverride, env: env, compute: compute)
        }
    }

    /// A cargo overlay: its iOS app (`ios.bundleID`, else `bundleID`) and the version `CargoProject.resolve` gives (the
    /// overlay's `version:`, else the package's Cargo.toml in the source, without a prerelease suffix).
    static func cargo(at url: URL, sourceOverride: String?, env: [String: String], compute: Compute) async throws -> String {
        let (overlay, source, _) = try CargoOverlay.load(from: url, sourceOverride: sourceOverride, env: env)
        guard overlay.ios != nil else {
            throw XlessError(.config, "overlay \(overlay.name) has no ios: block; next-build is for iOS (App Store Connect build numbers)",
                             fix: "macOS builds choose their dated build number locally: run the build without next-build")
        }
        let resolved = try CargoProject.resolve(overlay: overlay, platform: .ios, source: source)
        guard resolved.config.buildScheme == .dated else { return resolved.config.build }
        return try await compute(resolved.config.version, resolved.config.bundleID(for: .ios))
    }

    /// A Tauri overlay (`xless tauri next-build`): the iOS bundle ID and the version `tauri.conf.json` or the overlay gives.
    public static func tauri(at url: URL, sourceOverride: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                             compute: Compute) async throws -> String {
        let loc = try OverlayLocation.load(from: url, sourceOverride: sourceOverride, env: env)
        let resolved = try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot)
        guard resolved.config.buildScheme == .dated else { return resolved.config.build }
        return try await compute(resolved.config.version, resolved.config.bundleID(for: .ios))
    }
}

extension ReactNativeProject {
    /// The overlay is read without its work copy (step 1 of `xless run` has none): the version comes from the
    /// overlay's `version:`, else the app's app.json / package.json in the source; the bundle ID is the app target's
    /// `bundleIDs` entry (the one named like the scheme, or the only one).
    public static func nextBuild(overlay: ReactNativeOverlay, source: URL, work: URL, compute: NextBuild.Compute) async throws -> String {
        let resolved = try resolve(overlay: overlay, source: source, work: work)
        guard resolved.config.buildScheme == .dated else { return resolved.config.build }
        return try await compute(resolved.config.version, resolved.config.bundleID)
    }
}
