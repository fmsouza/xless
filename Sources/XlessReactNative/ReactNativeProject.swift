import Foundation
import XlessCore
import XlessXcode

/// A React Native overlay resolved into the pipeline's `ProjectConfig`. Until a `prepare` has succeeded (Expo CNG apps
/// commit no `ios/`), what only the Xcode project knows is provisional: the app target is the overlay's guess
/// (`ReactNativeOverlay.appTargetGuess`), the product its name, the minimum iOS version Expo SDK 57's default.
/// `Context` resolves again after `prepare`.
public struct ResolvedReactNative: Sendable {
    public var config: ProjectConfig
    /// Relative to the source root.
    public var appDir: String
    public var appTarget: String
    /// Where `version` came from: `overlay`, `app.json` or `package.json`.
    public var versionSource: String
}

public enum ReactNativeProject {
    /// Expo SDK 57's default deployment target, used until the generated project says otherwise.
    static let defaultMinimumOS = "16.4"

    /// Recorded by a successful `prepare` (its inputs' fingerprint): the work copy's native project is complete.
    static func stateFile(work: URL) -> URL { work.appendingPathComponent(".xless/rn-prepare.json") }

    /// Never fails because of the work copy's native project: a stale or half-written `ios/` (another scheme after an
    /// `env` change, an interrupted `pod install`, another configuration) is what the next `prepare` replaces, so it
    /// may not stop that prepare. The project is read only after a successful prepare, and any error reading it falls
    /// back to the provisional values with a note.
    public static func resolve(overlay: ReactNativeOverlay, source: URL, work: URL) throws -> ResolvedReactNative {
        let (version, versionSource) = try self.version(overlay: overlay, appDir: source.appendingPathComponent(overlay.appDir))
        var appTarget = overlay.appTargetGuess
        var product: String? = nil
        var minimumOS = defaultMinimumOS
        if FileManager.default.fileExists(atPath: stateFile(work: work).path) {
            do {
                let native = try self.native(overlay: overlay, work: work)
                (appTarget, product, minimumOS) = (native.appTarget, native.product ?? native.appTarget, native.minimumOS ?? defaultMinimumOS)
            } catch {
                let cause = (error as? XlessError)?.cause ?? "\(error)"
                log("the work copy's Xcode project is not usable (\(cause)); using the overlay's values until prepare regenerates it")
            }
        }
        guard let appTarget, let bundleID = overlay.bundleIDs[appTarget] else {
            let known = overlay.bundleIDs.keys.sorted().joined(separator: ", ")
            throw XlessError(.config, appTarget.map { "bundleIDs has no entry for the app target \($0) (it has \(known))" }
                                 ?? "cannot tell which bundleIDs entry is the app (\(known)) before the Xcode project exists",
                             fix: "name the app target in bundleIDs; Expo names it like the scheme (\(overlay.scheme))")
        }
        let dated = overlay.build == "dated"
        let config = ProjectConfig(
            bundleID: bundleID, teamID: overlay.teamID, version: version,
            build: dated ? "\(version).2000010101" : overlay.build,   // placeholder; Context chooses the real value when a run starts
            platforms: [.ios: PlatformConfig(minimumOS: minimumOS, product: product ?? appTarget)],
            // Without the overlay's, the app's own (Expo writes one from its config): finalize checks it is in the bundle.
            assets: nil, privacyManifest: overlay.privacyManifest ?? "PrivacyInfo.xcprivacy", infoPlist: nil, launchStoryboard: nil,
            testflight: overlay.testflight, usesNonExemptEncryption: overlay.usesNonExemptEncryption,
            buildScheme: dated ? .dated : .fixed, xcode: overlay.xcode, provisioningUpdates: overlay.provisioningUpdates)
        try config.validate()
        return ResolvedReactNative(config: config, appDir: overlay.appDir, appTarget: appTarget, versionSource: versionSource)
    }

    /// What the generated project says: the scheme's app target, its product name and deployment target.
    static func native(overlay: ReactNativeOverlay, work: URL) throws -> (appTarget: String, product: String?, minimumOS: String?) {
        let ios = work.appendingPathComponent(overlay.appDir).appendingPathComponent("ios")
        let ws = try XcodeWorkspace.load(workspaceURL(ios: ios, scheme: overlay.scheme, stage: .config))
        let app = try appTarget(ws, scheme: overlay.scheme, stage: .config)
        let settings = try TargetSettings(project: app.project, target: app.target, configuration: overlay.configuration, overrides: [:])
        let name = app.target.name
        return (name, try settings.raw("PRODUCT_NAME").map { try settings.expand($0, context: "\(name)'s PRODUCT_NAME") },
                try settings.raw("IPHONEOS_DEPLOYMENT_TARGET").map { try settings.expand($0, context: "\(name)'s IPHONEOS_DEPLOYMENT_TARGET") })
    }

