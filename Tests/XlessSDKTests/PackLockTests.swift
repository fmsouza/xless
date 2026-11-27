import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore
import XlessImages

private var fm: FileManager { FileManager.default }

/// A real directory (macOS: /var is /private/var), as the store lists its packs.
private func tempStore() throws -> XcodeStore {
    let dir = fm.temporaryDirectory.appendingPathComponent("pack-lock-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return XcodeStore(root: dir.appendingPathComponent("xcodes")) }
    defer { free(real) }
    return XcodeStore(root: URL(fileURLWithPath: String(cString: real)).appendingPathComponent("xcodes"))
}

private let name = "26.2-17C52-arm64"

private func manifest(parts: [String: String] = ["sdk": "h"]) -> PackManifest {
    PackManifest(format: PackRecipe.format, xcode: "26.2", build: "17C52", arch: "arm64", swift: "6.2.3", mode: .separate, parts: parts)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    func set(_ v: Bool) { lock.lock(); held = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return held }
}

@Test func secondHolderWaits() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    var first: PackLock? = try PackLock(store: store, name: name, wait: false)
    #expect(first != nil)
    // A second holder, not waiting: refused while the first lives, naming the lock file.
    #expect { try PackLock(store: store, name: name, wait: false) } throws: {
        ($0 as? PackLock.Busy)?.file.path == store.root.appendingPathComponent("\(name).lock").path
    }
    // Another pack's lock is another lock.
    #expect(throws: Never.self) { _ = try PackLock(store: store, name: "27.0-27A266a-arm64", wait: false) }
    // A waiting holder gets it only once the first is released.
    let got = DispatchSemaphore(value: 0), done = Flag()
    Thread.detachNewThread {
        let lock = try? PackLock(store: store, name: name, wait: true)
        done.set(lock != nil)
        got.signal()
        _ = lock
    }
    #expect(got.wait(timeout: .now() + 0.5) == .timedOut)
    first = nil
    #expect(got.wait(timeout: .now() + 10) == .success)
    #expect(done.value)
    // Released by the waiter too (its value went away): free again.
    #expect(throws: Never.self) { _ = try PackLock(store: store, name: name, wait: false) }
}

@Test func theLockFileIsNoPackOfTheStore() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    let lock = try PackLock(store: store, name: name, wait: false)
    var isDirectory: ObjCBool = true
    #expect(fm.fileExists(atPath: lock.file.path, isDirectory: &isDirectory) && !isDirectory.boolValue)
    #expect(store.packs().isEmpty && store.subdirectories().isEmpty && store.broken().isEmpty)
    // Beside a pack, the store lists the pack alone.
    let pack = store.directory(xcode: "26.2", build: "17C52", arch: "arm64")
    try manifest().write(to: pack.appendingPathComponent("pack.json"))
    #expect(store.packs().map(\.root.lastPathComponent) == [name])
    _ = lock
}

@Test func theCaseProbeTellsWhatTheFileSystemDoes() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    let dir = store.root.deletingLastPathComponent()
    // A direct probe of the same directory: this Mac's disk does not tell the two apart; Linux's does.
    try Data().write(to: dir.appendingPathComponent("Probe"))
    let direct = !fm.fileExists(atPath: dir.appendingPathComponent("probe").path)
    try fm.removeItem(at: dir.appendingPathComponent("Probe"))
    #expect(try PackStore.distinguishesCase(dir) == direct)
    #if os(Linux)
    #expect(direct)
    #endif
    // It cleans up after itself.
    #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func aStoreOnACaseInsensitiveFileSystemIsRefused() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    #expect { try PackStore.requireCaseSensitive(store, distinguishes: { _ in false }) } throws: { error in
        guard let e = error as? XlessError else { return false }
        return e.cause == "the store of Xcode packs \(store.root.path) is on a file system that does not tell `Endian.h` from `endian.h`, and the SDK needs both"
            && e.fix.contains("set XLESS_XCODES to a directory on a case-sensitive file system") && e.fix.contains("xless setup --docker")
    }
    // The probe ran in the store's directory, made for it.
    var probed: URL?
    try PackStore.requireCaseSensitive(store, distinguishes: { probed = $0; return true })
    #expect(probed?.path == store.root.path)
}

