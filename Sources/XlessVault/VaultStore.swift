import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads and writes the store's file. Writers hold an exclusive `flock` on `lock` for the whole read–modify–write, and
/// replace the file atomically: a temporary file in the same directory (O_EXCL, 0600), `fsync`, `rename`, `fsync` of the
/// directory. A reader always sees a whole file, old or new.
public struct VaultStore: Sendable {
    public let location: VaultLocation
    /// The most a store file may weigh (it holds keys, not builds).
    static let maximumSize = 16 << 20

    public init(location: VaultLocation) { self.location = location }

    /// The store, or nil when there is none yet. Its directory and file are checked first.
    public func read() throws -> VaultFile? {
        guard try location.checkDirectory() else { return nil }
        let path = location.file.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                var st = stat()
                if lstat(path, &st) == 0 { try VaultLocation.check(st, path: path, directory: false) }
            }
            throw VaultError(.io, "cannot open \(path): \(String(cString: strerror(errno)))", fix: "check the file's permissions")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw VaultError(.io, "cannot inspect \(path): \(String(cString: strerror(errno)))", fix: "check the file's permissions")
        }
        try VaultLocation.check(st, path: path, directory: false)
        guard Int(st.st_size) <= Self.maximumSize else { throw VaultError.tampered("file larger than \(Self.maximumSize >> 20) MiB") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buffer.withUnsafeMutableBytes { Glibc_read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw VaultError(.io, "cannot read \(path): \(String(cString: strerror(errno)))", fix: "check the disk")
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            guard data.count <= Self.maximumSize else { throw VaultError.tampered("file larger than \(Self.maximumSize >> 20) MiB") }
        }
        return try VaultFile.decode(data)
    }

    /// Writes a new store; refuses to replace one.
    public func create(_ file: VaultFile) throws {
        try location.createDirectory()
        try withLock {
            if location.fileExists {
                throw VaultError(.alreadyInitialized, "a secret store already exists at \(location.file.path)",
                                 fix: "use it (`xless secrets status`), change its passphrase with `xless secrets passwd`, or move it aside first")
            }
            try write(file)
        }
    }

    /// Read–modify–write under the writers' lock. `body` gets the current file (re-read under the lock) and returns the
    /// new one. A file a newer xless wrote (`VaultFile.requireWritable`) is refused before `body` runs; nothing changes.
    @discardableResult
    public func update(_ body: (VaultFile) throws -> VaultFile) throws -> VaultFile {
        guard try location.checkDirectory() else { throw Self.notInitialized(location) }
        return try withLock {
            guard let current = try read() else { throw Self.notInitialized(location) }
            try current.requireWritable()
            let next = try body(current)
            try write(next)
            return next
        }
    }

    public static func notInitialized(_ location: VaultLocation) -> VaultError {
        VaultError(.notInitialized, "there is no secret store at \(location.file.path)", fix: "create one with `xless secrets init`")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let path = location.lockFile.path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw VaultError(.io, "cannot open the lock file \(path): \(String(cString: strerror(errno)))", fix: "check the store directory's permissions")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw VaultError(.io, "cannot inspect \(path)", fix: "check the store directory's permissions") }
        try VaultLocation.check(st, path: path, directory: false)
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw VaultError(.io, "cannot lock \(path): \(String(cString: strerror(errno)))", fix: "re-run")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// The atomic replace. Call with the lock held.
    func write(_ file: VaultFile) throws {
        let data = try file.encoded()
        let dir = location.directory.path
        let tmp = location.directory.appendingPathComponent(".secrets.vault.\(getpid()).\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw VaultError(.io, "cannot create a temporary file in \(dir): \(String(cString: strerror(errno)))", fix: "check disk space and permissions")
        }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = Glibc_write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        let why = String(cString: strerror(errno))
        ok = close(fd) == 0 && ok
        guard ok, rename(tmp, location.file.path) == 0 else {
            unlink(tmp)
            throw VaultError(.io, "could not write \(location.file.path): \(why)", fix: "check disk space and permissions; the store is unchanged")
        }
        let dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
    }
}

// `read`/`write` are shadowed by the methods above inside the type.
@inline(__always) private func Glibc_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buf, count) }
@inline(__always) private func Glibc_write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buf, count) }
