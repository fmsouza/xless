import Foundation
import XlessCore
import XlessImages

/// What a store must be for a pack to be prepared in it (a store of the host: `XcodeStore`), and the packs a stopped setup
/// left aside, put back. Here rather than beside `PackStore` (XlessImages, the --docker store's kind) because it uses
/// `PackPlan` and `PackLock`.
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
    /// `docker`: the store is the directory `XLESS_XCODES` names for `--docker` (checked on the host, before a container
    /// would refuse it under the name /xcodes); the fix then keeps the packs in volumes.
    public static func requireCaseSensitive(_ store: XcodeStore, docker: Bool = false, distinguishes: (URL) throws -> Bool = distinguishesCase) throws {
        do { try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true) } catch {
            throw XlessError(.sdk, "cannot make the store of Xcode packs \(store.root.path): \(error.localizedDescription)",
                             fix: "make it writable, or set XLESS_XCODES to a writable directory")
        }
        guard try distinguishes(store.root) else {
            throw XlessError(.sdk, "the store of Xcode packs \(store.root.path) is on a file system that does not tell `Endian.h` from `endian.h`, and the SDK needs both",
                             fix: docker
                                ? "unset XLESS_XCODES, so that the packs are Docker volumes, or set it to a directory on a case-sensitive file system (on a Mac: a case-sensitive APFS volume)"
                                : "set XLESS_XCODES to a directory on a case-sensitive file system (on a Mac: a case-sensitive APFS volume), or build in Docker: xless setup --docker")
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
            let lock: PackLock
            do { lock = try PackLock(store: store, name: name, wait: false) } catch is PackLock.Busy { continue }
            try withExtendedLifetime(lock) { try tidy() }
        }
        return back
    }
}