    /// The overlay's `version`, else `expo.version` of the app's `app.json`, else its `package.json` `version`. An app
    /// whose version is computed (`app.config.js`) or carries a pre-release suffix must name it in the overlay.
    static func version(overlay: ReactNativeOverlay, appDir: URL) throws -> (String, String) {
        if let v = overlay.version { return (v, "overlay") }
        func json(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: appDir.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let candidates: [(String?, String)] = [((json("app.json")?["expo"] as? [String: Any])?["version"] as? String, "app.json"),
                                               (json("package.json")?["version"] as? String, "package.json")]
        guard let (found, source) = candidates.first(where: { $0.0 != nil }).map({ ($0.0!, $0.1) }) else {
            throw XlessError(.config, "cannot determine the app version (no expo.version in app.json, no version in package.json)",
                             fix: "set version: in the overlay")
        }
        guard found.wholeMatch(of: /\d+(\.\d+){0,2}/) != nil else {
            throw XlessError(.config, "the app version '\(found)' (\(source)) is not 1–3 dot-separated integers, as CFBundleShortVersionString must be",
                             fix: "set version: in the overlay (the version the app's config computes, e.g. without a pre-release suffix)")
        }
        return (found, source)
    }

    /// The `.xcworkspace` in `ios`: the only one, or the one named like the scheme.
    static func workspaceURL(ios: URL, scheme: String, stage: Stage) throws -> URL {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: ios.path)) ?? []).filter { $0.hasSuffix(".xcworkspace") }.sorted()
        if names.count == 1 { return ios.appendingPathComponent(names[0]) }
        if names.contains("\(scheme).xcworkspace") { return ios.appendingPathComponent("\(scheme).xcworkspace") }
        throw XlessError(stage, names.isEmpty ? "no .xcworkspace in \(ios.path)" : "several workspaces in \(ios.path) and none is named \(scheme).xcworkspace",
                         fix: names.isEmpty ? "run xless prepare first (expo prebuild and pod install write it)" : "remove the stale workspaces from the work copy")
    }

    /// The scheme's application target (exactly one).
    static func appTarget(_ ws: Workspace, scheme name: String, stage: Stage) throws -> (project: XcodeProject, target: Target) {
        let apps = try restage(stage) { try ws.buildTargets(of: ws.scheme(named: name)) }.filter { $0.target.productType == "com.apple.product-type.application" }
        guard apps.count == 1 else {
            throw XlessError(stage, "scheme \(name) builds \(apps.count) application targets (\(apps.map(\.target.name).joined(separator: ", ")))",
                             fix: "name a scheme that builds one app")
        }
        return apps[0]
    }

    /// Product types of bundles signed on their own when embedded in an app.
    static let embeddedBundleTypes: Set<String> = [
        "com.apple.product-type.app-extension", "com.apple.product-type.extensionkit-extension", "com.apple.product-type.application",
        "com.apple.product-type.application.watchapp2", "com.apple.product-type.application.watchapp2-container",
        "com.apple.product-type.application.on-demand-install-capable",
    ]

    /// The bundle targets `app` embeds through its Copy Files phases (an extension's `.appex` into PlugIns), and the
    /// ones those embed, in phase order.
    static func embeddedTargets(_ app: (project: XcodeProject, target: Target), in ws: Workspace) -> [(project: XcodeProject, target: Target)] {
        var out: [(XcodeProject, Target)] = []
        var queue = [app]
        var seen = Set([PIFWriter.targetGUID(app.target, in: app.project, workspace: ws)])
        while !queue.isEmpty {
            let (project, target) = queue.removeFirst()
            for phase in target.phases {
                guard case .copyFiles = phase.kind else { continue }
                for file in phase.files {
                    guard case .reference(let id) = file.item else { continue }
                    var found: (XcodeProject, Target)?
                    if let t = project.producingTarget(ofProduct: id) {
                        found = (project, t)
                    } else if let proxy = project.referenceProxies[id], let url = project.resolvedPath(of: proxy.containerPortalID),
                              let other = ws.project(at: url), let t = other.producingTarget(ofProduct: proxy.remoteProductID) {
                        found = (other, t)
                    }
                    guard let (p, t) = found, let type = t.productType, embeddedBundleTypes.contains(type),
                          seen.insert(PIFWriter.targetGUID(t, in: p, workspace: ws)).inserted else { continue }
                    out.append((p, t))
                    queue.append((p, t))
                }
            }
        }
        return out
    }
}
