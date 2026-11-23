import Foundation
import Yams
import XlessCore
import XlessTauri

/// An xless overlay for a React Native / Expo iOS app (`type: react-native`). It lives outside the app repository.
/// Schema: docs/react-native.md ("The overlay"); samples/HelloRN/xless.overlay.yml describes every key too.
public struct ReactNativeOverlay: Sendable, Equatable {
    /// Overlay file basename without extension (names the work copy).
    public var name: String
    public var source: String?
    /// The app's directory (its `package.json`, `app.json`, `ios/`), relative to the source root; `.` for a single-app repository.
    public var appDir: String
    /// Variables for the app's own tooling (prepare commands, Expo prebuild, CocoaPods, the build's script phases),
    /// e.g. a switch an `app.config.js` reads.
    public var env: [String: String]
    /// The shared Xcode scheme to build (Expo names it after the app target).
    public var scheme: String
    public var configuration: String
    /// Xcode target name → bundle identifier. It names the app target and every app extension the app embeds.
    public var bundleIDs: [String: String]
    public var teamID: String
    /// The marketing version; nil means the app's `app.json` `expo.version`, else its `package.json` `version`.
    public var version: String?
    /// `"dated"` or an explicit build number.
    public var build: String
    /// Shell commands run in the work copy's root after the JS install, before Expo prebuild (an app's own config
    /// generator, for example). Run with `sh -c`, in order, with `env`.
    public var prepareRun: [String]
    /// Commands a build phase may find missing with only a warning (ruling R4: a missing command fails the build).
    /// A name matches the command as the shell reported it, or that path's last component.
    public var allowMissingCommands: [String]
    public var testflight: TestFlightConfig?
    public var usesNonExemptEncryption: Bool?
    /// PrivacyInfo.xcprivacy copied into the app, replacing the app's own; absolute after `ReactNativeOverlay.load`.
    public var privacyManifest: String?
    /// `identifiers: { replace: {…} }` (Ruling R9): another team's identifiers mapped to the signing team's, in every
    /// bundle's entitlements (sign; the simulator build's simulated entitlements) and every string value of every
    /// bundle's Info.plist (finalize; the simulator build before its ad-hoc signature).
    public var identifiers: IdentifierReplacement = .none
    /// `entitlements: { remove: […] }`: top-level keys dropped from every bundle's entitlements before signing.
    public var entitlementsRemove: [String] = []
    /// `xcode:` (Ruling R8): the Xcode whose SDK must build the app (`XcodePin`); nil: the image's SDK.
    public var xcode: String? = nil

    /// What the sign stage (and the simulator build) does to every bundle's entitlements.
    public var entitlements: EntitlementRewrites { EntitlementRewrites(replace: identifiers.map, remove: entitlementsRemove) }

    /// The overlay's entry for the app target when it can be told without the Xcode project: the entry named like
    /// the scheme (Expo names scheme and app target alike), else the only entry, else the one entry whose bundle ID
    /// every other entry's extends with a `.` (an extension's ID must, so this is the app's in a valid overlay; a
    /// committed `ios/` may name its scheme unlike its app target). The build checks it against the scheme.
    public var appTargetGuess: String? {
        if bundleIDs[scheme] != nil { return scheme }
        if bundleIDs.count == 1 { return bundleIDs.keys.first }
        let roots = bundleIDs.filter { candidate in
            bundleIDs.allSatisfy { $0.key == candidate.key || $0.value.hasPrefix(candidate.value + ".") }
        }
        return roots.count == 1 ? roots.first!.key : nil
    }

    /// Environment variables xless sets itself in prepare or build, which `env:` may not change.
    static let reservedEnvironment: Set<String> = [
        "PATH", "HOME", "SDKROOT", "DEVELOPER_DIR", "TAR_OPTIONS", "XCODE_EXTRA_PLATFORM_FOLDERS", "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        "BUNDLE_PATH", "COCOAPODS_ALLOW_ROOT", "COREPACK_HOME", "EXPO_NO_TELEMETRY", "EXPO_NO_GIT_STATUS", "CI",
    ]
}

