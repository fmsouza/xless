import ArgumentParser
import Crypto
import Foundation
import Testing
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault
@testable import xless

/// A store in a fresh 0700 directory, made with fast scrypt; removed by `cleanup()`.
private struct KeyVault {
    let root: URL
    let store: VaultStore
    let file: VaultFile
    let key: SymmetricKey

    init(entries: [(String, VaultEntry.Kind, VaultEntry.Metadata)] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-authkey-\(UUID().uuidString)")
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

    var authKeyStore: AuthKeyStore { AuthKeyStore(store: store, fileID: file.id, dataKey: key) }
    func read() throws -> VaultFile { try #require(try store.read()) }
    func secret(_ name: String) throws -> String { try VaultCrypto.open(try #require(try read().entry(named: name)), dataKey: key).utf8String() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// What happened, in order.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [String] = []
    var list: [String] { lock.withLock { _list } }
    func add(_ e: String) { lock.withLock { _list.append(e) } }
}

private struct FakePortal: AuthKeyWeb {
    var events: Events
    var existing: [PortalAuthKey] = []
    var created = PortalAuthKey(id: "NEWKEY1234", name: "Push", services: [.init(id: "U27F4V844T")], canDownload: true)
    var download: @Sendable () throws -> SecretBytes = { SecretBytes(utf8: p8) }
    var createError: (any Error & Sendable)?

    func list() async throws -> [PortalAuthKey] { events.add("list"); return existing }
    func get(id: String) async throws -> PortalAuthKey {
        events.add("get \(id)")
        guard let k = existing.first(where: { $0.id == id }) else { throw XlessError(.account, "the team has no auth key \(id)", fix: "") }
        return k
    }
    func create(name: String, services: [AuthKeyService], bundleIDs: [String], musicIDs: [String]) async throws -> PortalAuthKey {
        events.add("create \(name) \(services.map(\.argument).joined(separator: ",")) \(bundleIDs.joined(separator: ","))\(musicIDs.isEmpty ? "" : " music:" + musicIDs.joined(separator: ","))")
        if let createError { throw createError }
        return created
    }
    func downloadPrivateKey(id: String) async throws -> SecretBytes { events.add("download \(id)"); return try download() }
    func revoke(id: String) async throws { events.add("revoke \(id)") }
}

private let p8 = P256.Signing.PrivateKey().pemRepresentation
private let team = "ABCDE12345"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func apnsKey(_ id: String, _ name: String) -> PortalAuthKey { PortalAuthKey(id: id, name: name, services: [.init(id: "U27F4V844T")]) }

private func accountError(_ body: () async throws -> Void) async -> XlessError? {
    do { try await body(); Issue.record("expected an error"); return nil } catch let e as XlessError {
        #expect(e.stage == .account)
        return e
    } catch { Issue.record("unexpected \(error)"); return nil }
}

private func create(_ portal: FakePortal, _ vault: KeyVault, services: [AuthKeyService] = [.apns], bundleIDs: [String] = []) async throws -> AuthKeyCreated {
    try await AuthKeyCreation(web: portal, vault: vault.authKeyStore).run(name: "Push", services: services, bundleIDs: bundleIDs, team: team, now: now)
}

// MARK: create

@Test func createDownloadsOnceThenStoresBeforeReporting() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let created = try await create(FakePortal(events: events), vault)
    #expect(events.list == ["list", "create Push apns ", "download NEWKEY1234"])
    #expect(created == AuthKeyCreated(keyID: "NEWKEY1234", name: "Push", services: ["apns"], bundleIDs: [], musicIDs: [], team: team, entry: "XLESS_APNS_KEY@\(team)"))
    let entry = try #require(try vault.read().entry(named: "XLESS_APNS_KEY@\(team)"))
    #expect(entry.kind == .authKey)
    #expect(entry.metadata == VaultEntry.Metadata(teamID: team, keyID: "NEWKEY1234", created: now, services: "apns"))
    #expect(try vault.secret("XLESS_APNS_KEY@\(team)") == p8)
    #expect(!created.text.contains("PRIVATE KEY"))
    #expect(created.text.contains("xless secrets export XLESS_APNS_KEY@\(team) --out AuthKey_NEWKEY1234.p8"))
    #expect(!(try ASCOutput.json(created)).contains("PRIVATE KEY"))
}

@Test func aKeyOfSeveralServicesGoesToTheAuthKeyEntryWithItsServices() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let created = try await create(FakePortal(events: events), vault, services: [.apns, .signInWithApple], bundleIDs: ["B1"])
    #expect(events.list[1] == "create Push apns,siwa B1")
    #expect(created.entry == "XLESS_AUTH_KEY@\(team)")
    #expect(try vault.read().entry(named: created.entry)?.metadata.services == "apns,siwa")
    #expect(AuthKeyStore.base(for: [.deviceCheck]) == "XLESS_DEVICECHECK_KEY")
    #expect(AuthKeyStore.base(for: [.musicKit]) == "XLESS_MUSICKIT_KEY")
    #expect(AuthKeyStore.base(for: [.signInWithApple]) == "XLESS_SIWA_KEY")
}

@Test func aSecondAPNsKeyOfTheTeamGetsItsKeyIDInTheNameSoLookupsStayUnambiguous() async throws {
    let vault = try KeyVault(entries: [("XLESS_APNS_KEY@\(team)", .authKey, .init(teamID: team, keyID: "OLD1", services: "apns")),
                                       ("XLESS_APNS_KEY@ZZZZZ99999", .authKey, .init(teamID: "ZZZZZ99999", keyID: "OTHER", services: "apns"))])
    defer { vault.cleanup() }
    let created = try await create(FakePortal(events: Events(), existing: [apnsKey("OLD1", "Old")]), vault)
    #expect(created.entry == "XLESS_APNS_KEY.NEWKEY1234@\(team)")
    #expect(try VaultResolver.candidate(for: "XLESS_APNS_KEY", in: try vault.read(), team: team)?.name == "XLESS_APNS_KEY@\(team)")
    // Another team's entry does not push this team's key off the well-known name.
    let other = try KeyVault(entries: [("XLESS_APNS_KEY@ZZZZZ99999", .authKey, .init(teamID: "ZZZZZ99999", keyID: "OTHER", services: "apns"))])
    defer { other.cleanup() }
    #expect(AuthKeyStore.entryName(base: "XLESS_APNS_KEY", keyID: "K", team: team, in: other.file) == "XLESS_APNS_KEY@\(team)")
}

@Test func theAPNsLimitIsCheckedBeforeAnythingIsCreatedAndNamesTheKeys() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let portal = FakePortal(events: events, existing: [apnsKey("K1", "Prod"), apnsKey("K2", "Staging"),
                                                       PortalAuthKey(id: "K3", name: "Check", services: [.init(id: "DQ8HTZ7739")])])
    let e = await accountError { _ = try await create(portal, vault) }
    #expect(events.list == ["list"])
    #expect(e?.cause == "the team already has 2 APNs keys (Apple allows 2): K1 \"Prod\", K2 \"Staging\"")
    #expect(e?.fix.contains("xless keys revoke <KEY_ID>") == true)
    // DeviceCheck has no limit xless knows: a third key is Apple's to refuse.
    _ = try await create(FakePortal(events: Events(), existing: portal.existing), vault, services: [.deviceCheck])
}

@Test func aNameTheTeamUsesIsRefusedBeforeCreating() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let e = await accountError { _ = try await create(FakePortal(events: events, existing: [PortalAuthKey(id: "K1", name: "Push", services: [])]), vault) }
    #expect(events.list == ["list"])
    #expect(e?.cause.contains("named \"Push\" (K1)") == true)
}

