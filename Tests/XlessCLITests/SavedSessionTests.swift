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

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-saved-\(UUID().uuidString)")
        let store = VaultStore(location: VaultLocation(directory: dir))
        try store.create(try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1)).0)
        let asked = asked
        vault = VaultSecretStore(store: store, cache: nil, prompter: { asked })
    }

    var saved: VaultSavedSession { VaultSavedSession { [vault] in vault } }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
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
    #expect(throws: XlessError.self) { try SecretsExportCommand.parse(["xless-apple-session", "--out", "/tmp/x"]).run() }
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