private struct BuildNumber: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct Raw: Decodable {
    struct App: Decodable { var dir: String? }
    struct Prepare: Decodable { var run: [String]? }
    struct Entitlements: Decodable { var remove: [String]? }
    struct Identifiers: Decodable { var replace: [String: String]? }
    var type: String
    var source: String?
    var app: App?
    var env: [String: String]?
    var scheme: String
    var configuration: String?
    var bundleIDs: [String: String]
    var teamID: String
    var version: BuildNumber?
    var build: BuildNumber?
    var prepare: Prepare?
    var allowMissingCommands: [String]?
    var testflight: TestFlightConfig?
    var usesNonExemptEncryption: Bool?
    var privacyManifest: String?
    var entitlements: Entitlements?
    var identifiers: Identifiers?
    var xcode: String?
}

extension ReactNativeOverlay {
    static let keys: Set<String> = ["type", "source", "app", "env", "scheme", "configuration", "bundleIDs", "teamID", "version", "build",
                                    "prepare", "allowMissingCommands", "testflight", "usesNonExemptEncryption", "privacyManifest", "entitlements",
                                    "identifiers", "xcode"]
    static let nestedKeys: [String: Set<String>] = ["app": ["dir"], "prepare": ["run"], "entitlements": ["remove"], "identifiers": ["replace"]]

    public static func parse(yaml: String, name: String) throws -> ReactNativeOverlay {
        let schema = "see docs/react-native.md for the schema (samples/HelloRN/xless.overlay.yml is an example)"
        // Unknown keys are refused: a misspelt key (`bundleIds`, `app.directory`) would otherwise be dropped silently.
        if let top = try? Yams.load(yaml: yaml) as? [String: Any] {
            // Never released: refused with where the map went, rather than as an unknown key.
            if (top["entitlements"] as? [String: Any])?["replace"] != nil {
                throw XlessError(.config, "overlay \(name): entitlements.replace is now identifiers.replace",
                                 fix: "move the map to a top-level identifiers: { replace: { <old>: <new> } } (same rules); it rewrites every bundle's entitlements and, now, every string value of the app's and its extensions' Info.plists too")
            }
            for key in top.keys.sorted() where !keys.contains(key) {
                throw XlessError(.config, "overlay \(name): unknown key '\(key)'", fix: schema)
            }
            for (parent, allowed) in nestedKeys {
                for key in ((top[parent] as? [String: Any])?.keys).map(Array.init)?.sorted() ?? [] where !allowed.contains(key) {
                    throw XlessError(.config, "overlay \(name): unknown key '\(parent).\(key)'", fix: schema)
                }
            }
        }
        let raw: Raw
        do {
            raw = try YAMLDecoder().decode(Raw.self, from: yaml)
        } catch {
            throw XlessError(.config, "overlay \(name) is invalid: \(error)", fix: schema)
        }
        guard raw.type == "react-native" else {
            throw XlessError(.config, "overlay \(name): type '\(raw.type)' is not supported here", fix: "set type: react-native")
        }
        func invalid(_ what: String, _ fix: String) -> XlessError { XlessError(.config, "overlay \(name): \(what)", fix: fix) }

        if raw.teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw invalid("teamID '\(raw.teamID)' is not a 10-character Apple team ID", "copy it from developer.apple.com → Membership")
        }
        if raw.scheme.isEmpty || raw.scheme.contains("/") {
            throw invalid("scheme '\(raw.scheme)' is not a scheme name", "name the app's shared Xcode scheme (Expo: the app target's name)")
        }
        let configuration = raw.configuration ?? "Release"
        if configuration.isEmpty || configuration == "Debug" {
            throw invalid("configuration '\(configuration)' is not supported",
                          "use Release (or the app's own release configuration): debug builds load JavaScript from a Metro server")
        }
        let appDir = raw.app?.dir ?? "."
        if appDir.isEmpty || appDir.hasPrefix("/") || appDir.split(separator: "/").contains("..") {
            throw invalid("app.dir '\(appDir)' must be a relative path inside the source, without '..'", "e.g. app: { dir: apps/client }, or leave it out for a single-app repository")
        }

