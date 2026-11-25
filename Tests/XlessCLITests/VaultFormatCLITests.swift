import Foundation
import Testing
import XlessASC
import XlessCore
import XlessVault
@testable import xless

// #138: an account command refuses, before it asks a passphrase or creates anything at Apple, a secret store a newer
// xless wrote (exit 20), and leaves the file as it was.

/// A store whose file says a newer xless wrote it (store format 3, minimum reader version 3).
private struct NewerVault {
    let root: URL
    let store: VaultStore

    init(extra: [(String, VaultEntry.Kind, VaultEntry.Metadata)] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-newer-\(UUID().uuidString)")
        try makePrivateDirectory(root)
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        file.entries.append(try VaultCrypto.seal(name: "XLESS_DIST_KEY", kind: .signingKey, metadata: .init(teamID: "ABCDE12345"),
                                                 secret: SecretBytes(utf8: "pem"), dataKey: key))
        for (name, kind, metadata) in extra {
            file.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: metadata, secret: SecretBytes(utf8: "x"), dataKey: key))
        }
        try store.create(file)
        let url = store.location.file
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 3
        object["minimumReaderVersion"] = 3
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Fails the test if asked anything.
private final class NeverAsked: PassphrasePrompter, @unchecked Sendable {
    func askSecret(_ prompt: String) throws -> SecretBytes { Issue.record("asked \(prompt)"); return SecretBytes(count: 0) }
    func ask(_ prompt: String) throws -> String { Issue.record("asked \(prompt)"); return "" }
    func say(_ line: String) {}
}

@Test func anAccountCommandRefusesAStoreANewerXlessWroteWithExit20() throws {
    let vault = try NewerVault()
    defer { vault.cleanup() }
    let before = try Data(contentsOf: vault.store.location.file)
    let secrets = VaultSecretStore(store: vault.store, cache: nil, prompter: { NeverAsked() })
    let provision = ProvisionVault(store: secrets, env: [:])
    let catalog = try provision.existing()
    #expect(catalog.entry(named: "XLESS_DIST_KEY") != nil) // reading stays possible
    do {
        try provision.unlock(catalog, reason: "storing the new certificate's private key")
        Issue.record("unlocked a store it may not change")
    } catch let e as XlessError {
        #expect(e.stage == .account && e.stage.exitCode == 20)
        #expect(e.cause.contains("newer xless") && e.fix.contains("upgrade xless"))
    }
    // The store's own write path refuses as well (what `xless secrets rm` and every other writer go through).
    #expect(throws: VaultError.self) { try CertificateKeyStore.remove("XLESS_DIST_KEY", from: secrets) }
    #expect(try Data(contentsOf: vault.store.location.file) == before)
}

// #142 (leftover of #138): once Apple revoked a key, a store a newer xless wrote keeps its entry, and `xless secrets rm`
// would be refused too: the fix says the revoke is done and to upgrade xless first.

@Test func anAPIKeyRevokedAtAppleWhoseEntryANewerStoreKeepsSaysToUpgrade() throws {
    let vault = try NewerVault(extra: [("ASC_KEY_P8@ABCDE12345", .ascAPIKey, .init(teamID: "ABCDE12345", keyID: "2X9R4HXF34"))])
    defer { vault.cleanup() }
    let before = try Data(contentsOf: vault.store.location.file)
    do {
        _ = try APIKeyStore.removeRevoked(id: "2X9R4HXF34", from: VaultSecretStore(store: vault.store, cache: nil, prompter: { NeverAsked() }))
        Issue.record("removed an entry from a store it may not change")
    } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.hasPrefix("API key 2X9R4HXF34 is revoked, but ASC_KEY_P8@ABCDE12345 could not be removed from the secret store"))
        #expect(e.fix.hasPrefix("the key itself is revoked at Apple already;") && e.fix.contains("upgrade xless (run the install line again: README.md#install), then remove ASC_KEY_P8@ABCDE12345"))
    }
    #expect(try Data(contentsOf: vault.store.location.file) == before)
}

@Test func certsRevokeSaysToUpgradeBeforeRemovingTheKeyFromANewerStore() async throws {
    let vault = try NewerVault(extra: [("XLESS_DEVID_KEY", .signingKey, .init(certificateID: "C1"))])
    defer { vault.cleanup() }
    let catalog = try #require(try VaultSecretStore(store: vault.store, cache: nil, prompter: { NeverAsked() }).catalog())
    #expect(!catalog.isWritable)
    let cert = #"{"data":{"type":"certificates","id":"C1","attributes":{"certificateType":"DISTRIBUTION","expirationDate":"2027-02-01T00:00:00.000+0000"}}}"#
    let t = FakeTransport([(200, cert), (200, #"{"data":[],"links":{"self":"x"}}"#), (204, "")])
    let creds = try ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    let cli = CertCLI(certificates: ASCCertificates(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))),
                      storeFile: { catalog }, say: { _ in })
    let out = try await cli.revoke("C1", yes: true)
    #expect(out.contains("as XLESS_DEVID_KEY; a newer xless wrote the store and this one may not change it: upgrade xless"))
    #expect(StoreCleanup.leftEntry("XLESS_DIST_KEY", writable: false).contains("upgrade xless (run the install line again: README.md#install), then remove it with `xless secrets rm XLESS_DIST_KEY`"))
    #expect(StoreCleanup.leftEntry("XLESS_DIST_KEY", writable: true) == "the secret store still holds its private key as XLESS_DIST_KEY: remove it with `xless secrets rm XLESS_DIST_KEY`")
    // Any other failure keeps the plain fix.
    let plain = StoreCleanup.fix(after: VaultError(.io, "disk full", fix: "free space"), names: ["A", "B"], fallback: "?", done: "the key itself is revoked at Apple")
    #expect(plain == "remove A, B with `xless secrets rm <name>`; the key itself is revoked at Apple")
}
