import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault
@testable import xless

/// A store in a fresh 0700 directory, made with fast scrypt; removed by `cleanup()`.
private struct TempVault {
    let root: URL
    let store: VaultStore
    let file: VaultFile
    let key: SymmetricKey

    init(entries: [(String, VaultEntry.Kind, VaultEntry.Metadata)] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-apikey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        for (name, kind, meta) in entries {
            file.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: meta, secret: SecretBytes(utf8: "x"), dataKey: key))
        }
        try store.create(file)
        self.file = file
        self.key = key
    }

    var apiKeyStore: APIKeyStore { APIKeyStore(store: store, fileID: file.id, dataKey: key) }
    func read() throws -> VaultFile { try #require(try store.read()) }
    func secret(_ name: String) throws -> String { try VaultCrypto.open(try #require(try read().entry(named: name)), dataKey: key).utf8String() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// What happened, in order.
private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func add(_ e: String) { lock.withLock { _events.append(e) } }
}

private struct FakeWeb: APIKeyWeb {
    var journal: Journal
    var key = ASCAPIKeyInfo(id: "2X9R4HXF34", nickname: "ci", roles: ["APP_MANAGER"], canDownload: true)
    var download: @Sendable () throws -> SecretBytes

    func create(nickname: String, roles: [String], appIDs: [String]) async throws -> ASCAPIKeyInfo {
        journal.add("create \(nickname) \(roles.joined(separator: ",")) \(appIDs.joined(separator: ","))")
        return key
    }

    func downloadPrivateKey(id: String) async throws -> SecretBytes {
        journal.add("download \(id)")
        return try download()
    }
}

private let pem = P256.Signing.PrivateKey().pemRepresentation
private let team = "ABCDE12345"
private let issuer = "69a6de7e-0000-47e3-e053-5b8c7c11a4d1"

private func creation(_ vault: TempVault, _ journal: Journal, web: FakeWeb? = nil,
                      verify: APIKeyVerifier? = nil) -> APIKeyCreation {
    let web = web ?? FakeWeb(journal: journal, download: { SecretBytes(utf8: pem) })
    let store = vault.store
    return APIKeyCreation(web: web, vault: vault.apiKeyStore, verify: verify ?? { c in
        // The key is already in the store when it is verified.
        journal.add("verify \(c.keyID) \(c.issuerID) stored=\((try? store.read())?.entry(named: "ASC_KEY_P8@\(team)") != nil)")
        #expect(c.privateKeyPEM == pem)
    })
}

private func run(_ c: APIKeyCreation) async throws -> APIKeyCreated {
    try await c.run(nickname: "ci", roles: ["APP_MANAGER"], appIDs: [], team: team, issuerID: issuer, entry: "ASC_KEY_P8@\(team)",
                    now: Date(timeIntervalSince1970: 1_800_000_000))
}

private func accountError(_ body: () async throws -> Void) async -> XlessError? {
    do { try await body(); Issue.record("expected an error"); return nil } catch let e as XlessError {
        #expect(e.stage == .account)
        return e
    } catch { Issue.record("unexpected \(error)"); return nil }
}

// MARK: create

@Test func createDownloadsOnceStoresThenVerifies() async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let created = try await run(creation(vault, journal))
    #expect(journal.events == ["create ci APP_MANAGER ", "download 2X9R4HXF34", "verify 2X9R4HXF34 \(issuer) stored=true"])
    #expect(created == APIKeyCreated(keyID: "2X9R4HXF34", nickname: "ci", roles: ["APP_MANAGER"], allApps: true, appIDs: [],
                                     issuerID: issuer, team: team, entry: "ASC_KEY_P8@\(team)", verified: true))
    let entry = try #require(try vault.read().entry(named: "ASC_KEY_P8@\(team)"))
    #expect(entry.kind == .ascAPIKey)
    #expect(entry.metadata == VaultEntry.Metadata(teamID: team, keyID: "2X9R4HXF34", issuerID: issuer,
                                                  created: Date(timeIntervalSince1970: 1_800_000_000), role: "APP_MANAGER"))
    #expect(try vault.secret("ASC_KEY_P8@\(team)") == pem)
    #expect(!created.text.contains("PRIVATE KEY"))
    #expect(!(try ASCOutput.json(created)).contains("PRIVATE KEY"))
}

@Test func aKeyThatCannotBeDownloadedIsNeverAskedFor() async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    var web = FakeWeb(journal: journal, download: { SecretBytes(utf8: pem) })
    web.key.canDownload = false
    let e = await accountError { _ = try await run(creation(vault, journal, web: web)) }
    #expect(journal.events == ["create ci APP_MANAGER "])
    #expect(e?.cause.contains("API key 2X9R4HXF34 was created, but xless does not have its private key") == true)
    #expect(e?.fix.contains("xless auth api-key revoke 2X9R4HXF34") == true)
    #expect(try vault.read().entries.isEmpty)
}

