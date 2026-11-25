import Foundation
import XlessASC
import XlessCore
import XlessSign

// What `xless provision` reads before it asks Apple anything: the bundles the project signs (and their entitlements),
// the distribution lanes, the TestFlight groups and the `appstore/` manifest (docs/apple-account.md#xless-provision).

struct ProvisionInputs: @unchecked Sendable {
    var team: String
    /// App targets first per platform (iOS, then macOS), extensions after their app.
    var targets: [SigningTarget]
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
    static func targets(_ config: ProjectConfig, platform: Platform, root: URL, rewrites: EntitlementRewrites = .none) throws -> [SigningTarget] {
        let pc = try config.platform(platform)
        func entitlements(_ path: String?) throws -> [String: Any] {
            let raw = try path.map { try Plist.read(isAbsolute($0) ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0), stage: .account) } ?? [:]
            return prepared(raw, team: config.teamID, rewrites: rewrites)
        }
        let distribution = config.distribution(for: platform)
        let app = SigningTarget(platform: platform, distribution: distribution, bundleID: config.bundleID(for: platform), entitlements: try entitlements(pc.entitlements))
        return [app] + (try pc.extensions.map {
            SigningTarget(platform: platform, distribution: distribution, bundleID: $0.bundleID, entitlements: try entitlements($0.entitlements), extensionPath: $0.path)
        })
    }

    private static func isAbsolute(_ path: String) -> Bool {
        #if os(Windows)
        return UserPaths.isOnDrive(path)
        #else
        return path.hasPrefix("/")
        #endif
    }

    static func prepared(_ raw: [String: Any], team: String, rewrites: EntitlementRewrites) -> [String: Any] {
        Entitlements.rewrite(Entitlements.expandSigningPrefixes(raw, teamID: team), with: rewrites)
    }
}

extension Platform {
    /// iOS first, then macOS: the order the plan lists them in.
    static var allCasesOrdered: [Platform] { [.ios, .macos] }
}
