import Foundation

/// `identifiers: { replace: {…} }` in a React Native overlay (Ruling R9): an app built under another team names that
/// team's identifiers (an app group `group.<their app ID>`, a keychain group `<prefix><their app ID>.x`), which the
/// signing team's profiles never grant, both in its entitlements and in Info.plist keys the app reads at run time (an
/// app group name its code opens the shared container with). The map turns them into identifiers the signing
/// team owns: in every bundle's entitlements at sign (`EntitlementRewrites`), and in every string value of the app's own
/// bundles' Info.plists at finalize (`rewriteInfoPlists`), so the signature seals the rewritten files.
///
/// A key matches only where an identifier ends: the next character is not a letter, digit or `-` (`com.other.app`
/// matches `group.com.other.app`, `com.other.app.share`, `com.other.app:x` and `com.other.app/x`, never
/// `com.other.apple` or `com.other.app-beta`).
///
/// Ruling (fix wave M3): the Info.plists rewritten are the app's and its extensions' (`.app`, `.appex`), whose bundle
/// IDs come from the overlay's `bundleIDs`, and those of other bundles (frameworks, resource bundles, …) only when their
/// own `CFBundleIdentifier` is one of the replaced identifiers or starts with one (the other team's own code). Their
/// `CFBundleIdentifier` itself is kept: it is the code's identity, which it may look itself up by. Every other embedded
/// bundle (third-party frameworks) is left as it is.
public struct IdentifierReplacement: Sendable, Equatable {
    /// Literal substring → replacement. Keys are whole identifiers (4+ characters with a `.`; the overlay checks).
    public var map: [String: String]

    public init(_ map: [String: String] = [:]) { self.map = map }

    public static let none = IdentifierReplacement()
    public var isEmpty: Bool { map.isEmpty }

    /// The map finalize applied, recorded next to its app (`final/identifiers.json`, only for a non-empty map), so sign
    /// can refuse a map edited since: the Info.plists would carry the old one and the entitlements the new one.
    public static let recordName = "identifiers.json"

    public func record(in finalDir: URL) throws {
        let url = finalDir.appendingPathComponent(Self.recordName)
        guard !isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(["replace": map]).write(to: url, options: .atomic)
    }

    /// The map finalize recorded in `finalDir` (empty when it recorded none).
    public static func recorded(in finalDir: URL) throws -> IdentifierReplacement {
        let url = finalDir.appendingPathComponent(recordName)
        let data: Data
        do { data = try PlainFile.read(url) } catch .absent { return .none } catch {
            throw XlessError(.sign, "\(url.path) \(error.reason)", fix: "run again from finalize (`xless ship --from finalize`)")
        }
        guard let rec = try? JSONDecoder().decode([String: [String: String]].self, from: data), let m = rec["replace"] else {
            throw XlessError(.sign, "\(url.path) is not a record of identifiers.replace", fix: "run again from finalize (`xless ship --from finalize`)")
        }
        return IdentifierReplacement(m)
    }

    /// Sign's check: the overlay's map must be the one finalize applied to the Info.plists. Build code can write the record, beside the
    /// app of finalize, which is not signed: it can have sign refused, or make Info.plists of another map pass, as it can make any others.
    public func checkFinalized(in finalDir: URL, stage: Stage = .sign) throws {
        let applied = try Self.recorded(in: finalDir)
        guard applied != self else { return }
        func keys(_ r: IdentifierReplacement) -> String { r.isEmpty ? "none" : r.map.keys.sorted().joined(separator: ", ") }
        throw XlessError(stage, "identifiers.replace changed since finalize (finalize replaced: \(keys(applied)); the overlay now replaces: \(keys(self)), or maps them differently): the Info.plists and the entitlements would name different identifiers",
                         fix: "run again from finalize: `xless ship --from finalize` (make testflight … ARGS=\"--from finalize\")")
    }

    /// Characters that continue an identifier: a key followed by one of them does not match there.
    static func continuesIdentifier(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }

    /// True when `s` starts with `key` and the identifier ends there (end of `s`, or a character that is not a letter,
    /// digit or `-`).
    static func matches(_ key: String, atStartOf s: Substring) -> Bool {
        guard !key.isEmpty, s.hasPrefix(key) else { return false }
        return s.dropFirst(key.count).first.map { !continuesIdentifier($0) } ?? true
    }

    /// `s` with every occurrence of a key replaced, in one left-to-right pass: at each position the longest key that
    /// matches there (at an identifier boundary, `matches`) wins and replaced text is never scanned again, so the result
    /// does not depend on the map's order and a replacement that contains another key is not rewritten twice.
    public func apply(to s: String) -> String {
        if map.isEmpty { return s }
        let keys = map.keys.filter { !$0.isEmpty }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        var out = "", rest = Substring(s)
        while !rest.isEmpty {
            if let key = keys.first(where: { Self.matches($0, atStartOf: rest) }) {
                out += map[key]!
                rest = rest.dropFirst(key.count)
            } else {
                out.append(rest.removeFirst())
            }
        }
        return out
    }

    /// `value` (a property list value) with `apply` on every string, in nested arrays and dictionaries too (not on
    /// dictionary keys). `changed` gets the key path of each string that changed: `A.B`, `A[0].C`.
    public func rewrite(_ value: Any, path: String = "", changed: inout [String]) -> Any {
        switch value {
        case let s as String:
            let r = apply(to: s)
            if r != s { changed.append(path) }
            return r
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for k in d.keys.sorted() { out[k] = rewrite(d[k]!, path: path.isEmpty ? k : "\(path).\(k)", changed: &changed) }
            return out
        case let a as [Any]:
            return a.enumerated().map { rewrite($1, path: "\(path)[\($0)]", changed: &changed) }
        default:
            return value
        }
    }

