import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What build code left for a program that runs where the secrets are: signed, zipped, imaged, uploaded, by tools that follow links,
/// read what they find and take lists of names.
public enum BuiltTree {
    /// Directories in one another.
    public static let maxDepth = 256

    /// Refuses a tree that holds anything but directories, files, and links that stay in it wherever it is copied to (`rsync`, `cpio` or
    /// a signer may go through one), or a name that ends a line or drives a terminal.
    public static func check(_ root: URL, stage: Stage) throws {
        let top = root.path
        func refused(_ path: String, _ why: String) -> XlessError {
            XlessError(stage, TerminalText.escaped("\(path) in \(root.lastPathComponent) \(why)"), fix: "look at what in the build put it there, then build again")
        }
        guard type(of: top) == S_IFDIR else { throw XlessError(stage, TerminalText.escaped("\(top) is not a directory"), fix: "look at what put it there, then run the previous stage again") }
        guard let real = real(top) else { throw refused(".", "cannot be read") }

        func walk(_ directory: String, _ above: [String]) throws {
            let place = above.joined(separator: "/")
            guard above.count < maxDepth else { throw refused(place, "is nested deeper than \(maxDepth) directories") }
            guard let names = names(in: directory) else { throw refused(place, "cannot be listed, or holds a name that is not UTF-8") }
            for name in names {
                let path = "\(directory)/\(name)", parts = above + [name], shown = parts.joined(separator: "/")
                guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw refused(shown, "has a control character in its name") }
                switch type(of: path) {
                case S_IFDIR: try walk(path, parts)
                case S_IFREG: continue
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), stays(target, in: above), isBelow(path, real) else {
                        throw refused(shown, "is a link that leads out of it")
                    }
                default: throw refused(shown, "is neither a file, nor a directory, nor a link")
                }
            }
        }
        try walk(top, [])
    }

    /// By its text.
    private static func stays(_ target: String, in directory: [String]) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        var depth = directory.count
        for part in target.split(separator: "/") where part != "." {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return false }
        }
        return true
    }

    /// By where it leads now (a part of its path may be a link as well). What is not there leads nowhere.
    private static func isBelow(_ link: String, _ root: String) -> Bool {
        guard let there = real(link) else { return errno == ENOENT }
        return there == root || there.hasPrefix(root + "/")
    }

    private static func real(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func type(of path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    /// In C: on a Mac, Foundation's crashes on very deep paths. nil: not a list of names.
    private static func names(in path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) }
            guard let name else { return nil }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}

extension StagePaths {
    /// The single `.app` inside a stage directory.
    public func bundle(in dir: URL, stage: Stage) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw XlessError(stage, "no .app found in \(dir.path)", fix: "run the previous stage first (or `xless ship`)")
        }
        // (one that leads elsewhere would be signed there)
        guard (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory else {
            throw XlessError(stage, "\(dir.path) is not a directory", fix: "look at what put it there, then run the previous stage again")
        }
        try BuiltTree.check(app, stage: stage)
        return app
    }
}
