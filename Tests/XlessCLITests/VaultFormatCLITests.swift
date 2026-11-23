import Foundation
import Testing
import XlessCore
import XlessVault
@testable import xless

// #138: an account command refuses, before it asks a passphrase or creates anything at Apple, a secret store a newer
// xless wrote (exit 20), and leaves the file as it was.

/// A store whose file says a newer xless wrote it (store format 3, minimum reader version 3).
private struct NewerVault {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-newer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        file.entries.append(try VaultCrypto.seal(name: "XLESS_DIST_KEY", kind: .signingKey, metadata: .init(teamID: "ABCDE12345"),
                                                 secret: SecretBytes(utf8: "pem"), dataKey: key))
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
