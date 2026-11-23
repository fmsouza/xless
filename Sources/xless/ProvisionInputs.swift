import Foundation
import XlessASC
import XlessCargo
import XlessCore
import XlessReactNative
import XlessSign
import XlessTauri

// What `xless provision` reads before it asks Apple anything: the bundles the project signs (and their entitlements),
// the distribution lanes, the TestFlight groups and the `appstore/` manifest (docs/apple-account.md#xless-provision).

/// One bundle signed for one lane: the app of a platform, or an app extension (React Native: from the build's record;
/// xless.yml, Tauri, cargo: declared under `platforms.ios.extensions` / `ios.extensions`).
struct ProvisionTarget: @unchecked Sendable {
    var platform: Platform
    var distribution: Distribution
    var bundleID: String
    /// With the signing prefixes expanded (and a React Native overlay's rewrites applied), as `sign` sees them.
    var entitlements: [String: Any]
    /// An app extension's path in the app (`PlugIns/Widget.appex`); nil for the app.
    var extensionPath: String? = nil
    /// false when the entitlements could not be read (a React Native app before its first build): nothing is reported
    /// as drift against them.
    var entitlementsKnown = true

    var isApp: Bool { extensionPath == nil }
    /// `the iOS app`, `PlugIns/Widget.appex`.
    var label: String { extensionPath ?? "the \(platform.display) app" }

    /// The certificate this target is signed with.
    var signingKind: CertificateKind { distribution == .appStore ? .distribution : .developerID }
    var profileType: ProfileType { ProfileType.for(platform: platform, distribution: distribution) }
}

struct ProvisionInputs: @unchecked Sendable {
    var team: String
    /// App targets first per platform (iOS, then macOS), extensions after their app.
    var targets: [ProvisionTarget]
    var version: String
    var testflight: TestFlightConfig?
    /// The `appstore/` manifest directory, when it exists.
    var storeDir: URL?
    /// What could not be read and is left out, for the plan's notes.
    var notes: [String] = []

    /// The certificates the lanes sign with, in a stable order: iOS / Mac App Store → Apple Distribution (and the Mac
    /// Installer Distribution certificate for a Mac App Store package), Developer ID → Developer ID Application.
    var certificateKinds: [CertificateKind] {
        var kinds: [CertificateKind] = []
        for t in targets {
            var needed = [t.signingKind]
            if t.platform == .macos, t.distribution == .appStore { needed.append(.installer) }
            for k in needed where !kinds.contains(k) { kinds.append(k) }
        }
        return CertificateKind.allCases.filter(kinds.contains)
    }

    /// The bundle identifiers, each once, in target order.
    var bundleIDs: [String] {
        var out: [String] = []
        for t in targets where !out.contains(t.bundleID) { out.append(t.bundleID) }
        return out
    }

    /// The App Store app: the iOS app's bundle ID when iOS ships to the App Store, else the macOS app's when it does;
    /// nil when no lane goes to the App Store (Developer ID only: no app record, listing or TestFlight).
    var appStoreBundleID: String? {
        let apps = targets.filter { $0.isApp && $0.distribution == .appStore }
        return (apps.first { $0.platform == .ios } ?? apps.first)?.bundleID
    }

    /// The App Store platforms of the app record (`IOS`, `MAC_OS`): the App Store lanes whose app has that bundle ID.
    func appPlatforms(for bundleID: String) -> [String] {
        targets.filter { $0.isApp && $0.distribution == .appStore && $0.bundleID == bundleID }
            .map { $0.platform == .ios ? "IOS" : "MAC_OS" }
    }
}

extension ProvisionInputs {
    /// Reads xless.yml (`project`) or the overlay at `config`. No build number is settled and nothing is sent.
    /// - Parameter storeDir: `--dir`; default `appstore/` next to xless.yml or the overlay file.
    static func load(project: URL, config: URL?, source: String?, storeDir: String?, env: [String: String] = ProcessInfo.processInfo.environment) throws -> ProvisionInputs {
        var inputs: ProvisionInputs
        let base: URL
        if let config {
            inputs = try overlay(config, source: source, env: env)
            base = config.deletingLastPathComponent()
        } else {
            let file = project.appendingPathComponent("xless.yml")
            let parsed = try ProjectConfig.load(from: file)
            inputs = ProvisionInputs(team: parsed.teamID, targets: [], version: parsed.version, testflight: parsed.testflight)
            for p in Platform.allCasesOrdered where parsed.platforms[p] != nil {
                inputs.targets += try targets(parsed, platform: p, root: project)
            }
            base = project
        }
        let dir = storeDir.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? base.appendingPathComponent("appstore")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            inputs.storeDir = dir
        } else if storeDir != nil {
            throw XlessError(.account, "\(dir.path) is not a directory", fix: "point --dir at the appstore/ manifest (`xless store pull` writes one), or leave it out")
        }
        return inputs
    }

    /// The app of `platform` as the config describes it, then the app extensions it declares (`platforms.ios.extensions`),
    /// each signed for the app's lane with its own entitlements; relative entitlement paths resolve against `root`.
    static func targets(_ config: ProjectConfig, platform: Platform, root: URL, rewrites: EntitlementRewrites = .none) throws -> [ProvisionTarget] {
        let pc = try config.platform(platform)
        func entitlements(_ path: String?) throws -> [String: Any] {
            let raw = try path.map { try Plist.read($0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0), stage: .account) } ?? [:]
            return prepared(raw, team: config.teamID, rewrites: rewrites)
        }
        let distribution = config.distribution(for: platform)
        let app = ProvisionTarget(platform: platform, distribution: distribution, bundleID: config.bundleID(for: platform), entitlements: try entitlements(pc.entitlements))
        return [app] + (try pc.extensions.map {
            ProvisionTarget(platform: platform, distribution: distribution, bundleID: $0.bundleID, entitlements: try entitlements($0.entitlements), extensionPath: $0.path)
        })
    }

    static func prepared(_ raw: [String: Any], team: String, rewrites: EntitlementRewrites) -> [String: Any] {
        Entitlements.rewrite(Entitlements.expandSigningPrefixes(raw, teamID: team), with: rewrites)
    }

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
                inputs.targets = [ProvisionTarget(platform: .ios, distribution: .appStore, bundleID: config.bundleID(for: .ios), entitlements: [:], entitlementsKnown: false)]
                inputs.notes.append("the React Native app's entitlements are read from its last build (\(record.path)), and there is none yet: capabilities, app groups, iCloud containers and app extensions are not planned (run `xless build --config \(url.path) --platform ios` first, then plan again)")
                return inputs
            }
            for entry in try SignTargets.recorded(record) {
                let target = ProvisionTarget(platform: .ios, distribution: .appStore, bundleID: entry.bundleID,
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

extension Platform {
    /// iOS first, then macOS: the order the plan lists them in.
    static var allCasesOrdered: [Platform] { [.ios, .macos] }

    /// `iOS`, `macOS`.
    var display: String { self == .ios ? "iOS" : "macOS" }
}
