import Foundation
import Yams

/// Writes a manifest directory all at once: the new tree is built next to it and swapped in by renames, so an
/// interrupted `pull` leaves the old directory as it was. Files the format does not own (a README, notes, `iap/`) are
/// carried over from the old directory.
public enum ManifestWriter {
    /// A file of the new tree besides app.yml and the text files: bytes, or a file to copy (a kept original).
    public enum Content: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    public static func renderApp(_ manifest: StoreManifest) throws -> String {
        var options = YAMLEncoder.Options()
        options.allowUnicode = true
        options.width = -1
        options.newLineScalarStyle = .literal
        let encoder = YAMLEncoder()
        encoder.options = options
        var text = "# The App Store listing (docs/appstore-manifest.md). `xless store pull` rewrites this file; values are App Store Connect's.\n"
        let body = try encoder.encode(manifest.app)
        if body.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" { text += body }
        for extra in manifest.extras {
            if !text.hasSuffix("\n") { text += "\n" }
            text += extra.yaml
        }
        return text
    }

    /// Whether `relative` (a path inside the manifest directory) is a file the format owns: rewritten by `pull`, never
    /// carried over.
    public static func owns(_ relative: String) -> Bool {
        let c = relative.split(separator: "/").map(String.init)
        guard let first = c.first else { return false }
        if c.count == 1 { return [ManifestReader.appFile, MediaLock.fileName, "eula.txt"].contains(first) }
        if ManifestReader.reservedDirectories.contains(first) { return false }
        if c.count == 2 { return LocaleListing.textFields.contains { $0.file == c[1] } }
        return c[1] == "screenshots" || c[1] == "previews"
    }

    /// Writes `manifest` to `dir`, replacing it.
    /// - Parameters:
    ///   - files: the other files of the new tree (screenshots, previews, eula.txt), by path relative to `dir`.
    ///   - lock: written as media.lock unless empty.
    public static func write(_ manifest: StoreManifest, files: [String: Content], lock: MediaLock, to dir: URL) throws {
        let fm = FileManager.default
        let parent = dir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let partial = parent.appendingPathComponent(".\(dir.lastPathComponent).partial-\(pid)")
        let old = parent.appendingPathComponent(".\(dir.lastPathComponent).old-\(pid)")
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: old)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            try fill(partial, manifest: manifest, files: files, lock: lock, previous: dir)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        guard fm.fileExists(atPath: dir.path) else {
            try fm.moveItem(at: partial, to: dir)
            return
        }
        try fm.moveItem(at: dir, to: old)
        do { try fm.moveItem(at: partial, to: dir) } catch {
            try? fm.moveItem(at: old, to: dir)
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    static func fill(_ root: URL, manifest: StoreManifest, files: [String: Content], lock: MediaLock, previous: URL) throws {
        let fm = FileManager.default
        func put(_ data: Data, _ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try put(Data(try renderApp(manifest).utf8), ManifestReader.appFile)
        for (locale, listing) in manifest.locales {
            try fm.createDirectory(at: root.appendingPathComponent(locale), withIntermediateDirectories: true)
            for (file, field) in LocaleListing.textFields {
                if let value = listing[keyPath: field] { try put(Data(ManifestText.render(value).utf8), "\(locale)/\(file)") }
            }
        }
        for (relative, content) in files.sorted(by: { $0.key < $1.key }) {
            switch content {
            case .data(let data): try put(data, relative)
            case .file(let source):
                let url = root.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: url)
            }
        }
        if !lock.files.isEmpty { try put(Data(try lock.render().utf8), MediaLock.fileName) }

        // What the format does not own comes along from the old directory.
        for relative in relativeFiles(under: previous) {
            let target = root.appendingPathComponent(relative)
            guard !owns(relative), !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: previous.appendingPathComponent(relative), to: target)
        }
    }

    /// The regular files under `dir` (hidden ones included, symbolic links not followed), as paths relative to it. The
    /// enumerator gives relative paths, so a symbolic link in `dir`'s own path (macOS's /var → /private/var) cannot skew them.
    static func relativeFiles(under dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        return e.compactMap { $0 as? String }.filter {
            (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.type] as? FileAttributeType) == .typeRegular
        }.sorted()
    }
}
