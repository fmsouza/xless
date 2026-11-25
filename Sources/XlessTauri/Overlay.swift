import Foundation
import Yams
import XlessCore

/// iOS-specific overrides in an overlay's `ios:` block.
public struct OverlayIOS: Sendable, Equatable, Decodable {
    public var product: String?
    public var minimumOS: String?
    public var entitlements: String?
    /// The app extensions the app embeds (entitlements relative to the source, like `entitlements`).
    public var extensions: [ExtensionConfig]?
}

/// macOS-specific overrides in an overlay's `macos:` block.
public struct OverlayMac: Sendable, Equatable, Decodable {
    public var product: String?
    public var minimumOS: String?
    /// `OverlayLocation.load` makes it absolute (relative paths resolve against the overlay file's directory).
    public var entitlements: String?
    /// A plist merged last into the macOS Info.plist. The top-level `infoPlist` is iOS-only (it carries Xcode
    /// placeholders such as `$(EXECUTABLE_NAME)`). `OverlayLocation.load` makes it absolute, like `entitlements`.
    public var infoPlist: String?
    /// Cargo features for the macOS build. When present (an empty list included) it replaces `tauri.features`, which
    /// may name iOS-only features; when absent, `tauri.features` applies.
    public var features: [String]?

    public init(product: String? = nil, minimumOS: String? = nil, entitlements: String? = nil, infoPlist: String? = nil, features: [String]? = nil) {
        self.product = product; self.minimumOS = minimumOS; self.entitlements = entitlements; self.infoPlist = infoPlist; self.features = features
    }
}

/// A prebuilt binary that replaces a CocoaPods dependency.
public struct BinaryDependency: Sendable, Equatable, Decodable {
    public struct Fixes: Sendable, Equatable, Decodable {
        public var minimumOSVersion: String?
    }
    public var url: String
    public var sha256: String
    public var extract: String
    public var to: String
    public var fixes: Fixes?
    /// Extra linker flags this dependency needs (consumed when linking the app).
    public var linkFlags: [String]

    enum CodingKeys: String, CodingKey { case url, sha256, extract, to, fixes, linkFlags }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256)
        extract = try c.decode(String.self, forKey: .extract)
        to = try c.decode(String.self, forKey: .to)
        fixes = try c.decodeIfPresent(Fixes.self, forKey: .fixes)
        linkFlags = try c.decodeIfPresent([String].self, forKey: .linkFlags) ?? []
    }
}

/// How a `project.yml` build script (other than Tauri's own) is treated.
public enum ScriptHandling: String, Sendable, Decodable { case ignore }

/// An xless overlay for a Tauri v2 iOS app (`type: tauri`). It lives outside the app repository.
public struct TauriOverlay: Sendable, Equatable {
    /// Overlay file basename without extension.
    public var name: String
    public var source: String?
    public var tauriDir: String
    public var features: [String]
    public var bundleID: String
    public var teamID: String
    /// nil (absent or `tauri`) means "take it from the Tauri config".
    public var version: String?
    /// `"dated"` or an explicit build number.
    public var build: String
    public var ios: OverlayIOS?
    public var macos: OverlayMac?
    public var assets: String?
    public var launchStoryboard: String?
    public var infoPlist: String?
    /// PrivacyInfo.xcprivacy for the app bundle. `OverlayLocation.load` makes it absolute (relative paths resolve
    /// against the overlay file's directory, like `source:`), so it may live outside the app repository.
    public var privacyManifest: String?
    public var linkFlags: [String]
    public var binaryDependencies: [BinaryDependency]
    public var scripts: [String: ScriptHandling]
    public var usesNonExemptEncryption: Bool?
    public var testflight: TestFlightConfig?
    /// `xcode:`: the Xcode whose SDK must build the app (`XcodePin`); nil: the image's SDK.
    public var xcode: String? = nil
    /// `provisioningUpdates: false`: `sign` changes nothing on the account; nil: it may.
    public var provisioningUpdates: Bool? = nil

    /// The cargo features of the macOS build: `macos.features` when set, else `tauri.features`.
    public var macFeatures: [String] { macos?.features ?? features }
}

