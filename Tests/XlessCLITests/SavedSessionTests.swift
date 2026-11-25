import Foundation
import Testing
@testable import XlessCore
@testable import XlessAppleID
@testable import XlessVault
@testable import xless

/// A vault in a directory of its own, and the saved session in it.
private struct Fixture {
    let dir: URL
    let vault: VaultSecretStore
    let asked = Counter()

    final class Counter: PassphrasePrompter, @unchecked Sendable {
        var count = 0
        func askSecret(_ prompt: String) throws -> SecretBytes { count += 1; return SecretBytes(utf8: "correct horse battery") }
        func ask(_ prompt: String) throws -> String { "correct horse battery" }
        func say(_ line: String) {}
    }

    /// - Parameter cache: what holds an unlock.
    init(cache: FakeKeyring? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-saved-\(UUID().uuidString)")
        let store = VaultStore(location: VaultLocation(directory: dir))
        try store.create(try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1)).0)
        let asked = asked
        vault = VaultSecretStore(store: store, cache: cache, prompter: { asked })
    }

    var saved: VaultSavedSession { VaultSavedSession { [vault] in vault } }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// Nothing is held.
private struct NoHold: SessionKeyStore {
    var isAvailable: Bool { false }
    func allowed(_ hold: SecretHold) -> Int { 0 }
    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {}
    func get(_ name: String, using: Bool) throws -> SecretBytes? { nil }
    func revoke(_ name: String) throws -> Bool { false }
}

@Test func aSessionSavedInTheStoreIsSealedThereAndOpensWithThePassphrase() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    #expect(f.saved.expires == nil && f.asked.count == 0)
    let until = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 5000).rounded(.down))
    try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: until)
    try f.saved.save(SecretBytes(utf8: "COOKIES-2"), expires: until)
    #expect(f.saved.expires == until)
    let file = try String(contentsOf: f.dir.appendingPathComponent("secrets.vault"), encoding: .utf8)
    #expect(!file.contains("COOKIES") && file.contains("xless-apple-session"))
    f.vault.forget()
    let before = f.asked.count
    #expect(try f.saved.load(asking: false) == nil)
    #expect(f.asked.count == before)
    #expect(try f.saved.load(asking: true)?.utf8String() == "COOKIES-2")
    #expect(f.asked.count == before + 1)
    #expect(try f.saved.load(asking: false)?.utf8String() == "COOKIES-2") // unlocked by now
    f.vault.forget()
    #expect(try f.saved.remove())
    #expect(try !f.saved.remove())
    #expect(f.saved.expires == nil && f.asked.count == before + 1)
}

@Test func aLoweredMaximumEndsASavedSessionSooner() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let until = Date() + 5000
    try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: until)
    #expect(abs(try #require(f.saved.expires).timeIntervalSince(until)) < 1)
    let lower = VaultSavedSession({ [vault = f.vault] in vault }, maximum: { 600 })
    #expect(abs(try #require(lower.expires).timeIntervalSince(Date() + 600)) < 30)
}

@Test func aSessionIsSavedInTheEncryptedStoreOnly() {
    let none = VaultSavedSession { throw VaultSavedSession.unsupported("a credential helper holds the secrets") }
    #expect(none.expires == nil)
    #expect(throws: XlessError.self) { try none.save(SecretBytes(utf8: "x"), expires: Date()) }
    #expect((try? none.load(asking: true)) ?? nil == nil)
    #expect((try? none.remove()) != true)
}

@Test func theSavedSessionIsNeverWrittenInClear() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: Date() + 5000)
    try f.vault.update(reason: "test") { _ in ["xless-sparkle", "xless-apple-session@ABCDE12345"].map { .add(name: $0, kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "mine")) } }
    let catalog = try f.vault.existingCatalog()
    let session = try #require(catalog.entry(named: SecretEnvironment.savedSession))
    #expect(session.kind == .appleSession)
    let e = #expect(throws: XlessError.self) { try SecretsExportCommand.refuseSession(session) }
    #expect(e?.fix.contains("xless auth logout") == true)
    for entry in catalog.entries where entry.name != session.name { try SecretsExportCommand.refuseSession(entry) }
}

/// Before the file is so much as opened, and before any passphrase is asked.
@Test func aNameThatIsTakenByTheSavedSessionIsRefusedFirst() throws {
    let e = #expect(throws: XlessError.self) { try SecretsImportCommand.parse(["xless-apple-session", "--file", "/nonexistent/secret"]).run() }
    #expect(e?.cause.contains("xless-apple-session is the name of xless's own entry") == true && e?.fix.contains("another name") == true, "\(String(describing: e))")
    let other = #expect(throws: XlessError.self) { try SecretsImportCommand.parse(["xless-sparkle", "--file", "/nonexistent/secret"]).run() }
    #if os(Windows)
    #expect(other?.cause == "there is no file /nonexistent/secret", "\(String(describing: other))")
    #else
    #expect(other?.cause.contains("cannot open /nonexistent/secret") == true, "\(String(describing: other))")
    #endif
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "distribution", "--name", "xless-apple-session"]) }
    #expect(throws: Never.self) { try CertsCreateCommand.parse(["--type", "distribution", "--name", "xless-sparkle"]) }
}

