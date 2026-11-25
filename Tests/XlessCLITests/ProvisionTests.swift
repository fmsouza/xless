import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftASN1
import Testing
import X509
import XlessAppleID
import XlessASC
import XlessCore
import XlessSign
import XlessStore
import XlessVault
@testable import xless

private let team = "ABCDE12345"
private let bundle = "com.example.app"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private struct Failure: Error {}

/// One in-memory Apple account: the documented API's resources, the web session's, and what was written.
private final class World: @unchecked Sendable {
    var bundles: [String: String] = [:]
    var capabilities: [String: [SigningCapability]] = [:]
    var certificates: [ASCCertificate] = []
    var profiles: [SigningProfile] = []
    var apps: [AppSummary] = []
    var groups: [String: [ProvisionGroup]] = [:]
    var portal: [PortalLinkedKind: [PortalIdentifier]] = [:]
    var linked: [PortalLinkedKind: [String: [String]]] = [:]
    var authKeys: [PortalAuthKey] = []
    var listingPushed = false
    /// What the listing's push holds back once planned again after it made a new version (Apple copied the old one's).
    var heldAfterPush: [String] = []
    var notesAfterPush: [String] = []
    var privacySent = false
    /// App Store Connect declares a category app.yml no longer has.
    var privacyExtra = false
    /// Write operations, in order.
    var writes: [String] = []
    /// Operations that fail once.
    var failing: Set<String> = []
    var counter = 0

    var listingSecrets: [String] = []
    func next(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }

    func write(_ op: String, _ detail: String) throws {
        if failing.remove(op) != nil { throw XlessError(.account, "Apple refused \(op)", fix: "try later") }
        writes.append("\(op) \(detail)")
    }

    /// What a profile made now grants: every key of the enabled capabilities, the assigned groups and containers.
    func content(bundleID identifier: String, platform: Platform) -> Data {
        var ents: [String: Any] = [:]
        let types = Set((capabilities[bundles[identifier] ?? ""] ?? []).map(\.type))
        for (key, type) in Capabilities.map(for: platform) where types.contains(type.rawValue) { ents[key] = ["*"] }
        if types.contains("APP_GROUPS") { ents["com.apple.security.application-groups"] = ids(.appGroup, identifier) }
        if types.contains("ICLOUD") { ents["com.apple.developer.icloud-container-identifiers"] = ids(.cloudContainer, identifier) }
        if types.contains("PUSH_NOTIFICATIONS") { ents["aps-environment"] = "production" }
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["Entitlements": ents], format: .xml, options: 0)
        return Data("CMS".utf8) + plist + Data("SIG".utf8)
    }

    func ids(_ kind: PortalLinkedKind, _ identifier: String) -> [String] {
        (linked[kind]?[identifier] ?? []).compactMap { id in portal[kind]?.first { $0.id == id }?.identifier }
    }
}

private struct FakeAccount: ProvisionAccount {
    let world: World
    var issuerID: String { "ISSUER" }

    func bundleID(_ identifier: String) async throws -> String? { world.bundles[identifier] }
    func register(bundleID identifier: String) async throws -> String {
        if let id = world.bundles[identifier] { return id }
        try world.write("registerBundle", identifier)
        let id = world.next("B")
        world.bundles[identifier] = id
        return id
    }
    func capabilities(of bundleResourceID: String) async throws -> [SigningCapability] { world.capabilities[bundleResourceID] ?? [] }
    func enable(_ request: CapabilityRequest, on bundleResourceID: String, identifier: String) async throws {
        try world.write("enable", "\(request.type.rawValue) \(identifier)")
        world.capabilities[bundleResourceID, default: []].removeAll { $0.type == request.type.rawValue }
        world.capabilities[bundleResourceID, default: []].append(SigningCapability(id: world.next("CAP"), type: request.type.rawValue,
                                                                                   settings: CapabilitySetting.chosen(request.settings)))
    }
    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate] {
        world.certificates.filter { types.map(\.rawValue).contains($0.certificateType) }
    }
    func create(type: CertificateType, csrPEM: String, relatedID: String?) async throws -> ASCCertificate {
        try world.write("createCertificate", type.rawValue)
        let cert = certificate(world.next("C"), type: type.rawValue, der: try issue(csrPEM))
        world.certificates.append(cert)
        return cert
    }
    func profiles(named name: String, type: ProfileType) async throws -> [SigningProfile] {
        world.profiles.filter { $0.name == name && $0.type == type.rawValue }
    }
    func createProfile(name: String, type: ProfileType, bundleResourceID: String, bundleID: String, certificateID: String) async throws -> SigningProfile {
        try world.write("createProfile", name)
        let identifier = world.bundles.first { $0.value == bundleResourceID }!.key
        let p = SigningProfile(id: world.next("P"), name: name, type: type.rawValue, state: "ACTIVE", expires: now.addingTimeInterval(300 * 86_400),
                                 bundleID: bundleResourceID, certificateIDs: [certificateID],
                                 content: world.content(bundleID: identifier, platform: type == .iosAppStore ? .ios : .macos))
        world.profiles.append(p)
        return p
    }
    func findApp(bundleID: String) async throws -> AppSummary? { world.apps.first { $0.bundleId == bundleID } }
    func showsApp(id: String) async throws -> Bool { world.apps.contains { $0.id == id } }
    func hasBundleID(_ identifier: String) async throws -> Bool { world.bundles[identifier] != nil }
    func registerBundleID(_ identifier: String) async throws { _ = try await register(bundleID: identifier) }
    func betaGroups(app appID: String) async throws -> [ProvisionGroup] { world.groups[appID] ?? [] }
    func createBetaGroup(name: String, app appID: String, external: Bool) async throws {
        try world.write("createGroup", name)
        world.groups[appID, default: []].append(ProvisionGroup(id: world.next("G"), name: name, isInternal: !external))
    }
}

private struct FakePortal: LinkedIdentifierPortal {
    let world: World
    let kind: PortalLinkedKind

    func list() async throws -> [PortalIdentifier] { world.portal[kind] ?? [] }
    func create(identifier: String, name: String) async throws -> PortalCreation {
        try world.write("create\(kind.rawValue)", identifier)
        let item = PortalIdentifier(id: world.next("L"), identifier: identifier, name: name)
        world.portal[kind, default: []].append(item)
        return .created(item)
    }
    func bundle(_ argument: String) async throws -> PortalBundleID {
        guard let id = world.bundles[argument] else { throw XlessError(.account, "no bundle \(argument)", fix: "") }
        return PortalBundleID(id: id, identifier: argument, name: argument)
    }
    func linked(of bundle: PortalBundleID) async throws -> LinkedState {
        let present = (world.capabilities[bundle.id] ?? []).contains { $0.type == kind.capability }
        return LinkedState(present: present, enabled: present, ids: world.linked[kind]?[bundle.identifier] ?? [])
    }
    func setLinked(_ ids: [String], enabled: Bool, on bundle: PortalBundleID) async throws -> LinkedState {
        try world.write("assign\(kind.rawValue)", "\(ids.joined(separator: ",")) \(bundle.identifier)")
        world.linked[kind, default: [:]][bundle.identifier] = ids
        return LinkedState(present: true, enabled: enabled, ids: ids)
    }
}

private struct FakeAuthKeys: AuthKeyWeb {
    let world: World
    func list() async throws -> [PortalAuthKey] { world.authKeys }
    func get(id: String) async throws -> PortalAuthKey { world.authKeys.first { $0.id == id }! }
    func create(name: String, services: [AuthKeyService], bundleIDs: [String], musicIDs: [String]) async throws -> PortalAuthKey {
        try world.write("createAuthKey", name)
        let key = PortalAuthKey(id: "KEY\(world.authKeys.count + 1)", name: name, services: services.map { .init(id: $0.id) })
        world.authKeys.append(key)
        return key
    }
    func downloadPrivateKey(id: String) async throws -> SecretBytes { SecretBytes(utf8: "-----BEGIN PRIVATE KEY-----\nAPNS\n-----END PRIVATE KEY-----\n") }
    func revoke(id: String) async throws { Issue.record("revoked \(id)") }
}

