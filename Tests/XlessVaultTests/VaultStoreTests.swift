import Crypto
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

#if !os(Windows) // VaultOnWindowsTests
@Test func theStoreIsCreatedPrivate() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    #expect(try mode(t.location.directory.path) == 0o700)
    #expect(try mode(t.location.file.path) == 0o600)
    #expect(try mode(t.location.lockFile.path) == 0o600)
}
#endif

@Test func noStoreReadsAsNil() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    #expect(try t.store.read() == nil)
    do { try t.store.update { $0 }; Issue.record("updated a missing store") } catch let e as VaultError { #expect(e.kind == .notInitialized) }
}

@Test func initRefusesToReplaceAStore() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    do { try t.make(); Issue.record("replaced a store") } catch let e as VaultError { #expect(e.kind == .alreadyInitialized) }
}

#if !os(Windows)
@Test func anOpenDirectoryOrFileIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: t.location.file.path)
    do { _ = try t.store.read(); Issue.record("read a 0644 store") } catch let e as VaultError { #expect(e.kind == .unsafePath) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: t.location.file.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: t.location.directory.path)
    do { _ = try t.store.read(); Issue.record("read from a 0750 directory") } catch let e as VaultError { #expect(e.kind == .unsafePath) }
}
#endif

@Test func symlinksAreRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    let real = t.root.appendingPathComponent("real.vault")
    try FileManager.default.moveItem(at: t.location.file, to: real)
    try FileManager.default.createSymbolicLink(at: t.location.file, withDestinationURL: real)
    do { _ = try t.store.read(); Issue.record("followed a symlinked file") } catch let e as VaultError { #expect(e.kind == .unsafePath) }

    let other = try TempStore()
    defer { other.cleanup() }
    try FileManager.default.createDirectory(at: other.location.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: other.location.directory, withDestinationURL: t.location.directory)
    do { _ = try other.store.read(); Issue.record("followed a symlinked directory") } catch let e as VaultError { #expect(e.kind == .unsafePath) }
}

#if !os(Windows)
/// Only root can give a file away; CI's containers run the tests as root.
@Test(.enabled(if: geteuid() == 0)) func anotherOwnersStoreIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    #expect(chown(t.location.file.path, 12345, 12345) == 0)
    do { _ = try t.store.read(); Issue.record("read another user's store") } catch let e as VaultError { #expect(e.kind == .unsafePath) }
}
#endif

@Test func concurrentWritersLoseNoUpdate() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make()
    let keyBytes = key.withUnsafeBytes { Array($0) }
    let store = t.store
    let failures = NSLock()
    nonisolated(unsafe) var errors: [String] = []
    DispatchQueue.concurrentPerform(iterations: 24) { i in
        do {
            try store.update { file in
                var next = file
                next.entries.append(try VaultCrypto.seal(name: "E\(i)", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "\(i)"), dataKey: SymmetricKey(data: keyBytes)))
                return next
            }
        } catch { failures.withLock { errors.append("\(error)") } }
    }
    #expect(errors.isEmpty)
    let file = try #require(try store.read())
    #expect(Set(file.entries.map(\.name)) == Set((0..<24).map { "E\($0)" }))
}

@Test func writesLeaveNoTemporaryFileAndIgnoreAStaleOne() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make()
    // A crash between writing the temporary file and the rename leaves one behind: never read.
    try Data("garbage".utf8).write(to: t.location.directory.appendingPathComponent(".secrets.vault.1.dead.tmp"))
    try t.store.update { file in
        var next = file
        next.entries.append(try VaultCrypto.seal(name: "A", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "a"), dataKey: key))
        return next
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: t.location.directory.path).sorted()
    #expect(names == [".secrets.vault.1.dead.tmp", "lock", "secrets.vault"])
    #expect(try t.store.read()?.entries.map(\.name) == ["A"])
}

#if !os(Windows)
@Test func theStandardLocationFollowsXDG() {
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "/data", "HOME": "/home/u"]).file.path == "/data/xless/vault/secrets.vault")
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "relative", "HOME": "/home/u"]).file.path == "/home/u/.local/share/xless/vault/secrets.vault")
    #expect(VaultLocation.standard(env: ["HOME": "/home/u"]).directory.path == "/home/u/.local/share/xless/vault")
}
#endif
