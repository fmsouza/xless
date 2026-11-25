#if os(Windows)
import Crypto
import CXlessWindowsTestSupport
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

// What the store refuses of its files on Windows; PrivateFileTests has the rest of what it may be.

private func security(_ path: String) -> String {
    var text = [UInt16](repeating: 0, count: 2048)
    #expect(path.withWide { xless_test_security($0, &text, text.count) } == 0)
    return String(wide: text)
}

private func set(_ path: String, _ sddl: String) {
    #expect(path.withWide { path in sddl.withWide { xless_test_set_security(path, $0) } } == 0)
}

private func kind<T>(_ body: () throws -> T) -> VaultError.Kind? { #expect(throws: VaultError.self) { try body() }?.kind }

private func owner(_ path: String) -> String { String(security(path).dropFirst(2).prefix { $0 != "D" }) }

@Test func theStoreIsCreatedPrivate() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    for path in [t.location.file.path, t.location.lockFile.path] {
        #expect(security(path).hasSuffix("D:P(A;;FA;;;\(owner(path)))"), "\(security(path))")
    }
    #expect(security(t.location.directory.path).hasSuffix("D:P(A;OICI;FA;;;\(owner(t.location.directory.path)))"))
    // It stays so when it is written again.
    try t.store.update { $0 }
    #expect(security(t.location.file.path).hasSuffix("D:P(A;;FA;;;\(owner(t.location.file.path)))"))
    // And the directory above it is any directory of the user's.
    #expect(!security(t.location.directory.deletingLastPathComponent().path).contains("D:P"))
}

@Test func aStoreOthersMayReadIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (file, _) = try t.make()
    let own = security(t.location.file.path), ownDirectory = security(t.location.directory.path)
    set(t.location.file.path, own + "(A;;FR;;;WD)")
    #expect(kind { try t.store.read() } == .unsafePath)
    #expect(kind { try t.store.update { $0 } } == .unsafePath)
    set(t.location.file.path, own)
    #expect(try t.store.read() == file)
    set(t.location.directory.path, ownDirectory + "(A;;0x1;;;BU)")
    #expect(kind { try t.store.read() } == .unsafePath)
    #expect(kind { try t.store.update { $0 } } == .unsafePath)
    #expect(kind { try t.store.create(file) } == .unsafePath)
    set(t.location.directory.path, ownDirectory)
    set(t.location.lockFile.path, own + "(A;;FW;;;BU)")
    #expect(kind { try t.store.update { $0 } } == .unsafePath)
    set(t.location.lockFile.path, own)
    try t.store.update { $0 }
    // The system and the administrators are root's counterparts.
    set(t.location.file.path, own + "(A;;FA;;;SY)(A;;FA;;;BA)")
    #expect(try t.store.read() != nil)
}

@Test func aDirectoryMadeBySomethingElseIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try FileManager.default.createDirectory(at: t.location.directory, withIntermediateDirectories: true)
    let (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: testKDF())
    #expect(kind { try t.store.create(file) } == .unsafePath)
    #expect(kind { try t.store.read() } == .unsafePath)
    #expect(try FileManager.default.contentsOfDirectory(atPath: t.location.directory.path) == [])
}

@Test func aJunctionAndASecondNameAreRefused() throws {
    let t = try TempStore(), other = try TempStore()
    defer { t.cleanup(); other.cleanup() }
    try t.make()
    try FileManager.default.createDirectory(at: other.location.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(other.location.directory.path.withWide { link in t.location.directory.path.withWide { xless_test_junction(link, $0) } } == 0)
    #expect(kind { try other.store.read() } == .unsafePath)
    let second = t.root.appendingPathComponent("second").path
    #expect(second.withWide { link in t.location.file.path.withWide { xless_test_hard_link(link, $0) } } == 0)
    #expect(kind { try t.store.read() } == .unsafePath)
}

@Test func aStoreOnAShareIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make()
    let share = "\\\\localhost\\" + t.location.directory.path.replacingOccurrences(of: "/", with: "\\").replacingOccurrences(of: ":", with: "$")
    #expect(kind { try PrivateFileProbe.read(share) } == .unsafePath)
}

private enum PrivateFileProbe {
    static func read(_ directory: String) throws -> VaultFile? { try VaultStore(location: VaultLocation(directory: URL(fileURLWithPath: directory))).read() }
}

/// A file larger than a store is, and one that is none.
@Test func anOversizedStoreIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.location.createDirectory()
    try PrivateFile.create(t.location.file.path, Data(count: VaultStore.maximumSize + 1), .builtInDrive)
    #expect(kind { try t.store.read() } == .tampered)
}

@Test func theStandardLocationIsLocalAppData() {
    let standard = VaultLocation.standard(env: ["HOME": "C:\\home", "LOCALAPPDATA": "C:\\elsewhere"])
    #expect(standard.directory.path.replacingOccurrences(of: "\\", with: "/").hasSuffix("/AppData/Local/xless/vault"))
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "relative"]) == standard)
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "/rooted"]) == standard)
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "\\\\server\\share"]) == standard)
    #expect(VaultLocation.standard(env: ["XDG_DATA_HOME": "D:\\data"]).file == URL(fileURLWithPath: "D:/data/xless/vault/secrets.vault"))
}

@Test func aCredentialHelperIsRefused() {
    #expect(kind { try CredentialHelper.find(name: "pass", env: [:]) } == .helper)
}
#endif
