import ArgumentParser
import Crypto
import SwiftASN1
import X509
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
import XlessSign
import XlessVault
@testable import xless

private let team = "ABCDE12345"

/// A real store in a temporary directory, with a fast KDF.
private struct CertVault {
    let root: URL
    let store: VaultStore
    let file: VaultFile
    let key: SymmetricKey

    init(entries: [(String, VaultEntry.Metadata)] = [], secrets: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-certs-\(UUID().uuidString)")
        try makePrivateDirectory(root)
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        for (name, meta) in entries {
            file.entries.append(try VaultCrypto.seal(name: name, kind: .signingKey, metadata: meta, secret: SecretBytes(utf8: secrets[name] ?? "x"), dataKey: key))
        }
        try store.create(file)
        self.file = file
        self.key = key
    }

    var keys: CertificateKeyStore { CertificateKeyStore(store: store.secretStore, catalogID: file.id) }
    func read() throws -> VaultFile { try #require(try store.read()) }
    func secret(_ name: String) throws -> String { try VaultCrypto.open(try #require(try read().entry(named: name)), dataKey: key).utf8String() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func add(_ e: String) { lock.withLock { _events.append(e) } }
}

/// App Store Connect's certificate endpoints, scripted.
private struct FakeCertificates: CertificateAPI {
    let journal: Journal
    var existing: [ASCCertificate] = []
    /// What the create request does with the CSR: a certificate, or an error.
    var create: @Sendable (CertificateType, String) throws -> ASCCertificate
    /// Checked when the POST is sent (the key must be in the store by then).
    var atPost: @Sendable () -> Void = {}
    /// What the listing answers when it changes after the POST (a certificate made by a request whose answer was lost).
    var listed: (@Sendable () -> [ASCCertificate])? = nil

    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate] {
        journal.add("list \(types.map(\.rawValue).joined(separator: ","))\(withContent ? " +content" : "")")
        return listed?() ?? existing
    }

    func create(type: CertificateType, csrPEM: String, relatedID: String?) async throws -> ASCCertificate {
        journal.add("POST \(type.rawValue)\(relatedID.map { " \($0)" } ?? "")")
        atPost()
        return try create(type, csrPEM)
    }
}

private func resource(_ id: String, type: String = "DISTRIBUTION", der: Data? = nil, expires: String = "2027-03-01T12:00:00.000+0000") -> ASCCertificate {
    var attributes: [String: JSONValue] = ["certificateType": .string(type), "name": .string("Apple Distribution: Example (\(team))"),
                                           "expirationDate": .string(expires), "serialNumber": .string("5A1B"), "displayName": .string("Example")]
    if let der { attributes["certificateContent"] = .string(der.base64EncodedString()) }
    return ASCCertificate(resource: ASCAnyResource(type: "certificates", id: id, attributes: attributes))
}

/// A certificate for the CSR's key, issued by itself, with the team as its OU (as Apple's are).
private func issue(_ csrPEM: String, notAfter: Date = Date(timeIntervalSince1970: 1_900_000_000)) throws -> Data {
    let csr = try CertificateSigningRequest(pemEncoded: csrPEM)
    let issuerKey = P256.Signing.PrivateKey()
    let name = try DistinguishedName { CommonName("Apple Distribution: Example (\(team))"); OrganizationalUnitName(team) }
    let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: csr.publicKey, notValidBefore: Date(timeIntervalSince1970: 1_700_000_000),
                               notValidAfter: notAfter, issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
                               extensions: Certificate.Extensions(), issuerPrivateKey: .init(issuerKey))
    var ser = DER.Serializer()
    try ser.serialize(cert)
    return Data(ser.serializedBytes)
}

private func accountError(_ body: () async throws -> Void) async -> XlessError? {
    do { try await body(); Issue.record("expected an error"); return nil } catch let e as XlessError { return e } catch {
        Issue.record("not an XlessError: \(error)"); return nil
    }
}

// MARK: - Create with a generated key

@Test func theKeyIsStoredBeforeTheCertificateIsRequestedThenItsIDRecorded() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let store = vault.store
    let api = FakeCertificates(journal: journal, create: { _, csr in resource("C1", der: try issue(csr)) },
                               atPost: { journal.add("stored=\((try? store.read())?.entry(named: "XLESS_DIST_KEY@\(team)") != nil)") })
    let created = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY@\(team)", team: team,
                                                               keys: { journal.add("unlock"); return vault.keys },
                                                               now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(journal.events == ["unlock", "POST DISTRIBUTION", "stored=true"])
    #expect(created.entry == "XLESS_DIST_KEY@\(team)" && created.certificate.id == "C1" && created.team == team)
    let entry = try #require(try vault.read().entry(named: "XLESS_DIST_KEY@\(team)"))
    #expect(entry.kind == .signingKey)
    #expect(entry.metadata == VaultEntry.Metadata(teamID: team, certificateID: "C1", created: Date(timeIntervalSince1970: 1_800_000_000),
                                                  expires: Date(timeIntervalSince1970: 1_900_000_000), certificateType: "DISTRIBUTION"))
    // The stored key is the certificate's key, and the sign stage's matching finds it.
    let key = try SigningKey(pem: try vault.secret("XLESS_DIST_KEY@\(team)"))
    #expect(try key.matches(certificateDER: Array(try #require(created.certificate.der))))
    #expect(created.text.contains("stored its private key in the secret store as XLESS_DIST_KEY@\(team)"))
    let json = try ASCOutput.json(created)
    #expect(json.contains(#""entry" : "XLESS_DIST_KEY@ABCDE12345""#) && json.contains(#""id" : "C1""#))
}

