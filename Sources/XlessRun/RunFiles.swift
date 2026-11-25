import Foundation

/// Paths as a run takes them, and what keeps secrets out of what a build container mounts.
struct RunFiles {
    let host: any RunHost
    let home: String

    /// `~` and `~/…` in full.
    func expanded(_ path: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    /// In full, without `.` and `..`, symbolic links as they are.
    func absolute(_ path: String, in directory: String? = nil) -> String {
        var parts: [Substring] = []
        for part in (path.hasPrefix("/") ? path : (directory ?? host.currentDirectory) + "/" + path).split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    func isFile(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) && !isDirectory(path) }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    static func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    /// A file's name without its last extension.
    static func stem(_ path: String) -> String {
        let name = name(path)
        return name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
    }

    /// `directory` or one above it is `other`: compared as files, so that neither a symbolic link nor another spelling of the
    /// path (case, on macOS file systems) hides it.
    func directory(_ directory: String, isIn other: String) -> Bool {
        guard var here = host.realPath(directory) else { return false }
        while true {
            if host.isSame(here, other) { return true }
            if here == "/" { return false }
            here = Self.parent(here)
        }
    }

    /// The file is somewhere below `directory`, wherever a link to it is.
    func file(_ path: String, isIn other: String) -> Bool {
        host.realPath(path).map { directory(Self.parent($0), isIn: other) } ?? false
    }

    /// `/`, the home directory or a directory above it.
    func isBroad(_ path: String) -> Bool { host.isSame(path, "/") || host.isSame(path, home) || directory(home, isIn: path) }
}
