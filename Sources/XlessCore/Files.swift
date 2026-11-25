import Foundation

public enum Files {
    /// Where temporary files go: TMPDIR's directory, on a Mac too, where Foundation takes the user's own whatever TMPDIR says (and in
    /// the sandbox of a build, `BuildSandbox`, there is none but TMPDIR's).
    public static var temporary: URL {
        #if canImport(Darwin)
        if let path = ProcessInfo.processInfo.environment["TMPDIR"], path.hasPrefix("/"), FileManager.default.isWritableFile(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.temporaryDirectory
    }

    /// Recreates `dir` empty, copies `bundle` into it, returns the copy's URL.
    public static func copyBundle(_ bundle: URL, intoFreshDir dir: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: bundle, to: dest)
        return dest
    }

    /// Builds a stage's output directory so it exists only if the stage succeeded; the next stage trusts it.
    /// Removes `dir` first (a stale output must not outlive a failed run), lets `body` fill an empty `<dir>.partial`,
    /// then renames it to `dir`. On failure `<dir>.partial` is removed and the error rethrown. Returns `body`'s URL
    /// rebased from `<dir>.partial` into `dir`.
    public static func atomicOutput(_ dir: URL, _ body: (URL) throws -> URL) throws -> URL {
        let partial = try beginOutput(dir)
        let result: URL
        do { result = try body(partial) } catch { try? FileManager.default.removeItem(at: partial); throw error }
        return try commitOutput(partial, to: dir, result: result)
    }

    /// Async variant of `atomicOutput(_:_:)`.
    public static func atomicOutput(_ dir: URL, _ body: (URL) async throws -> URL) async throws -> URL {
        let partial = try beginOutput(dir)
        let result: URL
        do { result = try await body(partial) } catch { try? FileManager.default.removeItem(at: partial); throw error }
        return try commitOutput(partial, to: dir, result: result)
    }

    static func partialDir(for dir: URL) -> URL {
        dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".partial", isDirectory: true)
    }

    private static func beginOutput(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        let partial = partialDir(for: dir)
        try? fm.removeItem(at: dir)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        return partial
    }

    private static func commitOutput(_ partial: URL, to dir: URL, result: URL) throws -> URL {
        let fm = FileManager.default
        do { try fm.moveItem(at: partial, to: dir) } catch { try? fm.removeItem(at: partial); throw error }
        let base = partial.standardizedFileURL.path, path = result.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return result }
        let rel = String(path.dropFirst(base.count)).drop { $0 == "/" }
        return rel.isEmpty ? dir : dir.appendingPathComponent(String(rel))
    }

    /// Recreates `dir` empty.
    public static func fresh(_ dir: URL) throws -> URL {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All regular files under `dir`, recursively, not following symlinks.
    public static func regularFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter {
            let v = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return v?.isRegularFile == true && v?.isSymbolicLink != true
        }
    }
}
