import Foundation
import XlessCore

/// The build's record of each separately signed bundle's entitlements (React Native: `.xless/build/ios/entitlements.json`,
/// written by the build stage) and the overlay's edits to them. The sign stage reads only this file, the built `.app`
/// and the overlay: no project file and no build code.
public struct EntitlementsManifest: Sendable {
    public var file: URL
    public var rewrites: EntitlementRewrites

    public init(file: URL, rewrites: EntitlementRewrites = .none) { self.file = file; self.rewrites = rewrites }
}

/// A bundle signed with its own identifier, profile and entitlements: the app (`path` "") or an app extension.
struct SignTarget {
    /// Relative to the `.app`: "" or `PlugIns/X.appex`.
    var path: String
    var bundleID: String
    /// The project's entitlements with the signing prefixes expanded and the overlay's rewrites applied.
    var entitlements: [String: Any]
}

/// An app extension the config declares, with its entitlements read (`ExtensionConfig`).
struct DeclaredExtension {
    var path: String
    var bundleID: String
    var entitlements: [String: Any]
}

public enum SignTargets {
    /// Where an iOS app keeps app extensions; each one is signed with its own profile.
    static let extensionDirs = ["PlugIns", "Extensions"]
    /// Nested apps xless does not sign yet.
    static let unsupportedDirs = ["Watch", "AppClips"]

    /// The bundles to provision and sign, app extensions first (sorted by path), the app last. Without a manifest the
    /// app's entitlements are `appEntitlements` (xless.yml / a Tauri or cargo overlay): with `declared` extensions
    /// (`platforms.ios.extensions`) the app must hold exactly those, each signed with its declared entitlements; with
    /// none declared an extension has none. With a manifest, every bundle's come from the manifest, which must describe
    /// exactly the bundles the app holds.
    static func plan(app: URL, platform: Platform, appBundleID: String, appEntitlements: [String: Any],
                     manifest: EntitlementsManifest?, teamID: String, declared: [DeclaredExtension] = []) throws -> [SignTarget] {
        let rewrites = manifest?.rewrites ?? .none
        func prepared(_ ents: [String: Any]) -> [String: Any] {
            Entitlements.rewrite(Entitlements.expandSigningPrefixes(ents, teamID: teamID), with: rewrites)
        }
        let nested = platform == .ios ? try extensions(in: app) : []
        // App Store Connect refuses an app whose extension's identifier is not under the app's (and Xcode's
        // embedded-binary validation does too); a profile for it would be wasted.
        for e in nested where !e.bundleID.hasPrefix(appBundleID + ".") {
            throw XlessError(.sign, "app extension \(e.path) has bundle ID \(e.bundleID), which does not start with the app's \(appBundleID).",
                             fix: "give the extension a bundle ID under the app's, e.g. \(appBundleID).\(((e.path as NSString).lastPathComponent as NSString).deletingPathExtension)")
        }
        let entries: [String: Entry]
        let source: String, rerun: String
        if let manifest {
            entries = try read(manifest.file)
            source = manifest.file.lastPathComponent
            rerun = "run `xless build` again (the manifest and the app come from the same build)"
        } else if !declared.isEmpty {
            entries = Dictionary(uniqueKeysWithValues: declared.map { ($0.path, Entry(bundleID: $0.bundleID, entitlements: $0.entitlements)) })
                .merging(["": Entry(bundleID: appBundleID, entitlements: appEntitlements)]) { a, _ in a }
            source = "the config's extensions (platforms.ios.extensions)"
            rerun = "declare exactly the app extensions the app embeds, each with its bundle ID, in platforms.ios.extensions (ios.extensions in an overlay)"
        } else {
            return nested.map { SignTarget(path: $0.path, bundleID: $0.bundleID, entitlements: [:]) }
                + [SignTarget(path: "", bundleID: appBundleID, entitlements: prepared(appEntitlements))]
        }

        // A watch app or App Clip actually in the app was refused by `extensions(in:)`; an entry for a bundle the app
        // does not hold, whatever its kind, means the manifest is stale (or the declaration wrong).
        for path in entries.keys.sorted() where !path.isEmpty && !nested.contains(where: { $0.path == path }) {
            throw XlessError(.sign, "\(source) names \(path), which is not in \(app.lastPathComponent)", fix: rerun)
        }
        func entry(_ path: String, bundleID: String) throws -> SignTarget {
            let label = path.isEmpty ? "the app" : path
            guard let e = entries[path] else {
                throw XlessError(.sign, "\(source) has no entry for \(label)", fix: rerun)
            }
            guard e.bundleID == bundleID else {
                throw XlessError(.sign, "\(source) records \(e.bundleID) for \(label), which is \(bundleID)", fix: rerun)
            }
            return SignTarget(path: path, bundleID: bundleID, entitlements: prepared(e.entitlements))
        }
        return try nested.map { try entry($0.path, bundleID: $0.bundleID) } + [entry("", bundleID: appBundleID)]
    }