private struct FakeApps: AppCreationWeb, Sendable {
    let world: World
    func issuerID() async throws -> String? { "ISSUER" }
    func findApp(bundleID: String) async throws -> AppSummary? { world.apps.first { $0.bundleId == bundleID } }
    func requireBundleID(_ identifier: String) async throws {}
    func create(_ request: AppCreateRequest) async -> AppCreateAnswer {
        do { try world.write("createApp", "\(request.name) \(request.platforms.joined(separator: ","))") } catch {
            return .ambiguous("no answer")
        }
        let app = WebApp(id: "APP1", name: request.name, bundleID: request.bundleID, sku: request.sku, primaryLocale: request.primaryLocale)
        world.apps.append(AppSummary(app))
        return .created(app)
    }
}

private struct FakePrivacy: ProvisionPrivacy {
    let world: World
    func plan(_ want: AppYAML.Privacy, app: String, appName: String) async throws -> [StoreChange] {
        var changes = world.privacySent ? [] : [StoreChange(.create, .privacy, "App Privacy EMAIL_ADDRESS", requests: [])]
        if world.privacyExtra { changes.append(StoreChange(.delete, .privacy, "App Privacy PRECISE_LOCATION", requests: [], privacy: [.delete("U9", nil)])) }
        if !changes.isEmpty { changes.append(StoreChange(.update, .privacy, "publish the App Privacy answers of \(appName)", requests: [], privacy: [.publish])) }
        return changes
    }
    func apply(_ change: StoreChange, app: String) async throws {
        try world.write("privacy", change.subject)
        world.privacySent = true
    }
}

private struct FakeListing: ProvisionListing {
    let world: World
    func plan(appID: String) async throws -> ProvisionListingPlan {
        ProvisionListingPlan(changes: world.listingPushed ? [] : ["+ version text en-US"], held: [], notes: [], secrets: world.listingSecrets)
    }
    func apply(appID: String) async throws -> ProvisionListingApplied {
        try world.write("push", appID)
        world.listingPushed = true
        return ProvisionListingApplied(sent: 1, held: world.heldAfterPush, notes: world.notesAfterPush)
    }
}

/// A real store in a temporary directory, with a fast KDF.
private struct TestVault {
    let root: URL
    let store: VaultStore
    let key: SymmetricKey
    var vault: ProvisionVault

    init(env: [String: String] = [:], create: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-provision-\(UUID().uuidString)")
        try makePrivateDirectory(root)
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        let (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        if create { try store.create(file) }
        self.key = key
        vault = ProvisionVault(store: store.secretStore, env: env)
    }

    func add(_ name: String, kind: VaultEntry.Kind = .signingKey, secret: String, metadata: VaultEntry.Metadata) throws {
        try store.update { file in
            var next = file
            next.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: metadata, secret: SecretBytes(utf8: secret), dataKey: key))
            return next
        }
    }

    func entry(_ name: String) throws -> VaultEntry? { try store.read()?.entry(named: name) }

    /// Makes the file say a newer xless wrote it (store format 3): readable, never rewritten.
    func makeNewer() throws {
        let url = store.location.file
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 3
        object["minimumReaderVersion"] = 3
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func certificate(_ id: String, type: String, der: Data?, expires: String = "2030-03-01T12:00:00.000+0000") -> ASCCertificate {
    var attributes: [String: JSONValue] = ["certificateType": .string(type), "expirationDate": .string(expires)]
    if let der { attributes["certificateContent"] = .string(der.base64EncodedString()) }
    return ASCCertificate(resource: ASCAnyResource(type: "certificates", id: id, attributes: attributes))
}

/// A certificate for the CSR's key, issued by itself, with the team as its OU (as Apple's are).
private func issue(_ csrPEM: String) throws -> Data {
    let csr = try CertificateSigningRequest(pemEncoded: csrPEM)
    let issuerKey = P256.Signing.PrivateKey()
    let name = try DistinguishedName { CommonName("Example (\(team))"); OrganizationalUnitName(team) }
    let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: csr.publicKey, notValidBefore: Date(timeIntervalSince1970: 1_700_000_000),
                               notValidAfter: Date(timeIntervalSince1970: 1_900_000_000), issuer: name, subject: name,
                               signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(), issuerPrivateKey: .init(issuerKey))
    var ser = DER.Serializer()
    try ser.serialize(cert)
    return Data(ser.serializedBytes)
}

private nonisolated(unsafe) let entitlements: [String: Any] = [
    "aps-environment": "production",
    "com.apple.security.application-groups": ["group.com.example.app"],
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.app"],
    "com.apple.developer.icloud-services": ["CloudKit"],
]

/// An iOS App Store app and its Developer ID macOS app under one bundle ID, internal and external TestFlight groups.
private func inputs(ios: Bool = true, macDistribution: Distribution = .developerID) -> ProvisionInputs {
    var targets: [SigningTarget] = []
    if ios { targets.append(SigningTarget(platform: .ios, distribution: .appStore, bundleID: bundle, entitlements: entitlements)) }
    targets.append(SigningTarget(platform: .macos, distribution: macDistribution, bundleID: bundle, entitlements: [:]))
    return ProvisionInputs(team: team, targets: targets, version: "1.0",
                           testflight: TestFlightConfig(groups: ["Internal"], whatToTest: "Everything", external: ExternalTestFlight(groups: ["Beta"])))
}

private func manifest() -> StoreManifest {
    var m = StoreManifest()
    m.app.primaryLocale = "en-US"
    m.app.sku = "EX1"
    m.app.version = "1.0"
    m.app.privacy = AppYAML.Privacy(collectsData: true, data: [.init(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false)])
    m.locales["en-US"] = LocaleListing(name: "Example")
    return m
}

private struct Setup {
    let world = World()
    var inputs = xless_inputs()
    var vault: TestVault
    var hasWeb = true
    var signIns = 0

    init(vault: TestVault) { self.vault = vault }

    var account: FakeAccount { FakeAccount(world: world) }
    var web: ProvisionWebSide {
        ProvisionWebSide(appGroups: FakePortal(world: world, kind: .appGroup), cloudContainers: FakePortal(world: world, kind: .cloudContainer),
                         authKeys: FakeAuthKeys(world: world), apps: FakeApps(world: world), privacy: FakePrivacy(world: world))
    }
    var store: ProvisionStore { ProvisionStore(manifest: manifest(), listing: FakeListing(world: world)) }

    func plan() async throws -> ProvisionPlan {
        try await ProvisionPlanner(inputs: inputs, account: account, web: hasWeb ? web : nil, vault: vault.vault, store: store, now: now).plan()
    }

    func apply(_ plan: ProvisionPlan, lines: Lines = Lines()) async throws -> ProvisionApplied {
        let web = self.web
        return try await ProvisionApplier(inputs: inputs, account: account, web: { lines.add("sign-in"); return web }, vault: vault.vault, store: store,
                                          say: { lines.add($0) }, now: now).apply(plan)
    }
}

private func xless_inputs() -> ProvisionInputs { inputs() }

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.withLock { _all } }
    func add(_ line: String) { lock.withLock { _all.append(line) } }
}

private func subjects(_ plan: ProvisionPlan) -> [String] { plan.steps.map { "\($0.area.rawValue): \($0.action.rawValue) \($0.subject)" } }

// MARK: - Plan