private struct BuildNumber: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct Raw: Decodable {
    struct Tauri: Decodable { var dir: String?; var features: [String]? }
    var type: String
    var source: String?
    var tauri: Tauri?
    var bundleID: String
    var teamID: String
    var version: BuildNumber?
    var build: BuildNumber?
    var ios: OverlayIOS?
    var macos: OverlayMac?
    var assets: String?
    var launchStoryboard: String?
    var infoPlist: String?
    var privacyManifest: String?
    var linkFlags: [String]?
    var binaryDependencies: [BinaryDependency]?
    var scripts: [String: ScriptHandling]?
    var usesNonExemptEncryption: Bool?
    var testflight: TestFlightConfig?
    var xcode: String?
    /// For `xless run`, which reads it itself (XlessRun): the image the app is built in.
    var image: String?
    var provisioningUpdates: Bool?
}

extension TauriOverlay {
    public static func parse(yaml: String, name: String) throws -> TauriOverlay {
        try ProvisioningUpdates.check(yaml: yaml, file: "overlay \(name)")
        let raw: Raw
        do {
            raw = try YAMLDecoder().decode(Raw.self, from: yaml)
        } catch {
            throw XlessError(.config, "overlay \(name) is invalid: \(error)", fix: "see samples/HelloTauri/xless.overlay.example.yml for the schema")
        }
        guard raw.type == "tauri" else {
            throw XlessError(.config, "overlay \(name): type '\(raw.type)' is not supported", fix: "set type: tauri (type: react-native is a React Native / Expo overlay, type: cargo a plain Cargo app)")
        }
        if raw.teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw XlessError(.config, "overlay \(name): teamID '\(raw.teamID)' is not a 10-character Apple team ID", fix: "copy it from developer.apple.com → Membership")
        }
        if raw.bundleID.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
            throw XlessError(.config, "overlay \(name): bundleID '\(raw.bundleID)' is invalid", fix: "use reverse-DNS form, e.g. com.example.app")
        }
        let deps = raw.binaryDependencies ?? []
        for (i, d) in deps.enumerated() {
            if d.sha256.wholeMatch(of: /[0-9a-fA-F]{64}/) == nil {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].sha256 is not 64 hex characters", fix: "paste the sha256 of the downloaded file")
            }
            if !d.url.hasPrefix("https://") {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].url must be https", fix: "host the dependency at an https:// URL")
            }
            if d.to.hasPrefix("/") || d.to.split(separator: "/").contains("..") || d.to.isEmpty {
                throw XlessError(.config, "overlay \(name): binaryDependencies[\(i)].to '\(d.to)' must be a relative path without '..'", fix: "use a path inside the work copy, e.g. src-tauri/gen/apple/Pods/X/X.xcframework")
            }
        }
        if let pin = raw.xcode { try XcodePin.validate(pin, file: "overlay \(name)") }
        try ExtensionConfig.validate(raw.ios?.extensions ?? [], platform: .ios, appBundleID: raw.bundleID, key: "overlay \(name): ios.extensions")
        let version = raw.version?.value
        return TauriOverlay(
            name: name, source: raw.source, tauriDir: raw.tauri?.dir ?? "src-tauri", features: raw.tauri?.features ?? [],
            bundleID: raw.bundleID, teamID: raw.teamID, version: (version == nil || version == "tauri") ? nil : version,
            build: raw.build?.value ?? "dated", ios: raw.ios, macos: raw.macos, assets: raw.assets, launchStoryboard: raw.launchStoryboard,
            infoPlist: raw.infoPlist, privacyManifest: raw.privacyManifest, linkFlags: raw.linkFlags ?? [], binaryDependencies: deps, scripts: raw.scripts ?? [:],
            usesNonExemptEncryption: raw.usesNonExemptEncryption, testflight: raw.testflight, xcode: raw.xcode, provisioningUpdates: raw.provisioningUpdates)
    }
}

/// An overlay file plus where its source tree and work copy live.
public struct OverlayLocation: Sendable, Equatable {
    public var overlay: TauriOverlay
    public var sourceRoot: URL
    public var workRoot: URL

