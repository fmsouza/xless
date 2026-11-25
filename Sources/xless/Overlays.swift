import Foundation
import XlessASC
import XlessCargo
import XlessCore
import XlessReactNative
import XlessSign
import XlessTauri

// What the account commands read of an overlay (Tauri, cargo, React Native), where its models are compiled; OverlaysNotHere.swift is
// what they say elsewhere.

extension StoreProject {
    /// The overlay at `url`; its errors are the configuration's.
    static func overlay(_ url: URL) throws -> StoreProject {
        let text = try OverlayPaths.read(url)
        let name = OverlayPaths(overlay: url).name
        let label = "overlay \(url.lastPathComponent)"
        switch try OverlayKind.of(url) {
        case .tauri:
            let o = try TauriOverlay.parse(yaml: text, name: name)
            var ids: [Platform: String] = [:]
            if o.ios != nil || o.macos == nil { ids[.ios] = o.bundleID }
            if o.macos != nil { ids[.macos] = o.bundleID }
            return StoreProject(bundleIDs: ids, team: o.teamID, name: label)
        case .cargo:
            let o = try CargoOverlay.parse(yaml: text, name: name)
            var ids: [Platform: String] = [:]
            if let ios = o.ios { ids[.ios] = ios.bundleID ?? o.bundleID }
            if let mac = o.macos { ids[.macos] = mac.bundleID ?? o.bundleID }
            return StoreProject(bundleIDs: ids, team: o.teamID, name: label)
        case .reactNative:
            let o = try ReactNativeOverlay.parse(yaml: text, name: name)
            return StoreProject(bundleIDs: o.appTargetGuess.flatMap { o.bundleIDs[$0] }.map { [.ios: $0] } ?? [:], team: o.teamID, name: label)
        }
    }
}

extension StoreDirOption {
    /// The overlay's work copy, where its builds leave their records.
    static func workRoot(_ overlay: URL, env: [String: String]) -> URL { OverlayPaths(overlay: overlay, env: env).workRoot }
}

extension RunSecretNames {
    /// The `testflight:` block of the overlay at `config`.
    static func overlay(_ config: URL, platform: Platform) throws -> TestFlightConfig? {
        let text = try OverlayPaths.read(config)
        let name = OverlayPaths(overlay: config).name
        switch try OverlayKind.of(config) {
        case .reactNative: return platform == .ios ? try ReactNativeOverlay.parse(yaml: text, name: name).testflight : nil
        case .cargo: return try CargoOverlay.parse(yaml: text, name: name).testflight
        case .tauri: return platform == .ios ? try TauriOverlay.parse(yaml: text, name: name).testflight : nil
        }
    }
}

extension ProvisionInputs {
    /// An overlay: Tauri (iOS, and macOS with a `macos:` block), cargo (each platform block) or React Native (iOS; every
    /// bundle's entitlements from the last build's record when there is one). Relative entitlement paths resolve against
    /// the source tree (the work copy mirrors it).
    static func overlay(_ url: URL, source: String?, env: [String: String]) throws -> ProvisionInputs {
        switch try OverlayKind.of(url) {
        case .reactNative:
            let (overlay, sourceRoot, workRoot) = try ReactNativeOverlay.load(from: url, sourceOverride: source, env: env)
            let config = try ReactNativeProject.resolve(overlay: overlay, source: sourceRoot, work: workRoot).config
            var inputs = ProvisionInputs(team: config.teamID, targets: [], version: config.version, testflight: config.testflight)
            let record = StagePaths(project: workRoot, platform: .ios).root.appendingPathComponent("entitlements.json")
            guard FileManager.default.fileExists(atPath: record.path) else {
                inputs.targets = [SigningTarget(platform: .ios, distribution: .appStore, bundleID: config.bundleID(for: .ios), entitlements: [:], entitlementsKnown: false)]
                inputs.notes.append("the React Native app's entitlements are read from its last build (\(record.path)), and there is none yet: capabilities, app groups, iCloud containers and app extensions are not planned (run `xless build --config \(url.path) --platform ios` first, then plan again)")
                return inputs
            }
            for entry in try SignTargets.recorded(record) {
                let target = SigningTarget(platform: .ios, distribution: .appStore, bundleID: entry.bundleID,
                                             entitlements: prepared(entry.entitlements, team: config.teamID, rewrites: overlay.entitlements),
                                             extensionPath: entry.path.isEmpty ? nil : entry.path)
                if entry.path.isEmpty { inputs.targets.insert(target, at: 0) } else { inputs.targets.append(target) }
            }
            return inputs
        case .cargo:
            let (overlay, sourceRoot, _) = try CargoOverlay.load(from: url, sourceOverride: source, env: env)
            var inputs: ProvisionInputs?
            for p in Platform.allCasesOrdered where (p == .ios ? overlay.ios : overlay.macos) != nil {
                let config = try CargoProject.resolve(overlay: overlay, platform: p, source: sourceRoot).config
                if inputs == nil { inputs = ProvisionInputs(team: config.teamID, targets: [], version: config.version, testflight: config.testflight) }
                inputs?.targets += try targets(config, platform: p, root: sourceRoot)
            }
            guard let inputs else {
                throw XlessError(.config, "overlay \(overlay.name) has neither an ios: nor a macos: block", fix: "add the platform the app is built for")
            }
            return inputs
        case .tauri:
            let loc = try OverlayLocation.load(from: url, sourceOverride: source, env: env)
            var configs: [(Platform, ProjectConfig)] = []
            if loc.overlay.ios != nil || loc.overlay.macos == nil { configs.append((.ios, try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot).config)) }
            if loc.overlay.macos != nil { configs.append((.macos, try TauriProject.resolveMac(overlay: loc.overlay, source: loc.sourceRoot).config)) }
            let first = configs[0].1
            var inputs = ProvisionInputs(team: first.teamID, targets: [], version: first.version, testflight: first.testflight)
            for (p, config) in configs { inputs.targets += try targets(config, platform: p, root: loc.sourceRoot) }
            return inputs
        }
    }
}