@Test func anEmptyAccountGetsTheWholePlanInDependencyOrder() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    let plan = try await s.plan()
    #expect(subjects(plan) == [
        "bundle-ids: create com.example.app",
        "capabilities: enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app",
        "capabilities: enable ICLOUD (iCloud) on com.example.app",
        "capabilities: enable APP_GROUPS (App Groups) on com.example.app",
        "app-groups: create group.com.example.app",
        "icloud-containers: create iCloud.com.example.app",
        "certificates: create Apple Distribution",
        "certificates: create Developer ID Application",
        "keys: create APNs key",
        "profiles: create xless com.example.app IOS_APP_STORE",
        "profiles: create xless com.example.app MAC_APP_DIRECT",
        "app: create app record for com.example.app",
        "listing: push appstore/",
        "privacy: push app.yml privacy",
        "testflight: create group Internal",
        "testflight: create group Beta",
    ], "\(plan.text)")
    #expect(plan.blockers.isEmpty && plan.drift.isEmpty)
    #expect(plan.steps.filter(\.web).map(\.area) == [.appGroups, .iCloudContainers, .keys, .app, .privacy])
    let app = try #require(plan.steps.first { $0.area == .app })
    #expect(app.details == ["\"Example\", SKU EX1, primary locale en-US, IOS version 1.0"], "a Developer ID Mac app is not on the App Store")
    #expect(plan.steps[0].details == ["registered as universal (iOS and macOS), named \"xless com example app\""], "the name `sign` gives it")
    #expect(plan.text.contains("16 steps to apply (5 through the Apple ID web session)"))
    #expect(s.world.writes.isEmpty, "planning only reads")
    let json = try ASCOutput.json(plan)
    #expect(json.contains("\"webSession\" : true") && json.contains("\"area\" : \"bundle-ids\"") && json.contains("\"team\" : \"ABCDE12345\""), "\(json)")
}

@Test func applyingTheWholePlanLeavesNothingToDo() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    let lines = Lines()
    let applied = try await s.apply(try await s.plan(), lines: lines)
    #expect(applied.done.count == 16 && applied.drift.isEmpty)
    #expect(lines.all.filter { $0 == "sign-in" }.count == 1, "one sign-in for every web step")
    #expect(s.world.writes.count == 19, "\(s.world.writes)")
    #expect(s.world.writes.contains("createApp Example IOS"))
    let dist = try #require(try v.entry("XLESS_DIST_KEY@\(team)"))
    #expect(dist.metadata.certificateID != nil && dist.metadata.teamID == team)
    #expect(try v.entry("XLESS_DEVID_KEY@\(team)")?.metadata.certificateID != nil)
    #expect(try v.entry("XLESS_APNS_KEY@\(team)")?.kind == .authKey)

    let again = try await s.plan()
    #expect(again.steps.isEmpty, "\(again.text)")
    #expect(again.drift.isEmpty && again.blockers.isEmpty, "\(again.text)")
    #expect(again.text.contains("nothing to do"))
}

/// Types the passphrase, and says so in `lines`.
private final class TypingPassphrase: PassphrasePrompter {
    let lines: Lines
    init(lines: Lines) { self.lines = lines }
    func askSecret(_ prompt: String) throws -> SecretBytes { lines.add("passphrase"); return SecretBytes(utf8: "correct horse battery") }
    func ask(_ prompt: String) throws -> String { lines.add("question"); return "" }
    func say(_ line: String) {}
}

@Test func everythingIsAskedBeforeTheFirstStepOncePerApply() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    let lines = Lines()
    s.vault.vault = ProvisionVault(store: VaultSecretStore(store: v.store, cache: nil, prompter: { TypingPassphrase(lines: lines) }), env: [:])
    s.hasWeb = false // planned without a session: what needs one is known
    _ = try await s.apply(try await s.plan(), lines: lines)
    #expect(Array(lines.all.prefix(2)) == ["passphrase", "sign-in"] && lines.all[2].hasPrefix("1/"), "\(lines.all)")
    #expect(lines.all.filter { ["passphrase", "question", "sign-in"].contains($0) }.count == 2, "each once")
    // Nothing to write and no web step: nothing is asked.
    let more = Lines()
    s.hasWeb = true
    s.world.groups = [:]
    let plan = try await s.plan()
    #expect(!plan.steps.isEmpty && !plan.steps.contains { $0.web || $0.writesStore }, "\(plan.text)")
    s.vault.vault = ProvisionVault(store: VaultSecretStore(store: v.store, cache: nil, prompter: { TypingPassphrase(lines: more) }), env: [:])
    _ = try await s.apply(plan, lines: more)
    #expect(!more.all.contains { ["passphrase", "question", "sign-in"].contains($0) }, "\(more.all)")
}

@Test func theDemoAccountsPasswordIsReadableBeforeTheFirstStep() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    try v.add("XLESS_DEMO_PASSWORD", kind: .password, secret: "pw", metadata: .init())
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true, macDistribution: .appStore)
    _ = try await s.apply(try await s.plan())
    func asked(_ secrets: [String], env: [String: String] = [:]) async throws -> Int {
        let lines = Lines()
        s.world.listingPushed = false
        s.world.listingSecrets = secrets
        let plan = try await s.plan()
        #expect(plan.steps.map(\.area) == [.listing], "\(plan.text)")
        s.vault.vault = ProvisionVault(store: VaultSecretStore(store: v.store, cache: nil, prompter: { TypingPassphrase(lines: lines) }), env: env)
        _ = try await s.apply(plan, lines: lines)
        #expect(lines.all.first != "passphrase" || lines.all.dropFirst().first?.hasPrefix("1/1") == true)
        return lines.all.filter { $0 == "passphrase" }.count
    }
    #expect(try await asked(["XLESS_DEMO_PASSWORD"]) == 1)
    #expect(try await asked([]) == 0, "a push that sends no password reads none")
    #expect(try await asked(["XLESS_DEMO_PASSWORD"], env: ["XLESS_DEMO_PASSWORD": "pw"]) == 0)
    #expect(try await asked(["NOT_STORED"]) == 0)
}

@Test func aSignInThatFailsStopsApplyBeforeAnythingIsSent() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    let plan = try await s.plan()
    let applier = ProvisionApplier(inputs: s.inputs, account: s.account, web: { throw XlessError(.account, "Apple refused the password", fix: "try again") },
                                   vault: s.vault.vault, store: s.store, now: now)
    var caught: ProvisionApplyFailure?
    do { _ = try await applier.apply(plan) } catch let f as ProvisionApplyFailure { caught = f }
    let failure = try #require(caught)
    #expect(s.world.writes.isEmpty, "\(s.world.writes)")
    #expect(failure.applied.done.isEmpty && failure.left.count == plan.steps.count - 1 && failure.failed?.cause == "Apple refused the password")
    #expect(failure.error.cause.contains("(0 of 16 steps were done, 16 left)"), "\(failure.error.cause)")
}

