import Foundation
import Yams
import XlessCore
import XlessTauri

/// One platform block (`ios:` or `macos:`) of a `type: cargo` overlay.
public struct CargoPlatform: Sendable, Equatable {
    /// `cargo -p`.
    public var package: String
    /// `cargo --bin`; nil: the package's only binary.
    public var bin: String?
    public var features: [String]
    /// The `.app` name and `CFBundleName`.
    public var product: String
    public var minimumOS: String
    /// Overrides the overlay's `bundleID` for this platform.
    public var bundleID: String?
    /// Relative to the source root (the work copy), or `input:<name>/…`.
    public var infoPlist: String?
    /// An asset catalog (`.xcassets`). Required on iOS; on macOS the alternative to `icon`. In the source root only.
    public var assets: String?
    /// A ready `.icns` (macOS only).
    public var icon: String?
    /// In the source root only (the sign stage reads it from the work copy).
    public var entitlements: String?
    public var resources: [CargoResource]
    /// macOS only, in canonical order (`MacArchitecture.allCases`; default: both, merged into a universal executable).
    /// Empty on iOS, which builds arm64 alone.
    public var architectures: [MacArchitecture]
}

/// A copy into the bundle: `Contents/Resources/<to>` on macOS, `<to>` at the bundle root on iOS.
public struct CargoResource: Sendable, Equatable {
    /// Relative to the source root, or `input:<name>/…`; a glob when `to` ends in `/`.
    public var from: String
    public var to: String
}

/// An extra read-only directory the build needs: a local path or a git checkout at a pinned commit.
public enum CargoInput: Sendable, Equatable {
    case path(name: String, path: String, env: String)
    case git(name: String, url: String, rev: String, env: String)

    public var name: String {
        switch self { case .path(let name, _, _), .git(let name, _, _, _): name }
    }
    /// The variable that carries the input's directory into the build.
    public var env: String {
        switch self { case .path(_, _, let env), .git(_, _, _, let env): env }
    }
}

/// An xless overlay for a plain Cargo app (`type: cargo`). It lives outside the app repository.
/// Paths: `privacyManifest` is relative to the overlay file (`load` makes it absolute); every other path is relative to
/// the source root (the work copy), or `input:<name>/…` into a declared input (except `assets` and `entitlements`,
/// which the assets and sign stages read from the work copy).
public struct CargoOverlay: Sendable, Equatable {
    /// Overlay file basename without extension (names the work copy).
    public var name: String
    public var source: String?
    public var bundleID: String
    public var teamID: String
    /// nil (absent or `cargo`) means the binary's package version.
    public var version: String?
    /// `"dated"` or an explicit build number.
    public var build: String
    public var usesNonExemptEncryption: Bool?
    public var privacyManifest: String?
    public var testflight: TestFlightConfig?
    /// `xcode:`: the Xcode whose SDK must build the app (`XcodePin`); nil: the image's SDK.
    public var xcode: String?
    /// `rust.toolchain`; nil: the workspace's rust-toolchain file, else stable.
    public var toolchain: String?
    /// Plain build-time variables (never secrets).
    public var env: [String: String]
    public var inputs: [CargoInput]
    /// Values for `@NAME@` placeholders in the app's Info.plist.
    public var plistVars: [String: String]
    public var ios: CargoPlatform?
    public var macos: CargoPlatform?

    /// Variables xless sets itself, which `env:` may not change.
    static let reservedEnvironment: Set<String> = [
        "PATH", "HOME", "SDKROOT", "DEVELOPER_DIR", "TAR_OPTIONS", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN",
        "IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET", "CARGO_PROFILE_RELEASE_STRIP",
    ]
    /// Prefixes of variables that carry credentials (`ASC_KEY_P8_FILE`, `XLESS_DEVID_KEY_FILE`…) or that xless sets.
    static let reservedPrefixes = ["XLESS_", "SWIFT_", "ASC_", "CARGO_TARGET_"]
}

private struct Scalar: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct RawResource: Decodable { var from: String; var to: String }