    /// Reads and parses the overlay at `url`. `sourceRoot` is `sourceOverride`, else the overlay's `source:`
    /// (`~` expanded; relative resolves against the overlay file's directory). `workRoot` is
    /// `$XLESS_WORK_ROOT` (default `~/.cache/xless/work`) + `/<overlay name>`.
    public static func load(from url: URL, sourceOverride: String? = nil, env: [String: String] = ProcessInfo.processInfo.environment) throws -> OverlayLocation {
        let text = try OverlayPaths.read(url)
        let paths = OverlayPaths(overlay: url, env: env)
        var overlay = try TauriOverlay.parse(yaml: text, name: paths.name)
        overlay.testflight?.registerSecretNames()   // before anything may start a tool (SecretEnvironment.scrub)
        overlay.privacyManifest = overlay.privacyManifest.map { paths.resolve($0).path }
        if var mac = overlay.macos {
            mac.entitlements = mac.entitlements.map { paths.resolve($0).path }
            mac.infoPlist = mac.infoPlist.map { paths.resolve($0).path }
            overlay.macos = mac
        }
        let sourceRoot = try paths.sourceRoot(source: overlay.source, sourceOverride: sourceOverride)
        let workRoot = paths.workRoot
        return OverlayLocation(overlay: overlay, sourceRoot: sourceRoot, workRoot: workRoot)
    }
}

/// The overlay types `--config` accepts, told apart by the file's `type:` before it is parsed as that type.
public enum OverlayKind: Sendable, Equatable {
    case tauri, reactNative, cargo

    /// `react-native` and `cargo` by name; anything else is read as a Tauri overlay (whose parser refuses a wrong `type:`).
    public init(type: String?) {
        switch type {
        case "react-native": self = .reactNative
        case "cargo": self = .cargo
        default: self = .tauri
        }
    }

    /// The kind of the overlay file at `url`.
    public static func of(_ url: URL) throws -> OverlayKind { OverlayKind(type: OverlayPaths.type(of: try OverlayPaths.read(url))) }

    /// `xless inspect --config` reports on Tauri and React Native overlays; cargo overlays have no report yet.
    public func requireInspectable() throws {
        guard self == .cargo else { return }
        throw XlessError(.config, "xless inspect --config is not supported for cargo overlays yet",
                         fix: "run `xless ship --config <overlay> --platform <ios|macos> --to build` to see what the build does")
    }
}

/// Where an overlay's paths lead, for every overlay type: its name (the file's basename without extension), `~`
/// expansion, paths relative to the overlay file's directory, the source tree and the work copy location.
public struct OverlayPaths: Sendable {
    public let name: String
    let home: String
    let overlayDir: URL
    let env: [String: String]

    /// The home that an overlay's `~` means, where HOME is another one (the sandbox of a build on a Mac).
    public static let homeVariable = "XLESS_OVERLAY_HOME"

    public init(overlay url: URL, env: [String: String] = ProcessInfo.processInfo.environment) {
        name = url.deletingPathExtension().lastPathComponent
        home = (env[Self.homeVariable] ?? env["HOME"]).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        overlayDir = url.deletingLastPathComponent()
        self.env = env
    }

    /// The overlay file's text.
    public static func read(_ url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read overlay \(url.path)", fix: "pass the path of an existing overlay file to --config")
        }
        return text
    }

    /// The `type:` of an overlay file, before it is parsed as that type (nil when there is no string `type:`).
    public static func type(of text: String) -> String? {
        (try? Yams.load(yaml: text) as? [String: Any])?["type"] as? String
    }

    /// The `teamID:` of an overlay file of any type (nil when there is no string `teamID:`): whose secrets a run uses.
    public static func team(of text: String) -> String? {
        (try? Yams.load(yaml: text) as? [String: Any])?["teamID"] as? String
    }

    public func expand(_ p: String) -> String {
        p == "~" ? home : p.hasPrefix("~/") ? home + String(p.dropFirst(1)) : p
    }

    /// `p` with `~` expanded; a relative path resolves against the overlay file's directory.
    public func resolve(_ p: String) -> URL {
        let e = expand(p)
        return (e.hasPrefix("/") ? URL(fileURLWithPath: e) : URL(fileURLWithPath: e, relativeTo: overlayDir)).standardizedFileURL
    }

    /// `sourceOverride` (`~` expanded, relative to the current directory), else the overlay's `source:` (`resolve`).
    public func sourceRoot(source: String?, sourceOverride: String?) throws -> URL {
        if let s = sourceOverride { return URL(fileURLWithPath: expand(s)).standardizedFileURL }
        if let s = source { return resolve(s) }
        throw XlessError(.config, "overlay \(name) has no source", fix: "set source: in the overlay or pass --source <dir>")
    }

    /// `$XLESS_WORK_ROOT` (default `~/.cache/xless/work`) + `/<overlay name>`.
    public var workRoot: URL {
        let base = env["XLESS_WORK_ROOT"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home + "/.cache/xless/work"
        return URL(fileURLWithPath: base).appendingPathComponent(name).standardizedFileURL
    }
}