@Test func theTeamComesFromTheCertificateWhenNoneWasSelected() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let api = FakeCertificates(journal: Journal(), create: { _, csr in resource("C2", der: try issue(csr)) })
    let created = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY", team: nil, keys: { vault.keys })
    #expect(created.team == team)
    #expect(try vault.read().entry(named: "XLESS_DIST_KEY")?.metadata.teamID == team)
}

@Test func aStoreThatCannotKeepTheKeyMeansNoRequest() async throws {
    let vault = try CertVault(entries: [("XLESS_DIST_KEY", .init())])
    defer { vault.cleanup() }
    let journal = Journal()
    let api = FakeCertificates(journal: journal, create: { _, _ in Issue.record("POST sent"); return resource("X") })
    // The name was taken after the precheck.
    let e = await accountError {
        _ = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY", team: nil, keys: { vault.keys })
    }
    #expect(e?.cause.contains("nothing was sent to Apple") == true)
    // The store cannot even be unlocked.
    let locked = await accountError {
        _ = try await CertificateCreation(api: api).run(type: .development, relatedID: nil, entry: "XLESS_DEVELOPMENT_KEY", team: nil,
                                                        keys: { throw VaultError(.wrongPassphrase, "wrong passphrase", fix: "retry") })
    }
    #expect(locked?.cause.contains("wrong passphrase") == true && locked?.stage == .account)
    #expect(!journal.events.contains { $0.hasPrefix("POST") })
}

@Test func aDefiniteRefusalRemovesTheKeyAgain() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let api = FakeCertificates(journal: journal, create: { _, _ in
        let item = try JSONDecoder().decode(ASCErrorItem.self, from: Data(#"{"status":"409","code":"ENTITY_ERROR","title":"There is a problem with the request entity","detail":"You already have a current Distribution certificate or a pending certificate request."}"#.utf8))
        throw ASCError(status: 409, items: [item])
    })
    let e = await accountError {
        _ = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY", team: nil, keys: { vault.keys })
    }
    #expect(e?.cause.contains("refused to create the Apple Distribution certificate") == true)
    #expect(e?.cause.contains("removed from the secret store (XLESS_DIST_KEY)") == true)
    #expect(e?.fix.contains("xless certs revoke") == true)
    #expect(try vault.read().entries.isEmpty)
    #expect(journal.events.filter { $0.hasPrefix("POST") }.count == 1)
}

@Test func aFailureThatMayHaveCreatedTheCertificateKeepsTheKey() async throws {
    for failure in [ASCError(status: 503, items: []) as Error, URLError(.timedOut), DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "html"))] {
        let vault = try CertVault()
        defer { vault.cleanup() }
        let journal = Journal()
        let api = FakeCertificates(journal: journal, create: { _, _ in throw failure })
        let e = await accountError {
            _ = try await CertificateCreation(api: api).run(type: .development, relatedID: nil, entry: "XLESS_DEVELOPMENT_KEY", team: nil, keys: { vault.keys })
        }
        #expect(e?.isAmbiguousCertificateCreation == true, "\(failure)")
        #expect(e?.fix.contains("xless certs list --type development") == true)
        #expect(e?.fix.contains("kept in the secret store as XLESS_DEVELOPMENT_KEY") == true)
        #expect(try vault.read().entry(named: "XLESS_DEVELOPMENT_KEY") != nil)
        #expect(journal.events.filter { $0.hasPrefix("POST") }.count == 1)
    }
}

/// Holds what a scripted App Store Connect made.
private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var _certificates: [ASCCertificate] = []
    var certificates: [ASCCertificate] { lock.withLock { _certificates } }
    func add(_ c: ASCCertificate) { lock.withLock { _certificates.append(c) } }
}

@Test func anAmbiguousCreateWhoseCertificateExistsIsRecordedWithItsKey() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let made = Made()
    let said = Said()
    // Another key's certificate is listed too; only the one for the new key is taken.
    let other = resource("C0", der: try issue(try SigningKey.generate().csrPEM(commonName: "other")))
    let api = FakeCertificates(journal: journal, create: { _, csr in
        made.add(resource("C7", der: try issue(csr)))
        throw URLError(.networkConnectionLost)
    }, listed: { [other] + made.certificates })
    var creation = CertificateCreation(api: api)
    creation.say = { said.lines.append($0) }
    let created = try await creation.run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY@\(team)", team: team, keys: { vault.keys })
    #expect(created.certificate.id == "C7" && created.entry == "XLESS_DIST_KEY@\(team)")
    #expect(try vault.read().entry(named: "XLESS_DIST_KEY@\(team)")?.metadata.certificateID == "C7")
    #expect(journal.events == ["POST DISTRIBUTION", "list DISTRIBUTION +content"])
    #expect(said.lines.contains { $0.contains("lists certificate C7 for this key: it was created") })
}

@Test func anAmbiguousCreateWithNoCertificateListedStaysAmbiguousAndPointsAtLink() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let other = resource("C0", der: try issue(try SigningKey.generate().csrPEM(commonName: "other")))
    let api = FakeCertificates(journal: journal, existing: [other], create: { _, _ in throw ASCError(status: 500, items: []) })
    let e = await accountError {
        _ = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY", team: nil, keys: { vault.keys })
    }
    #expect(e?.isAmbiguousCertificateCreation == true)
    #expect(e?.fix.contains("`xless certs link` records it with its certificate") == true)
    #expect(try vault.read().entry(named: "XLESS_DIST_KEY")?.metadata.certificateID == nil)
}