private struct RawPlatform: Decodable {
    var package: String
    var bin: String?
    var features: [String]?
    var product: String?
    var minimumOS: String?
    var bundleID: String?
    var infoPlist: String?
    var assets: String?
    var icon: String?
    var entitlements: String?
    var resources: [RawResource]?
    var architectures: [String]?
}

private struct RawInput: Decodable {
    var name: String
    var path: String?
    var git: String?
    var rev: String?
    var env: String?
}

private struct Raw: Decodable {
    struct Rust: Decodable { var toolchain: Scalar? }
    var type: String
    var source: String?
    var bundleID: String
    var teamID: String
    var version: Scalar?
    var build: Scalar?
    var usesNonExemptEncryption: Bool?
    var privacyManifest: String?
    var testflight: TestFlightConfig?
    var xcode: String?
    var rust: Rust?
    var env: [String: String]?
    var inputs: [RawInput]?
    var plistVars: [String: String]?
    var ios: RawPlatform?
    var macos: RawPlatform?
}

extension CargoOverlay {
    static let keys: Set<String> = ["type", "source", "bundleID", "teamID", "version", "build", "usesNonExemptEncryption", "privacyManifest",
                                    "testflight", "xcode", "rust", "env", "inputs", "plistVars", "ios", "macos"]
    static let platformKeys: Set<String> = ["package", "bin", "features", "product", "minimumOS", "bundleID", "infoPlist", "assets", "icon",
                                            "entitlements", "resources", "architectures"]
    static let inputKeys: Set<String> = ["name", "path", "git", "rev", "env"]
    static let resourceKeys: Set<String> = ["from", "to"]

    public static func parse(yaml: String, name: String) throws -> CargoOverlay {
        let schema = "check the key against the type: cargo overlay schema (top level: \(keys.sorted().joined(separator: ", ")))"
        func invalid(_ what: String, _ fix: String) -> XlessError { XlessError(.config, "overlay \(name): \(what)", fix: fix) }

        // Unknown keys are refused: a misspelt key (`bundleId`, `ios.feature`) would otherwise be dropped silently.
        if let top = try? Yams.load(yaml: yaml) as? [String: Any] {
            func check(_ map: Any?, _ allowed: Set<String>, _ path: String) throws {
                guard let map = map as? [String: Any] else { return }
                for key in map.keys.sorted() where !allowed.contains(key) {
                    throw invalid("unknown key '\(path.isEmpty ? "" : path + ".")\(key)'", schema)
                }
            }
            try check(top, keys, "")
            try check(top["rust"], ["toolchain"], "rust")
            for platform in ["ios", "macos"] {
                try check(top[platform], platformKeys, platform)
                for resource in ((top[platform] as? [String: Any])?["resources"] as? [Any]) ?? [] {
                    try check(resource, resourceKeys, "\(platform).resources")
                }
            }
            for input in (top["inputs"] as? [Any]) ?? [] { try check(input, inputKeys, "inputs") }
        }
        let raw: Raw
        do {
            raw = try YAMLDecoder().decode(Raw.self, from: yaml)
        } catch {
            throw XlessError(.config, "overlay \(name) is invalid: \(error)", fix: schema)
        }
        guard raw.type == "cargo" else {
            throw invalid("type '\(raw.type)' is not supported here", "set type: cargo")
        }
        if raw.teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw invalid("teamID '\(raw.teamID)' is not a 10-character Apple team ID", "copy it from developer.apple.com → Membership")
        }
        let bundlePattern = /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/
        if raw.bundleID.wholeMatch(of: bundlePattern) == nil {
            throw invalid("bundleID '\(raw.bundleID)' is invalid", "use reverse-DNS form, e.g. com.example.app")
        }
        if raw.ios == nil && raw.macos == nil {
            throw invalid("neither ios nor macos is configured", "add an ios: or macos: block naming the cargo package to build")
        }

