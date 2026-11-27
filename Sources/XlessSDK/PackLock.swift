import Foundation
import XlessCore
import XlessImages

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

/// What a store must be for a pack to be prepared in it (a store of the host: `XcodeStore`).
extension PackStore {
    /// Whether names that differ only in case are two names in `directory` (it must exist): a file is made there, its other
    /// spelling looked for, and the file removed.
    public static func distinguishesCase(_ directory: URL) throws -> Bool {
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let upper = directory.appendingPathComponent(".xless-case-\(id)-A"), lower = directory.appendingPathComponent(".xless-case-\(id)-a")
        guard fm.createFile(atPath: upper.path, contents: nil) else {
            throw XlessError(.sdk, "cannot write in \(directory.path), where the Xcode packs go",
                             fix: "make it writable, or set XLESS_XCODES to a writable directory")
        }
        defer { try? fm.removeItem(at: upper) }
        return !fm.fileExists(atPath: lower.path)
    }

    /// Refuses `store` when its file system does not tell names apart by case (a Mac's disk): the SDK has `Endian.h` and
    /// `endian.h` side by side (scripts/fit-toolchain.sh links one to the other). The store's directory is made first.
    /// `distinguishes`: the probe (`distinguishesCase`).
    public static func requireCaseSensitive(_ store: XcodeStore, distinguishes: (URL) throws -> Bool = distinguishesCase) throws {
        do { try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true) } catch {
            throw XlessError(.sdk, "cannot make the store of Xcode packs \(store.root.path): \(error.localizedDescription)",
                             fix: "make it writable, or set XLESS_XCODES to a writable directory")
        }
        guard try distinguishes(store.root) else {
            throw XlessError(.sdk, "the store of Xcode packs \(store.root.path) is on a file system that does not tell `Endian.h` from `endian.h`, and the SDK needs both",
                             fix: "set XLESS_XCODES to a directory on a case-sensitive file system (on a Mac: a case-sensitive APFS volume), or build in Docker: xless setup --docker")
        }
    }

    /// Puts back every pack a setup left at `<name>.old` with no `<name>` (it stopped between the two renames of
    /// `PackPlan.commit`), and removes a `<name>.old` beside a pack in place (it stopped before removing the one it
    /// replaced), each under its lock; a pack another setup is preparing is left to it. `holding`: the pack whose lock the
    /// caller holds already (a second lock of it, even in this process, would wait for that one). Returns the names put
    /// back. For setup alone: a build never renames anything in the store.
    public static func recoverAll(_ store: XcodeStore, holding: String? = nil) throws -> [String] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: store.root.path)) ?? [])
            .filter { $0.hasSuffix(".old") }.map { String($0.dropLast(4)) }.sorted()
        var back: [String] = []
        for name in names {
            let final = store.root.appendingPathComponent(name)
            func tidy() throws {
                if fm.fileExists(atPath: final.path) {
                    try PackPlan.removeTree(store.root.appendingPathComponent("\(name).old"))
                } else if try PackPlan.recover(final) { back.append(name) }
            }
            if name == holding { try tidy(); continue }
            guard let lock = try? PackLock(store: store, name: name, wait: false) else { continue }
            try withExtendedLifetime(lock) { try tidy() }
        }
        return back
    }
}