@Test func anAmbiguousCSRCreateWhoseCertificateExistsSucceeds() async throws {
    let made = Made()
    let csr = try SigningKey.generate().csrPEM(commonName: "hsm")
    let api = FakeCertificates(journal: Journal(), create: { _, csr in
        made.add(resource("C8", der: try issue(csr)))
        throw ASCError(status: 502, items: [])
    }, listed: { made.certificates })
    let created = try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, csrPEM: csr)
    #expect(created.certificate.id == "C8" && created.entry == nil && created.team == team)
    // Nothing listed: still ambiguous.
    let none = FakeCertificates(journal: Journal(), create: { _, _ in throw URLError(.timedOut) })
    let e = await accountError { _ = try await CertificateCreation(api: none).run(type: .distribution, relatedID: nil, csrPEM: csr) }
    #expect(e?.isAmbiguousCertificateCreation == true)
}

@Test func theDeveloperIDCapIsCheckedBeforeAKeyIsMade() async throws {
    let journal = Journal()
    let five = (1...5).map { resource("D\($0)", type: $0 % 2 == 0 ? "DEVELOPER_ID_APPLICATION" : "DEVELOPER_ID_APPLICATION_G2") }
    let api = FakeCertificates(journal: journal, existing: five, create: { _, _ in Issue.record("POST sent"); return resource("X") })
    var creation = CertificateCreation(api: api)
    creation.generate = { Issue.record("key generated"); return try SigningKey.generate() }
    let e = await accountError {
        _ = try await creation.run(type: .developerIDApplicationG2, relatedID: nil, entry: "XLESS_DEVID_KEY", team: nil, keys: { Issue.record("unlocked"); throw CancellationError() })
    }
    #expect(e?.cause == "the team already has 5 Developer ID Application certificates (Apple allows 5)")
    #expect(journal.events == ["list DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2"])
    // Other types have no documented cap: nothing is listed first.
    let none = Journal()
    let vault = try CertVault()
    defer { vault.cleanup() }
    _ = try await CertificateCreation(api: FakeCertificates(journal: none, create: { _, csr in resource("C", type: "DEVELOPMENT", der: try issue(csr)) }))
        .run(type: .development, relatedID: nil, entry: "XLESS_DEVELOPMENT_KEY", team: nil, keys: { vault.keys })
    #expect(none.events == ["POST DEVELOPMENT"])
}

@Test func bootstrapRefusesASecondCertificateUnlessAllowed() async throws {
    let journal = Journal()
    let api = FakeCertificates(journal: journal, existing: [resource("C1")], create: { _, _ in Issue.record("POST sent"); return resource("X") })
    let e = await accountError {
        _ = try await CertificateCreation(api: api, stage: .sign, refuseIfAny: true)
            .run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY", team: nil, keys: { Issue.record("unlocked"); throw CancellationError() })
    }
    #expect(e?.stage == .sign && e?.fix.contains("--allow-new") == true)
}

/// `sign bootstrap --out`: the same creation with its key in a new file instead of the store.
private func keyFile() throws -> (dir: URL, path: String) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-certs-out-\(UUID().uuidString)")
    try makePrivateDirectory(dir)
    return (dir, dir.appendingPathComponent("dist.pem").path)
}

@Test func aKeyFileIsWrittenBeforeTheCertificateIsRequested() async throws {
    let (dir, path) = try keyFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let journal = Journal()
    let api = FakeCertificates(journal: journal, create: { _, csr in resource("C1", der: try issue(csr)) },
                               atPost: { journal.add("written=\(FileManager.default.fileExists(atPath: path))") })
    let created = try await CertificateCreation(api: api, stage: .sign, refuseIfAny: true).run(type: .distribution, file: path)
    #expect(journal.events == ["list DISTRIBUTION", "POST DISTRIBUTION", "written=true"])
    #expect(created.certificate.id == "C1" && created.entry == nil && created.team == team)
    #expect(try isPrivateFile(path))
    #expect(try SigningKey(pem: String(contentsOfFile: path, encoding: .utf8)).matches(certificateDER: Array(try #require(created.certificate.der))))
}

@Test func aKeyFileIsRemovedWhenNoCertificateCanBeItsOwn() async throws {
    for (existing, failure) in [([resource("C0")], nil), ([], ASCError(status: 409, items: []) as Error?), ([], XlessError(.sign, "cannot build the token", fix: ""))] {
        let (dir, path) = try keyFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let api = FakeCertificates(journal: Journal(), existing: existing, create: { _, _ in throw failure ?? CancellationError() })
        let e = await accountError { _ = try await CertificateCreation(api: api, stage: .sign, refuseIfAny: true).run(type: .distribution, file: path) }
        #expect(e?.stage == .sign && e?.isAmbiguousCertificateCreation == false)
        if failure is ASCError { #expect(e?.cause.contains("its private key (\(path)) was removed") == true) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Test func aKeyFileIsKeptWhenTheCertificateMayExist() async throws {
    for failure in [ASCError(status: 503, items: []) as Error, URLError(.timedOut), CancellationError(),
                    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "html"))] {
        let (dir, path) = try keyFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = Journal()
        let api = FakeCertificates(journal: journal, create: { _, _ in throw failure })
        let e = await accountError { _ = try await CertificateCreation(api: api, stage: .sign).run(type: .distribution, file: path) }
        #expect(e?.isAmbiguousCertificateCreation == true && e?.stage == .sign)
        #expect(e?.fix.contains("the private key is kept in \(path)") == true && e?.fix.contains("--allow-new") == true)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(journal.events.filter { $0.hasPrefix("POST") }.count == 1)
    }
}

