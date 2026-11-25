import Foundation

/// Paths as a run takes them, and what keeps secrets out of what a build container mounts.
struct RunFiles {
    let host: any RunHost
    let home: String

    /// `~` and `~/…` in full.
    func expanded(_ path: String) -> String {
        path == "~" ? home : RunText.value(of: "~/", in: path).map { "\(home)/\($0)" } ?? path
    }

    /// In full, without `.` and `..`, symbolic links as they are.
    func absolute(_ path: String, in directory: String? = nil) -> String {
        var parts: [String] = []
        for part in RunText.cut(RunText.isAbsolute(path) ? path : (directory ?? host.currentDirectory) + "/" + path, at: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// A regular file, or a link to one.
    func isFile(_ path: String) -> Bool { host.isFile(path) }

    static func parent(_ path: String) -> String {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return "." }
        return slash == bytes.startIndex ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
    }

    static func name(_ path: String) -> String { RunText.cut(path, at: "/").last ?? path }

    /// A file's name without its last extension.
    static func stem(_ path: String) -> String {
        let bytes = name(path).utf8
        return bytes.lastIndex(of: UInt8(ascii: ".")).map { String(decoding: bytes[..<$0], as: UTF8.self) } ?? String(bytes)
    }

    /// The path with every symbolic link resolved, of what a container gets or a secret is in: where it is must be known.
    func real(_ path: String) throws -> String {
        guard let real = host.realPath(path) else { throw unknown(path) }
        return real
    }

    /// The same for the home directory, which no container gets.
    private func realHome() throws -> String {
        guard let real = host.realPath(home) else {
            let why = home.isEmpty ? "HOME is empty" : "HOME: \(home), which is not there, or not to be seen"
            throw RunStop.usage("cannot tell where your home directory is (\(why)), and so not whether it would be in what the build container gets; set HOME to a directory that is there")
        }
        return real
    }

    private func unknown(_ path: String) -> RunStop {
        .usage("cannot tell where \(path) is, and so not whether a secret would be in what the build container gets; check that it is there, that you may reach it, and that its name is UTF-8")
    }

    private func isSame(_ a: String, _ b: String) throws -> Bool {
        guard let same = host.isSame(a, b) else { throw unknown(host.isSame(a, a) == nil ? a : b) }
        return same
    }

    /// `directory` or one above it is `other`: compared as files, so that neither a symbolic link nor another spelling of the
    /// path (case and Unicode on macOS file systems, and the folders that macOS shows in two places) hides it. Throws where that
    /// cannot be told.
    func directory(_ directory: String, isIn other: String) throws -> Bool {
        let path = try real(directory)
        guard let physical = host.physicalPath(path), RunText.isAbsolute(physical) else { throw unknown(directory) }
        return try [path, physical].contains {
            var here = $0
            while try !isSame(here, other) {
                if here == "/" { return false }
                here = Self.parent(here)
            }
            return true
        }
    }

    /// The file is somewhere below `directory`, wherever a link to it is.
    func file(_ path: String, isIn other: String) throws -> Bool { try directory(Self.parent(real(path)), isIn: other) }

    /// `/`, the home directory or a directory above it.
    func isBroad(_ path: String) throws -> Bool { try isSame(path, "/") || directory(realHome(), isIn: path) }

    /// The file or directory itself, or one below it.
    func file(_ path: String, isOrIsIn other: String) throws -> Bool { try isSame(path, other) || file(path, isIn: other) }
}