@Test func aFailedApplySaysWhatWasDoneAndARerunDoesTheRest() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    s.world.failing = ["createProfile"]
    let lines = Lines()
    var caught: ProvisionApplyFailure?
    let plan = try await s.plan()
    do { _ = try await s.apply(plan, lines: lines) } catch let f as ProvisionApplyFailure { caught = f }
    let failure = try #require(caught)
    let e = XlessError.wrapping(failure, stage: .account)
    #expect(e.stage == .account && e.stage.exitCode == 20 && e.cause == failure.error.cause)
    #expect(e.cause.contains("Profiles, create xless com.example.app IOS_APP_STORE: Apple refused createProfile (9 of 16 steps were done, 7 left)"), "\(e.cause)")
    #expect(e.fix.contains("re-run `xless provision apply`"))
    #expect(lines.all.contains { $0.hasPrefix("done: registered bundle ID com.example.app") })
    #expect(lines.all.contains { $0.hasPrefix("left: Profiles: create xless com.example.app IOS_APP_STORE;") })
    // --json: the same story on standard output, with the exit code unchanged (the command rethrows `failure.error`).
    #expect(failure.applied.done.count == 9)
    #expect(failure.failed == .init(area: .profiles, action: .create, subject: "xless com.example.app IOS_APP_STORE", cause: "Apple refused createProfile", fix: "try later"))
    #expect(failure.left.map(\.subject) == ["xless com.example.app MAC_APP_DIRECT", "app record for com.example.app", "appstore/", "app.yml privacy", "group Internal", "group Beta"])
    let json = try ProvisionApplyCommand.output(plan: plan, failure: failure, json: true)
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect((doc["done"] as? [Any])?.count == 9 && (doc["left"] as? [Any])?.count == 6 && (doc["drift"] as? [Any])?.isEmpty == true)
    let failed = try #require(doc["failed"] as? [String: Any])
    #expect(failed["area"] as? String == "profiles" && failed["subject"] as? String == "xless com.example.app IOS_APP_STORE" && failed["cause"] as? String == "Apple refused createProfile")
    #expect((doc["plan"] as? [String: Any])?["team"] as? String == team)
    #expect(try ProvisionApplyCommand.output(plan: plan, failure: failure, json: false).isEmpty, "the text output is the error itself")

    let rest = try await s.plan()
    #expect(subjects(rest) == [
        "profiles: create xless com.example.app IOS_APP_STORE",
        "profiles: create xless com.example.app MAC_APP_DIRECT",
        "app: create app record for com.example.app",
        "listing: push appstore/",
        "privacy: push app.yml privacy",
        "testflight: create group Internal",
        "testflight: create group Beta",
    ], "\(rest.text)")
    let before = s.world.writes.count
    _ = try await s.apply(rest)
    #expect(s.world.writes.count == before + 8)
    #expect(s.world.writes.filter { $0.hasPrefix("createCertificate") }.count == 2, "certificates are not made twice")
    #expect(try await s.plan().steps.isEmpty)
}

@Test func withoutAKeptSessionTheWebStepsAreCheckedWhenApplied() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.hasWeb = false
    let plan = try await s.plan()
    let unchecked = plan.steps.filter { !$0.checked }
    #expect(unchecked.map(\.area) == [.appGroups, .iCloudContainers, .keys, .privacy])
    #expect(unchecked.allSatisfy { $0.web })
    #expect(plan.steps.first { $0.area == .appGroups }?.details.last?.contains("xless auth login --keep") == true)
    #expect(plan.text.contains("[web] (checked when applied)"))
    // Applying signs in and finds the groups in place: nothing is created twice.
    s.world.portal[.appGroup] = [PortalIdentifier(id: "LG", identifier: "group.com.example.app", name: "Example")]
    _ = try await s.apply(plan)
    #expect(!s.world.writes.contains { $0.hasPrefix("createappGroup") })
    #expect(s.world.writes.contains("assignappGroup LG com.example.app"))
}

@Test func aStoredKeyWhoseCertificateIsGoneGetsANewCertificateNotANewKey() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let key = try SigningKey.generate()
    try v.add("XLESS_DIST_KEY@\(team)", secret: key.pem, metadata: .init(teamID: team, certificateID: "REVOKED"))
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true, macDistribution: .appStore)
    s.inputs.targets[0].entitlements = [:]
    s.inputs.testflight = nil
    let plan = try await s.plan()
    let certs = plan.steps.filter { $0.area == .certificates }
    #expect(certs.map(\.subject) == ["Apple Distribution", "Mac Installer Distribution"], "\(plan.text)")
    #expect(certs[0].details[0].contains("stored as XLESS_DIST_KEY@\(team), whose certificate is gone"))
    _ = try await s.apply(plan)
    let entry = try #require(try v.entry("XLESS_DIST_KEY@\(team)"))
    let made = try #require(s.world.certificates.first { $0.certificateType == "DISTRIBUTION" })
    #expect(entry.metadata.certificateID == made.id)
    #expect(try key.matches(certificateDER: Array(try #require(made.der))))
    #expect(try v.entry("XLESS_INSTALLER_KEY@\(team)") != nil)
    #expect(try await s.plan().steps.isEmpty)
}

@Test func aKeyInTheEnvironmentWithItsCertificateIsUsedAsItIs() async throws {
    let key = try SigningKey.generate()
    let v = try TestVault(env: ["XLESS_DIST_KEY": key.pem])
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true)
    s.inputs.targets.removeLast()
    s.world.certificates = [certificate("C9", type: "DISTRIBUTION", der: try issue(try key.csrPEM(commonName: "x")))]
    let plan = try await s.plan()
    #expect(!plan.steps.contains { $0.area == .certificates })
    #expect(plan.known.certificates[.distribution] == "C9")
}

@Test func aDeveloperIDOnlyProjectHasNoAppRecordListingOrTestFlight() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.inputs = inputs(ios: false)
    let plan = try await s.plan()
    #expect(subjects(plan) == ["bundle-ids: create com.example.app", "certificates: create Developer ID Application",
                               "profiles: create xless com.example.app MAC_APP_DIRECT"], "\(plan.text)")
}

@Test func whatWouldBeDeletedIsDriftNotAStep() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    _ = try await s.apply(try await s.plan())
    let resource = try #require(s.world.bundles[bundle])
    // An extra capability with an entitlement, one Apple enables by itself, an extra app group, a profile gone stale.
    s.world.capabilities[resource]!.append(SigningCapability(id: "X1", type: "HEALTHKIT", settings: [:]))
    s.world.capabilities[resource]!.append(SigningCapability(id: "X2", type: "IN_APP_PURCHASE", settings: [:]))
    s.world.portal[.appGroup]!.append(PortalIdentifier(id: "OLD", identifier: "group.com.example.old", name: "Old"))
    s.world.linked[.appGroup]![bundle]!.append("OLD")
    let i = try #require(s.world.profiles.firstIndex { $0.type == "IOS_APP_STORE" })
    s.world.profiles[i].expires = now.addingTimeInterval(86_400)
    let plan = try await s.plan()
    #expect(plan.steps.isEmpty, "\(plan.text)")
    #expect(plan.drift.map(\.subject) == ["HEALTHKIT on com.example.app", "group.com.example.old on com.example.app",
                                          "xless com.example.app IOS_APP_STORE (\(s.world.profiles[i].id))"], "\(plan.text)")
    #expect(plan.drift[0].fix == "`xless bundle-ids capabilities com.example.app disable HEALTHKIT` once no app uses it")
    #expect(plan.drift[1].fix.contains("xless app-groups unassign com.example.app group.com.example.old"))
    #expect(plan.drift[2].message.contains("it expires on") && plan.drift[2].fix.contains("xless profiles renew"))
    #expect(plan.text.contains("Drift (left as it is: provision never deletes, revokes or replaces):"))
}

@Test func aProfileMissingANewCapabilityIsDrift() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.inputs.targets[0].entitlements = [:]
    _ = try await s.apply(try await s.plan())
    s.inputs.targets[0].entitlements = ["aps-environment": "production"]
    let plan = try await s.plan()
    #expect(subjects(plan) == ["capabilities: enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app", "keys: create APNs key"], "\(plan.text)")
    #expect(plan.drift.first?.message.contains("it lacks aps-environment") == true, "\(plan.text)")
}