@Test(arguments: [
    (APIKeyDownloadError.noAnswer("timed out"), "Apple may have served it, and it is lost"),
    (.refused(status: 200, message: "already downloaded"), "answered HTTP 200 to its download (already downloaded)"),
    (.unreadable("something that is not a P-256 private key (.p8)"), "held something that is not a P-256"),
])
func aFailedAuthKeyDownloadSaysTheKeyExistsAndShouldBeRevoked(error: APIKeyDownloadError, says: String) async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let e = await accountError { _ = try await create(FakePortal(events: events, download: { throw error }), vault) }
    #expect(events.list == ["list", "create Push apns ", "download NEWKEY1234"], "downloaded once, never again")
    #expect(e?.cause.contains("auth key NEWKEY1234 was created, but xless does not have its private key") == true)
    #expect(e?.cause.contains(says) == true, "\(e?.cause ?? "")")
    #expect(e?.fix.contains("cannot be downloaded again") == true)
    #expect(e?.fix.contains("xless keys revoke NEWKEY1234") == true)
    #expect(try vault.read().entries.isEmpty)
}

@Test func aStoreThatCannotKeepTheKeySaysTheKeyIsLost() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let replaced = AuthKeyStore(store: vault.store, fileID: "another-store", dataKey: vault.key)
    let e = await accountError {
        _ = try await AuthKeyCreation(web: FakePortal(events: Events()), vault: replaced).run(name: "Push", services: [.apns], bundleIDs: [], team: team)
    }
    #expect(e?.cause.contains("auth key NEWKEY1234 was created") == true)
    #expect(e?.cause.contains("the secret store could not keep it") == true)
    #expect(e?.fix.contains("xless keys revoke NEWKEY1234") == true)
}

