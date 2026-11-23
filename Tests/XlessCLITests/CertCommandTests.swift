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

    init(entries: [(String, VaultEntry.Metadata)] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-certs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        for (name, meta) in entries {
            file.entries.append(try VaultCrypto.seal(name: name, kind: .signingKey, metadata: meta, secret: SecretBytes(utf8: "x"), dataKey: key))
        }
        try store.create(file)
        self.file = file
        self.key = key
    }

    var keys: CertificateKeyStore { CertificateKeyStore(store: store, fileID: file.id, dataKey: key) }
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

    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate] {
        journal.add("list \(types.map(\.rawValue).joined(separator: ","))")
        return existing
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
    #expect(journal.events == ["POST APPLE_PAY_MERCHANT_IDENTITY M1"])
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
    #expect(throws: (any Error).self) { try SignBootstrapCommand.parse(["--type", "distribution", "--csr-only"]) }
    _ = try CertsCreateCommand.parse(["--type", "Apple Pay Merchant Identity", "--merchant-id", "merchant.com.example", "--team", team])
    _ = try CertsCreateCommand.parse(["--type", "pass-type-id-with-nfc", "--pass-type-id", "pass.com.example.ticket", "--csr", "p.csr"])
    _ = try CertsListCommand.parse(["--type", "distribution", "--type", "developer-id", "--expiring", "30", "--json"])
    _ = try SignBootstrapCommand.parse(["--type", "distribution"])
    _ = try SignBootstrapCommand.parse(["--type", "installer", "--out", "k.pem", "--csr-only"])
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
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
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