    /// `PlugIns/*.appex` and `Extensions/*.appex` with their `CFBundleIdentifier`, sorted by path. Refused: a watch app
    /// or an App Clip (each needs its own kind of profile); a symlink in place of the directory or of an extension (what
    /// gets signed and sealed must be the bundle itself); a name rcodesign would read as scope syntax; an extension with
    /// its own `Frameworks/`.
    static func extensions(in app: URL) throws -> [(path: String, bundleID: String)] {
        let fm = FileManager.default
        for dir in unsupportedDirs {
            let found = ((try? fm.contentsOfDirectory(atPath: app.appendingPathComponent(dir).path)) ?? []).filter { $0.hasSuffix(".app") }
            if let name = found.sorted().first {
                throw XlessError(.sign, "\(dir)/\(name) is a watch app or App Clip, which xless does not sign yet", fix: "build the app without it")
            }
        }
        var out: [(path: String, bundleID: String)] = []
        for dir in extensionDirs {
            let dirURL = app.appendingPathComponent(dir)
            guard fm.fileExists(atPath: dirURL.path) || isSymlink(dirURL.path) else { continue }
            guard isRealDirectory(dirURL.path) else {
                throw XlessError(.sign, "\(dir) in \(app.lastPathComponent) is not a directory (a symlink?)", fix: "check the build output: \(dir) must be a real directory")
            }
            for name in ((try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []).sorted() where name.hasSuffix(".appex") {
                let path = "\(dir)/\(name)"
                guard isRealDirectory(dirURL.appendingPathComponent(name).path) else {
                    throw XlessError(.sign, "app extension \(path) is not a directory (a symlink?)", fix: "check the build output: an app extension must be a real bundle directory")
                }
                // rcodesign 0.29 reads `<scope>:<file>` (the scope ends at the first colon) and `<path>@<int>` /
                // `<path>@[cpu_type=…]` as a scope on a Mach-O slice.
                if let c = name.first(where: { $0 == ":" || $0 == "@" }) {
                    throw XlessError(.sign, "app extension \(path) has a '\(c)' in its name, which rcodesign reads as scope syntax", fix: "rename the extension's product")
                }
                // rcodesign's help says a setting scoped to a nested bundle applies to everything within it, so a framework
                // inside the extension could be signed with the extension's entitlements (0.29.0 did not, on a probe; xless
                // does not rely on either).
                let frameworks = dirURL.appendingPathComponent(name).appendingPathComponent("Frameworks")
                if fm.fileExists(atPath: frameworks.path) || isSymlink(frameworks.path) {
                    throw XlessError(.sign, "app extension \(path) contains Frameworks/: under rcodesign's path scoping, its frameworks could inherit the extension's entitlements",
                                     fix: "embed the frameworks in the app (\(app.lastPathComponent)/Frameworks) instead of in the extension")
                }
                let info = try Plist.read(app.appendingPathComponent(path).appendingPathComponent("Info.plist"), stage: .sign)
                guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else {
                    throw XlessError(.sign, "\(path) has no CFBundleIdentifier in its Info.plist", fix: "check the extension target's Info.plist")
                }
                out.append((path, id))
            }
        }
        return out
    }

    /// A directory itself, not a symlink to one (`attributesOfItem` does not follow the last component).
    static func isRealDirectory(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// The bundles the build recorded (`entitlements.json`): path ("" for the app), bundle ID and entitlements, sorted
    /// by path (`xless provision` reads it before a build has been signed).
    public static func recorded(_ file: URL) throws -> [(path: String, bundleID: String, entitlements: [String: Any])] {
        try read(file).sorted { $0.key < $1.key }.map { ($0.key, $0.value.bundleID, $0.value.entitlements) }
    }

    struct Entry { var bundleID: String; var entitlements: [String: Any] }

    /// `entitlements.json`: bundle path → `{bundleID, target, file?, entitlements}`.
    static func read(_ file: URL) throws -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else {
            throw XlessError(.sign, "\(file.path) does not exist", fix: "run `xless build` first: the build records each bundle's entitlements there")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XlessError(.sign, "\(file.path) is not a JSON object", fix: "run `xless build` again")
        }
        var out: [String: Entry] = [:]
        for (path, value) in root {
            guard let o = value as? [String: Any], let id = o["bundleID"] as? String, let ents = o["entitlements"] as? [String: Any] else {
                throw XlessError(.sign, "\(file.lastPathComponent): the entry for '\(path)' lacks a bundleID or entitlements", fix: "run `xless build` again")
            }
            out[path] = Entry(bundleID: id, entitlements: try ents.mapValues { try plistValue($0, file: file) })
        }
        return out
    }

    /// JSON as plist values: booleans and integers made explicit (Foundation decodes JSON numbers differently on Linux).
    static func plistValue(_ v: Any, file: URL) throws -> Any {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return try d.mapValues { try plistValue($0, file: file) } }
        if let a = v as? [Any] { return try a.map { try plistValue($0, file: file) } }
        switch FoundationScalar(v) {
        case .bool(let b)?: return b
        case .int(let i)?: return Int(i)
        case .uint(let u)? where u <= UInt64(Int.max): return Int(u)
        default:
            throw XlessError(.sign, "\(file.lastPathComponent) holds an entitlement value xless cannot sign with (\(type(of: v)))", fix: "run `xless build` again")
        }
    }
}