@Test func aCreateErrorIsPassedOnAndNothingIsDownloaded() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    var portal = FakePortal(events: events)
    portal.createError = XlessError(.account, "no answer", fix: "check `xless keys list`")
    let e = await accountError { _ = try await create(portal, vault) }
    #expect(e?.cause == "no answer")
    #expect(events.list == ["list", "create Push apns "])
}

// MARK: list, show, revoke

@Test func listShowsServicesAndTheStoreEntryHoldingEachKey() async throws {
    let vault = try KeyVault(entries: [("XLESS_APNS_KEY@\(team)", .authKey, .init(teamID: team, keyID: "K1", services: "apns")),
                                       ("ASC_KEY_P8", .ascAPIKey, .init(keyID: "K2"))])
    defer { vault.cleanup() }
    let keys = [apnsKey("K1", "Push"),
                PortalAuthKey(id: "K2", name: "Login", services: [.init(id: "APPLE_ID_AUTH_KEY_CONFIGURATION", bundleIDs: ["B1"]), .init(id: "X9", name: "WeatherKit")])]
    let file = try vault.read()
    let cli = AuthKeyCLI(web: FakePortal(events: Events(), existing: keys), storeFile: { file })
    let table = try await cli.list()
    #expect(table.contains("K1") && table.contains("APNs") && table.contains("XLESS_APNS_KEY@\(team)"))
    #expect(table.contains("Sign in with Apple, WeatherKit"))
    let json = try await AuthKeyCLI(web: FakePortal(events: Events(), existing: keys), json: true, storeFile: { file }).list()
    let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [[String: Any]]]
    #expect(decoded?["data"]?.first?["storeEntries"] as? [String] == ["XLESS_APNS_KEY@\(team)"])
    #expect(decoded?["data"]?.last?["bundleIDs"] as? [String] == ["B1"])
    #expect(decoded?["data"]?.last?["services"] as? [String] == ["siwa", "X9"])
    let empty = try await AuthKeyCLI(web: FakePortal(events: Events())).list()
    #expect(empty.contains("no auth keys"))
}

@Test func showSaysWhetherXlessHasThePrivateKey() async throws {
    let cli = AuthKeyCLI(web: FakePortal(events: Events(), existing: [apnsKey("K1", "Push")]))
    let text = try await cli.show("K1")
    #expect(text.contains("Key ID:       K1"))
    #expect(text.contains("none (xless does not have its private key)"))
}

@Test func revokeAsksRevokesThenRemovesTheStoreEntries() async throws {
    let vault = try KeyVault(entries: [("XLESS_APNS_KEY@\(team)", .authKey, .init(teamID: team, keyID: "K1", services: "apns")),
                                       ("ASC_KEY_P8", .ascAPIKey, .init(keyID: "K1"))])
    defer { vault.cleanup() }
    let events = Events()
    let store = vault.store
    let cli = AuthKeyCLI(web: FakePortal(events: events, existing: [apnsKey("K1", "Push")]), storeFile: { try? store.read() },
                         removeEntries: { try AuthKeyStore.removeKeys(id: $0, from: store) })
    var asked = ""
    let out = try await cli.revoke("K1") { asked = $0; return true }
    #expect(asked.contains("Revoke auth key K1 \"Push\" (APNs)?"))
    #expect(asked.contains("XLESS_APNS_KEY@\(team)"))
    #expect(events.list == ["get K1", "revoke K1"])
    #expect(out == "revoked auth key K1\nremoved XLESS_APNS_KEY@\(team) from the secret store\n")
    // Only auth-key entries go: an API key that shares the ID stays.
    #expect(try vault.read().entries.map(\.name) == ["ASC_KEY_P8"])
}

