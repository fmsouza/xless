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
    public convenience init(store: XcodeStore, name: String, wait: Bool) throws {
        try self.init(file: Self.file(store: store, name: name), what: "the store of Xcode packs", variable: "XLESS_XCODES", wait: wait)
    }

    /// The lock of the tools a native setup installs (`<native home>/tools.lock`): two setups of different Xcodes, each under
    /// its own pack's lock, install xtool and rcodesign one after the other.
    public convenience init(tools layout: NativeLayout, wait: Bool) throws {
        try self.init(file: layout.root.appendingPathComponent("tools.lock"), what: "the native home", variable: "XLESS_NATIVE_HOME", wait: wait)
    }

    /// `file`'s directory (`what`, set by `variable`) is made when missing.
    private init(file: URL, what: String, variable: String, wait: Bool) throws {
        self.file = file
        let directory = file.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw XlessError(.sdk, "cannot make \(what) \(directory.path): \(error.localizedDescription)",
                             fix: "make it writable, or set \(variable) to a writable directory")
        }
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let error = errno
            throw XlessError(.sdk, "cannot open \(file.path): \(String(cString: strerror(error)))",
                             fix: "check that \(directory.path) is writable, or set \(variable) to a writable directory")
        }
        while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let error = errno
            if error == EINTR { continue }
            close(fd)
            if error == EWOULDBLOCK { throw Busy(file: file) }
            throw XlessError(.sdk, "cannot lock \(file.path): \(String(cString: strerror(error)))",
                             fix: "set \(variable) to a directory on a local file system")
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
