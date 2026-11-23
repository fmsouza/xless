import Foundation
import Yams

/// Reads an `appstore/` directory into a `StoreManifest`. Never fails outright: what cannot be read becomes a
/// `StoreIssue` (the caller decides whether errors stop it), so `validate` reports every problem in one run.
public enum ManifestReader {
    public static let appFile = "app.yml"
    /// Directories at the top of the manifest that are not locales: in-app purchases (#108), App Review attachments
    /// and the export compliance document.
    public static let reservedDirectories: Set<String> = ["iap", "subscriptions", "review", "compliance"]

    public struct Result: Sendable {
        public var manifest: StoreManifest
        public var issues: [StoreIssue]
        /// Whether `app.yml` exists.
        public var hasAppFile: Bool
        /// Whether `app.yml` exists and its values could be read (else `manifest.app` is empty, not the file's).
        public var appReadable: Bool = false
    }

    public static func read(_ dir: URL) -> Result {
        let name = dir.lastPathComponent
        var issues: [StoreIssue] = []
        var manifest = StoreManifest()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return Result(manifest: manifest, issues: [StoreIssue(name, "no such directory",
                                                                 fix: "run `xless store pull` to create it from an existing app, or pass --dir")],
                          hasAppFile: false)
        }

        let appURL = dir.appendingPathComponent(appFile)
        let hasAppFile = fm.fileExists(atPath: appURL.path)
        var appReadable = false
        if hasAppFile {
            let (app, extras, appIssues) = readApp(appURL, display: "\(name)/\(appFile)")
            manifest.app = app
            manifest.extras = extras
            issues += appIssues
            appReadable = !appIssues.contains { $0.severity == .error }
        } else {
            issues.append(StoreIssue("\(name)/\(appFile)", "missing", fix: "run `xless store pull`, or write it (docs/appstore-manifest.md)"))
        }