@Test func aNoAtTheQuestionSendsNothing() async throws {
    let events = Events()
    let out = try await AuthKeyCLI(web: FakePortal(events: events, existing: [apnsKey("K1", "Push")])).revoke("K1") { _ in false }
    #expect(out == "cancelled; nothing was sent\n")
    #expect(events.list == ["get K1"])
}

@Test func aKeyThisAppleIDCannotRevokeIsRefusedBeforeAsking() async throws {
    var key = apnsKey("K1", "Push")
    key.canRevoke = false
    let e = await accountError { _ = try await AuthKeyCLI(web: FakePortal(events: Events(), existing: [key])).revoke("K1") { _ in Issue.record("asked"); return true } }
    #expect(e?.fix.contains("Account Holder or an Admin") == true)
}

// MARK: arguments

@Test func servicesAreRepeatableOrCommaSeparatedAndUnknownOnesAreRefused() throws {
    #expect(try AuthKeyServiceArgument.parse(["apns,siwa", "APNs", "device-check"]) == [.apns, .signInWithApple, .deviceCheck])
    #expect(throws: ValidationError.self) { try AuthKeyServiceArgument.parse(["mapkit"]) }
    #expect(throws: ValidationError.self) { try AuthKeyServiceArgument.parse([]) }
}

@Test func signInWithAppleNeedsABundleIDAndOnlyItTakesOne() throws {
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "siwa"]) }
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "apns", "--bundle-id", "com.example.app"]) }
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "apns", "--name", "Push-Key"]) }
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "siwa", "--bundle-id", "com/example"]) }
    _ = try KeysCreateCommand.parse(["--service", "siwa", "--bundle-id", "com.example.app", "--name", "Login"])
    _ = try KeysCreateCommand.parse(["--service", "apns"])
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "musickit"]) }
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "apns", "--music-id", "M1"]) }
    #expect(throws: (any Error).self) { try KeysCreateCommand.parse(["--service", "musickit", "--music-id", "music.com.example"]) }
    _ = try KeysCreateCommand.parse(["--service", "musickit", "--music-id", "AB12CD34EF"])
    #expect(throws: (any Error).self) { try KeysRevokeCommand.parse(["../x"]) }
    _ = try KeysRevokeCommand.parse(["2X9R4HXF34", "--yes"])
}

@Test func theAppleAccountGroupListsKeys() {
    #expect(Xless.helpMessage().contains("keys"))
    #expect(AuthKeyCreation.defaultName([.apns, .signInWithApple], now: now) == "xless APNs SIWA 20270115")
    #expect(throws: Never.self) { try PortalName.validate(AuthKeyCreation.defaultName(AuthKeyService.allCases, now: now)) }
}

@Test func withoutANameTheDefaultNameNeverCollidesWithTheTeamsKeys() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let taken = AuthKeyCreation.defaultName([.apns], now: now)
    let portal = FakePortal(events: events, existing: [PortalAuthKey(id: "K1", name: taken, services: [.init(id: "DQ8HTZ7739")]),
                                                       PortalAuthKey(id: "K2", name: taken + " 2", services: [.init(id: "DQ8HTZ7739")])])
    let created = try await AuthKeyCreation(web: portal, vault: vault.authKeyStore).run(name: nil, services: [.apns], bundleIDs: [], team: team, now: now)
    #expect(created.name == taken + " 3")
    #expect(events.list[1] == "create \(taken) 3 apns ")
}

@Test func aMusicKitKeyIsCreatedForItsMusicIDs() async throws {
    let vault = try KeyVault()
    defer { vault.cleanup() }
    let events = Events()
    let created = try await AuthKeyCreation(web: FakePortal(events: events), vault: vault.authKeyStore)
        .run(name: "Music", services: [.musicKit], bundleIDs: [], musicIDs: ["M1"], team: team, now: now)
    #expect(events.list[1] == "create Music musickit  music:M1")
    #expect(created.entry == "XLESS_MUSICKIT_KEY@\(team)")
}

@Test func aStoreFailureAfterTheRevokeSaysTheKeyIsRevoked() async throws {
    struct Broken: Error {}
    let cli = AuthKeyCLI(web: FakePortal(events: Events(), existing: [apnsKey("K1", "Push")]), removeEntries: { _ in throw Broken() })
    let e = await accountError { _ = try await cli.revoke("K1") { _ in true } }
    #expect(e?.cause.hasPrefix("revoked auth key K1, but could not remove") == true)
    #expect(e?.fix.contains("the key itself is revoked") == true)
}