@Test func aKeyFilesCertificateIsFoundWhenTheAnswerWasLost() async throws {
    let (dir, path) = try keyFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    let made = Made()
    let api = FakeCertificates(journal: Journal(), create: { _, csr in
        made.add(resource("C7", der: try issue(csr)))
        throw URLError(.networkConnectionLost)
    }, listed: { made.certificates })
    #expect(try await CertificateCreation(api: api, stage: .sign).run(type: .distribution, file: path).certificate.id == "C7")
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func aKeyFileThatExistsIsNeverOverwrittenAndNothingIsSent() async throws {
    let (dir, path) = try keyFile()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("mine".utf8).write(to: URL(fileURLWithPath: path))
    let journal = Journal()
    let api = FakeCertificates(journal: journal, create: { _, _ in resource("X") })
    _ = await accountError { _ = try await CertificateCreation(api: api, stage: .sign).run(type: .distribution, file: path) }
    #expect(journal.events.isEmpty)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine")
}

@Test func applePayProcessingNeedsACSR() async throws {
    let api = FakeCertificates(journal: Journal(), create: { _, _ in Issue.record("POST sent"); return resource("X") })
    let e = await accountError {
        _ = try await CertificateCreation(api: api).run(type: .applePay, relatedID: "M1", entry: "X", team: nil, keys: { throw CancellationError() })
    }
    #expect(e?.cause.contains("ECC P-256") == true && e?.fix.contains("--csr") == true)
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "apple-pay", "--merchant-id", "merchant.com.example"]) }
}

@Test func aCSRIsSentAsGivenAndNothingIsStored() async throws {
    let journal = Journal()
    let csr = try SigningKey.generate().csrPEM(commonName: "hsm")
    let api = FakeCertificates(journal: journal, create: { type, sent in
        #expect(sent == csr)
        return resource("C9", type: type.rawValue, der: try issue(sent))
    })
    let created = try await CertificateCreation(api: api).run(type: .applePayMerchantIdentity, relatedID: "M1", csrPEM: csr)
    #expect(journal.events == ["list ", "POST APPLE_PAY_MERCHANT_IDENTITY M1"])
    #expect(created.entry == nil && created.text.contains("xless certs download C9"))
    let ambiguous = await accountError {
        _ = try await CertificateCreation(api: FakeCertificates(journal: Journal(), create: { _, _ in throw URLError(.networkConnectionLost) }))
            .run(type: .development, relatedID: nil, csrPEM: csr)
    }
    #expect(ambiguous?.isAmbiguousCertificateCreation == true && ambiguous?.fix.contains("secret store") == false)
}

@Test func aSecondKeyForTheSameNameOrTeamIsRefusedUpFront() throws {
    let vault = try CertVault(entries: [("XLESS_DIST_KEY@\(team)", .init(teamID: team)), ("XLESS_DEVID_KEY", .init()),
                                        ("XLESS_INSTALLER_KEY@ZZZZZ99999", .init(teamID: "ZZZZZ99999"))])
    defer { vault.cleanup() }
    let file = try vault.read()
    func clash(_ name: String, _ base: String?, _ team: String?) -> Bool {
        (try? CertificateKeyStore.precheck(file, name: name, base: base, team: team, stage: .account)) == nil
    }
    #expect(clash("XLESS_DIST_KEY@\(team)", "XLESS_DIST_KEY", team))
    #expect(clash("XLESS_DEVID_KEY@\(team)", "XLESS_DEVID_KEY", team))  // the unteamed key would also be read for the team
    #expect(!clash("XLESS_INSTALLER_KEY@\(team)", "XLESS_INSTALLER_KEY", team))  // another team's key
    #expect(clash("XLESS_INSTALLER_KEY", "XLESS_INSTALLER_KEY", nil))
    #expect(!clash("MY_DIST_KEY", nil, team))
    #expect(clash("XLESS_DEVID_KEY", nil, nil))
    do { try CertificateKeyStore.precheck(file, name: "XLESS_DIST_KEY@\(team)", base: "XLESS_DIST_KEY", team: team, stage: .account) } catch let e as XlessError {
        #expect(e.fix.contains("xless secrets rm XLESS_DIST_KEY@\(team)") && e.fix.contains("--name"))
    }
    #expect(CertificateKeyStore.entryName(base: "XLESS_DIST_KEY", team: team) == "XLESS_DIST_KEY@\(team)")
    #expect(CertificateKeyStore.entryName(base: "XLESS_DIST_KEY", team: nil) == "XLESS_DIST_KEY")
}

// MARK: - Commands

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said(), store: VaultFile? = nil) -> CertCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return CertCLI(certificates: ASCCertificates(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))),
                   json: json, storeFile: { store }, terminal: { terminal }, say: { said.lines.append($0) },
                   now: { Date(timeIntervalSince1970: 1_800_000_000) })  // 2027-01-15
}