        // Environment: plain variables only.
        func checkVariable(_ key: String, in what: String) throws {
            if key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) == nil {
                throw invalid("\(what) name '\(key)' is not a variable name", "use letters, digits and _")
            }
            if reservedEnvironment.contains(key) || reservedPrefixes.contains(where: key.hasPrefix) || Shell.scrubbedEnvironment.contains(key) {
                throw invalid("\(what) \(key) is set by xless itself or carries a secret", "remove it; secrets reach xless only through the environment of the stage that uses them")
            }
        }
        var env: [String: String] = [:]
        for (key, value) in (raw.env ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkVariable(key, in: "env.")
            env[key] = value
        }

        // Inputs.
        var inputs: [CargoInput] = []
        var seenNames = Set<String>(), seenEnv = Set(env.keys)
        for (i, input) in (raw.inputs ?? []).enumerated() {
            let at = "inputs[\(i)]"
            if input.name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) == nil {
                throw invalid("\(at).name '\(input.name)' is not a name", "use letters, digits, '.', '_' and '-' (it is used in input:<name>/… paths)")
            }
            if !seenNames.insert(input.name).inserted {
                throw invalid("input '\(input.name)' is declared twice", "give every input its own name")
            }
            guard let variable = input.env, !variable.isEmpty else {
                throw invalid("\(at) (\(input.name)) has no env", "name the variable that carries the input's directory into the build, e.g. env: FONTS_DIR")
            }
            try checkVariable(variable, in: "\(at).env")
            if !seenEnv.insert(variable).inserted {
                throw invalid("\(at).env \(variable) is already used by env: or another input", "give every input its own variable")
            }
            switch (input.path, input.git) {
            case (nil, nil):
                throw invalid("input '\(input.name)' has neither path nor git", "give it path: <directory> or git: <https url> with rev: <40-hex commit>")
            case (.some, .some):
                throw invalid("input '\(input.name)' has both path and git", "use one: path for a local directory, git + rev for a pinned checkout")
            case (let path?, nil):
                if input.rev != nil { throw invalid("input '\(input.name)' has rev without git", "rev pins a git input; remove it or use git:") }
                if path.isEmpty { throw invalid("input '\(input.name)' has an empty path", "name the directory") }
                // `xless cargo inputs` prints `name<TAB>path` lines for scripts/testflight.sh to read.
                // Unicode scalars, not Characters: "\r\n" is one Character, equal to neither "\n" nor "\r".
                if path.unicodeScalars.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
                    throw invalid("input '\(input.name)' has a tab or line break in its path", "rename the directory, or point path: at a link without one")
                }
                inputs.append(.path(name: input.name, path: path, env: variable))
            case (nil, let url?):
                guard url.hasPrefix("https://"), url.count > "https://".count, !url.contains(where: \.isWhitespace) else {
                    throw invalid("input '\(input.name)': git '\(url)' must be an https:// URL", "host the input at an https:// URL (ssh and http are not supported)")
                }
                guard let rev = input.rev, rev.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
                    throw invalid("input '\(input.name)': rev '\(input.rev ?? "")' is not a full 40-character lowercase hex commit", "pin the exact commit (git rev-parse HEAD); branches and tags move")
                }
                inputs.append(.git(name: input.name, url: url, rev: rev, env: variable))
            }
        }
        let inputNames = Set(inputs.map(\.name))

        // Paths: relative to their root, no `..` out of it; `input:<name>/…` into a declared input.
        func checkPath(_ p: String, _ key: String, allowInput: Bool = true) throws {
            let fix = "use a path relative to the source root (or input:<name>/… into a declared input) that stays inside it"
            if p.isEmpty { throw invalid("\(key) is empty", fix) }
            var rest = Substring(p)
            if rest.hasPrefix("input:") {
                // The assets and sign stages read these files from the work copy, where no input is.
                guard allowInput else {
                    throw invalid("\(key) '\(p)' may not name an input", "put the file in the repository and give its path relative to the source root")
                }
                let after = rest.dropFirst("input:".count)
                let input = after.prefix(while: { $0 != "/" })
                guard !input.isEmpty, after.count > input.count else {
                    throw invalid("\(key) '\(p)' is not input:<name>/<path>", fix)
                }
                guard inputNames.contains(String(input)) else {
                    throw invalid("\(key) '\(p)' names input '\(input)', which is not declared", "declare it under inputs:")
                }
                rest = after.dropFirst(input.count + 1)
            }
            if rest.hasPrefix("/") || rest.hasPrefix("~") || p.contains("\0") {
                throw invalid("\(key) '\(p)' must be a relative path", fix)
            }
            var depth = 0
            for part in rest.split(separator: "/", omittingEmptySubsequences: true) {
                if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
                if depth < 0 { throw invalid("\(key) '\(p)' leaves its root with '..'", fix) }
            }
        }
        func checkTarget(_ p: String, _ key: String) throws {
            if p.isEmpty || p.hasPrefix("/") || p.hasPrefix("~") || p.split(separator: "/").contains("..") {
                throw invalid("\(key) '\(p)' must be a relative path without '..'", "name a location inside the bundle, e.g. Licenses/")
            }
        }

        func platform(_ r: RawPlatform?, _ which: String) throws -> CargoPlatform? {
            guard let r else { return nil }
            func name(_ value: String, _ key: String) throws {
                if value.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]*/) == nil {
                    throw invalid("\(which).\(key) '\(value)' is not a cargo name", "use letters, digits, '_', '-' and '.'")
                }
            }
            try name(r.package, "package")
            if let bin = r.bin { try name(bin, "bin") }
            let features = r.features ?? []
            if let f = features.first(where: { $0.isEmpty || $0.contains(where: { $0.isWhitespace || $0 == "," }) }) {
                throw invalid("\(which).features has an invalid feature '\(f)'", "list cargo features, e.g. features: [heif]")
            }
            guard let product = r.product, !product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("\(which).product is missing", "name the .app and CFBundleName, e.g. product: Hello")
            }
            if product.contains("/") || product.hasPrefix(".") || product.contains(where: \.isNewline) {
                throw invalid("\(which).product '\(product)' is not an app name", "use a plain name, e.g. Hello")
            }
            guard let minimumOS = r.minimumOS, minimumOS.wholeMatch(of: /\d+(\.\d+){0,2}/) != nil else {
                throw invalid("\(which).minimumOS '\(r.minimumOS ?? "")' is missing or not a version", "quote 1–3 dot-separated integers, e.g. minimumOS: \"17.0\"")
            }
            if let id = r.bundleID, id.wholeMatch(of: bundlePattern) == nil {
                throw invalid("\(which).bundleID '\(id)' is invalid", "use reverse-DNS form, e.g. com.example.app")
            }
            if which == "ios" {
                if r.icon != nil {
                    throw invalid("ios.icon is not supported", "iOS takes an asset catalog: set ios.assets (the App Store needs an icon)")
                }
                if r.assets == nil {
                    throw invalid("ios.assets is missing", "point ios.assets at the app's .xcassets catalog (the App Store needs an icon)")
                }
                if r.architectures != nil {
                    throw invalid("ios.architectures is not supported", "remove it: iOS builds are arm64 only")
                }
            } else if r.icon != nil && r.assets != nil {
                throw invalid("macos sets both icon and assets", "use one: icon for a ready .icns, assets for an asset catalog")
            }
            var architectures: [MacArchitecture] = []
            if which == "macos" {
                let names = MacArchitecture.allCases.map(\.rawValue).joined(separator: ", ")
                let listed = r.architectures ?? MacArchitecture.allCases.map(\.rawValue)
                if listed.isEmpty {
                    throw invalid("macos.architectures is empty", "list at least one of \(names), or remove it to build both")
                }
                var seen = Set<MacArchitecture>()
                for value in listed {
                    guard let arch = MacArchitecture(rawValue: value) else {
                        throw invalid("macos.architectures has an unknown architecture '\(value)'", "use \(names)")
                    }
                    if !seen.insert(arch).inserted {
                        throw invalid("macos.architectures lists \(value) twice", "list each architecture once")
                    }
                }
                architectures = MacArchitecture.allCases.filter(seen.contains)
                // No macOS before 11.0 runs on Apple Silicon: an arm64-only app with a lower minimum would claim Macs it cannot run on.
                if architectures == [.arm64], let min = DottedVersion(minimumOS), min < DottedVersion("11.0")! {
                    throw invalid("macos.minimumOS \(minimumOS) is below 11.0, the first macOS on Apple Silicon, and macos.architectures is [arm64]",
                                  "set minimumOS: \"11.0\" or later, or add x86_64 to architectures")
                }
            }
            // `assets` and `entitlements` are read by the assets and sign stages from the work copy: no `input:` there.
            for (key, value, allowInput) in [("infoPlist", r.infoPlist, true), ("assets", r.assets, false), ("icon", r.icon, true),
                                             ("entitlements", r.entitlements, false)] {
                if let value { try checkPath(value, "\(which).\(key)", allowInput: allowInput) }
            }
            var resources: [CargoResource] = []
            for (i, resource) in (r.resources ?? []).enumerated() {
                try checkPath(resource.from, "\(which).resources[\(i)].from")
                try checkTarget(resource.to, "\(which).resources[\(i)].to")
                resources.append(CargoResource(from: resource.from, to: resource.to))
            }
            return CargoPlatform(package: r.package, bin: r.bin, features: features, product: product, minimumOS: minimumOS, bundleID: r.bundleID,
                                 infoPlist: r.infoPlist, assets: r.assets, icon: r.icon, entitlements: r.entitlements, resources: resources,
                                 architectures: architectures)
        }
        let ios = try platform(raw.ios, "ios")
        let macos = try platform(raw.macos, "macos")

        var version = raw.version?.value
        if version == "cargo" { version = nil }
        if let version, version.wholeMatch(of: /\d+(\.\d+){0,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?/) == nil {
            throw invalid("version '\(version)' is invalid", "use `cargo`, or 1–3 dot-separated integers with an optional -prerelease, e.g. 1.2.0 or 1.2.0-beta.1")
        }
        let build = raw.build?.value ?? "dated"
        if build != "dated", build.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw invalid("build '\(build)' is invalid", "use dated, or 1–3 dot-separated integers")
        }
        let toolchain = raw.rust?.toolchain?.value
        if let toolchain, toolchain.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) == nil {
            throw invalid("rust.toolchain '\(toolchain)' is invalid", "use a rustup toolchain name, e.g. \"1.97.0\" or stable")
        }
        if let privacy = raw.privacyManifest, privacy.isEmpty {
            throw invalid("privacyManifest is empty", "name the PrivacyInfo.xcprivacy file, relative to the overlay")
        }
        for key in (raw.plistVars ?? [:]).keys.sorted() where key.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*/) == nil {
            throw invalid("plistVars name '\(key)' is invalid", "use letters, digits and _ (it replaces @\(key)@)")
        }
        if let pin = raw.xcode { try XcodePin.validate(pin, file: "overlay \(name)") }
        return CargoOverlay(
            name: name, source: raw.source, bundleID: raw.bundleID, teamID: raw.teamID, version: version, build: build,
            usesNonExemptEncryption: raw.usesNonExemptEncryption, privacyManifest: raw.privacyManifest, testflight: raw.testflight,
            xcode: raw.xcode, toolchain: toolchain, env: env, inputs: inputs, plistVars: raw.plistVars ?? [:], ios: ios, macos: macos)
    }

    /// Reads and parses the overlay at `url` (paths as for Tauri overlays, `OverlayPaths`). `privacyManifest` is made
    /// absolute against the overlay's directory; every other path stays relative to the source root.
    public static func load(from url: URL, sourceOverride: String? = nil,
                            env: [String: String] = ProcessInfo.processInfo.environment) throws -> (overlay: CargoOverlay, sourceRoot: URL, workRoot: URL) {
        let text = try OverlayPaths.read(url)
        let paths = OverlayPaths(overlay: url, env: env)
        var overlay = try parse(yaml: text, name: paths.name)
        overlay.privacyManifest = overlay.privacyManifest.map { paths.resolve($0).path }
        return (overlay, try paths.sourceRoot(source: overlay.source, sourceOverride: sourceOverride), paths.workRoot)
    }
}