@Test func aPackLeftAsideIsPutBackBySetupAlone() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    let final = store.directory(xcode: "26.2", build: "17C52", arch: "arm64")
    let old = store.root.appendingPathComponent("\(name).old")
    try manifest().write(to: old.appendingPathComponent("pack.json"))
    // Stopped between the two renames: no pack in its place, and the store does not take the one aside for one.
    #expect(store.packs().isEmpty)
    // Another setup is preparing it: left to that one.
    do {
        let other = try PackLock(store: store, name: name, wait: false)
        #expect(try PackStore.recoverAll(store).isEmpty)
        #expect(!fm.fileExists(atPath: final.path))
        _ = other
    }
    // The caller holds its lock (setup, preparing that pack): put back all the same.
    do {
        let mine = try PackLock(store: store, name: name, wait: false)
        #expect(try PackStore.recoverAll(store, holding: name) == [name])
        _ = mine
    }
    #expect(store.packs().map(\.root.path) == [final.path] && !fm.fileExists(atPath: old.path))
    #expect(try PackManifest.load(from: final.appendingPathComponent("pack.json")) == manifest())
    // Nothing more to do.
    #expect(try PackStore.recoverAll(store).isEmpty)
    // Without the lock held: taken, the pack put back, released.
    try fm.moveItem(at: final, to: old)
    #expect(try PackStore.recoverAll(store) == [name])
    #expect(store.packs().map(\.root.path) == [final.path])
    #expect(throws: Never.self) { _ = try PackLock(store: store, name: name, wait: false) }
}

@Test func recoverLeavesAPackInPlaceAndAnythingThatIsNoPack() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    let final = store.directory(xcode: "26.2", build: "17C52", arch: "arm64")
    let old = store.root.appendingPathComponent("\(name).old")
    // A pack in place and one aside (the commit had not removed it yet): the one in place stays, the one aside too.
    try manifest(parts: ["sdk": "new"]).write(to: final.appendingPathComponent("pack.json"))
    try manifest(parts: ["sdk": "old"]).write(to: old.appendingPathComponent("pack.json"))
    #expect(try PackPlan.recover(final) == false)
    #expect(try PackManifest.load(from: final.appendingPathComponent("pack.json")).parts == ["sdk": "new"])
    // Aside without a pack.json: no pack, not put back.
    try fm.removeItem(at: final)
    try fm.removeItem(at: old.appendingPathComponent("pack.json"))
    #expect(try PackPlan.recover(final) == false)
    #expect(!fm.fileExists(atPath: final.path))
}

/// A pack set aside (`<name>.old`) beside the pack in place is what a setup that stopped before removing it left: the next
/// setup removes it, under that pack's lock (left while another setup holds it).
@Test func recoverAllRemovesAStaleOldBesideAPackInPlace() throws {
    let store = try tempStore()
    defer { try? fm.removeItem(at: store.root.deletingLastPathComponent()) }
    let final = store.directory(xcode: "26.2", build: "17C52", arch: "arm64")
    let old = store.root.appendingPathComponent("\(name).old")
    try manifest(parts: ["sdk": "new"]).write(to: final.appendingPathComponent("pack.json"))
    try manifest(parts: ["sdk": "old"]).write(to: old.appendingPathComponent("pack.json"))
    try fm.createDirectory(at: old.appendingPathComponent("locked"), withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: old.appendingPathComponent("locked").path)
    do {
        let other = try PackLock(store: store, name: name, wait: false)
        #expect(try PackStore.recoverAll(store).isEmpty)
        #expect(fm.fileExists(atPath: old.path))
        _ = other
    }
    #expect(try PackStore.recoverAll(store).isEmpty)
    #expect(!fm.fileExists(atPath: old.path))
    #expect(try PackManifest.load(from: final.appendingPathComponent("pack.json")).parts == ["sdk": "new"])
    // The caller's own pack, its lock held.
    try manifest(parts: ["sdk": "old"]).write(to: old.appendingPathComponent("pack.json"))
    let mine = try PackLock(store: store, name: name, wait: false)
    #expect(try PackStore.recoverAll(store, holding: name).isEmpty)
    #expect(!fm.fileExists(atPath: old.path))
    _ = mine
}