private func certJSON(_ id: String, type: String = "DISTRIBUTION", expires: String, content: String? = nil) -> String {
    #"{"type":"certificates","id":"\#(id)","attributes":{"name":"Apple Distribution: Example","certificateType":"\#(type)","displayName":"Example","serialNumber":"5A1B","expirationDate":"\#(expires)"\#(content.map { #","certificateContent":"\#($0)""# } ?? "")}}"#
}
private func listing(_ items: [String]) -> String { #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"}}"# }

@Test func certsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("certs") } == true, "\(help)")
}

@Test func badCertificateArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "developer-id-installer"]) }
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "distribution", "--csr", "a.csr", "--name", "X"]) }
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "distribution", "--name", "bad name"]) }
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "apple-pay-merchant-identity"]) }
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "pass-type-id", "--merchant-id", "merchant.x.y"]) }
    #expect(throws: (any Error).self) { try CertsCreateCommand.parse(["--type", "development", "--pass-type-id", "PT1"]) }
    #expect(throws: (any Error).self) { try CertsListCommand.parse(["--type", "nope"]) }
    #expect(throws: (any Error).self) { try CertsListCommand.parse(["--expiring", "-1"]) }
    #expect(throws: (any Error).self) { try CertsRevokeCommand.parse(["../v1/apps"]) }
    #expect(throws: (any Error).self) { try CertsDownloadCommand.parse(["C1"]) }
    _ = try CertsCreateCommand.parse(["--type", "Apple Pay Merchant Identity", "--merchant-id", "merchant.com.example", "--team", team])
    _ = try CertsCreateCommand.parse(["--type", "pass-type-id-with-nfc", "--pass-type-id", "pass.com.example.ticket", "--csr", "p.csr"])
    _ = try CertsListCommand.parse(["--type", "distribution", "--type", "developer-id", "--expiring", "30", "--json"])
    #if !os(Windows) && !XLESS_WINDOWS_TARGETS // a command of the builds
    #expect(throws: (any Error).self) { try SignBootstrapCommand.parse(["--type", "distribution", "--csr-only"]) }
    _ = try SignBootstrapCommand.parse(["--type", "distribution"])
    _ = try SignBootstrapCommand.parse(["--type", "installer", "--out", "k.pem", "--csr-only"])
    #endif
}

@Test func listShowsTheKeysInTheStoreAndFiltersByExpiry() async throws {
    let vault = try CertVault(entries: [("XLESS_DIST_KEY", .init(certificateID: "C1"))])
    defer { vault.cleanup() }
    let body = listing([certJSON("C1", expires: "2027-02-01T00:00:00.000+0000"), certJSON("C2", type: "DEVELOPMENT", expires: "2028-01-01T00:00:00.000+0000")])
    let t = FakeTransport([(200, body), (200, body), (200, body)])
    let out = try await cli(t, store: try vault.read()).list(types: [], expiringWithin: nil)
    let lines = out.split(separator: "\n")
    #expect(lines[0].hasPrefix("ID  TYPE") && lines[0].hasSuffix("KEY IN STORE"))
    #expect(lines.contains { $0.hasPrefix("C1  distribution") && $0.contains("2027-02-01") && $0.hasSuffix("XLESS_DIST_KEY") })
    #expect(lines.contains { $0.hasPrefix("C2  development") && $0.hasSuffix("-") })
    let soon = try await cli(t).list(types: [], expiringWithin: 30)
    #expect(soon.contains("C1") && !soon.contains("C2"))
    let json = try await cli(t, json: true).list(types: [.distribution], expiringWithin: nil)
    #expect(json.hasPrefix("{\n  \"data\" : [") && json.contains(#""certificateType" : "DEVELOPMENT""#))
    #expect(t.requests[2].url!.query!.contains("DISTRIBUTION"))
}