        for entry in children(dir) where isDirectory(entry) && !reservedDirectories.contains(entry.lastPathComponent) {
            let (listing, localeIssues) = readLocale(entry, display: "\(name)/\(entry.lastPathComponent)")
            manifest.locales[entry.lastPathComponent] = listing
            issues += localeIssues
        }
        return Result(manifest: manifest, issues: issues, hasAppFile: hasAppFile, appReadable: appReadable)
    }

    // MARK: - app.yml

    static func readApp(_ url: URL, display: String) -> (AppYAML, [(key: String, yaml: String)], [StoreIssue]) {
        guard let data = try? Data(contentsOf: url) else {
            return (AppYAML(), [], [StoreIssue(display, "cannot be read", fix: "check its permissions")])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return (AppYAML(), [], [StoreIssue(display, "is not UTF-8 text", fix: "save it as UTF-8")])
        }
        let node: Node?
        do { node = try Yams.compose(yaml: text) } catch {
            return (AppYAML(), [], [StoreIssue(display, "is not valid YAML (\(yamlProblem(error)))", fix: "fix the YAML syntax")])
        }
        guard let node else { return (AppYAML(), [], []) }
        guard let mapping = node.mapping else {
            return (AppYAML(), [], [StoreIssue(display, "is not a YAML mapping", fix: "write `key: value` lines, e.g. `primaryLocale: en-US` (docs/appstore-manifest.md)")])
        }
        var issues: [StoreIssue] = []
        var extras: [(key: String, yaml: String)] = []
        for (key, value) in mapping {
            let k = key.string ?? "\(key)"
            if AppYAML.keys.contains(k) { continue }
            if !AppYAML.reservedKeys.contains(k) {
                let near = AppYAML.keys.first { $0.lowercased() == k.lowercased() }
                issues.append(StoreIssue(display, "unknown key `\(k)`", fix: near.map { "did you mean `\($0)`?" } ?? "remove it; the keys are listed in docs/appstore-manifest.md",
                                         severity: .warning))
            }
            let single = Node([(key, value)], .implicit, .block)
            extras.append((k, (try? Yams.serialize(node: single, width: -1, allowUnicode: true)) ?? ""))
        }
        do {
            let app = try YAMLDecoder().decode(AppYAML.self, from: node)
            return (app, extras, issues)
        } catch let error as DecodingError {
            issues.append(decodingIssue(error, display: display))
        } catch {
            issues.append(StoreIssue(display, "cannot be read: \(error)", fix: "compare it with docs/appstore-manifest.md"))
        }
        return (AppYAML(), extras, issues)
    }

    /// The first line of Yams' description (it goes on to quote the offending line).
    static func yamlProblem(_ error: Error) -> String {
        String(describing: error).split(separator: "\n").first.map(String.init) ?? "\(error)"
    }

    static func decodingIssue(_ error: DecodingError, display: String) -> StoreIssue {
        func path(_ c: [CodingKey]) -> String {
            c.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .typeMismatch(let type, let context):
            let name = "\(type)"
            let what = type == String.self ? "a text value" : type == Bool.self ? "true or false"
                : name.contains("Dictionary") || name.contains("Mapping") || name.contains("Keyed") ? "a mapping"
                : name.contains("Array") || name.contains("Sequence") || name.contains("Unkeyed") ? "a list" : name
            return StoreIssue(display, "`\(path(context.codingPath))` should be \(what)", fix: "compare it with docs/appstore-manifest.md")
        case .valueNotFound(_, let context):
            return StoreIssue(display, "`\(path(context.codingPath))` has no value", fix: "give it a value or remove the key")
        case .keyNotFound(let key, let context):
            return StoreIssue(display, "`\(path(context.codingPath + [key]))` is missing", fix: "add it (docs/appstore-manifest.md)")
        case .dataCorrupted(let context):
            return StoreIssue(display, "`\(path(context.codingPath))`: \(context.debugDescription)", fix: "compare it with docs/appstore-manifest.md")
        @unknown default:
            return StoreIssue(display, "cannot be read: \(error)", fix: "compare it with docs/appstore-manifest.md")
        }
    }

    // MARK: - Locales

    static func readLocale(_ dir: URL, display: String) -> (LocaleListing, [StoreIssue]) {
        var listing = LocaleListing()
        var issues: [StoreIssue] = []
        let known = Set(LocaleListing.textFields.map(\.file))
        for (file, field) in LocaleListing.textFields {
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            switch ManifestText.read(url, isURL: LocaleListing.urlFiles.contains(file)) {
            case .success(let value): listing[keyPath: field] = value
            case .failure(let problem): issues.append(StoreIssue("\(display)/\(file)", problem.message, fix: problem.fix))
            }
        }
        for entry in children(dir) {
            let n = entry.lastPathComponent
            if n == "screenshots" || n == "previews", isDirectory(entry) { continue }
            if !known.contains(n) {
                let near = known.first { $0.lowercased() == n.lowercased() }
                issues.append(StoreIssue("\(display)/\(n)", "is not part of the listing; xless ignores it",
                                         fix: near.map { "rename it to \($0)" } ?? "the files of a locale are listed in docs/appstore-manifest.md", severity: .warning))
            }
        }
        listing.screenshots = mediaSets(dir.appendingPathComponent("screenshots"), relative: "\(dir.lastPathComponent)/screenshots",
                                        display: "\(display)/screenshots", issues: &issues)
        listing.previews = mediaSets(dir.appendingPathComponent("previews"), relative: "\(dir.lastPathComponent)/previews",
                                     display: "\(display)/previews", issues: &issues)
        return (listing, issues)
    }

    static func mediaSets(_ dir: URL, relative: String, display: String, issues: inout [StoreIssue]) -> [MediaSet] {
        var sets: [MediaSet] = []
        for entry in children(dir) {
            guard isDirectory(entry) else {
                issues.append(StoreIssue("\(display)/\(entry.lastPathComponent)", "is not inside a display type directory",
                                         fix: "move it into \(display)/<display type>/ (e.g. APP_IPHONE_67)", severity: .warning))
                continue
            }
            let type = entry.lastPathComponent
            let files = MediaOrder.sorted(children(entry).filter { !isDirectory($0) }.map(\.lastPathComponent))
            sets.append(MediaSet(type: type, files: files.map { "\(relative)/\(type)/\($0)" }))
        }
        return sets.sorted { $0.type < $1.type }
    }

    /// The visible entries of `dir` (no dot files), by name; empty when it does not exist.
    static func children(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// The text files of a locale: UTF-8, trailing line breaks not part of the value (URL files: no surrounding
/// whitespace); an empty file is the same as no file.
public enum ManifestText {
    public struct Problem: Error, Sendable, Equatable {
        public var message: String
        public var fix: String
    }

    public static func read(_ url: URL, isURL: Bool) -> Result<String?, Problem> {
        guard let data = try? Data(contentsOf: url) else { return .failure(Problem(message: "cannot be read", fix: "check its permissions")) }
        guard var text = String(data: data, encoding: .utf8) else {
            return .failure(Problem(message: "is not UTF-8 text", fix: "save it as UTF-8"))
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return .success(normalize(text, isURL: isURL))
    }

    /// The value a file's text stands for.
    public static func normalize(_ raw: String, isURL: Bool) -> String? {
        var text = raw
        if isURL {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            // "\r\n" is one Character in Swift: strip it and lone "\n" / "\r" alike.
            while let last = text.last, last == "\n" || last == "\r" || last == "\r\n" { text.removeLast() }
        }
        return text.isEmpty ? nil : text
    }

    /// A value as written to its file.
    public static func render(_ value: String) -> String { value + "\n" }
}