    /// Bundle directory extensions whose `Info.plist` is a bundle's (the app, app extensions, frameworks, resource
    /// bundles, XPC services, plug-ins); a macOS bundle's is `Contents/Info.plist`, a macOS framework's `Resources/Info.plist`.
    static let bundleExtensions: Set<String> = ["app", "appex", "framework", "bundle", "xpc", "plugin"]

    /// The bundle-relative paths (`Info.plist`, `PlugIns/X.appex/Info.plist`, `Frameworks/Y.framework/Info.plist`) of
    /// every bundle's Info.plist under `app`, sorted; symbolic links are not followed. Only components below `app` are
    /// looked at (a directory above it named `*.framework` makes nothing a bundle).
    public static func infoPlists(in app: URL) -> [String] {
        let base = app.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.lastPathComponent == "Info.plist" {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            if isBundleInfoPlist(rel) { out.append(rel) }
        }
        return out.sorted()
    }

    /// `rel` (relative to the app) is a bundle's Info.plist: the app's own (`Info.plist`, `Contents/Info.plist`), or one
    /// right inside a nested bundle directory (or its `Contents/`), or a macOS framework's `Resources/Info.plist` (also
    /// below `Versions/<v>/`).
    static func isBundleInfoPlist(_ rel: String) -> Bool {
        let dirs = rel.split(separator: "/").dropLast().map(String.init)
        guard let parent = dirs.last else { return true }   // the app's Info.plist
        func isBundle(_ name: String) -> Bool { bundleExtensions.contains((name as NSString).pathExtension) }
        if isBundle(parent) { return true }
        if parent == "Contents" { return dirs.count == 1 || isBundle(dirs[dirs.count - 2]) }
        if parent == "Resources" { return dirs.dropLast().contains { $0.hasSuffix(".framework") } }
        return false
    }

    /// The extension of the innermost bundle `rel` belongs to ("app" for the app's own Info.plist).
    static func bundleExtension(of rel: String) -> String {
        let dirs = rel.split(separator: "/").dropLast().map(String.init)
        return dirs.last { bundleExtensions.contains(($0 as NSString).pathExtension) }.map { ($0 as NSString).pathExtension } ?? "app"
    }

    /// True when `id` is one of the replaced identifiers or starts with one (at an identifier boundary).
    public func ownsBundleID(_ id: String) -> Bool { map.keys.contains { Self.matches($0, atStartOf: Substring(id)) } }

    /// The app's Info.plists with `rewrite` applied, in place, in their own format (binary stays binary, XML stays XML);
    /// a file with nothing to replace is not rewritten. Rewritten: the app's and its extensions' (`.app`, `.appex`), and
    /// other bundles' only when `ownsBundleID` their `CFBundleIdentifier`, which is kept as it is; every other bundle is
    /// left alone (the ruling above). Returns `<plist path>: <key path>` for each replaced value. A change to the
    /// `CFBundleIdentifier` of an app or extension is refused: those bundle IDs come from the overlay's `bundleIDs`.
    public func rewriteInfoPlists(in app: URL, stage: Stage) throws -> [String] {
        if isEmpty { return [] }
        var report: [String] = []
        for rel in Self.infoPlists(in: app) {
            let url = app.appendingPathComponent(rel)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let data = try? PlainFile.read(url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
                throw XlessError(stage, "\(rel) in \(app.lastPathComponent) is not a dictionary property list", fix: "check how the build produced it")
            }
            let appBundle = ["app", "appex"].contains(Self.bundleExtension(of: rel))
            let bundleID = plist["CFBundleIdentifier"] as? String
            guard appBundle || bundleID.map(ownsBundleID) == true else { continue }
            var changed: [String] = []
            guard var rewritten = rewrite(plist, changed: &changed) as? [String: Any], !changed.isEmpty else { continue }
            if changed.contains("CFBundleIdentifier") {
                guard !appBundle else {
                    throw XlessError(stage, "identifiers.replace would change CFBundleIdentifier in \(rel) (\(plist["CFBundleIdentifier"] ?? "?"))",
                                     fix: "bundle IDs come from the overlay's bundleIDs: narrow the identifiers.replace key so it does not match them")
                }
                rewritten["CFBundleIdentifier"] = bundleID
                changed.removeAll { $0 == "CFBundleIdentifier" }
                if changed.isEmpty { continue }
            }
            do {
                let new = try PropertyListSerialization.data(fromPropertyList: rewritten, format: format, options: 0)
                // (a new file: what else the old one is, is not written. Not `.atomic`: on Windows that writes into the old file.)
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                try FileManager.default.removeItem(at: url)
                try new.write(to: url, options: .withoutOverwriting)
                if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
            } catch {
                throw XlessError(stage, "cannot write \(rel) in \(app.lastPathComponent): \(error)", fix: "check disk space and permissions")
            }
            report += changed.map { "\(rel): \($0)" }
        }
        return report
    }
}

/// Edits an overlay makes to the built app's entitlements before signing: `replace` is the overlay's
/// `identifiers.replace` (`IdentifierReplacement`), `remove` its `entitlements.remove` (keys the signing team cannot have).
public struct EntitlementRewrites: Sendable, Equatable {
    /// Literal substring → replacement, applied to every string value (not to keys) of every bundle's entitlements.
    public var replace: [String: String]
    /// Top-level entitlement keys removed from every bundle's entitlements.
    public var remove: [String]

    public init(replace: [String: String] = [:], remove: [String] = []) { self.replace = replace; self.remove = remove }

    public static let none = EntitlementRewrites()
    public var isEmpty: Bool { replace.isEmpty && remove.isEmpty }

    /// `IdentifierReplacement.apply` with `replace`.
    public func apply(to s: String) -> String { IdentifierReplacement(replace).apply(to: s) }
}