@Test func showNeverPrintsTheContent() async throws {
    let t = FakeTransport([(200, #"{"data":\#(certJSON("C1", expires: "2027-02-01T00:00:00.000+0000", content: "MAA="))}"#)])
    let out = try await cli(t).show("C1")
    #expect(out.contains("ID:           C1") && out.contains("Expires:      2027-02-01") && out.contains("not in the secret store"))
    #expect(!out.contains("MAA="))
}

@Test func downloadWritesTheDEROnceWithMode0644() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-cer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("d.cer").path
    let single = #"{"data":\#(certJSON("C1", expires: "2027-02-01T00:00:00.000+0000", content: "MAA="))}"#
    let t = FakeTransport([(200, single), (200, single)])
    let out = try await cli(t).download("C1", to: path)
    #expect(out.hasPrefix("wrote certificate C1 (DISTRIBUTION, expires 2027-02-01) to "))
    #expect(FileManager.default.contents(atPath: path) == Data([0x30, 0x00]))
    #if !os(Windows)
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    #endif
    try Data("mine".utf8).write(to: URL(fileURLWithPath: path))
    let e = await accountError { _ = try await cli(t).download("C1", to: path) }
    #expect(e?.stage == .account && e?.cause.contains("already exists") == true)
    #expect(FileManager.default.contents(atPath: path) == Data("mine".utf8))
}

@Test func revokeNamesWhatStopsWorkingAndAsksFirst() async throws {
    let vault = try CertVault(entries: [("XLESS_DEVID_KEY", .init(certificateID: "C1"))])
    defer { vault.cleanup() }
    let cert = #"{"data":\#(certJSON("C1", type: "DEVELOPER_ID_APPLICATION_G2", expires: "2027-02-01T00:00:00.000+0000"))}"#
    let profiles = listing([#"{"type":"profiles","id":"P1","attributes":{"name":"xless com.example.app MAC_APP_DIRECT","profileType":"MAC_APP_DIRECT"},"relationships":{"certificates":{"data":[{"type":"certificates","id":"C1"}]}}}"#])

    final class Asked: Confirming, @unchecked Sendable {
        var questions: [String] = []
        let answer: Bool
        init(_ answer: Bool) { self.answer = answer }
        func confirm(_ question: String) throws -> Bool { questions.append(question); return answer }
    }
    let no = Asked(false), declined = FakeTransport([(200, cert), (200, profiles)])
    let said = Said()
    #expect(try await cli(declined, terminal: no, said: said, store: try vault.read()).revoke("C1", yes: false) == "")
    #expect(no.questions.count == 1 && no.questions[0].contains("1 profile stop working") && no.questions[0].contains("can no longer install apps"))
    #expect(said.lines.contains("stops working: profile xless com.example.app MAC_APP_DIRECT (P1, MAC_APP_DIRECT)") && said.lines.last == "cancelled; nothing was sent")
    #expect(declined.requests.allSatisfy { $0.httpMethod == "GET" })

    let noTerminal = FakeTransport([(200, cert), (200, profiles)])
    let e = await accountError { _ = try await cli(noTerminal, store: try vault.read()).revoke("C1", yes: false) }
    #expect(e?.fix == "re-run with --yes")
    #expect(noTerminal.requests.allSatisfy { $0.httpMethod == "GET" })

    let yes = FakeTransport([(200, cert), (200, profiles), (204, "")])
    let out = try await cli(yes, store: try vault.read()).revoke("C1", yes: true)
    #expect(yes.requests.last.map { "\($0.httpMethod!) \($0.url!.path)" } == "DELETE /v1/certificates/C1")
    #expect(out.contains("revoked certificate C1") && out.contains("now invalid: xless com.example.app MAC_APP_DIRECT"))
    #expect(out.contains("`xless secrets rm XLESS_DEVID_KEY`"))
    let json = try await cli(FakeTransport([(200, cert), (200, profiles), (204, "")]), json: true, store: try vault.read()).revoke("C1", yes: true)
    #expect(json.contains(#""revoked" : "C1""#) && json.contains(#""storeEntries" : ["#))
}

// MARK: - Review follow-ups

@Test func theCertificatesTeamWinsOverTheSelectedOne() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let said = Said()
    var creation = CertificateCreation(api: FakeCertificates(journal: Journal(), create: { _, csr in resource("C3", der: try issue(csr)) }))
    creation.say = { said.lines.append($0) }
    // The API key is team ABCDE12345's, but ZZZZZ99999 was selected.
    let created = try await creation.run(type: .distribution, relatedID: nil, entry: "XLESS_DIST_KEY@ZZZZZ99999", team: "ZZZZZ99999", keys: { vault.keys })
    #expect(created.team == team)
    #expect(try vault.read().entry(named: "XLESS_DIST_KEY@ZZZZZ99999")?.metadata.teamID == team)
    #expect(said.lines.contains { $0.hasPrefix("warning: certificate C3 belongs to team \(team)") })
}

@Test func limitMessagesListBothDeveloperIDGenerations() async throws {
    #expect(CertificateType.developerIDApplicationG2.listArguments == "--type developer-id-application --type developer-id-application-g2")
    #expect(CertificateType.distribution.listArguments == "--type distribution")
    #expect(try CertificateTypeArgument.parseForList("developer-id") == [.developerIDApplication, .developerIDApplicationG2])
    #expect(try CertificateTypeArgument.parseForList("developer-id-application-g2") == [.developerIDApplicationG2])
    let ambiguous = await accountError {
        _ = try await CertificateCreation(api: FakeCertificates(journal: Journal(), create: { _, _ in throw URLError(.timedOut) }))
            .run(type: .developerIDApplicationG2, relatedID: nil, csrPEM: "csr")
    }
    #expect(ambiguous?.fix.contains("xless certs list --type developer-id-application --type developer-id-application-g2") == true)
}

@Test func aChosenNameThatSignReadsIsCheckedLikeTheDefault() throws {
    #expect(CertificateKeyStore.signBase(of: "XLESS_DIST_KEY@\(team)") == "XLESS_DIST_KEY")
    #expect(CertificateKeyStore.signBase(of: "XLESS_INSTALLER_KEY") == "XLESS_INSTALLER_KEY")
    #expect(CertificateKeyStore.signBase(of: "MY_KEY") == nil && CertificateKeyStore.signBase(of: "XLESS_DEVELOPMENT_KEY") == nil)
    let vault = try CertVault(entries: [("XLESS_DIST_KEY", .init())])
    defer { vault.cleanup() }
    #expect(throws: XlessError.self) {
        try CertificateKeyStore.precheck(try vault.read(), name: "XLESS_DIST_KEY@\(team)", base: CertificateKeyStore.signBase(of: "XLESS_DIST_KEY@\(team)"), team: team, stage: .account)
    }
    // sign bootstrap has no --name: its fix says how to keep both another way.
    do {
        try CertificateKeyStore.precheck(try vault.read(), name: "XLESS_DIST_KEY", base: "XLESS_DIST_KEY", team: nil, stage: .sign,
                                         keepBoth: "create the new certificate with `xless certs create --type distribution --name <another entry name>`")
        Issue.record("no clash")
    } catch let e as XlessError {
        #expect(e.stage == .sign && e.fix.contains("xless certs create --type distribution --name") && !e.fix.contains("pass --name"))
    }
}

@Test func aFailureBeforeSendingIsNotCalledARefusal() async throws {
    let vault = try CertVault()
    defer { vault.cleanup() }
    let e = await accountError {
        _ = try await CertificateCreation(api: FakeCertificates(journal: Journal(), create: { _, _ in throw XlessError(.account, "cannot build the token", fix: "check ASC_KEY_P8") }))
            .run(type: .development, relatedID: nil, entry: "XLESS_DEVELOPMENT_KEY", team: nil, keys: { vault.keys })
    }
    #expect(e?.cause.hasPrefix("xless could not ask App Store Connect for the Apple Development certificate (cannot build the token)") == true)
    #expect(try vault.read().entries.isEmpty)
}

// MARK: - Linking keys to certificates by public key

/// Answers the passphrase and counts how often it was asked.
private final class CountedPassphrase: PassphrasePrompter, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    var asked: Int { lock.withLock { _asked } }
    func askSecret(_ prompt: String) throws -> SecretBytes { lock.withLock { _asked += 1 }; return SecretBytes(utf8: "correct horse battery") }
    func ask(_ prompt: String) throws -> String { try askSecret(prompt).utf8String() }
    func say(_ line: String) {}
}

@Test func aCSRCertificateIsRecordedWithItsStoredKeyFoundBeforeTheRequest() async throws {
    let key = try SigningKey.generate()
    let vault = try CertVault(entries: [("JUNK", .init()), ("XLESS_DIST_KEY", .init(created: Date(timeIntervalSince1970: 1_800_000_000))),
                                        ("XLESS_DEVID_KEY@ZZZZZ99999", .init(teamID: "ZZZZZ99999")), ("LINKED", .init(certificateID: "C0"))],
                              secrets: ["XLESS_DIST_KEY": key.pem])
    defer { vault.cleanup() }
    // Another team's key, and a key whose certificate is still listed, are not even candidates; without a team, only the
    // keys of no team are.
    #expect(CertificateKeyLink.candidates(in: try vault.read(), known: ["C0"], team: team).map(\.name) == ["JUNK", "XLESS_DIST_KEY"])
    #expect(CertificateKeyLink.candidates(in: try vault.read(), known: [], team: nil).map(\.name) == ["JUNK", "XLESS_DIST_KEY", "LINKED"])
    let prompter = CountedPassphrase()
    let store = VaultSecretStore(store: vault.store, cache: nil, prompter: { prompter })
    let journal = Journal()
    let api = FakeCertificates(journal: journal, existing: [resource("C0")], create: { _, csr in resource("C9", der: try issue(csr)) },
                               atPost: { journal.add("asked=\(prompter.asked)") })
    var creation = CertificateCreation(api: api)
    creation.link = CertificateKeyLink(store: store, team: team)
    let created = try await creation.run(type: .distribution, relatedID: nil, csrPEM: try key.csrPEM(commonName: "hsm"))
    // The passphrase was asked once, before the request.
    #expect(journal.events == ["list ", "POST DISTRIBUTION", "asked=1"])
    #expect(prompter.asked == 1)
    #expect(created.entry == "XLESS_DIST_KEY" && created.matched)
    let file = try vault.read()
    #expect(file.entry(named: "XLESS_DIST_KEY")?.metadata == VaultEntry.Metadata(
        teamID: team, certificateID: "C9", created: Date(timeIntervalSince1970: 1_800_000_000), expires: Date(timeIntervalSince1970: 1_900_000_000),
        certificateType: "DISTRIBUTION"))
    #expect(try vault.secret("XLESS_DIST_KEY") == key.pem)
    #expect(file.entry(named: "JUNK")?.metadata == VaultEntry.Metadata())
    #expect(file.entry(named: "XLESS_DEVID_KEY@ZZZZZ99999")?.metadata.certificateID == nil)
    #expect(created.text.contains("its private key is in the secret store as XLESS_DIST_KEY (matched by its public key)"))
    #expect(!(try ASCOutput.json(created)).contains("matched"))
}