@Test(arguments: [
    (APIKeyDownloadError.noAnswer("timed out"), "Apple may have served it, and it is lost"),
    (.refused(status: 404, message: "not found"), "answered HTTP 404 to its download (not found)"),
    (.unreadable("no private key"), "held no private key"),
])
func aFailedDownloadSaysTheKeyExistsAndShouldBeRevoked(error: APIKeyDownloadError, says: String) async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let web = FakeWeb(journal: journal, download: { throw error })
    let e = await accountError { _ = try await run(creation(vault, journal, web: web)) }
    #expect(journal.events == ["create ci APP_MANAGER ", "download 2X9R4HXF34"], "downloaded once, never again")
    #expect(e?.cause.contains(says) == true, "\(e?.cause ?? "")")
    #expect(e?.cause.contains("was created") == true)
    #expect(e?.fix.contains("cannot be downloaded again") == true)
    #expect(e?.fix.contains("xless auth api-key revoke 2X9R4HXF34") == true)
    #expect(try vault.read().entries.isEmpty)
}

@Test func aNameTakenSinceThePrecheckDoesNotLoseTheKey() async throws {
    let vault = try TempVault(entries: [("ASC_KEY_P8@\(team)", .ascAPIKey, .init(teamID: team, keyID: "OLDKEY0000"))])
    defer { vault.cleanup() }
    let journal = Journal()
    let created = try await run(creation(vault, journal, verify: { _ in }))
    #expect(created.entry == "ASC_KEY_P8@\(team).2X9R4HXF34")
    #expect(try vault.secret("ASC_KEY_P8@\(team).2X9R4HXF34") == pem)
}

@Test func aStoreThatCannotKeepTheKeySaysItIsLost() async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let wrong = APIKeyStore(store: vault.store, fileID: "another-store", dataKey: vault.key)
    let c = APIKeyCreation(web: FakeWeb(journal: journal, download: { SecretBytes(utf8: pem) }), vault: wrong, verify: { _ in journal.add("verify") })
    let e = await accountError { _ = try await run(c) }
    #expect(e?.cause.contains("the secret store could not keep it") == true)
    #expect(e?.fix.contains("revoke") == true)
    #expect(!journal.events.contains("verify"))
}

@Test func aKeyStoredButRefusedSaysWhereItIs() async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let e = await accountError {
        _ = try await run(creation(vault, journal, verify: { _ in throw ASCError(status: 401, items: [], method: "GET", path: "/v1/apps") }))
    }
    #expect(e?.cause.contains("is stored as ASC_KEY_P8@\(team)") == true)
    #expect(try vault.secret("ASC_KEY_P8@\(team)") == pem)
}

@Test func aCreateWithoutAnAnswerMayHaveCreatedAKey() async throws {
    struct Web: APIKeyWeb {
        func create(nickname: String, roles: [String], appIDs: [String]) async throws -> ASCAPIKeyInfo { throw URLError(.timedOut) }
        func downloadPrivateKey(id: String) async throws -> SecretBytes { Issue.record("downloaded"); return SecretBytes(count: 0) }
    }
    let vault = try TempVault()
    defer { vault.cleanup() }
    let e = await accountError {
        _ = try await APIKeyCreation(web: Web(), vault: vault.apiKeyStore, verify: { _ in })
            .run(nickname: "n", roles: ["ADMIN"], appIDs: [], team: team, issuerID: issuer, entry: "E")
    }
    #expect(e?.fix.contains("xless auth api-key list") == true)
}

// MARK: precheck

@Test func thePrecheckRefusesASecondKeyForTheTeam() throws {
    let vault = try TempVault(entries: [("ASC_KEY_P8@\(team)", .ascAPIKey, .init(teamID: team, keyID: "OLDKEY0000")),
                                        ("ASC_KEY_P8@ZZZZZ99999", .ascAPIKey, .init(teamID: "ZZZZZ99999", keyID: "OTHER00000"))])
    defer { vault.cleanup() }
    let file = try vault.read()
    do { try APIKeyStore.precheck(file, name: "ASC_KEY_P8@\(team)", team: team); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause.contains("OLDKEY0000"))
        #expect(e.fix.contains("xless auth api-key revoke OLDKEY0000"))
    }
    #expect(throws: XlessError.self) { try APIKeyStore.precheck(file, name: "ASC_KEY_P8", team: nil) }
    try APIKeyStore.precheck(file, name: "ASC_KEY_P8@QQQQQ11111", team: "QQQQQ11111")
    #expect(APIKeyStore.entryName(team: team) == "ASC_KEY_P8@\(team)")
    #expect(APIKeyStore.entryName(team: nil) == "ASC_KEY_P8")
}

