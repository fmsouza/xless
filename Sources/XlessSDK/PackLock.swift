import Foundation
import XlessCore

/// An exclusive lock on one pack's preparation: `<store>/<name>.lock`, flock(2). Released when the value goes away (and
/// by the system when the process ends, however it ends). The lock file stays: removing it would let a third setup lock a
/// new file while a second still waits on the old one. The store lists directories only, so it is never taken for a pack.
public final class PackLock {
    /// Another setup holds the lock and `wait` was false.
    public struct Busy: Error, Equatable {
        public let file: URL
    }

    public let file: URL
    private let fd: Int32

    /// The store's directory is made when missing. `wait`: block until the lock is free; else throw `Busy` at once.
    public init(store: XcodeStore, name: String, wait: Bool) throws {
        file = Self.file(store: store, name: name)
        do { try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true) } catch {
            throw XlessError(.sdk, "cannot make the store of Xcode packs \(store.root.path): \(error.localizedDescription)",
                             fix: "make it writable, or set XLESS_XCODES to a writable directory")
        }
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let error = errno
            throw XlessError(.sdk, "cannot open \(file.path): \(String(cString: strerror(error)))",
                             fix: "check that \(store.root.path) is writable, or set XLESS_XCODES to a writable directory")
        }
        while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let error = errno
            if error == EINTR { continue }
            close(fd)
            if error == EWOULDBLOCK { throw Busy(file: file) }
            throw XlessError(.sdk, "cannot lock \(file.path): \(String(cString: strerror(error)))",
                             fix: "set XLESS_XCODES to a directory on a local file system")
        }
        self.fd = fd
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    /// `<store>/<name>.lock`.
    public static func file(store: XcodeStore, name: String) -> URL { store.root.appendingPathComponent("\(name).lock") }
}
