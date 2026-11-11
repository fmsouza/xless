import Foundation
import XlessCore
import XlessMachO
import XlessXcode

/// What the build stage does to the `.app` Swift Build produced, and what it records about it for the sign stage.
public enum BuiltApp {
    /// A bundle inside the app that is signed on its own: the app (path `""`) and every embedded app extension or app.
    public struct Bundle: Equatable, Sendable {
        /// Relative to the `.app` (`""`, `PlugIns/X.appex`).
        public var path: String
        public var bundleID: String
    }

    /// Directories of an iOS app that hold separately signed bundles, and the bundle extensions found there.
    static let nestedLocations: [(dir: String, ext: String)] = [("PlugIns", "appex"), ("Extensions", "appex"), ("Watch", "app"), ("AppClips", "app")]

    /// The app and the bundles nested in it, app first, then by path.
    public static func bundles(in app: URL) throws -> [Bundle] {
        var out = [Bundle(path: "", bundleID: try bundleID(of: app))]
        let fm = FileManager.default
        for (dir, ext) in nestedLocations {
            let d = app.appendingPathComponent(dir)
            for name in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted() where (name as NSString).pathExtension == ext {
                out.append(Bundle(path: "\(dir)/\(name)", bundleID: try bundleID(of: d.appendingPathComponent(name))))
            }
        }
        return out
    }

    static func bundleID(of bundle: URL) throws -> String {
        let (plist, _) = try readInfoPlist(bundle)
        guard let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else {
            throw XlessError(.build, "\(bundle.lastPathComponent) has no CFBundleIdentifier in its Info.plist", fix: "check the target's Info.plist")
        }
        return id
    }