// MARK: import

@Test func importValidatesBeforeAnyRequestAndStoresOnlyAWorkingKey() async throws {
    let vault = try TempVault()
    defer { vault.cleanup() }
    let journal = Journal()
    let rsa = "-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END PRIVATE KEY-----\n"
    for bad in ["", "hello", rsa] {
        let e = await accountError {
            _ = try await APIKeyImport.run(secret: SecretBytes(utf8: bad), keyID: "K1", issuerID: issuer, role: nil, team: nil, entry: "ASC_KEY_P8",
                                           verify: { _ in journal.add("verify") }, unlock: { journal.add("unlock"); return vault.apiKeyStore })
        }
        #expect(e != nil)
    }
    #expect(journal.events.isEmpty)
    let refused = await accountError {
        _ = try await APIKeyImport.run(secret: SecretBytes(utf8: pem), keyID: "K1", issuerID: issuer, role: nil, team: nil, entry: "ASC_KEY_P8",
                                       verify: { _ in journal.add("verify"); throw ASCError(status: 401, items: []) },
                                       unlock: { journal.add("unlock"); return vault.apiKeyStore })
    }
    #expect(refused?.cause.contains("nothing was stored") == true)
    #expect(journal.events == ["verify"])
    #expect(try vault.read().entries.isEmpty)
    let name = try await APIKeyImport.run(secret: SecretBytes(utf8: pem), keyID: "K1", issuerID: issuer, role: "ADMIN", team: team,
                                          entry: "ASC_KEY_P8@\(team)", verify: { _ in }, unlock: { vault.apiKeyStore },
                                          now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(name == "ASC_KEY_P8@\(team)")
    let entry = try #require(try vault.read().entry(named: name))
    #expect(entry.metadata == .init(teamID: team, keyID: "K1", issuerID: issuer, created: Date(timeIntervalSince1970: 1_800_000_000), role: "ADMIN"))
    #expect(try vault.secret(name) == pem)
}

// MARK: verification

@Test func theVerificationRetriesAFreshKeysRefusalAFewTimes() async throws {
    let creds = ASCCredentials(keyID: "K1", issuerID: issuer, privateKeyPEM: pem)
    let t = FakeTransport([(401, "{}"), (401, "{}"), (200, #"{"data":[]}"#)])
    try await APIKeyVerification.verifier(transport: t, unauthorizedRetries: 4, sleep: { _ in })(creds)
    #expect(t.requests.count == 3)
    let url = try #require(t.requests.last?.url)
    #expect(url.path == "/v1/apps" && url.query == "limit=1")
    let once = FakeTransport([(401, "{}"), (200, "{}")])
    await #expect(throws: ASCError.self) { try await APIKeyVerification.verifier(transport: once, sleep: { _ in })(creds) }
    #expect(once.requests.count == 1)
}

// MARK: list and revoke

@Test func theListMarksTheKeyXlessUses() throws {
    let keys = [ASCAPIKeyInfo(id: "K1", nickname: "ci", roles: ["APP_MANAGER"], lastUsed: "2026-11-01", createdBy: "Jane Doe"),
                ASCAPIKeyInfo(id: "K2", nickname: nil, roles: ["ADMIN", "FINANCE"], isActive: false, allAppsVisible: false)]
    let rows = APIKeyListing.rows(keys, used: "K1")
    #expect(rows.map(\.usedByXless) == [true, false])
    let table = APIKeyListing.table(rows)
    let lines = table.split(separator: "\n")
    #expect(lines[1].hasPrefix("*  K1"))
    #expect(lines[2].contains("ADMIN,FINANCE") && lines[2].contains("revoked") && lines[2].contains("some"))
    #expect(table.contains("the key xless uses"))
    #expect(APIKeyListing.table([]).contains("no App Store Connect API keys"))
    #expect(try ASCOutput.json(rows).contains("\"usedByXless\" : true"))
}

@Test func theKeyXlessUsesComesFromTheEnvironmentElseTheStore() throws {
    let vault = try TempVault(entries: [("ASC_KEY_P8@\(team)", .ascAPIKey, .init(teamID: team, keyID: "STOREKEY00"))])
    defer { vault.cleanup() }
    #expect(APIKeyListing.usedKeyID(env: ["ASC_KEY_ID": "ENVKEY0000"], store: { try vault.store.read() }, team: team) == "ENVKEY0000")
    #expect(APIKeyListing.usedKeyID(env: [:], store: { try vault.store.read() }, team: team) == "STOREKEY00")
    #expect(APIKeyListing.usedKeyID(env: [:], store: { try vault.store.read() }, team: "ZZZZZ99999") == nil)
    #expect(APIKeyListing.usedKeyID(env: [:], store: { nil }, team: nil) == nil)
}

@Test func revokingRemovesEveryStoreEntryOfThatKeyOnly() throws {
    let vault = try TempVault(entries: [("ASC_KEY_P8@\(team)", .ascAPIKey, .init(teamID: team, keyID: "K1")),
                                        ("ASC_KEY_P8@\(team).K1", .ascAPIKey, .init(teamID: team, keyID: "K1")),
                                        ("ASC_KEY_P8@ZZZZZ99999", .ascAPIKey, .init(teamID: "ZZZZZ99999", keyID: "K2")),
                                        ("APNS", .authKey, .init(keyID: "K1"))])
    defer { vault.cleanup() }
    #expect(try APIKeyStore.removeKeys(id: "K1", from: vault.store) == ["ASC_KEY_P8@\(team)", "ASC_KEY_P8@\(team).K1"])
    #expect(try vault.read().entries.map(\.name) == ["ASC_KEY_P8@ZZZZZ99999", "APNS"])
    #expect(try APIKeyStore.removeKeys(id: "K9", from: vault.store).isEmpty)
    let none = VaultStore(location: VaultLocation(directory: vault.root.appendingPathComponent("nothing")))
    #expect(try APIKeyStore.removeKeys(id: "K1", from: none).isEmpty)
}

// MARK: roles

@Test func rolesAreNormalizedAndDefaultToAppManager() throws {
    #expect(try APIKeyRoles.parse([]) == ["APP_MANAGER"])
    #expect(try APIKeyRoles.parse(["admin", "Access-To-Reports", "ADMIN"]) == ["ADMIN", "ACCESS_TO_REPORTS"])
    #expect(try APIKeyRoles.parse(["app manager"]) == ["APP_MANAGER"])
    #expect(throws: XlessError.self) { try APIKeyRoles.parse(["OWNER"]) }
    #expect(APIKeyRoles.recorded(["ADMIN", "FINANCE"]) == "ADMIN,FINANCE")
}

// MARK: commands

@Test func createChecksItsOptionsBeforeAnything() throws {
    let c = try AuthAPIKeyCreateCommand.parse([])
    #expect(c.roles.isEmpty && c.apps.isEmpty && c.nickname == nil)
    let full = try AuthAPIKeyCreateCommand.parse(["--name", "ci", "--role", "developer", "--app", "123", "--app", "456", "--team", team])
    #expect(full.roles == ["developer"] && full.apps == ["123", "456"] && full.nickname == "ci")
    for bad in [["--all-apps", "--app", "1"], ["--role", "owner"], ["--role", "ADMIN", "--app", "1"], ["--app", "com.example.app"], ["--name", " "]] {
        #expect(throws: (any Error).self, "\(bad)") { try AuthAPIKeyCreateCommand.parse(bad) }
    }
}

@Test func importAndRevokeCheckTheirArguments() throws {
    let i = try AuthAPIKeyImportCommand.parse(["--p8-file", "AuthKey_2X9R4HXF34.p8", "--issuer-id", issuer, "--role", "admin"])
    #expect(i.p8File == "AuthKey_2X9R4HXF34.p8" && i.keyId == nil && i.role == "admin")
    #expect(throws: (any Error).self) { try AuthAPIKeyImportCommand.parse(["--p8-file", "k.p8"]) }
    #expect(throws: (any Error).self) { try AuthAPIKeyImportCommand.parse(["--p8-file", "k.p8", "--issuer-id", issuer, "--key-id", "abc"]) }
    #expect(throws: (any Error).self) { try AuthAPIKeyImportCommand.parse(["--p8-file", "k.p8", "--issuer-id", issuer, "--role", "boss"]) }
    #expect(try AuthAPIKeyRevokeCommand.parse(["2X9R4HXF34", "--yes"]).confirmation.yes)
    #expect(throws: (any Error).self) { try AuthAPIKeyRevokeCommand.parse(["../x"]) }
}

@Test func statusShowsTheRoleXlessRecorded() {
    let key = AuthStatusReport.StoreKey(name: "ASC_KEY_P8@\(team)", teamID: team, hasKeyID: true, hasIssuerID: true, role: "ADMIN,FINANCE")
    let r = AuthStatusReport.build(env: [:], storeKey: .success(key), teamFlag: nil, savedTeam: nil, keyringAvailable: true, session: nil, now: Date())
    #expect(r.keyRole == "ADMIN,FINANCE")
    #expect(r.text.contains("key's role     ADMIN, FINANCE"))
    let env = AuthStatusReport.build(env: ["ASC_KEY_P8": "x"], storeKey: .success(key), teamFlag: nil, savedTeam: nil, keyringAvailable: true,
                                     session: nil, now: Date())
    #expect(env.keyRole == nil, "the store's role is not the environment key's")
}