/// The kind is xless's to give, not `--kind`'s.
@Test func noEntryOfAUsersIsAnAppleSession() throws {
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["NOTE", "--file", "x", "--kind", "apple-session"]) }
    #expect(throws: Never.self) { try SecretsImportCommand.parse(["NOTE", "--file", "x", "--kind", "generic"]) }
    #expect(!VaultEntry.Kind.allValueStrings.contains("apple-session"))
    #expect(throws: VaultError.self) { try VaultImport.validate(SecretBytes(utf8: "x"), kind: .appleSession) }
}

/// An entry of a user's own, which had the name before xless took it.
@Test func anEntryOfAUsersOwnIsNeitherTakenForTheSavedSessionNorReplacedByIt() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let past = VaultEntry.Metadata(created: Date(timeIntervalSince1970: 1), expires: Date(timeIntervalSince1970: 2))
    try f.vault.vault.update { file in
        var next = file
        next.entries.append(try VaultCrypto.seal(name: "xless-apple-session", kind: .generic, metadata: past, secret: SecretBytes(utf8: "mine"),
                                                 dataKey: try f.vault.key(for: file, remember: nil, reason: "test")))
        return next
    }
    let cache = AppleSessionCache(store: NoHold(), saved: f.saved)
    #expect(f.saved.expires == nil && cache.savedUntil == nil)
    #expect(try f.saved.load(asking: true) == nil)
    #expect(try !f.saved.remove())
    #expect(throws: XlessError.self) { try f.saved.requireFreeName() }
    let e = #expect(throws: XlessError.self) { try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: Date() + 5000) }
    #expect(e?.cause.contains("xless-apple-session") == true && e?.fix.contains("xless secrets") == true, "\(String(describing: e))")
    let catalog = try f.vault.existingCatalog()
    let entry = try #require(catalog.entry(named: "xless-apple-session"))
    try SecretsExportCommand.refuseSession(entry)
    #expect(try f.vault.secret(entry, in: catalog, reason: "test").utf8String() == "mine")
    try f.vault.update(reason: "test") { _ in [.remove(name: "xless-apple-session")] }
    try f.saved.requireFreeName()
    try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: Date() + 5000)
    try f.saved.requireFreeName() // its own is there to be replaced
    #expect(try f.saved.load(asking: false)?.utf8String() == "COOKIES")
}

/// `xless auth status` in a loop must not keep an unlock from ending for want of use.
@Test func whatLooksAtWhatIsHeldDoesNotUseIt() throws {
    let keyring = FakeKeyring()
    let f = try Fixture(cache: keyring)
    defer { f.cleanup() }
    #expect(SecretStoreCLI.witness(of: f.vault) == nil)
    try f.saved.save(SecretBytes(utf8: "COOKIES"), expires: Date() + 5000)
    let file = try #require(try f.vault.vault.read())
    try keyring.put(file.id, VaultCrypto.keyBytes(try f.vault.key(for: file, remember: nil, reason: "test")), hold: SecretHold(seconds: 60, idle: 60, maximum: 60))
    let before = keyring.using.count
    for _ in 0..<3 {
        f.vault.forget()
        let witness = try #require(SecretStoreCLI.witness(of: f.vault))
        #expect(witness.item == HeldSecrets.name(ofVault: file.id))
        f.vault.forget()
        #expect(try f.saved.load(asking: false)?.utf8String() == "COOKIES")
        _ = f.saved.expires
    }
    #expect(keyring.using.dropFirst(before).allSatisfy { !$0 } && keyring.using.count == before + 6)
    f.vault.forget()
    #expect(try f.saved.load(asking: true)?.utf8String() == "COOKIES") // for use
    #expect(keyring.using.last == true)
}

@Test func acrossRebootsNeedsKeep() {
    #expect(throws: (any Error).self) { try AuthLoginCommand.parse(["--across-reboots"]) }
    #expect((try? AuthLoginCommand.parse(["--keep", "2d", "--across-reboots"]))?.acrossReboots == true)
}

@Test func statusSaysThatASessionIsSaved() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let r = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, savedUntil: now + 7200, now: now)
    #expect(r.session.state == "saved" && r.session.savedUntil == "1970-01-12T15:46:40Z")
    #expect(r.text.contains("saved in the secret store until 1970-01-12T15:46:40Z"), "\(r.text)")
    let opened = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true,
                                        session: KeptSessionInfo(appleID: "me@example.com", created: now, expires: now + 7200), savedUntil: now + 7200, now: now)
    #expect(opened.session.state == "kept" && opened.session.backend == "store" && opened.session.savedUntil != nil)
    #expect(opened.text.contains("kept for me@example.com in the secret store until"), "\(opened.text)")
}