/// `provision` and `sign` send a create again by one rule: only after reading shows nothing was made.
@Test func provisionAndSignSettleAFailedCreateTheSameWay() async throws {
    let none = #"{"data":[]}"#, made = #"{"data":{"type":"bundleIds","id":"B1","attributes":{"identifier":"com.example.app"}}}"#
    let on = #"{"data":{"type":"bundleIdCapabilities","id":"C1","attributes":{"capabilityType":"PUSH_NOTIFICATIONS"}}}"#
    let profile = #"{"data":{"type":"profiles","id":"P1","attributes":{"name":"n"}}}"#
    func requests(_ account: (ASCResources) -> any SigningAccount) async throws -> [String] {
        let t = FakeTransport([(200, none), (503, ""), (200, none), (201, made),           // the bundle ID
                               (200, none), (503, ""), (200, none), (201, on),             // a capability
                               (503, ""), (200, none), (201, profile)])                    // the profile
        let creds = try ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
        let a = account(ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })))
        _ = try await a.register(bundleID: "com.example.app")
        try await a.enable(CapabilityRequest(.pushNotifications), on: "B1", identifier: "com.example.app")
        _ = try await a.createProfile(name: "n", type: .iosAppStore, bundleResourceID: "B1", bundleID: "com.example.app", certificateID: "C1")
        #expect(t.responses.isEmpty)
        return t.requests.map { "\($0.httpMethod!) \($0.url!.path)" }
    }
    let sign = try await requests { APISigningAccount(resources: $0, stage: .sign) }
    #expect(sign == ["GET /v1/bundleIds", "POST /v1/bundleIds", "GET /v1/bundleIds", "POST /v1/bundleIds",
                     "GET /v1/bundleIds/B1/bundleIdCapabilities", "POST /v1/bundleIdCapabilities", "GET /v1/bundleIds/B1/bundleIdCapabilities", "POST /v1/bundleIdCapabilities",
                     "POST /v1/profiles", "GET /v1/profiles", "POST /v1/profiles"])
    #expect(try await requests { APIProvisionAccount(resources: $0) } == sign)
}

/// The names in a plan are the project's and Apple's: none of them clears, hides or forges a line of it.
@Test func nothingInAProvisionPlanDrivesTheTerminal() throws {
    let hostile = "\u{1B}[2J\r\n  + create\u{202E}\u{200B}"
    var plan = ProvisionPlan(team: team)
    plan.add(.bundleIDs, .create, "com.example.\(hostile)", ["named \(hostile)"], .bundleID("com.example.x"))
    plan.add(.listing, .push, "appstore/", ["~ name\n    \(hostile.replacingOccurrences(of: "\r\n", with: ""))"], .listing)
    plan.drift = [ProvisionDrift(area: .profiles, subject: hostile, message: hostile, fix: hostile)]
    plan.blockers = [ProvisionBlocker(area: .app, message: hostile, fix: hostile)]
    plan.notes = [hostile]
    #expect(TerminalText.escaped(plan.text, keepingLines: true) == plan.text)
    #expect(plan.text.split(separator: "\n").count == 13, "\(plan.text)")
    #expect(throws: XlessError(.account, #"\u{1B}[2J\u{D}\u{A}  + create\u{202E}\u{200B}; nothing was sent"#,
                               fix: #"\u{1B}[2J\u{D}\u{A}  + create\u{202E}\u{200B}"#)) { try plan.requireUnblocked() }
    let json = try ASCOutput.json(plan)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))["notes"] == .array([.string(hostile)]), "JSON keeps the values")
}

/// What `apply` says as it goes, and the error it stops with, are one line each, whatever the names in them.
@Test func nothingThatApplySaysStartsALineOfItsOwn() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    var plan = ProvisionPlan(team: team)
    plan.add(.bundleIDs, .create, "com.example.a", [], .bundleID("com.example.app.a"))
    plan.add(.appGroups, .create, "group.x\n2/2 forged\u{1B}", [], web: true, .bundleID("com.example.app.b"))
    let lines = Lines()
    let applier = ProvisionApplier(inputs: s.inputs, account: s.account, web: { throw XlessError(.account, "no\nerror: forged", fix: "a\nb") },
                                   vault: s.vault.vault, store: s.store, say: { lines.add($0) }, now: now)
    do { _ = try await applier.apply(plan); Issue.record("expected throw") }
    catch let f as ProvisionApplyFailure {
        #expect(!f.error.description.contains("\n") && f.error.cause.contains(#"group.x\u{A}2/2 forged\u{1B}: no\u{A}error: forged (0 of 2 "#), "\(f.error)")
    }
    #expect(lines.all.count == 2 && lines.all.allSatisfy { TerminalText.escaped($0) == $0 } && lines.all[1].contains(#"group.x\u{A}2/2 forged"#), "\(lines.all)")
}

@Test func blockersStopApplyBeforeAnythingIsSent() async throws {
    let v = try TestVault(create: false)
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.world.groups["APP1"] = [ProvisionGroup(id: "G1", name: "Beta", isInternal: true)]
    s.world.apps = [AppSummary(id: "APP1", name: "Example", bundleId: bundle, sku: "EX1", primaryLocale: "en-US")]
    s.inputs.testflight = TestFlightConfig(groups: [], external: ExternalTestFlight(groups: ["Beta"], submit: false))
    let plan = try await s.plan()
    #expect(plan.blockers.map(\.area) == [.certificates, .certificates, .testflight], "\(plan.text)")
    #expect(plan.blockers[0].fix.contains("xless secrets init"))
    #expect(plan.blockers[2].message == "the TestFlight group Beta exists as an internal group")
    #expect(!plan.steps.contains { $0.area == .keys } && plan.notes.contains { $0.contains("no APNs key is on this machine") })
    var caught: ProvisionApplyFailure?
    do { _ = try await s.apply(plan) } catch let f as ProvisionApplyFailure { caught = f }
    let failure = try #require(caught)
    #expect(failure.failed == nil && failure.left.count == plan.steps.count && failure.applied == ProvisionApplied())
    #expect(failure.error.cause.hasSuffix("; nothing was sent (and 2 more: see `xless provision plan`)"), "\(failure.error.cause)")
    #expect(s.world.writes.isEmpty)
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(try ProvisionApplyCommand.output(plan: plan, failure: failure, json: true).utf8)) as? [String: Any])
    #expect(doc["failed"] is NSNull && (doc["done"] as? [Any])?.isEmpty == true && (doc["left"] as? [Any])?.count == plan.steps.count)
    #expect(((doc["plan"] as? [String: Any])?["blockers"] as? [Any])?.count == 3)
}

@Test func aSuccessfulApplysJSONHasNoFailureAndNothingLeft() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    let plan = try await s.plan()
    let applied = try await s.apply(plan)
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(try ProvisionApplyCommand.output(plan: plan, applied: applied, json: true).utf8)) as? [String: Any])
    #expect(doc["failed"] is NSNull && (doc["left"] as? [Any])?.isEmpty == true && (doc["done"] as? [Any])?.count == 16)
    #expect(try ProvisionApplyCommand.output(plan: plan, applied: applied, json: false) == "applied 16 steps\n")
}

@Test func listingDriftFoundAfterANewVersionIsReported() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    // The plan could not see it: the app record (and so the version Apple fills from the last one) did not exist yet.
    s.world.heldAfterPush = ["screenshots en-US APP_IPHONE_67", "version text it-IT"]
    s.world.notesAfterPush = ["version text it-IT at App Store Connect that appstore/ does not have: kept"]
    let plan = try await s.plan()
    #expect(plan.drift.isEmpty)
    let lines = Lines()
    let applied = try await s.apply(plan, lines: lines)
    #expect(applied.drift.map(\.subject) == ["screenshots en-US APP_IPHONE_67", "version text it-IT"])
    #expect(applied.drift.allSatisfy { $0.area == .listing && $0.fix.contains("xless store push") })
    #expect(lines.all.contains("drift: version text it-IT: the manifest would delete or replace it — `xless store push` (it asks before deleting)"))
    #expect(lines.all.contains("note: version text it-IT at App Store Connect that appstore/ does not have: kept"))
    let text = try ProvisionApplyCommand.output(plan: plan, applied: applied, json: false)
    #expect(text.hasPrefix("Drift found while applying (left as it is: provision never deletes, revokes or replaces):\n  ! screenshots en-US APP_IPHONE_67:"), "\(text)")
    #expect(text.hasSuffix("applied 16 steps\n"))
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(try ProvisionApplyCommand.output(plan: plan, applied: applied, json: true).utf8)) as? [String: Any])
    #expect((doc["drift"] as? [[String: Any]])?.map { $0["subject"] as? String } == ["screenshots en-US APP_IPHONE_67", "version text it-IT"])

    // Drift the plan showed already is not reported twice.
    var known = plan
    known.drift = [ProvisionPlanner.listingDrift("version text it-IT")]
    s.world.listingPushed = false
    known.steps = known.steps.filter { $0.area == .listing }
    #expect(try await s.apply(known).drift.map(\.subject) == ["screenshots en-US APP_IPHONE_67"])
}

