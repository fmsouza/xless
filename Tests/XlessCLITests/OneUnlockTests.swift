import Crypto
import Foundation
import SwiftASN1
import X509
import Testing
import XlessASC
import XlessCore
import XlessSign
import XlessVault
@testable import xless

// One passphrase per command: the API-key lookup (`AccountSession` through the resolver) and the writes of the command
// (`APIKeyWebCLI.unlocked`, `CertificateKeyStore`) share the process's `SecretStore` and the data key it unlocked.

private let team = "ABCDE12345"

/// Answers the passphrase and counts how often it was asked.
private final class CountingPassphrase: PassphrasePrompter, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    var asked: Int { lock.withLock { _asked } }
    func askSecret(_ prompt: String) throws -> SecretBytes { lock.withLock { _asked += 1 }; return SecretBytes(utf8: "correct horse battery") }
    func ask(_ prompt: String) throws -> String { try askSecret(prompt).utf8String() }
    func say(_ line: String) {}
}

/// A store holding the team's API key, with a fast KDF.
private struct KeyVault {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-unlock-\(UUID().uuidString)")
        try makePrivateDirectory(root)
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        file.entries.append(try VaultCrypto.seal(name: "ASC_KEY_P8@\(team)", kind: .ascAPIKey,
                                                 metadata: .init(teamID: team, keyID: "2X9R4HXF34", issuerID: "69a6de70-03db-47e3-e053-5b8c7c11a4d1"),
                                                 secret: SecretBytes(utf8: P256.Signing.PrivateKey().pemRepresentation), dataKey: key))
        try store.create(file)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct IssuingCertificates: CertificateAPI {
    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate] { [] }
    func create(type: CertificateType, csrPEM: String, relatedID: String?) async throws -> ASCCertificate {
        ASCCertificate(resource: ASCAnyResource(type: "certificates", id: "C1", attributes: [
            "certificateType": .string(type.rawValue), "certificateContent": .string(try selfIssued(csrPEM).base64EncodedString()),
        ]))
    }
}

@Test func aCommandReadingTheAPIKeyAndStoringACertificateKeyAsksThePassphraseOnce() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let prompter = CountingPassphrase()
    let secrets = VaultSecretStore(store: vault.store, cache: nil, prompter: { prompter })
    // `certs create`: the session reads ASC_KEY_P8, ASC_KEY_ID and ASC_ISSUER_ID from the store...
    let session = try AccountSession.open(team: team, verbose: false, env: [:], fallback: { VaultResolver(secrets: secrets, team: $0) })
    #expect(session.team == team)
    #expect(prompter.asked == 1)
    // ...then unlocks it for the new key, stores the key and records the certificate with it.
    let created = try await CertificateCreation(api: IssuingCertificates()).run(
        type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY@\(team)", team: team,
        keys: { try APIKeyWebCLI.unlocked(store: secrets, reason: "storing the new certificate's private key") { CertificateKeyStore(store: $0, catalogID: $1.id) } })
    #expect(created.certificate.id == "C1")
    #expect(try vault.store.read()?.entry(named: "XLESS_DIST_KEY@\(team)")?.metadata.certificateID == "C1")
    #expect(prompter.asked == 1)
}

@Test func forgettingTheUnlockAsksAgain() throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let prompter = CountingPassphrase()
    let secrets = VaultSecretStore(store: vault.store, cache: nil, prompter: { prompter })
    let resolver = VaultResolver(secrets: secrets, team: team)
    #expect(try resolver.lookup("ASC_KEY_ID", stage: .account) == "2X9R4HXF34")
    #expect(try resolver.preferring(team: team).lookup("ASC_ISSUER_ID", stage: .account) == "69a6de70-03db-47e3-e053-5b8c7c11a4d1")
    #expect(prompter.asked == 1)
    secrets.forget()
    #expect(try resolver.lookup("ASC_KEY_P8", stage: .account)?.contains("PRIVATE KEY") == true)
    #expect(prompter.asked == 2)
}

@Test func everyUserOfTheStoreInAProcessSharesOneStore() throws {
    guard let store = try? SecretStoreCLI.store() else { return } // a broken config.yml on this machine: nothing to share
    #expect((AccountSession.storeFallback(team) as? VaultResolver)?.store === store)
    #expect((SecretStoreCLI.fallback as? VaultResolver)?.store === store)
    #expect(try APIKeyWebCLI.store() === store)
}

/// A certificate for the CSR's key, issued by itself, with the team as its OU (as Apple's are).
private func selfIssued(_ csrPEM: String) throws -> Data {
    let csr = try CertificateSigningRequest(pemEncoded: csrPEM)
    let name = try DistinguishedName { CommonName("Apple Distribution: Example (\(team))"); OrganizationalUnitName(team) }
    let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: csr.publicKey, notValidBefore: Date(timeIntervalSince1970: 1_700_000_000),
                               notValidAfter: Date(timeIntervalSince1970: 1_900_000_000), issuer: name, subject: name,
                               signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(),
                               issuerPrivateKey: .init(P256.Signing.PrivateKey()))
    var ser = DER.Serializer()
    try ser.serialize(cert)
    return Data(ser.serializedBytes)
}
