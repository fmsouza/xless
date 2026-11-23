import Crypto
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

private let p8Meta = VaultEntry.Metadata(teamID: "TEAM123456", keyID: "KEY1234567", issuerID: "issuer-uuid", created: Date())

@Test func aSecretRoundTripsThroughTheFile() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [("ASC_KEY_P8", .ascAPIKey, p8Meta, "-----BEGIN PRIVATE KEY-----\nsecret-p8\n")])
    let file = try #require(try t.store.read())
    let key = try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "correct horse battery"))
    let entry = try #require(file.entry(named: "ASC_KEY_P8"))
    #expect(try VaultCrypto.open(entry, dataKey: key).utf8String() == "-----BEGIN PRIVATE KEY-----\nsecret-p8\n")
    #expect(entry.metadata == p8Meta)
    #expect(entry.kind == .ascAPIKey)
}

@Test func theFileHoldsNoSecretInClear() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(passphrase: "my-passphrase-123", entries: [("XLESS_DIST_KEY", .signingKey, .init(), "SUPER-SECRET-PEM")])
    let text = try String(contentsOf: t.location.file, encoding: .utf8)
    #expect(!text.contains("SUPER-SECRET-PEM"))
    #expect(!text.contains("my-passphrase-123"))
    #expect(text.contains("XLESS_DIST_KEY"))
}

@Test func aWrongPassphraseIsAClearErrorThatNamesNoSecret() throws {
    let (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "hunter2-right"), kdf: testKDF())
    do {
        _ = try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "hunter2-typo"))
        Issue.record("expected a wrong passphrase")
    } catch let e as VaultError {
        #expect(e.kind == .wrongPassphrase)
        #expect(!e.description.contains("hunter2"))
    }
}

@Test func anAlteredSecretFailsAsAWholeNeverPartly() throws {
    var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    let entry = try VaultCrypto.seal(name: "N", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "0123456789abcdef"), dataKey: key)
    var sealed = entry.sealed
    sealed[sealed.count / 2] ^= 0x01
    file.entries = [VaultEntry(name: "N", kind: .generic, metadata: .init(), sealed: sealed)]
    #expect(throws: VaultError.self) { try VaultCrypto.open(file.entries[0], dataKey: key) }
    do { _ = try VaultCrypto.open(file.entries[0], dataKey: key) } catch let e as VaultError {
        #expect(e.kind == .tampered)
        #expect(e.cause.contains("integrity"))
    }
}

@Test func alteredMetadataFailsTheEntry() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [("ASC_KEY_P8", .ascAPIKey, p8Meta, "p8")])
    var text = try String(contentsOf: t.location.file, encoding: .utf8)
    text = text.replacingOccurrences(of: "KEY1234567", with: "KEY7654321")
    try Data(text.utf8).write(to: t.location.file)
    let file = try #require(try t.store.read())
    let key = try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "correct horse battery"))
    #expect(throws: VaultError.self) { try VaultCrypto.open(file.entries[0], dataKey: key) }
}