@Test func aStoreANewerXlessWroteBlocksAStepThatWritesItBeforeAnythingIsSent() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let key = try SigningKey.generate()
    try v.add("XLESS_DIST_KEY@\(team)", secret: key.pem, metadata: .init(teamID: team, certificateID: "REVOKED"))
    try v.makeNewer()
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true)
    s.inputs.targets.removeLast()
    s.inputs.targets[0].entitlements = [:]
    s.inputs.testflight = nil
    let plan = try await s.plan()
    #expect(plan.steps.contains { $0.area == .certificates && $0.writesStore })
    #expect(plan.blockers.map(\.area) == [.certificates], "\(plan.text)")
    #expect(plan.blockers[0].message.contains("writes the secret store, and the secret store was written by a newer xless"), "\(plan.blockers[0].message)")
    #expect(plan.blockers[0].fix.contains("upgrade xless"))
    await #expect(throws: ProvisionApplyFailure.self) { _ = try await s.apply(plan) }
    #expect(s.world.writes.isEmpty, "not even the bundle ID: nothing is sent")
}

@Test func aStoredKeysCertificateIsNotRequestedWhenTheStoreBecameUnwritable() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let key = try SigningKey.generate()
    try v.add("XLESS_DIST_KEY@\(team)", secret: key.pem, metadata: .init(teamID: team, certificateID: "REVOKED"))
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true)
    s.inputs.targets.removeLast()
    s.inputs.targets[0].entitlements = [:]
    s.inputs.testflight = nil
    let plan = try await s.plan()
    #expect(plan.blockers.isEmpty)
    // A newer xless rewrote the store between plan and apply.
    try v.makeNewer()
    var caught: ProvisionApplyFailure?
    do { _ = try await s.apply(plan) } catch let f as ProvisionApplyFailure { caught = f }
    let failure = try #require(caught)
    #expect(failure.failed?.area == .certificates && failure.error.cause.contains("written by a newer xless"), "\(failure.error.cause)")
    #expect(!s.world.writes.contains { $0.hasPrefix("createCertificate") }, "\(s.world.writes)")
}

@Test func aNewerStoreDoesNotBlockStepsThatLeaveItAlone() async throws {
    let key = try SigningKey.generate()
    let v = try TestVault(env: ["XLESS_DIST_KEY": key.pem])
    defer { v.cleanup() }
    try v.makeNewer()
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true)
    s.inputs.targets.removeLast()
    s.inputs.targets[0].entitlements = [:]
    s.inputs.testflight = nil
    let plan = try await s.plan()
    #expect(plan.blockers.isEmpty && !plan.steps.contains(where: \.writesStore), "\(plan.text)")
    #expect(plan.steps.contains { $0.area == .certificates }, "a certificate for the environment's key writes nothing to the store")
}

@Test func anAppRecordNeedsANameFromTheManifest() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    var m = manifest()
    m.locales = [:]
    let plan = try await ProvisionPlanner(inputs: s.inputs, account: s.account, web: s.web, vault: v.vault,
                                          store: ProvisionStore(manifest: m, listing: FakeListing(world: s.world)), now: now).plan()
    #expect(plan.blockers.map(\.area) == [.app])
    #expect(plan.blockers[0].fix.contains("appstore/<locale>/name.txt"))
}

// MARK: - Inputs and the CLI

@Test func xlessYmlGivesTheTargetsWithTheirEntitlements() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-provision-in-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("appstore"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try """
    bundleID: com.example.app
    teamID: \(team)
    version: 1.2.0
    build: 7
    platforms:
      ios: { minimumOS: "17.0", product: App, entitlements: App.entitlements }
      macos: { minimumOS: "14.0", product: App, distribution: app-store, bundleID: com.example.mac }
    """.write(to: dir.appendingPathComponent("xless.yml"), atomically: true, encoding: .utf8)
    try Plist.write(["keychain-access-groups": ["$(AppIdentifierPrefix)com.example.app"], "aps-environment": "production"],
                    to: dir.appendingPathComponent("App.entitlements"), format: .xml, stage: .account)
    let inputs = try ProvisionInputs.load(project: dir, config: nil, source: nil, storeDir: nil)
    #expect(inputs.team == team && inputs.version == "1.2.0")
    #expect(inputs.targets.map(\.bundleID) == ["com.example.app", "com.example.mac"])
    #expect(inputs.targets[0].entitlements["keychain-access-groups"] as? [String] == ["\(team).com.example.app"])
    #expect(inputs.certificateKinds == [.distribution, .installer])
    #expect(inputs.appStoreBundleID == "com.example.app")
    #expect(inputs.appPlatforms(for: "com.example.app") == ["IOS"])
    #expect(inputs.storeDir?.lastPathComponent == "appstore")
    #expect(throws: XlessError.self) { _ = try ProvisionInputs.load(project: dir, config: nil, source: nil, storeDir: dir.appendingPathComponent("nope").path) }
}

@Test func provisionIsAnAppleAccountCommandThatSaysItUsesTheWebSession() throws {
    let help = Xless.helpMessage()
    let group = try #require(help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive))
    #expect(help[group.upperBound...].contains("provision"))
    for command in [ProvisionCommand.self, ProvisionApplyCommand.self] as [any ParsableCommand.Type] {
        #expect(command.helpMessage(columns: 10_000).contains("Uses the Apple ID web session, not the App Store Connect API"), "\(command)")
    }
    #expect(throws: (any Error).self) { try ProvisionPlanCommand.parse(["--config", "x.yml", "--project", "p"]) }
    #expect(throws: (any Error).self) { try ProvisionPlanCommand.parse(["--source", "s"]) }
    _ = try ProvisionApplyCommand.parse(["--yes", "--json", "--company-name", "Example Ltd"])
}

@Test func privacyRemovalsAreDriftAndTheRestIsSent() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    _ = try await s.apply(try await s.plan())
    s.world.privacyExtra = true
    let plan = try await s.plan()
    #expect(plan.steps.isEmpty, "a removal alone is not sent, nor published: \(plan.text)")
    #expect(plan.drift.map(\.subject) == ["App Privacy PRECISE_LOCATION"])
    #expect(plan.drift[0].fix.contains("xless store privacy push"))
    s.world.privacySent = false
    let both = try await s.plan()
    #expect(both.steps.first { $0.area == .privacy }?.details == ["+ App Privacy EMAIL_ADDRESS", "~ publish the App Privacy answers of com.example.app"])
    _ = try await s.apply(both)
    #expect(!s.world.writes.contains { $0.contains("PRECISE_LOCATION") })
}

@Test func aBundleWhoseEntitlementsAreUnknownHasNoCapabilityDrift() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    _ = try await s.apply(try await s.plan())
    s.inputs.targets[0].entitlements = [:]
    s.inputs.targets[0].entitlementsKnown = false
    let plan = try await s.plan()
    #expect(plan.drift.isEmpty, "\(plan.text)")
}

