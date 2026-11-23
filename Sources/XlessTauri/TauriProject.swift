import Foundation
import XlessCore

/// A Tauri app's config and Xcode project resolved into the pipeline's `ProjectConfig`.
public struct ResolvedTauri: @unchecked Sendable {
    public var config: ProjectConfig
    public var tauri: TauriConfig
    public var target: XcodeGenTarget
    /// Relative to the repository root.
    public var tauriDir: String
    public var appleDir: String
    /// The `project.yml` `name` (`tauri ios init` uses the Cargo package name); Tauri's `TAURI_IOS_APP_NAME`.
    public var projectName: String = ""
}

/// A Tauri app's desktop config resolved into the pipeline's `ProjectConfig` (macOS; there is no Xcode project).
public struct ResolvedTauriMac: @unchecked Sendable {
    public var config: ProjectConfig
    public var tauri: TauriConfig
    /// Relative to the repository root.
    public var tauriDir: String
    /// Tauri's `mainBinaryName`; nil means the cargo package's binary name (known from `cargo metadata` at build time).
    public var mainBinaryName: String?
}

public enum TauriProject {
    public static func resolve(overlay: TauriOverlay, source: URL) throws -> ResolvedTauri {
        let tauriDir = overlay.tauriDir
        let appleDir = "\(tauriDir)/gen/apple"
        let tauri = try TauriConfig.load(tauriDir: source.appendingPathComponent(tauriDir), platform: "ios")

        let ymlPath = "\(appleDir)/project.yml"
        guard let yaml = try? String(contentsOf: source.appendingPathComponent(ymlPath), encoding: .utf8) else {
            throw XlessError(.prepare, "cannot read \(ymlPath) in \(source.path)", fix: "run `tauri ios init` in the app repository and commit gen/apple")
        }
        let (projectName, target) = try XcodeGenProject.parse(yaml: yaml, file: ymlPath)

        func need(_ what: String, _ key: String) -> XlessError {
            XlessError(.config, "cannot determine \(what) for overlay \(overlay.name)", fix: "set \(key) in the overlay")
        }
        guard let version = overlay.version ?? tauri.version ?? (target.infoProperties["CFBundleShortVersionString"] as? String) else {
            throw need("the app version", "version")
        }
        guard let product = overlay.ios?.product ?? target.settings["PRODUCT_NAME"] ?? tauri.productName else {
            throw need("the product name", "ios.product")
        }
        guard let minimumOS = overlay.ios?.minimumOS ?? tauri.iosMinimumSystemVersion ?? target.deploymentTarget else {
            throw need("the minimum iOS version", "ios.minimumOS")
        }
        let dated = overlay.build == "dated"
        let entitlements = overlay.ios?.entitlements ?? target.entitlementsPath.map { "\(appleDir)/\($0)" }
        let assets = overlay.assets ?? target.sources.first { $0.path.hasSuffix(".xcassets") }.map { "\(appleDir)/\($0.path)" }
        let storyboard = overlay.launchStoryboard ?? target.sources.first { $0.path.hasSuffix(".storyboard") }.map { "\(appleDir)/\($0.path)" }

        let config = ProjectConfig(
            bundleID: overlay.bundleID, teamID: overlay.teamID, version: version,
            build: dated ? "\(version).2000010101" : overlay.build,   // placeholder; Context chooses the real value when a run starts
            platforms: [.ios: PlatformConfig(minimumOS: minimumOS, product: product, entitlements: entitlements, extensions: overlay.ios?.extensions ?? [])],
            assets: assets, privacyManifest: overlay.privacyManifest, infoPlist: overlay.infoPlist ?? "\(appleDir)/\(target.infoPath)", launchStoryboard: storyboard,
            testflight: overlay.testflight, usesNonExemptEncryption: overlay.usesNonExemptEncryption,
            buildScheme: dated ? .dated : .fixed, xcode: overlay.xcode)
        try config.validate()
        return ResolvedTauri(config: config, tauri: tauri, target: target, tauriDir: tauriDir, appleDir: appleDir, projectName: projectName)
    }

    /// The macOS counterpart of `resolve`: `tauri.conf.json` + `tauri.macos.conf.json`, no `project.yml`.
    public static func resolveMac(overlay: TauriOverlay, source: URL) throws -> ResolvedTauriMac {
        let tauriDir = overlay.tauriDir
        let tauri = try TauriConfig.load(tauriDir: source.appendingPathComponent(tauriDir), platform: "macos")
        func need(_ what: String, _ key: String) -> XlessError {
            XlessError(.config, "cannot determine \(what) for overlay \(overlay.name)", fix: "set \(key) in the overlay")
        }
        guard let version = overlay.version ?? tauri.version else { throw need("the app version", "version") }
        guard let product = overlay.macos?.product ?? tauri.productName else { throw need("the product name", "macos.product") }
        let minimumOS = overlay.macos?.minimumOS ?? tauri.macOSMinimumSystemVersion ?? "10.13"
        let dated = overlay.build == "dated"
        // Tauri resolves bundle.macOS.entitlements against the Tauri directory; the overlay's is already absolute.
        let entitlements = tauri.macOSEntitlements.map { $0.hasPrefix("/") ? $0 : "\(tauriDir)/\($0)" } ?? overlay.macos?.entitlements

        let config = ProjectConfig(
            bundleID: overlay.bundleID, teamID: overlay.teamID, version: version,
            build: dated ? "\(version).200001010000" : overlay.build,   // placeholder; Context chooses the real value when a run starts
            platforms: [.macos: PlatformConfig(minimumOS: minimumOS, product: product, entitlements: entitlements, distribution: .developerID)],
            // Only `macos.infoPlist`: the top-level `infoPlist` is the iOS target's (Xcode placeholders, UIKit keys).
            assets: nil, privacyManifest: nil, infoPlist: overlay.macos?.infoPlist, launchStoryboard: nil,
            testflight: nil, usesNonExemptEncryption: overlay.usesNonExemptEncryption,
            buildScheme: dated ? .dated : .fixed, xcode: overlay.xcode)
        try config.validate()
        return ResolvedTauriMac(config: config, tauri: tauri, tauriDir: tauriDir, mainBinaryName: tauri.mainBinaryName)
    }
}