        if raw.bundleIDs.isEmpty {
            throw invalid("bundleIDs is empty", "map the app target (and each app extension target) to its bundle ID, e.g. bundleIDs: { MyApp: com.example.app }")
        }
        var seen: [String: String] = [:]
        for (target, id) in raw.bundleIDs.sorted(by: { $0.key < $1.key }) {
            if target.isEmpty { throw invalid("bundleIDs has an empty target name", "use the Xcode target names") }
            if id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
                throw invalid("bundleIDs.\(target) '\(id)' is invalid", "use reverse-DNS form, e.g. com.example.app")
            }
            if let other = seen[id] {
                throw invalid("bundleIDs.\(other) and bundleIDs.\(target) are both \(id)", "give every target its own bundle ID")
            }
            seen[id] = target
        }
        if let app = raw.bundleIDs[raw.scheme] {
            for (target, id) in raw.bundleIDs.sorted(by: { $0.key < $1.key }) where target != raw.scheme && !id.hasPrefix(app + ".") {
                throw invalid("bundleIDs.\(target) '\(id)' does not start with the app's bundle ID \(app) + '.'",
                              "App Store apps require it (Xcode's embedded-binary check refuses it too), e.g. \(app).\(target)")
            }
        }

        var env: [String: String] = [:]
        for (key, value) in raw.env ?? [:] {
            if key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) == nil {
                throw invalid("env name '\(key)' is not a variable name", "use letters, digits and _")
            }
            if reservedEnvironment.contains(key) || key.hasPrefix("XLESS_") || key.hasPrefix("SWIFT_") || SecretEnvironment.names.contains(key) {
                throw invalid("env.\(key) is set by xless itself", "remove it from env:")
            }
            env[key] = value
        }

        let version = raw.version?.value
        if let version, version.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw invalid("version '\(version)' is invalid", "use 1–3 dot-separated integers, e.g. 1.2.0")
        }
        let build = raw.build?.value ?? "dated"
        if build != "dated", build.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw invalid("build '\(build)' is invalid", "use dated, or 1–3 dot-separated integers")
        }
        let run = raw.prepare?.run ?? []
        if run.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw invalid("prepare.run has an empty command", "remove it")
        }
        let allow = raw.allowMissingCommands ?? []
        if allow.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
            throw invalid("allowMissingCommands has an empty or blank name", "list command names as a build log reports them, e.g. [PlistBuddy]")
        }
        let identifiers = IdentifierReplacement(raw.identifiers?.replace ?? [:])
        // A short or dot-less key (`com`, `app`) would rewrite unrelated values: replace whole identifiers.
        for (key, value) in identifiers.map.sorted(by: { $0.key < $1.key }) {
            if key.count < 4 || !key.contains(".") {
                throw invalid("identifiers.replace key '\(key)' is too broad", "replace a whole identifier (4+ characters with a '.'), e.g. replace: { com.other.app: com.example.app }")
            }
            if value.isEmpty {
                throw invalid("identifiers.replace.\(key) is empty", "give the identifier to use instead, or drop an entitlement with entitlements.remove")
            }
        }
        let remove = raw.entitlements?.remove ?? []
        if let key = remove.first(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
            throw invalid("entitlements.remove has an invalid key '\(key)'", "list entitlement keys, e.g. remove: [com.apple.developer.declared-age-range]")
        }
        if let pin = raw.xcode { try XcodePin.validate(pin, file: "overlay \(name)") }
        return ReactNativeOverlay(
            name: name, source: raw.source, appDir: appDir, env: env, scheme: raw.scheme, configuration: configuration,
            bundleIDs: raw.bundleIDs, teamID: raw.teamID, version: version, build: build, prepareRun: run,
            allowMissingCommands: allow, testflight: raw.testflight, usesNonExemptEncryption: raw.usesNonExemptEncryption,
            privacyManifest: raw.privacyManifest, identifiers: identifiers, entitlementsRemove: remove, xcode: raw.xcode)
    }

    /// Reads and parses the overlay at `url` (paths as for Tauri overlays, `OverlayPaths`).
    public static func load(from url: URL, sourceOverride: String? = nil,
                            env: [String: String] = ProcessInfo.processInfo.environment) throws -> (overlay: ReactNativeOverlay, sourceRoot: URL, workRoot: URL) {
        let text = try OverlayPaths.read(url)
        let paths = OverlayPaths(overlay: url, env: env)
        var overlay = try parse(yaml: text, name: paths.name)
        overlay.privacyManifest = overlay.privacyManifest.map { paths.resolve($0).path }
        return (overlay, try paths.sourceRoot(source: overlay.source, sourceOverride: sourceOverride), paths.workRoot)
    }
}