@Test func anAPNsKeyOnThisMachineOrAtAppleIsNotMadeAgain() async throws {
    // Imported by hand (kind generic, no services): it counts.
    let v = try TestVault()
    defer { v.cleanup() }
    try v.add("XLESS_APNS_KEY@\(team)", kind: .generic, secret: "p8", metadata: .init())
    let s = Setup(vault: v)
    #expect(!(try await s.plan()).steps.contains { $0.area == .keys })

    // In the environment, with no store at all (CI): no step and no blocker for it.
    let ci = try TestVault(env: ["XLESS_APNS_KEY": "p8"], create: false)
    defer { ci.cleanup() }
    let c = Setup(vault: ci)
    let plan = try await c.plan()
    #expect(!plan.steps.contains { $0.area == .keys } && !plan.blockers.contains { $0.area == .keys })

    // The team has one at Apple that is not here: a note, never a second key.
    let other = try TestVault()
    defer { other.cleanup() }
    let o = Setup(vault: other)
    o.world.authKeys = [PortalAuthKey(id: "AK1", name: "Push", services: [.init(id: AuthKeyService.apns.id)])]
    let noted = try await o.plan()
    #expect(!noted.steps.contains { $0.area == .keys })
    #expect(noted.notes.contains { $0.contains("the team already has APNs key AK1") }, "\(noted.text)")
}

@Test func aStoredKeyWhoseRecordedCertificateIsGoneButHasAnotherIsMatched() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let key = try SigningKey.generate()
    try v.add("XLESS_DIST_KEY@\(team)", secret: key.pem, metadata: .init(teamID: team, certificateID: "OLD"))
    var s = Setup(vault: v)
    s.inputs = inputs(ios: true)
    s.inputs.targets.removeLast()
    s.world.certificates = [certificate("NEW", type: "DISTRIBUTION", der: try issue(try key.csrPEM(commonName: "x")))]
    let plan = try await s.plan()
    #expect(!plan.steps.contains { $0.area == .certificates }, "a certificate made by an earlier apply is found, not made twice")
    #expect(plan.known.certificates[.distribution] == "NEW")
}

@Test func withoutAppstoreTheAppRecordListingAndTestFlightAreLeftOut() async throws {
    let v = try TestVault()
    defer { v.cleanup() }
    let s = Setup(vault: v)
    let plan = try await ProvisionPlanner(inputs: s.inputs, account: s.account, web: s.web, vault: v.vault, store: nil, now: now).plan()
    #expect(plan.blockers.isEmpty, "\(plan.text)")
    #expect(!plan.steps.contains { [.app, .listing, .privacy, .testflight].contains($0.area) })
    #expect(plan.notes.contains { $0.contains("there is no appstore/") })
}

// MARK: - App extensions an xless.yml / Tauri / cargo app declares (#143)

@Test func declaredExtensionsArePlannedWithTheirOwnBundleIDCapabilitiesAndProfile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-provision-ext-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try """
    bundleID: com.example.app
    teamID: \(team)
    version: 1.0.0
    build: 1
    platforms:
      ios:
        minimumOS: "17.0"
        product: App
        entitlements: App.entitlements
        extensions:
          - { path: PlugIns/Widget.appex, bundleID: com.example.app.widget, entitlements: Widget.entitlements }
          - { path: PlugIns/Plain.appex, bundleID: com.example.app.plain }
    """.write(to: dir.appendingPathComponent("xless.yml"), atomically: true, encoding: .utf8)
    try Plist.write(["com.apple.security.application-groups": ["group.com.example.app"]], to: dir.appendingPathComponent("App.entitlements"), format: .xml, stage: .account)
    try Plist.write(["com.apple.security.application-groups": ["group.com.example.app"], "keychain-access-groups": ["$(AppIdentifierPrefix)com.example.app"]],
                    to: dir.appendingPathComponent("Widget.entitlements"), format: .xml, stage: .account)
    let loaded = try ProvisionInputs.load(project: dir, config: nil, source: nil, storeDir: nil)
    #expect(loaded.targets.map(\.label) == ["the iOS app", "PlugIns/Widget.appex", "PlugIns/Plain.appex"])
    #expect(loaded.targets[1].entitlements["keychain-access-groups"] as? [String] == ["\(team).com.example.app"], "signing prefixes expanded, as sign does")
    #expect(loaded.targets.allSatisfy { $0.distribution == .appStore && $0.platform == .ios })
    #expect(loaded.appStoreBundleID == "com.example.app" && loaded.appPlatforms(for: "com.example.app") == ["IOS"])

    let v = try TestVault()
    defer { v.cleanup() }
    var s = Setup(vault: v)
    s.inputs = loaded
    s.inputs.testflight = nil
    let plan = try await ProvisionPlanner(inputs: s.inputs, account: s.account, web: s.web, vault: v.vault, store: nil, now: now).plan()
    #expect(subjects(plan) == [
        "bundle-ids: create com.example.app",
        "bundle-ids: create com.example.app.widget",
        "bundle-ids: create com.example.app.plain",
        "capabilities: enable APP_GROUPS (App Groups) on com.example.app",
        "capabilities: enable APP_GROUPS (App Groups) on com.example.app.widget",
        "app-groups: create group.com.example.app",
        "certificates: create Apple Distribution",
        "profiles: create xless com.example.app IOS_APP_STORE",
        "profiles: create xless com.example.app.widget IOS_APP_STORE",
        "profiles: create xless com.example.app.plain IOS_APP_STORE",
    ], "\(plan.text)")
    #expect(plan.steps.first { $0.area == .appGroups }?.details.contains("assigned to com.example.app, com.example.app.widget") == true)
    #expect(plan.steps.first { $0.subject == "xless com.example.app.widget IOS_APP_STORE" }?.details.first?.contains("for PlugIns/Widget.appex") == true)

    _ = try await ProvisionApplier(inputs: s.inputs, account: s.account, web: { s.web }, vault: v.vault, store: nil, now: now).apply(plan)
    #expect(s.world.linked[.appGroup]?["com.example.app.widget"]?.isEmpty == false)
    let again = try await ProvisionPlanner(inputs: s.inputs, account: s.account, web: s.web, vault: v.vault, store: nil, now: now).plan()
    #expect(again.steps.isEmpty && again.drift.isEmpty, "\(again.text)")
}

// MARK: - how often a person is asked

/// A terminal somebody sits at: the store starts locked, no Apple ID session is kept. Each command is a process of its own
/// (its own store, caches and offer), and what one leaves to the next is what its agent holds. Counts what was asked.
private final class Desk: @unchecked Sendable {
    /// Types the passphrase, the Apple ID and its password, and `keep` at the offer.
    final class Typist: PassphrasePrompter, SignInPrompter, @unchecked Sendable {
        let desk: Desk
        init(_ desk: Desk) { self.desk = desk }
        func askSecret(_ prompt: String) throws -> SecretBytes {
            desk.count(prompt.contains("assphrase") ? "passphrase" : "password")
            return SecretBytes(utf8: "correct horse battery")
        }
        func ask(_ prompt: String) throws -> String {
            desk.count(prompt.hasSuffix("[y/N] ") ? "offer" : "Apple ID")
            return prompt.hasSuffix("[y/N] ") ? desk.keep : "me@example.com"
        }
        func say(_ line: String) { desk.lines.add(line) }
    }

    let vault: TestVault
    let keep: String
    let agents = FakeAgents()
    let lines = Lines()
    private let lock = NSLock()
    private var asked: [String: Int] = [:]

    init(keep: String, env: [String: String] = [:]) throws { vault = try TestVault(); self.keep = keep }
    func count(_ what: String) { lock.withLock { asked[what, default: 0] += 1 } }

