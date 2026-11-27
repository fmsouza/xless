import Foundation
import XlessCore
import XlessXcode

/// `xless inspect --config <react-native overlay>`: a read-only, stable text report of what a build would do, in the
/// layout of the Tauri report (`InspectReport`): one `key: value` per line, sections in a fixed order, no absolute paths.
/// What only the generated Xcode project knows (targets, the original bundle IDs, Swift packages) is read from the work
/// copy when `prepare` has run, and reported as missing otherwise.
public enum ReactNativeInspectReport {
    /// The generated project, when it exists: the workspace (path relative to the work copy) and whether `ios/` is tracked.
    public struct Native {
        public var workspace: Workspace
        public var relativePath: String
        public init(workspace: Workspace, relativePath: String) { self.workspace = workspace; self.relativePath = relativePath }
    }

    /// Loads the generated workspace of the work copy; nil before a successful `prepare`, or (with a note on stderr)
    /// when the project is stale or incomplete, which the next prepare replaces.
    public static func native(overlay: ReactNativeOverlay, work: URL) -> Native? {
        guard FileManager.default.fileExists(atPath: ReactNativeProject.stateFile(work: work).path) else { return nil }
        do {
            let url = try ReactNativeProject.workspaceURL(ios: work.appendingPathComponent(overlay.appDir).appendingPathComponent("ios"),
                                                          scheme: overlay.scheme, stage: .config)
            return Native(workspace: try XcodeWorkspace.load(url), relativePath: ReactNativeBuilder.relative(url, to: work))
        } catch {
            log("the work copy's Xcode project is not usable (\((error as? XlessError)?.cause ?? "\(error)")); reporting the overlay only")
            return nil
        }
    }

    public static func make(resolved r: ResolvedReactNative, overlay o: ReactNativeOverlay, contract: ReactNativeContract.Detected,
                            native: Native?, nextBuild: String?) -> String {
        var out: [String] = []
        func section(_ name: String, _ lines: [String]) { out.append("[\(name)]"); out += lines; out.append("") }
        func list(_ items: [String]) -> String { items.isEmpty ? "(none)" : items.joined(separator: ", ") }
        let ios = r.config.platforms[.ios]
        let pending = "(run xless prepare to generate the Xcode project)"

        section("project", [
            "overlay: \(o.name)",
            "appDir: \(o.appDir)",
            "scheme: \(o.scheme)",
            "configuration: \(o.configuration)",
            "appTarget: \(r.appTarget)",
            "bundleID: \(r.config.bundleID)",
            "teamID: \(r.config.teamID)",
            "version: \(r.config.version) (\(r.versionSource))",
            "product: \(ios?.product ?? "(none)")\(native == nil ? " \(pending)" : "")",
            "minimumOS: \(ios?.minimumOS ?? "(none)")\(native == nil ? " \(pending)" : "")",
            "env: \(list(o.env.keys.sorted()))",
            "privacyManifest: \(o.privacyManifest.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(the app's own)")",
            "usesNonExemptEncryption: \(r.config.usesNonExemptEncryption.map { String($0) } ?? "(unset)")",
            "allowMissingCommands: \(list(o.allowMissingCommands))",
        ])

        section("prepare", ["run: \(o.prepareRun.isEmpty ? "(none)" : "")"] + o.prepareRun.map { "  | \($0)" })

        let notInstalled = "(not installed: run xless prepare)"
        let status = contract.inContract ? "in contract" : [contract.reactNative, contract.expo, contract.cocoaPods, contract.bundler].contains(nil)
            ? "incomplete" : "OFF CONTRACT"
        section("contract", [
            "supported: react-native \(ReactNativeContract.reactNative).x, expo SDK \(ReactNativeContract.expoSDK), cocoapods \(ReactNativeContract.cocoaPods), bundler \(ReactNativeContract.bundler)",
            "react-native: \(contract.reactNative ?? notInstalled)",
            "expo: \(contract.expo ?? notInstalled)",
            "cocoapods: \(contract.cocoaPods ?? "(no Gemfile.lock)")",
            "bundler: \(contract.bundler ?? "(no Gemfile.lock)")",
            "status: \(status)",
        ])

        var bundleLines: [String] = []
        if let native, let app = try? ReactNativeProject.appTarget(native.workspace, scheme: o.scheme, stage: .config) {
            let ws = native.workspace
            let scheme = try? ws.scheme(named: o.scheme)
            let built = (scheme.flatMap { try? ws.buildTargets(of: $0) } ?? []).map(\.target.name)
            let embedded = ReactNativeProject.embeddedTargets(app, in: ws)
            section("workspace", [
                "workspace: \(native.relativePath)",
                "projects: \(list(ws.projects.map(\.name)))",
                "schemeTargets: \(list(built))",
                "embeds: \(list(embedded.map { "\($0.target.name) (\($0.target.productType.map { $0.replacingOccurrences(of: "com.apple.product-type.", with: "") } ?? "?"))" }))",
            ])
            for (p, t) in [app] + embedded {
                let original = (try? TargetSettings(project: p, target: t, configuration: o.configuration, overrides: [:]))
                    .flatMap { s in try? s.raw("PRODUCT_BUNDLE_IDENTIFIER").map { try s.expand($0, context: t.name) } } ?? "(unset)"
                bundleLines.append("\(t.name): \(o.bundleIDs[t.name] ?? "MISSING") (project: \(original))")
            }
            for name in o.bundleIDs.keys.sorted() where !([app] + embedded).contains(where: { $0.target.name == name }) {
                bundleLines.append("\(name): \(o.bundleIDs[name]!) (NOT EMBEDDED: no such target in the app)")
            }
            let packages: [String]
            do { packages = try XcodePackageList.lines(ws).map { $0.replacingOccurrences(of: "\t", with: " ") } } catch let e as XlessError {
                packages = ["(\(e.cause))"]
            } catch { packages = ["(\(error))"] }
            section("bundleIDs", bundleLines)
            section("packages", packages.isEmpty ? ["(none)"] : packages)
        } else {
            section("workspace", ["workspace: \(pending)"])
            section("bundleIDs", o.bundleIDs.keys.sorted().map { "\($0): \(o.bundleIDs[$0]!)\($0 == r.appTarget ? " (app)" : "")" })
            section("packages", [pending])
        }

        section("build", [
            "scheme: \(r.config.buildScheme == .dated ? "dated" : "fixed")",
            "number: \(r.config.buildScheme == .dated ? "(chosen when a build starts)" : r.config.build)",
            "next: \(nextBuild ?? "(needs App Store Connect credentials)")",
            "signing: none at build (CODE_SIGNING_ALLOWED=NO); entitlements recorded in .xless/build/ios/entitlements.json",
            "xcode: \(o.xcode.map { "\"\($0)\" (prepare and build use that Xcode's pack, and stop without one)" } ?? "not pinned (the newest Xcode there is a pack of)")",
            "identifiers.replace: \(o.identifiers.isEmpty ? "none" : "\(o.identifiers.map.count) identifier(s), in entitlements (sign) and Info.plist string values (finalize)")",
        ])
        out.removeLast()
        return out.joined(separator: "\n") + "\n"
    }
}