    static func readInfoPlist(_ bundle: URL) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        let url = bundle.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw XlessError(.build, "cannot read \(url.path)", fix: "check the build output above")
        }
        return (plist, format)
    }

    /// Sets the version of every bundle (`CFBundleShortVersionString`, `CFBundleVersion`), keeping each Info.plist's
    /// format. The App Store refuses an extension whose versions differ from the app's, and an Info.plist may carry
    /// literal values (Expo writes the app's from its config) that no build setting reaches. Returns the bundles changed.
    @discardableResult
    public static func stampVersions(app: URL, bundles: [Bundle], version: String, build: String) throws -> [String] {
        var changed: [String] = []
        for b in bundles {
            let dir = b.path.isEmpty ? app : app.appendingPathComponent(b.path)
            var (plist, format) = try readInfoPlist(dir)
            guard plist["CFBundleShortVersionString"] as? String != version || plist["CFBundleVersion"] as? String != build else { continue }
            plist["CFBundleShortVersionString"] = version
            plist["CFBundleVersion"] = build
            try Plist.write(plist, to: dir.appendingPathComponent("Info.plist"), format: format, stage: .build)
            changed.append(b.path)
        }
        return changed
    }

    /// Copies every `.dSYM` under `products` into `dir`, at the same relative path (a vendored framework's sits under
    /// `XCFrameworkIntermediates/<pod>/`), as `xcodebuild archive` gathers them into `dSYMs/`. With `app`, only the dSYMs
    /// of binaries the app ships (sharing a UUID with one of its Mach-O images): derived data is kept between builds, so
    /// it can still hold the dSYM of a target or pod removed since. Replaces `dir`; with no dSYM it is removed. Returns
    /// the relative paths copied, sorted.
    @discardableResult
    public static func copyDSYMs(from products: URL, to dir: URL, keepingImagesOf app: URL? = nil) throws -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let base = products.standardizedFileURL.path
        let shipped = app.map { DSYM.imageUUIDs(in: $0) }
        if let walk = fm.enumerator(at: products, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walk where url.pathExtension == "dSYM" {
                walk.skipDescendants()
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let shipped, DSYM.uuids(ofDSYM: url).isDisjoint(with: shipped) { continue }
                found.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
            }
        }
        try? fm.removeItem(at: dir)
        guard !found.isEmpty else { return [] }
        _ = try Files.atomicOutput(dir) { out in
            for rel in found {
                let dest = out.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: products.appendingPathComponent(rel), to: dest)
            }
            return out
        }
        return found.sorted()
    }

    /// One `entitlements.json` entry.
    public struct Entitlements: Equatable, Sendable {
        public var target: String
        public var bundleID: String
        /// The entitlements file (`CODE_SIGN_ENTITLEMENTS`) relative to the project directory, nil when the target has none.
        public var file: String?
        public var entitlements: JSON
    }

    /// The target's `CODE_SIGN_ENTITLEMENTS` file as signing would use it: build settings in its values expanded with
    /// the target's settings, except `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)`, which Xcode defines only
    /// when it signs (from the signing team) and so are left for the sign stage. `{}` without the setting.
    static func entitlements(_ settings: TargetSettings, bundleID: String) throws -> Entitlements {
        let target = settings.target.name
        guard let raw = try settings.raw("CODE_SIGN_ENTITLEMENTS"), !raw.isEmpty else {
            return Entitlements(target: target, bundleID: bundleID, file: nil, entitlements: .object([:]))
        }
        let path = try settings.expand(raw, context: "\(target)'s CODE_SIGN_ENTITLEMENTS")
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : settings.project.directory.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            throw XlessError(.build, "\(target)'s entitlements file \(path) does not exist", fix: "check CODE_SIGN_ENTITLEMENTS of \(target)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil), plist is [String: Any] else {
            throw XlessError(.build, "\(target)'s entitlements file \(path) is not a dictionary plist", fix: "check \(url.path)")
        }
        let context = "\(target)'s entitlements (\(path))"
        let json = try toJSON(plist, context: context) { try settings.expand($0, keep: signingVariables, context: context) }
        let base = settings.project.directory.standardizedFileURL.path
        let rel = url.standardizedFileURL.path.hasPrefix(base + "/") ? String(url.standardizedFileURL.path.dropFirst(base.count + 1)) : url.path
        return Entitlements(target: target, bundleID: bundleID, file: rel, entitlements: json)
    }

    /// Defined by Xcode only while signing (`<team ID>.`); left in place for the sign stage.
    static let signingVariables: Set<String> = ["AppIdentifierPrefix", "TeamIdentifierPrefix"]

    /// A plist value as JSON, strings passed through `expand`. Booleans and numbers are classified explicitly (Darwin
    /// and Linux Foundation decode them differently); reals, dates and data have no meaning in entitlements here.
    static func toJSON(_ v: Any, context: String, expand: (String) throws -> String) throws -> JSON {
        if let s = v as? String { return .string(try expand(s)) }
        if let d = v as? [String: Any] {
            var o: [String: JSON] = [:]
            for (k, x) in d { o[k] = try toJSON(x, context: context, expand: expand) }
            return .object(o)
        }
        if let a = v as? [Any] { return .array(try a.map { try toJSON($0, context: context, expand: expand) }) }
        switch FoundationScalar(v) {
        case .bool(let b)?: return .bool(b)
        case .int(let i)?: return .int(Int(i))
        case .uint(let u)? where u <= UInt64(Int.max): return .int(Int(u))
        default: break
        }
        throw XlessError(.build, "\(context) holds a \(type(of: v)) value, which xless does not carry to signing",
                         fix: "use strings, booleans, integers, arrays and dictionaries in the entitlements file")
    }

    /// `entitlements.json`: bundle path (`""` for the app) → `{bundleID, target, file, entitlements}`.
    public static func entitlementsJSON(_ entries: [String: Entitlements]) -> Data {
        let json = JSON.object(entries.mapValues { e in
            var o: [String: JSON] = ["bundleID": .string(e.bundleID), "target": .string(e.target), "entitlements": e.entitlements]
            if let f = e.file { o["file"] = .string(f) }
            return .object(o)
        })
        return Data((json.serialized(pretty: true) + "\n").utf8)
    }
}
