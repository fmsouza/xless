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
    public static let maxDepth = 64
    /// Links that lead to one another.
    static let maxLinks = 32

    /// Refuses a tree that holds anything but directories, files, and links that stay in it wherever it is copied to (`rsync`, `cpio` or
    /// a signer may go through one), or a name that ends a line or drives a terminal.
    public static func check(_ root: URL, stage: Stage) throws {
        let top = root.path
        func refused(_ path: String, _ why: String) -> XlessError {
            XlessError(stage, TerminalText.escaped("\(path) in \(root.lastPathComponent) \(why)"), fix: "look at what in the build put it there, then build again")
        }
        guard type(of: top) == S_IFDIR else { throw notDirectory(top, stage) }

        func walk(_ directory: String, _ above: [String]) throws {
            let place = above.joined(separator: "/")
            guard above.count < maxDepth else { throw refused(place, "is nested deeper than \(maxDepth) directories") }
            guard let names = opendir(directory).flatMap(names) else { throw refused(place, "cannot be listed, or holds a name that is not UTF-8") }
            for name in names {
                let path = "\(directory)/\(name)", parts = above + [name], shown = parts.joined(separator: "/")
                guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw refused(shown, "has a control character in its name") }
                switch type(of: path) {
                case S_IFDIR: try walk(path, parts)
                case S_IFREG: continue
                case S_IFLNK:
                    guard case .link(let target) = link(at: Array(path.utf8)), stays(target, in: above, of: top) else { throw refused(shown, "is a link that leads out of it") }
                default: throw refused(shown, "is neither a file, nor a directory, nor a link")
                }
            }
        }
        try walk(top, [])
    }

    /// Copies a tree that the build may still change meanwhile: by what is open and never by a path, so a directory that becomes a link to
    /// the user's own is not gone into, and a pipe is not waited for. Modes and dates stay, and what a file has besides its bytes, but for
    /// flags and lists that would keep xless from changing or removing it; a directory's extended attributes do not. `to` is not there yet.
    public static func copy(_ from: URL, to: URL, stage: Stage) throws { try copy(from, to: to, stage: stage) { _ in } }

    /// `between`: after something was looked at and before it is opened (for the tests).
    static func copy(_ from: URL, to: URL, stage: Stage, between: (_ path: String) -> Void) throws {
        func failed(_ name: String, _ why: String) -> XlessError {
            XlessError(stage, TerminalText.escaped("cannot copy \(name.isEmpty ? from.path : "\(name) in \(from.lastPathComponent)"): \(why)"), fix: "look at what in the build put it there, or still writes there, then build again")
        }
        func system(_ name: String) -> XlessError { failed(name, String(cString: strerror(errno))) }

        func directory(_ source: Int32, to target: String, _ above: [String]) throws {
            defer { close(source) }
            let place = above.joined(separator: "/")
            guard above.count < maxDepth else { throw failed(place, "it is nested deeper than \(maxDepth) directories") }
            var own = stat()
            guard fstat(source, &own) == 0, mkdir(target, 0o700) == 0 else { throw system(place) }
            guard let names = opened(source).flatMap(names) else { throw failed(place, "it cannot be listed, or holds a name that is not UTF-8") }
            for name in names {
                let shown = (above + [name]).joined(separator: "/"), to = "\(target)/\(name)"
                var info = stat()
                guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw system(shown) }
                between(shown)
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    guard case .link(let path) = link(at: Array(name.utf8), in: source) else { throw system(shown) }
                    guard symlink(path.map { CChar(bitPattern: $0) } + [0], to) == 0, utimensat(AT_FDCWD, to, times(info), AT_SYMLINK_NOFOLLOW) == 0 else { throw system(shown) }
                case S_IFDIR:
                    let fd = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw system(shown) }
                    try directory(fd, to: to, above + [name])
                default:
                    let fd = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw system(shown) }
                    defer { close(fd) }
                    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw failed(shown, "it is neither a file, nor a directory, nor a link") }
                    guard file(fd, to: to, info) else { throw system(shown) }
                }
            }
            guard chmod(target, own.st_mode & 0o777) == 0, utimensat(AT_FDCWD, target, times(own), 0) == 0 else { throw system(place) }
        }
        let fd = open(from.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? system("") : notDirectory(from.path, stage) }
        try directory(fd, to: to.path, [])
    }

    /// Writes a new file into a tree of the build's: what is at its place, a link say, goes (a file's mode stays), and nothing on the way
    /// there is a link. (When it is looked at: the way is for a tree that only xless writes, sign's copy. In finalize on a Mac what the
    /// build left running can change it meanwhile, but there the build writes with the same rights.)
    public static func write(_ data: Data, at path: String, in root: URL, stage: Stage) throws {
        var at = root.path
        let parts = path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
        func system(_ place: String) -> XlessError { XlessError(stage, TerminalText.escaped("cannot write \(place): \(String(cString: strerror(errno)))"), fix: "check disk space and permissions") }
        func refused(_ place: String) -> XlessError { XlessError(stage, TerminalText.escaped("\(place) is in the way of \(path)"), fix: "look at what in the build put it there, then build again") }
        for part in parts.dropLast() {
            at += "/\(part)"
            guard type(of: at) == nil ? mkdir(at, 0o777) == 0 : type(of: at) == S_IFDIR else { throw refused(at) }
        }
        guard let name = parts.last else { throw refused(at) }
        at += "/\(name)"
        guard type(of: at) != S_IFDIR else { throw refused(at) }
        var old = stat()
        let mode = lstat(at, &old) == 0 && old.st_mode & S_IFMT == S_IFREG ? old.st_mode & 0o777 : nil
        guard unlink(at) == 0 || errno == ENOENT else { throw system(at) }
        let fd = open(at, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw system(at) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            if let mode, fchmod(fd, mode) != 0 { throw system(at) }
            try file.write(contentsOf: data)
        } catch { throw system(at) }
    }

    // MARK: -

    private static func notDirectory(_ path: String, _ stage: Stage) -> XlessError {
        XlessError(stage, TerminalText.escaped("\(path) is not a directory"), fix: "look at what put it there, then run the previous stage again")
    }

    /// Whether a link in `directory` (names below `top`, none of them a link) leads to a place below `top`, or to `top`: as the system
    /// goes, through links as well, name by name and by their bytes; and as it would go if what is not there were, for whoever makes it.
    private static func stays(_ target: [UInt8], in directory: [String], of top: String) -> Bool {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        func ahead(_ path: [UInt8]) -> [[UInt8]] { path.split(separator: slash).reversed().map(Array.init) }
        guard !target.isEmpty, target.first != slash else { return false }
        var at = directory.map { Array($0.utf8) }, rest = ahead(target), links = 1
        while let part = rest.popLast() {
            if part == [dot] { continue }
            if part == [dot, dot] {
                guard at.popLast() != nil else { return false }
                continue
            }
            switch link(at: at.reduce(Array(top.utf8)) { $0 + [slash] + $1 } + [slash] + part) {
            case .none: at.append(part)
            case .link(let next):
                links += 1
                guard links <= maxLinks, !next.isEmpty, next.first != slash else { return false }
                rest += ahead(next)
            case .unknown: return false
            }
        }
        return true
    }

    private enum Link { case none, link([UInt8]), unknown }

    private static func link(at path: [UInt8], in directory: Int32 = AT_FDCWD) -> Link {
        var target = [CChar](repeating: 0, count: 8192)
        let count = readlinkat(directory, path.map { CChar(bitPattern: $0) } + [0], &target, target.count)
        if count < 0 { return [EINVAL, ENOENT, ENOTDIR].contains(errno) ? .none : .unknown }
        return count < target.count ? .link(target.prefix(count).map { UInt8(bitPattern: $0) }) : .unknown
    }

    private static func type(of path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    /// In C: on a Mac, Foundation's crashes on very deep paths. nil: not a list of names.
    private static func names(in directory: Directory) -> [String]? {
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) }
            guard let name else { return nil }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// A directory of its own to list, so that `directory` stays open, in no program that another thread starts.
    private static func opened(_ directory: Int32) -> Directory? {
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let listing = fdopendir(fd) else { close(fd); return nil }
        return listing
    }

    private static func times(_ info: stat) -> [timespec] {
        #if canImport(Darwin)
        [info.st_mtimespec, info.st_mtimespec]
        #else
        [info.st_mtim, info.st_mtim]
        #endif
    }

    private static func file(_ source: Int32, to path: String, _ info: stat) -> Bool {
        #if canImport(Darwin)
        if fclonefileat(source, AT_FDCWD, path, UInt32(CLONE_NOFOLLOW)) == 0 {
            var copy = stat()
            let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
            return lstat(path, &copy) == 0 && (copy.st_flags & locks == 0 || chflags(path, copy.st_flags & ~locks) == 0)
        }
        #endif
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        #if canImport(Darwin)
        guard fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_DATA_SPARSE | COPYFILE_XATTR)) == 0 else { return false }
        #else
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let got = read(source, &buffer, buffer.count)
            if got < 0, errno == EINTR { continue }
            guard got >= 0 else { return false }
            if got == 0 { break }
            if buffer[..<got].allSatisfy({ $0 == 0 }) { // a hole, perhaps of many gigabytes
                guard lseek(fd, off_t(got), SEEK_CUR) >= 0 else { return false }
                continue
            }
            var put = 0
            while put < got {
                let n = buffer.withUnsafeBytes { systemWrite(fd, $0.baseAddress! + put, got - put) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                put += n
            }
        }
        guard ftruncate(fd, lseek(fd, 0, SEEK_CUR)) == 0 else { return false }
        #endif
        return fchmod(fd, info.st_mode & 0o777) == 0 && futimens(fd, times(info)) == 0
    }

    #if canImport(Darwin)
    private typealias Directory = UnsafeMutablePointer<DIR>
    #else
    private typealias Directory = OpaquePointer
    #endif
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

#if !canImport(Darwin)
/// (`BuiltTree.write` hides it.)
private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int { write(descriptor, bytes, count) }
#endif