@Test func aCSRWhoseKeyIsNotThereAsksNothingOrOnlyNotes() async throws {
    let csr = try SigningKey.generate().csrPEM(commonName: "hsm")
    let api = FakeCertificates(journal: Journal(), existing: [resource("C0")], create: { _, csr in resource("C9", der: try issue(csr)) })
    // Every key linked to a listed certificate: nothing is opened.
    let linked = try CertVault(entries: [("LINKED", .init(certificateID: "C0"))])
    defer { linked.cleanup() }
    let prompter = CountedPassphrase()
    var creation = CertificateCreation(api: api)
    creation.link = CertificateKeyLink(store: VaultSecretStore(store: linked.store, cache: nil, prompter: { prompter }), team: team)
    #expect(try await creation.run(type: .distribution, relatedID: nil, csrPEM: csr).entry == nil)
    #expect(prompter.asked == 0)
    // An ECC CSR (Apple Pay processing): the store keeps RSA keys only, so it is not looked at.
    let unlinked = try CertVault(entries: [("XLESS_DIST_KEY", .init())])
    defer { unlinked.cleanup() }
    let ecc = try CertificateSigningRequest(version: .v1, subject: try DistinguishedName { CommonName("pay") }, privateKey: .init(P256.Signing.PrivateKey()),
                                            attributes: .init(), signatureAlgorithm: .ecdsaWithSHA256).serializeAsPEM().pemString
    creation.link = CertificateKeyLink(store: VaultSecretStore(store: unlinked.store, cache: nil, prompter: { prompter }), team: team)
    #expect(try await creation.run(type: .applePay, relatedID: "M1", csrPEM: ecc).entry == nil)
    #expect(prompter.asked == 0)
    // A store that cannot be unlocked (no terminal): a note, and the certificate is still made.
    let said = Said()
    creation.link = CertificateKeyLink(store: VaultSecretStore(store: unlinked.store, cache: nil, prompter: { nil }), team: team)
    creation.say = { said.lines.append($0) }
    #expect(try await creation.run(type: .distribution, relatedID: nil, csrPEM: csr).certificate.id == "C9")
    #expect(said.lines.count == 1 && said.lines[0].contains("`xless certs link` records the certificate with it later"))
}

