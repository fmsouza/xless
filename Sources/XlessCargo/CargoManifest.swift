import Foundation
import XlessCore
import XlessTauri

/// Reads package versions out of a repository's tracked `Cargo.toml` files. This is a line-based reader for the few
/// keys xless needs (`[package]` name/version, `[workspace.package]` version), not a TOML parser.
public enum CargoManifest {
    /// How a manifest states its package version.
    enum VersionSpec: Equatable {
        case literal(String)
        /// `version.workspace = true` / `version = { workspace = true }`.
        case workspace
    }

    /// What one manifest says about itself.
    struct Info: Equatable {
        var name: String?
        var version: VersionSpec?
        /// Has a `[workspace]` or `[workspace.*]` table, so members below it can inherit from it.
        var isWorkspace = false
        /// `[workspace.package] version`.
        var workspaceVersion: String?
    }

    /// A repository has hundreds of manifests at most; more means the listing is not what we think it is.
    static let maxManifests = 5000
    static let maxManifestBytes = 1 << 20

    /// The version of the tracked package called `package`, following `version.workspace = true` to the workspace root.
    public static func version(package: String, source: URL) throws -> String {
        let manifests = try load(source: source)
        let matches = manifests.filter { $0.value.name == package }.map(\.key).sorted()
        guard let path = matches.first else {
            throw XlessError(.config, "no package named '\(package)' in the git-tracked Cargo.toml files of \(source.path)",
                             fix: "check the overlay's package: name, and that the package's Cargo.toml is committed (xless reads tracked files only), or set version: in the overlay")
        }
        if matches.count > 1 {
            throw XlessError(.config, "package '\(package)' is declared by several tracked manifests: \(matches.joined(separator: ", "))",
                             fix: "set version: in the overlay, or remove the duplicate manifest")
        }
        guard let info = manifests[path] else {
            throw XlessError(.config, "cannot read \(path)", fix: "set version: in the overlay")
        }
        switch info.version {
        case .literal(let v)?:
            return v
        case nil:
            throw XlessError(.config, "package '\(package)' (\(path)) has no version", fix: "give the package a version in \(path), or set version: in the overlay")
        case .workspace?:
            let root = workspaceRoot(of: path, in: manifests)
            if let root, let v = manifests[root]?.workspaceVersion { return v }
            let rootName = root ?? "Cargo.toml"
            throw XlessError(.config, "\(path) inherits its version from the workspace, but \(rootName) has no [workspace.package] version",
                             fix: "add `[workspace.package]` with `version = \"…\"` to \(rootName), or set version: in the overlay")
        }
    }

    /// `path` itself when it declares a workspace (a root package inheriting from its own `[workspace.package]`); else the
    /// nearest manifest above it that does; failing that, the topmost one above it.
    static func workspaceRoot(of path: String, in manifests: [String: Info]) -> String? {
        if manifests[path]?.isWorkspace == true { return path }
        var dir = (path as NSString).deletingLastPathComponent
        var topmost: String?
        while true {
            // Above the member only: a manifest is its own directory's, so start at the parent.
            dir = (dir as NSString).deletingLastPathComponent
            let candidate = dir.isEmpty ? "Cargo.toml" : "\(dir)/Cargo.toml"
            if let info = manifests[candidate] {
                if info.isWorkspace { return candidate }
                topmost = candidate
            }
            if dir.isEmpty { return topmost }
        }
    }

    /// Every tracked `Cargo.toml` under `source` (relative path → what it says), each read once.
    static func load(source: URL) throws -> [String: Info] {
        let listing: String
        do {
            listing = try WorkCopy.git(source, ["ls-files", "-z", "--", "Cargo.toml", "*/Cargo.toml"], stage: .config)
        } catch let e as XlessError {
            throw XlessError(.config, "cannot list the tracked Cargo.toml files of \(source.path): \(e.cause)",
                             fix: "point source: at a directory of a git checkout, or set version: in the overlay")
        }
        let paths = listing.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if paths.count > maxManifests {
            throw XlessError(.config, "\(source.path) tracks \(paths.count) Cargo.toml files (limit \(maxManifests))",
                             fix: "point source: at the app's directory, or set version: in the overlay")
        }
        var manifests: [String: Info] = [:]
        for path in paths where manifests[path] == nil {
            let url = source.appendingPathComponent(path)
            // A tracked file deleted from disk, or a huge one, is skipped rather than failing the whole lookup.
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxManifestBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            manifests[path] = parse(text)
        }
        return manifests
    }

    static func parse(_ text: String) -> Info {
        enum Table { case none, package, workspacePackage, other }
        var info = Info()
        var table = Table.none
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let header = line.wholeMatch(of: /\[\[?([^\]]*)\]\]?/) {
                let name = header.1.filter { !$0.isWhitespace }
                if name == "workspace" || name.hasPrefix("workspace.") { info.isWorkspace = true }
                switch name {
                case "package" where !line.hasPrefix("[["): table = .package
                case "workspace.package" where !line.hasPrefix("[["): table = .workspacePackage
                default: table = .other
                }
                continue
            }
            switch table {
            case .package:
                if let name = stringValue(line, key: "name") { info.name = name }
                else if let v = stringValue(line, key: "version") { info.version = .literal(v) }
                else if line.wholeMatch(of: /version\s*\.\s*workspace\s*=\s*true/) != nil
                            || line.wholeMatch(of: /version\s*=\s*\{\s*workspace\s*=\s*true\s*,?\s*\}/) != nil {
                    info.version = .workspace
                }
            case .workspacePackage:
                if let v = stringValue(line, key: "version") { info.workspaceVersion = v }
            case .none, .other:
                break
            }
        }
        return info
    }

    /// `key = "value"` or `key = 'value'`.
    private static func stringValue(_ line: String, key: String) -> String? {
        guard let m = line.wholeMatch(of: /([A-Za-z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/), m.1 == key else { return nil }
        return String(m.2 ?? m.3 ?? "")
    }

    /// The line without a trailing `# comment` (a `#` inside a quoted string stays).
    private static func stripComment(_ line: Substring) -> String {
        var quote: Character?
        for i in line.indices {
            let c = line[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<i])
            }
        }
        return String(line)
    }
}
