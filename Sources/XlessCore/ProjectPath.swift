import Foundation
#if os(Windows)
import CXlessWindows
#endif

/// Names that a project's files, or Apple's answers, give to files. Windows takes more of them for something other than a file in
/// the directory they are put in: a device (`NUL`), a stream (`a.txt:b`), another drive or share, or a name without its last dot.
public enum ProjectPath {
    /// Why `relative`, whose parts are separated by `/`, names no plain file on this system: a sentence's end, or nil. Only Windows
    /// refuses any; what leads outside a directory is `isInside`'s to tell.
    public static func problem(_ relative: String) -> String? {
        #if os(Windows)
        problemOnWindows(relative)
        #else
        nil
        #endif
    }

    /// Throws where `problem` has something to say.
    public static func check(_ relative: String, stage: Stage) throws {
        guard let problem = problem(relative) else { return }
        throw XlessError(stage, "\(relative) \(problem)", fix: "Windows can have no file of that name: rename it where it comes from, or use xless on Linux, macOS or in WSL2")
    }

    static func problemOnWindows(_ relative: String) -> String? {
        if relative.unicodeScalars.contains(where: { $0.value < 0x20 }) { return "has a control character in its name" }
        if let bad = relative.first(where: { "\\:<>\"|?*".contains($0) }) { return "has a \(bad) in its name" }
        if relative.hasPrefix("/") { return "is not a path inside the directory" }
        for part in relative.split(separator: "/") where part != "." && part != ".." {
            // Looked at by scalar: a combining mark makes another character of a dot, and Windows sees the dot.
            if let last = part.unicodeScalars.last, last == "." || last == " " { return "ends in a dot or a space, which Windows drops" }
            if isDevice(part) { return "is the name of a device" }
        }
        return nil
    }

    /// `NUL`, `nul.txt`, `COM1`, …: a device whatever comes after the first dot (Windows 11 has some of them as files; Windows 10 not).
    private static func isDevice(_ part: Substring) -> Bool {
        let scalars = part.unicodeScalars.prefix { $0 != "." }
        var base = String(String.UnicodeScalarView(scalars)).uppercased()
        while base.unicodeScalars.last == " " { base.unicodeScalars.removeLast() }
        if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"].contains(base) { return true }
        guard base.hasPrefix("COM") || base.hasPrefix("LPT"), base.unicodeScalars.count == 4, let digit = base.unicodeScalars.last else { return false }
        return "0123456789\u{B9}\u{B2}\u{B3}".unicodeScalars.contains(digit)
    }

    /// Whether `file`, or the directory it would be in, is inside the directory `root`, links followed.
    public static func isInside(_ file: URL, _ root: URL) -> Bool {
        #if os(Windows)
        guard let base = finalPath(root.path) else { return false }
        if let target = finalPath(file.path) { return isInsideOnWindows(target, base) }
        // Not there: what is there of its path, and the rest as it is.
        guard !PrivateFile.exists(file.path), !file.lastPathComponent.isEmpty, ![".", "..", "/"].contains(file.lastPathComponent) else { return false }
        var parent = file.deletingLastPathComponent()
        while finalPath(parent.path) == nil {
            let above = parent.deletingLastPathComponent()
            guard above.path.count < parent.path.count, !PrivateFile.exists(parent.path) else { return false }
            parent = above
        }
        guard let held = finalPath(parent.path) else { return false }
        return held.compare(base, options: [.caseInsensitive, .literal]) == .orderedSame || isInsideOnWindows(held, base)
        #else
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        // A missing file's own path cannot be resolved: resolve its directory's.
        let resolved = FileManager.default.fileExists(atPath: file.path) ? file.resolvingSymlinksInPath()
            : file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
        return resolved.standardizedFileURL.path.hasPrefix(base + "/")
        #endif
    }

    /// Of two whole paths with `\`, as Windows has them: whether the first is inside the second, without case, part by part.
    static func isInsideOnWindows(_ path: String, _ root: String) -> Bool {
        func parts(_ path: String) -> [String] { path.split(separator: "\\").map { $0.lowercased() } }
        let inner = parts(path), outer = parts(root)
        return inner.count > outer.count && inner.starts(with: outer)
    }

    #if os(Windows)
    private static func finalPath(_ path: String) -> String? {
        var out = [UInt16](repeating: 0, count: 32768)
        guard path.withWide({ xless_final_path($0, &out, out.count) }) > 0 else { return nil }
        return String(wide: out)
    }
    #endif
}