@Test func aReusedCSRsOldCertificateIsNotTakenForTheNewOne() async throws {
    let csr = try SigningKey.generate().csrPEM(commonName: "reused")
    let old = resource("OLD", der: try issue(csr, notAfter: Date(timeIntervalSince1970: 1_750_000_000)))
    let made = Made()
    // The request fails and made nothing: the old certificate for the same key does not count.
    let nothing = FakeCertificates(journal: Journal(), existing: [old], create: { _, _ in throw ASCError(status: 503, items: []) })
    let e = await accountError { _ = try await CertificateCreation(api: nothing).run(type: .distribution, relatedID: nil, csrPEM: csr) }
    #expect(e?.isAmbiguousCertificateCreation == true)
    // It made one: that one is taken.
    let api = FakeCertificates(journal: Journal(), create: { _, csr in
        made.add(resource("NEW", der: try issue(csr)))
        throw ASCError(status: 503, items: [])
    }, listed: { [old] + made.certificates })
    #expect(try await CertificateCreation(api: api).run(type: .distribution, relatedID: nil, csrPEM: csr).certificate.id == "NEW")
}

@Test func certsLinkRecordsEveryMatchAndNamesTheKeysNoCertificateMatches() async throws {
    let dist = try SigningKey.generate(), devid = try SigningKey.generate()
    let vault = try CertVault(entries: [("XLESS_DIST_KEY", .init()), ("XLESS_DEVID_KEY", .init(certificateID: "GONE")), ("ORPHAN", .init())],
                              secrets: ["XLESS_DIST_KEY": dist.pem, "XLESS_DEVID_KEY": devid.pem, "ORPHAN": try SigningKey.generate().pem])
    defer { vault.cleanup() }
    func content(_ key: SigningKey, until: Date) throws -> String { try issue(try key.csrPEM(commonName: "x"), notAfter: until).base64EncodedString() }
    // Two certificates for the distribution key: the later one is recorded.
    let list = listing([
        certJSON("D1", expires: "2027-01-01T00:00:00.000+0000", content: try content(dist, until: Date(timeIntervalSince1970: 1_798_761_600))),
        certJSON("D2", expires: "2028-01-01T00:00:00.000+0000", content: try content(dist, until: Date(timeIntervalSince1970: 1_830_297_600))),
        certJSON("V1", type: "DEVELOPER_ID_APPLICATION_G2", expires: "2028-01-01T00:00:00.000+0000", content: try content(devid, until: Date(timeIntervalSince1970: 1_830_297_600))),
    ])
    let t = FakeTransport([(200, list)])
    let out = try await cli(t).link(store: vault.store.secretStore, team: team)
    #expect(t.requests[0].url!.query!.contains("certificateContent"))
    #expect(out == """
    linked XLESS_DIST_KEY to Apple Distribution certificate D2, expires 2028-01-01
    linked XLESS_DEVID_KEY to Developer ID Application certificate V1, expires 2028-01-01
    no certificate of the team matches ORPHAN: if its certificate is gone, remove it with `xless secrets rm ORPHAN`

    """)
    let file = try vault.read()
    #expect(file.entry(named: "XLESS_DIST_KEY")?.metadata.certificateID == "D2")
    #expect(file.entry(named: "XLESS_DEVID_KEY")?.metadata.certificateType == "DEVELOPER_ID_APPLICATION_G2")
    #expect(file.entry(named: "XLESS_DIST_KEY")?.metadata.teamID == team)
    // Without a selected team, the certificates' own team is used: another team's key is not opened nor called unmatched.
    let other = try CertVault(entries: [("XLESS_DIST_KEY@ZZZZZ99999", .init(teamID: "ZZZZZ99999")), ("SPARE", .init())],
                              secrets: ["SPARE": try SigningKey.generate().pem])
    defer { other.cleanup() }
    let teamless = try await cli(FakeTransport([(200, list)])).link(store: other.store.secretStore, team: nil)
    #expect(teamless == "no certificate of the team matches SPARE: if its certificate is gone, remove it with `xless secrets rm SPARE`\n")
    // Run again: nothing left but the orphan.
    let again = try await cli(FakeTransport([(200, list)]), json: true).link(store: vault.store.secretStore, team: team)
    struct Outcome: Decodable { let linked: [[String: String]]; let unmatched: [String] }
    let decoded = try JSONDecoder().decode(Outcome.self, from: Data(again.utf8))
    #expect(decoded.linked.isEmpty && decoded.unmatched == ["ORPHAN"])
}