@Test func anAlteredHeaderFailsTheUnlock() throws {
    var (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    file.kdf.rounds = 1 << 11
    #expect(throws: VaultError.self) { try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "pass phrase")) }
    file.kdf.rounds = 1 << 10
    file.id = "another-id"
    #expect(throws: VaultError.self) { try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "pass phrase")) }
}

@Test func outlandishKDFParametersAreRefusedBeforeDeriving() throws {
    var (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    for (rounds, r, p) in [(1 << 30, 8, 1), (1000, 8, 1), (1 << 17, 64, 1), (1 << 17, 8, 1000), (1 << 22, 32, 16)] {
        file.kdf.rounds = rounds
        file.kdf.blockSize = r
        file.kdf.parallelism = p
        do {
            _ = try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "pass phrase"))
            Issue.record("accepted N=\(rounds) r=\(r) p=\(p)")
        } catch let e as VaultError { #expect(e.kind == .tampered) }
    }
}

@Test func theStandardKDFIsScryptAtTwoToTheSeventeen() {
    let kdf = VaultKDF.standard()
    #expect(kdf.algorithm == "scrypt" && kdf.rounds == 1 << 17 && kdf.blockSize == 8 && kdf.parallelism == 1 && kdf.salt.count == 16)
    #expect((try? kdf.validate()) != nil)
}

@Test func anotherFormatOrAVersionBelowOneIsRefused() throws {
    let (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    var json = String(decoding: try file.encoded(), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 0")
    do { _ = try VaultFile.decode(Data(json.utf8)); Issue.record("accepted version 0") } catch let e as VaultError { #expect(e.kind == .tampered) }
    do { _ = try VaultFile.decode(Data("{\"hello\": 1}".utf8)); Issue.record("accepted junk") } catch let e as VaultError { #expect(e.kind == .tampered) }
    do { _ = try VaultFile.decode(Data("not json".utf8)); Issue.record("accepted junk") } catch let e as VaultError { #expect(e.kind == .tampered) }
}

@Test func passwdRewrapsTheDataKeyWithoutReencryptingEntries() throws {
    var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "old passphrase"), kdf: testKDF())
    file.entries = [try VaultCrypto.seal(name: "N", kind: .password, metadata: .init(), secret: SecretBytes(utf8: "v"), dataKey: key)]
    let rewrapped = try VaultCrypto.rewrap(file, dataKey: key, passphrase: SecretBytes(utf8: "new passphrase"), kdf: testKDF())
    #expect(rewrapped.entries == file.entries)
    #expect(rewrapped.keyCheck == file.keyCheck)
    #expect(rewrapped.kdf.salt != file.kdf.salt)
    #expect(throws: VaultError.self) { try VaultCrypto.unwrap(rewrapped, passphrase: SecretBytes(utf8: "old passphrase")) }
    let again = try VaultCrypto.unwrap(rewrapped, passphrase: SecretBytes(utf8: "new passphrase"))
    #expect(try VaultCrypto.open(rewrapped.entries[0], dataKey: again).utf8String() == "v")
}

@Test func entryNamesAreRestricted() {
    for ok in ["ASC_KEY_P8", "XLESS_DIST_KEY@ABCDE12345", "a.b-c", "9"] { #expect(VaultEntry.isValidName(ok), "\(ok)") }
    for bad in ["", "-x", "a b", "a/b", "../x", "é", String(repeating: "a", count: 129)] { #expect(!VaultEntry.isValidName(bad), "\(bad)") }
}

// MARK: role (#85)

@Test func anEntryWithoutARoleKeepsTheAssociatedDataOlderReleasesWrote() {
    // The layout before the role existed: eight length-prefixed fields after the tag, nothing more.
    let entry = VaultEntry(name: "ASC_KEY_P8", kind: .ascAPIKey, metadata: .init(teamID: "TEAM123456"), sealed: Data(), format: 1)
    var expected = Data("xless-vault-entry/1".utf8)
    for field in ["ASC_KEY_P8", "asc-api-key", "TEAM123456"] as [String] {
        expected.append(1)
        withUnsafeBytes(of: UInt32(field.utf8.count).bigEndian) { expected.append(contentsOf: $0) }
        expected.append(Data(field.utf8))
    }
    expected.append(contentsOf: [0, 0, 0, 0, 0])
    #expect(entry.associatedData == expected)
}

@Test func theRoleIsRecordedAndAuthenticated() throws {
    let key = SymmetricKey(size: .bits256)
    let meta = VaultEntry.Metadata(teamID: "TEAM123456", keyID: "KEY1234567", issuerID: "iss", role: " APP_MANAGER ")
    #expect(meta.role == "APP_MANAGER")
    #expect(VaultEntry.Metadata(role: "  ").role == nil)
    let entry = try VaultCrypto.seal(name: "ASC_KEY_P8", kind: .ascAPIKey, metadata: meta, secret: SecretBytes(utf8: "p8"), dataKey: key)
    #expect(try VaultCrypto.open(entry, dataKey: key).utf8String() == "p8")
    var promoted = meta
    promoted.role = "ADMIN"
    let altered = VaultEntry(name: entry.name, kind: entry.kind, metadata: promoted, sealed: entry.sealed)
    #expect(throws: VaultError.self) { try VaultCrypto.open(altered, dataKey: key) }
    var dropped = meta
    dropped.role = nil
    #expect(throws: VaultError.self) { try VaultCrypto.open(VaultEntry(name: entry.name, kind: entry.kind, metadata: dropped, sealed: entry.sealed), dataKey: key) }
}

// MARK: certificate type (#88)

@Test func theCertificateTypeIsRecordedAndAuthenticated() throws {
    let key = SymmetricKey(size: .bits256)
    let meta = VaultEntry.Metadata(teamID: "TEAM123456", certificateID: "CERT1", certificateType: " DISTRIBUTION ")
    #expect(meta.certificateType == "DISTRIBUTION")
    #expect(VaultEntry.Metadata(certificateType: "").certificateType == nil)
    // Format 1: without a type, the associated data is the one older releases wrote.
    let plain = try #require(VaultEntry(name: "X", kind: .signingKey, metadata: .init(teamID: "TEAM123456", certificateID: "CERT1"), sealed: Data(), format: 1).associatedData)
    let typed = try #require(VaultEntry(name: "X", kind: .signingKey, metadata: meta, sealed: Data(), format: 1).associatedData)
    #expect(typed.starts(with: plain) && typed != plain)
    let entry = try VaultCrypto.seal(name: "XLESS_DIST_KEY", kind: .signingKey, metadata: meta, secret: SecretBytes(utf8: "pem"), dataKey: key)
    #expect(try VaultCrypto.open(entry, dataKey: key).utf8String() == "pem")
    for change in [{ (m: inout VaultEntry.Metadata) in m.certificateType = "DEVELOPMENT" }, { $0.certificateType = nil }] {
        var altered = meta
        change(&altered)
        #expect(throws: VaultError.self) { try VaultCrypto.open(VaultEntry(name: entry.name, kind: entry.kind, metadata: altered, sealed: entry.sealed), dataKey: key) }
    }
    // A role and a type never read as each other.
    for format in [1, 2] {
        let role = VaultEntry(name: "X", kind: .signingKey, metadata: .init(role: "DISTRIBUTION"), sealed: Data(), format: format)
        let type = VaultEntry(name: "X", kind: .signingKey, metadata: .init(certificateType: "DISTRIBUTION"), sealed: Data(), format: format)
        #expect(role.associatedData != type.associatedData)
    }
}

// MARK: auth key services (#91)

@Test func theServicesOfAnAuthKeyAreRecordedAndAuthenticated() throws {
    let key = SymmetricKey(size: .bits256)
    let meta = VaultEntry.Metadata(teamID: "TEAM123456", keyID: "K1", services: " apns,siwa ")
    #expect(meta.services == "apns,siwa")
    #expect(VaultEntry.Metadata(services: "").services == nil)
    // Format 1: without services, the associated data is the one older releases wrote.
    let plain = try #require(VaultEntry(name: "X", kind: .authKey, metadata: .init(teamID: "TEAM123456", keyID: "K1"), sealed: Data(), format: 1).associatedData)
    let withServices = try #require(VaultEntry(name: "X", kind: .authKey, metadata: meta, sealed: Data(), format: 1).associatedData)
    #expect(withServices.starts(with: plain) && withServices != plain)
    let entry = try VaultCrypto.seal(name: "XLESS_APNS_KEY", kind: .authKey, metadata: meta, secret: SecretBytes(utf8: "p8"), dataKey: key)
    #expect(try VaultCrypto.open(entry, dataKey: key).utf8String() == "p8")
    for change in [{ (m: inout VaultEntry.Metadata) in m.services = "apns" }, { $0.services = nil }] {
        var altered = meta
        change(&altered)
        #expect(throws: VaultError.self) { try VaultCrypto.open(VaultEntry(name: entry.name, kind: entry.kind, metadata: altered, sealed: entry.sealed), dataKey: key) }
    }
    for format in [1, 2] {
        let role = VaultEntry(name: "X", kind: .authKey, metadata: .init(role: "apns"), sealed: Data(), format: format)
        let services = VaultEntry(name: "X", kind: .authKey, metadata: .init(services: "apns"), sealed: Data(), format: format)
        #expect(role.associatedData != services.associatedData)
    }
}