    /// What `command` asked: the passphrase, Apple ID, password and offer, as often as each.
    func asked(_ command: () async throws -> Void) async rethrows -> [String: Int] {
        let before = lock.withLock { asked }
        try await command()
        return lock.withLock { asked.merging(before) { $0 - $1 }.filter { $0.value != 0 } }
    }

    /// One process of xless: what its commands share.
    struct Process {
        let desk: Desk
        let secrets: VaultSecretStore
        private let offer: KeepOffer
        private let cache: AppleSessionCache

        init(_ desk: Desk, _ command: String) {
            let held = HeldKeyCache(agents: desk.agents, keyring: FakeKeyring(available: false), isOff: false, maximum: 7 * 86400, say: { _ in })
            let offer = KeepOffer(agents: desk.agents, cache: held, settings: UnlockSettings(), isOff: false, command: command)
            let secrets = VaultSecretStore(store: desk.vault.store, cache: held, manner: offer, prompter: { Typist(desk) })
            self.desk = desk
            self.offer = offer
            self.secrets = secrets
            cache = AppleSessionCache(store: HeldSessionStore(agents: desk.agents, keyring: FakeKeyring(available: false), isOff: false, witness: { nil }, say: { _ in }))
        }

        /// The Apple ID session, as the commands open it, with an Apple that takes the typist's password.
        func web() async throws -> AppleWebSession {
            try await AppleWebCLI.session(AppleWebClient(transport: SigningIn(), stage: .account), cache: cache, offer: offer) { Typist(desk) }.session
        }

        /// The API key, as the account commands of a project read it.
        func account() throws -> AccountSession {
            try AccountSession.open(team: nil, project: team, verbose: false, env: [:], store: { secrets })
        }
    }

    func authAPIKeyCreate() async throws {
        let p = Process(self, "xless auth api-key create")
        let keys = try APIKeyWebCLI.unlocked(store: p.secrets, reason: "storing the new API key") { APIKeyStore(store: $0, catalogID: $1.id) }
        _ = try await p.web()
        let created = try await APIKeyCreation(web: NewAPIKey(), vault: keys, verify: { _ in })
            .run(nickname: "xless", roles: ["ADMIN"], appIDs: [], team: team, issuerID: "ISSUER", entry: "ASC_KEY_P8@\(team)")
        #expect(created.verified)
    }

    func provisionApply(_ world: Setup) async throws {
        let p = Process(self, "xless provision apply")
        _ = try p.account()
        var s = world
        s.vault.vault = ProvisionVault(store: p.secrets, env: [:])
        s.hasWeb = false
        let web = s.web
        _ = try await ProvisionApplier(inputs: s.inputs, account: s.account, web: { _ = try await p.web(); return web }, vault: s.vault.vault, store: s.store, now: now)
            .apply(try await s.plan())
    }

    /// Each step is a process of its own, inside one `xless session` (Tests/shell/testflight-secrets.test.sh, session.test.sh).
    func run() throws {
        let p = Process(self, "xless run")
        let resolver = VaultResolver(secrets: p.secrets).preferring(team: team)
        for name in ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID", "XLESS_DIST_KEY"] { #expect(try resolver.lookup(name, stage: .sign)?.isEmpty == false, "\(name)") }
    }

    func releaseSubmit() throws { _ = try Process(self, "xless release submit").account() }

    /// `xless store push` of a listing with a demo account and App Privacy details.
    func storePush() async throws {
        let p = Process(self, "xless store push")
        _ = try p.account()
        #expect(try VaultResolver(secrets: p.secrets).lookup("XLESS_DEMO_PASSWORD", stage: .account) == "pw")
        _ = try await p.web()
    }
}

private struct NewAPIKey: APIKeyWeb {
    func create(nickname: String, roles: [String], appIDs: [String]) async throws -> ASCAPIKeyInfo {
        ASCAPIKeyInfo(id: "2X9R4HXF34", nickname: nickname, roles: roles, isActive: true, allAppsVisible: true, canDownload: true)
    }
    func downloadPrivateKey(id: String) async throws -> SecretBytes { SecretBytes(utf8: P256.Signing.PrivateKey().pemRepresentation) }
}

/// Apple, taking "correct horse battery" without a second factor, and every session it gave.
private final class SigningIn: AppleTransport, @unchecked Sendable {
    // Apple's public value; what the client proves with it is not looked at here.
    private static let salt = Data(0..<16), B = Data(repeating: 0x42, count: 256)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var status = 200, headers: [String: String] = [:], body: [String: Any] = [:]
        switch (request.httpMethod ?? "GET", request.url!.path) {
        case ("HEAD", "/logout"): (status, headers) = (302, ["Location": "https://idmsa.apple.com/appleauth/auth/signin?widgetKey=WK123&locale=en_US"])
        case ("GET", "/appleauth/auth/signin"): headers = ["X-Apple-HC-Bits": "1", "X-Apple-HC-Challenge": "chal"]
        case ("POST", "/appleauth/auth/signin/init"):
            body = ["iteration": 1000, "salt": Self.salt.base64EncodedString(), "protocol": "s2k", "b": Self.B.base64EncodedString(), "c": "ctoken"]
        case ("POST", "/appleauth/auth/signin/complete"): headers = ["Set-Cookie": "myacinfo=NEW; Domain=.apple.com; Path=/; Secure"]
        case ("GET", "/appleauth/auth/2sv/trust"): status = 204
        case ("GET", "/olympus/v1/session"): break
        default: throw XlessError(.account, "unexpected \(request)", fix: "-")
        }
        headers["Content-Type"] = "application/json"
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        throw XlessError(.account, "unexpected download", fix: "-")
    }
}

/// The project's account is empty; its demo password is the person's own, imported before.
private func firstApp(_ desk: Desk) throws -> Setup { Setup(vault: desk.vault) }

@Test func theFirstAppFlowAsksThePassphraseOnceAndSignsInOnce() async throws {
    let desk = try Desk(keep: "y")
    defer { desk.vault.cleanup() }
    let world = try firstApp(desk)
    // From a locked store and no session, the one offer answered yes: the first command asks, the others nothing.
    #expect(try await desk.asked { try await desk.authAPIKeyCreate() } == ["passphrase": 1, "Apple ID": 1, "password": 1, "offer": 1])
    #expect(try await desk.asked { try await desk.provisionApply(world) } == [:])
    #expect(try await desk.asked { try desk.run() } == [:])
    #expect(try await desk.asked { try desk.releaseSubmit() } == [:])
    let said = desk.lines.all.joined(separator: "\n")
    for part in ["xless auth api-key create opens the secret store (storing the new API key)", "xless auth api-key create signs in to Apple", "8 h"] { #expect(said.contains(part), "\(part)") }
}

@Test func withNothingKeptEachCompositeCommandAsksThePassphraseOnceAndSignsInAtMostOnce() async throws {
    let desk = try Desk(keep: "")
    defer { desk.vault.cleanup() }
    let world = try firstApp(desk)
    let once = ["passphrase": 1, "offer": 1], signedIn = once.merging(["Apple ID": 1, "password": 1]) { a, _ in a }
    #expect(try await desk.asked { try await desk.authAPIKeyCreate() } == signedIn)
    #expect(try await desk.asked { try await desk.provisionApply(world) } == signedIn)
    #expect(try await desk.asked { try desk.run() } == once)
    #expect(try await desk.asked { try desk.releaseSubmit() } == once)
    try desk.vault.add("XLESS_DEMO_PASSWORD", kind: .password, secret: "pw", metadata: .init())
    #expect(try await desk.asked { try await desk.storePush() } == signedIn)
    #expect(desk.agents.names.isEmpty, "nothing is held that nobody asked for: \(desk.agents.names)")
}
