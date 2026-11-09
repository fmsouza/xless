import Foundation
import XlessCore

/// A `type: cargo` overlay resolved for one platform into the pipeline's `ProjectConfig`.
public struct ResolvedCargo: Sendable {
    /// Holds only the requested platform.
    public var config: ProjectConfig
    public var platform: CargoPlatform
    /// The version as Cargo or the overlay states it, prerelease included (`0.2.0-rc.1`); `config.version` is `0.2.0`.
    public var fullVersion: String
    /// The overlay's `plistVars`: values for the `@NAME@` placeholders of the app's Info.plist (`CargoBundler.infoPlist`).
    public var plistVars: [String: String] = [:]
}

public enum CargoProject {
    /// `distribution`: `--distribution` for this run (macOS: `app-store` for the TestFlight lane); the overlay has no
    /// such key, so without it macOS stays `developer-id` and iOS `app-store`.
    public static func resolve(overlay: CargoOverlay, platform: Platform, source: URL, distribution: Distribution? = nil) throws -> ResolvedCargo {
        guard let block = platform == .ios ? overlay.ios : overlay.macos else {
            throw XlessError(.config, "overlay \(overlay.name) has no \(platform.rawValue): block",
                             fix: "add a \(platform.rawValue): block naming the cargo package to build, or build the other platform")
        }
        let fullVersion = try overlay.version ?? CargoManifest.version(package: block.package, source: source)
        // App Store Connect and Info.plist want 1–3 integers: drop `-prerelease` and `+build` metadata.
        guard let short = fullVersion.prefixMatch(of: /\d+(\.\d+){0,2}/).map({ String($0.0) }),
              fullVersion.dropFirst(short.count).first.map({ $0 == "-" || $0 == "+" }) ?? true else {
            throw XlessError(.config, "version '\(fullVersion)' of package \(block.package) is not a release version number",
                             fix: "use 1–3 dot-separated integers with an optional -prerelease, or set version: in the overlay")
        }
        let ios = platform == .ios
        let dated = overlay.build == "dated"
        var config = ProjectConfig(
            bundleID: overlay.bundleID, teamID: overlay.teamID, version: short,
            // Placeholder; Context chooses the real value when a run starts (macOS-only builds use minute resolution).
            build: dated ? "\(short).\(ios ? "2000010101" : "200001010000")" : overlay.build,
            platforms: [platform: PlatformConfig(minimumOS: block.minimumOS, product: block.product, entitlements: block.entitlements,
                                                 distribution: ios ? .appStore : .developerID, bundleID: block.bundleID)],
            assets: block.assets, privacyManifest: ios ? overlay.privacyManifest : nil, infoPlist: block.infoPlist,
            testflight: ios ? overlay.testflight : nil, usesNonExemptEncryption: overlay.usesNonExemptEncryption,
            buildScheme: dated ? .dated : .fixed, xcode: overlay.xcode)
        config = try config.overridingDistribution(distribution, for: platform)
        // The macOS App-Store lane ends in TestFlight like iOS does; a DMG has none.
        if !ios, config.distribution(for: .macos) == .appStore { config.testflight = overlay.testflight }
        try config.validate()
        return ResolvedCargo(config: config, platform: block, fullVersion: fullVersion, plistVars: overlay.plistVars)
    }
}
