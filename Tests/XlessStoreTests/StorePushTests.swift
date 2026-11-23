import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessAppleID
import XlessCore
@testable import XlessStore

// `store push` against the path-routed fake App Store Connect of StorePullTests.

/// The fake app pulled into a fresh `appstore/` (the caller removes `root`).
private func pulled(_ routes: [String: (Int, String)] = fakeApp()) async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    return (root, dir)
}

private func client(_ t: HTTPTransport) -> ASCClient { ASCClient(credentials: storeCreds, transport: t, sleep: { _ in }) }

private func pusher(_ t: HTTPTransport, _ notes: Notes = Notes()) -> StorePush {
    StorePush(resources: ASCResources(client: client(t)), say: { notes.say($0) })
}

/// Secrets by name; records which were read.
private final class FakeSecrets: @unchecked Sendable {
    var values: [String: String]
    var read: [String] = []
    init(_ values: [String: String]) { self.values = values }
    func get(_ name: String) throws -> String {
        read.append(name)
        guard let v = values[name] else { throw XlessError(.account, "missing secret \(name)", fix: "store it") }
        return v
    }
}

private func sender(_ t: HTTPTransport, _ secrets: FakeSecrets = FakeSecrets([:])) -> StoreSender {
    StoreSender(client: client(t), secret: { try secrets.get($0) })
}

private func manifest(_ dir: URL) -> StoreManifest { ManifestReader.read(dir).manifest }

/// "METHOD path" of every write.
private func writes(_ t: RoutedTransport) -> [String] {
    t.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
}

private func body(_ r: URLRequest) -> [String: Any] {
    (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private func attributes(_ r: URLRequest) -> [String: Any] { ((body(r)["data"] as? [String: Any])?["attributes"] as? [String: Any]) ?? [:] }

private func request(_ t: RoutedTransport, _ key: String) -> URLRequest? {
    t.requests.first { "\($0.httpMethod!) \($0.url!.path)" == key }
}

/// The fake app with nothing pending: its accessibility answers published, no draft.
private func synced() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/accessibilityDeclarations"] = (200, list([
        #"{"type":"accessibilityDeclarations","id":"AC1","attributes":{"deviceFamily":"IPHONE","state":"PUBLISHED","supportsVoiceover":true,"supportsDarkInterface":true}}"#,
    ]))
    return routes
}

@Test func pulledManifestPushesNothing() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(synced())
    let push = pusher(t)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    #expect(plan.changes.isEmpty)
    #expect(report.planText == "com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION):\nnothing to push: App Store Connect already matches the manifest\n")
    let secrets = FakeSecrets(["XLESS_DEMO_PASSWORD": "demo-pass-1"])
    #expect(try await push.apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, sender: sender(t, secrets)).sent.isEmpty)
    #expect(writes(t).isEmpty, "a no-op push makes no write call")
    #expect(secrets.read.isEmpty, "nor reads the demo password")
}

@Test func planShowsWhatDiffersAndADryRunSendsNothing() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does more\n", "en-US/subtitle.txt", in: dir)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("en-US/whats_new.txt"))
    try write(String(repeating: "Long text. ", count: 10) + "\n", "en-US/description.txt", in: dir)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("de-DE"))
    try write("Exemple\n", "fr-FR/name.txt", in: dir)
    try write("Fait des choses.\n", "fr-FR/description.txt", in: dir)
    let t = RoutedTransport(synced())
    let notes = Notes()
    let (plan, report) = try await pusher(t, notes).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    #expect(report.planText == """
        com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION):
          ~ app info en-US: subtitle: "Does things" → "Does more"
          + app info fr-FR: name: "Exemple"
          ~ version text en-US
              description (18 → 110 characters)
              whatsNew: "Fixes." → (none)
          + version text fr-FR: description: "Fait des choses."
        4 changes: 2 to create, 2 to update

        """)
    #expect(plan.notes == [
        "app info de-DE is on App Store Connect but has no directory in appstore/: kept (--prune deletes it)",
        "version text de-DE is on App Store Connect but has no directory in appstore/: kept (--prune deletes it)",
    ])
    #expect(writes(t).isEmpty, "planning only reads")
    let json = try ASCOutput.json(report)
    #expect(json.contains("\"dryRun\" : true") && json.contains("\"subject\" : \"app info fr-FR\""))

    try await pusher(t).apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, sender: sender(t))
    #expect(writes(t) == ["PATCH /v1/appInfoLocalizations/L1", "POST /v1/appInfoLocalizations", "PATCH /v1/appStoreVersionLocalizations/VL1",
                          "POST /v1/appStoreVersionLocalizations"])
    let cleared = attributes(request(t, "PATCH /v1/appStoreVersionLocalizations/VL1")!)
    #expect(cleared["whatsNew"] is NSNull, "a removed file clears the field")
    let created = body(request(t, "POST /v1/appInfoLocalizations")!)["data"] as! [String: Any]
    #expect((created["attributes"] as! [String: String]) == ["locale": "fr-FR", "name": "Exemple"])
    #expect(((created["relationships"] as! [String: Any])["appInfo"] as! [String: Any])["data"] as! [String: String] == ["type": "appInfos", "id": "I2"])
}

@Test func pruneDeletesExtraLocalesButNeverThePrimary() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: dir.appendingPathComponent("de-DE"))
    let t = RoutedTransport(synced())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: .init(prune: true))
    #expect(plan.changes.map(\.text) == ["- app info de-DE", "- version text de-DE"])
    #expect(plan.changes.flatMap(\.requests).map { "\($0.method) \($0.path)" } == ["DELETE /v1/appInfoLocalizations/L2", "DELETE /v1/appStoreVersionLocalizations/VL2"])

    var m = manifest(dir)
    m.locales = ["de-DE": m.locales["en-US"]!]
    m.app.primaryLocale = "en-US"
    let (keep, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text], prune: true))
    #expect(!keep.changes.contains { $0.action == .delete && $0.subject.hasSuffix("en-US") })
    #expect(keep.notes.contains("app info en-US is the primary locale: never deleted"))
}

@Test func holdDeletesLeavesEveryDeletionOutOfThePlan() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: dir.appendingPathComponent("de-DE"))
    let t = RoutedTransport(synced())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: .init(prune: true, holdDeletes: true))
    #expect(plan.changes.isEmpty && plan.deletes.isEmpty)
    #expect(plan.held.map(\.text) == ["- app info de-DE", "- version text de-DE"])
}

/// The fake app with only its live version 1.0: a manifest for 1.2 creates the version.
private func liveOnly() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/appStoreVersions"] = (200, list([
        #"{"type":"appStoreVersions","id":"V1","attributes":{"platform":"IOS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","appStoreState":"READY_FOR_SALE","copyright":"2025 Example","releaseType":"MANUAL"}}"#,
    ]))
    routes["/v1/apps/123/appInfos"] = (200, list([
        #"{"type":"appInfos","id":"I1","attributes":{"state":"READY_FOR_DISTRIBUTION"},"relationships":{"primaryCategory":{"data":{"type":"appCategories","id":"UTILITIES"}},"secondaryCategory":{"data":{"type":"appCategories","id":"PRODUCTIVITY"}}}}"#,
    ]))
    routes["/v1/appInfos/I1/appInfoLocalizations"] = routes["/v1/appInfos/I2/appInfoLocalizations"]
    routes["/v1/appInfos/I1/ageRatingDeclaration"] = routes["/v1/appInfos/I2/ageRatingDeclaration"]
    return routes
}

@Test func createsTheVersionThenPlansItsTextAgain() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "1.2"
    let t = RoutedTransport(liveOnly())
    t.onRequest = { r, t in
        guard r.httpMethod == "POST", r.url!.path == "/v1/appStoreVersions" else { return }
        // App Store Connect now has the new version (no localizations yet) and new app information, copied from the live one.
        t.routes["POST /v1/appStoreVersions"] = (201, single(#"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2"}}"#))
        t.routes["/v1/apps/123/appStoreVersions"] = (200, list([
            #"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION","copyright":"2026 Example Inc.","releaseType":"SCHEDULED","earliestReleaseDate":"2026-12-01T08:00:00Z"}}"#,
        ]))
        t.routes["/v1/apps/123/appInfos"] = (200, list([
            #"{"type":"appInfos","id":"I3","attributes":{"state":"PREPARE_FOR_SUBMISSION"},"relationships":{"primaryCategory":{"data":{"type":"appCategories","id":"UTILITIES"}},"secondaryCategory":{"data":{"type":"appCategories","id":"PRODUCTIVITY"}}}}"#,
        ]))
        t.routes["/v1/appInfos/I3/appInfoLocalizations"] = t.routes["/v1/appInfos/I1/appInfoLocalizations"]
        t.routes["/v1/appInfos/I3/ageRatingDeclaration"] = t.routes["/v1/appInfos/I1/ageRatingDeclaration"]
        t.routes["/v1/appStoreVersions/V3/appStoreVersionLocalizations"] = (200, list([]))
    }
    let push = pusher(t)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text, .review]))
    #expect(report.versionState == "new")
    #expect(plan.changes.first?.text == """
        + version 1.2 (IOS)
            versionString: "1.2"
            copyright: "2026 Example Inc."
            releaseType: "SCHEDULED"
            earliestReleaseDate: "2026-12-01T08:00:00Z"
        """)
    #expect(plan.changes.contains { $0.subject == "App Review details" && $0.action == .create && $0.fields.contains { $0.secret == "XLESS_DEMO_PASSWORD" } })
    let applied = try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text, .review]),
                                       sender: sender(t, FakeSecrets(["XLESS_DEMO_PASSWORD": "demo-pass-1"])))
    #expect(writes(t) == ["POST /v1/appStoreVersions", "POST /v1/appStoreVersionPhasedReleases", "POST /v1/appStoreVersionLocalizations",
                          "POST /v1/appStoreVersionLocalizations", "POST /v1/appStoreReviewDetails"])
    #expect(applied.sent.count == 5)
    #expect(t.requests.filter { $0.url!.path == "/v1/appStoreVersions" }.count == 1, "the create is sent once")
    let localization = body(t.requests.first { $0.httpMethod == "POST" && $0.url!.path == "/v1/appStoreVersionLocalizations" }!)
    #expect("\(localization)".contains("V3"), "planned again: the localization belongs to the new version")
    #expect(attributes(request(t, "POST /v1/appStoreVersions")!)["versionString"] as? String == "1.2")
}

@Test func aLiveVersionTakesOnlyPromotionalText() async throws {
    var routes = fakeApp()
    routes["/v1/appStoreVersions/V1/appStoreVersionLocalizations"] = (200, list([
        #"{"type":"appStoreVersionLocalizations","id":"VL9","attributes":{"locale":"en-US","description":"Old.","promotionalText":"Old promo"}}"#,
    ]))
    // The live version's manifest is compared with the live app information.
    routes["/v1/appInfos/I1/appInfoLocalizations"] = routes["/v1/appInfos/I2/appInfoLocalizations"]
    var app = AppYAML()
    app.platform = "IOS"; app.version = "1.0"; app.primaryLocale = "en-US"
    let listing = LocaleListing(name: "Example", subtitle: "Does things", privacyURL: "https://example.com/privacy", description: "Old.", promotionalText: "New promo")
    let dir = URL(fileURLWithPath: "/nonexistent/appstore")
    let t = RoutedTransport(routes)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: StoreManifest(app: app, locales: ["en-US": listing]), dir: dir, options: .init(parts: [.text]))
    #expect(plan.changes.map(\.text) == [#"~ version text en-US: promotionalText: "Old promo" → "New promo""#])

    var changed = listing
    changed.description = "New."
    await #expect {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: StoreManifest(app: app, locales: ["en-US": changed]), dir: dir, options: .init(parts: [.text]))
    } throws: { "\($0)".contains("version 1.0 is READY_FOR_DISTRIBUTION and cannot be edited") && "\($0)".contains("description") }
}

@Test func aNewLocaleNeedsAName() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Fait des choses.\n", "fr-FR/description.txt", in: dir)
    let t = RoutedTransport(fakeApp())
    await #expect {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    } throws: { "\($0)".contains("appstore/fr-FR/name.txt is missing") }
}

@Test func categoriesAreCheckedAgainstAppStoreConnect() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = fakeApp()
    routes["/v1/appCategories"] = (200, list([
        #"{"type":"appCategories","id":"GAMES","relationships":{"subcategories":{"data":[{"type":"appCategories","id":"GAMES_ACTION"}]}}}"#,
        #"{"type":"appCategories","id":"UTILITIES","relationships":{"subcategories":{"data":[]}}}"#,
    ]))
    let t = RoutedTransport(routes)
    var m = manifest(dir)
    m.app.categories = AppYAML.Categories(primary: "GAMES", primarySubcategories: ["UTILITIES"])
    await #expect {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text]))
    } throws: { "\($0)".contains("UTILITIES is not a subcategory of GAMES") }
    #expect(t.queries("/v1/appCategories").first?.contains("filter[platforms]=IOS") == true)

    m.app.categories = AppYAML.Categories(primary: "GAMES", primarySubcategories: ["GAMES_ACTION"])
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text]))
    #expect(plan.changes.map(\.subject) == ["categories"])
    #expect(plan.changes[0].fields.map(\.text) == [#"primaryCategory: "UTILITIES" → "GAMES""#, #"primarySubcategoryOne: "GAMES_ACTION""#,
                                                     #"secondaryCategory: "PRODUCTIVITY" → (none)"#])
    #expect(plan.changes[0].requests == [.update("appInfos", id: "I2", relationships: [
        "primaryCategory": StoreRequest.link("appCategories", "GAMES"), "primarySubcategoryOne": StoreRequest.link("appCategories", "GAMES_ACTION"),
        "secondaryCategory": StoreRequest.link("appCategories", nil),
    ])])
}

@Test func declarationsSendOnlyWhatChanged() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.ageRating?["gambling"] = .bool(true)
    m.app.contentRights = "USES_THIRD_PARTY_CONTENT"
    m.app.encryption = ["appDescription": .string("Uses HTTPS only."), "availableOnFrenchStore": .bool(true),
                        "containsProprietaryCryptography": .bool(false), "containsThirdPartyCryptography": .bool(true), "exempt": .bool(true)]
    m.app.accessibility?["IPAD"] = ["supportsVoiceover": true]
    m.app.accessibility?["IPHONE"]?["supportsLargerText"] = true
    m.app.eula = .standard
    let t = RoutedTransport(fakeApp())
    let push = pusher(t)
    let notes = Notes()
    let (plan, _) = try await pusher(t, notes).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.declarations]))
    #expect(plan.changes.map(\.text) == [
        #"~ content rights: contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" → "USES_THIRD_PARTY_CONTENT""#,
        #"~ age rating: gambling: "false" → "true""#,
        #"- licence agreement: agreement: "custom" → "standard""#,
        """
        + export compliance
            appDescription: "Uses HTTPS only."
            availableOnFrenchStore: "true"
            containsThirdPartyCryptography: "true"
        """,
        #"+ accessibility IPAD: supportsVoiceover: "true""#,
        #"~ accessibility IPHONE: supportsLargerText: "true""#,
    ])
    #expect(plan.notes.contains { $0.contains("compliance document") })
    #expect(plan.deletes.map(\.subject) == ["licence agreement"])
    try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.declarations]), sender: sender(t))
    #expect(writes(t).map { $0.hasPrefix("PATCH /v1/accessibilityDeclarations/NEW") ? "PATCH /v1/accessibilityDeclarations/<created>" : $0 } == [
        "PATCH /v1/apps/123", "PATCH /v1/ageRatingDeclarations/A1", "DELETE /v1/endUserLicenseAgreements/EU1",
        "POST /v1/appEncryptionDeclarations", "POST /v1/accessibilityDeclarations", "PATCH /v1/accessibilityDeclarations/<created>",
        "PATCH /v1/accessibilityDeclarations/AC2"])
    #expect(attributes(request(t, "PATCH /v1/ageRatingDeclarations/A1")!) as? [String: Bool] == ["gambling": true], "only the changed answer")
    #expect(Set(attributes(request(t, "POST /v1/appEncryptionDeclarations")!).keys) == Set(PushContext.encryptionAnswers))
    let publish = t.requests.first { $0.httpMethod == "PATCH" && $0.url!.path.hasPrefix("/v1/accessibilityDeclarations/NEW") }!
    #expect(attributes(publish) as? [String: Bool] == ["publish": true])
    #expect((body(publish)["data"] as! [String: Any])["id"] as? String == publish.url!.lastPathComponent)
    #expect(attributes(request(t, "PATCH /v1/accessibilityDeclarations/AC2")!) as? [String: Bool] == ["supportsLargerText": true, "publish": true])
}

@Test func aCustomLicenceIsCreatedForEveryTerritory() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = synced()
    routes["/v1/apps/123/endUserLicenseAgreement"] = (200, single(nil))
    let t = RoutedTransport(routes)
    var m = manifest(dir)
    m.app.eula = .custom(file: "eula.txt", territories: .all)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.declarations]))
    #expect(plan.changes.map(\.text) == ["+ licence agreement\n    agreementText: \"Terms.\"\n    territories: \"CAN, GBR, USA\""])
}

@Test func partsAreChosenWithOnly() async throws {
    #expect(try StorePushPart.parse(["review,text"]) == [.text, .review])
    #expect(try StorePushPart.parse(["declarations", " TEXT "]) == [.text, .declarations])
    #expect(try StorePushPart.parse(["media,text"]) == [.text, .media])
    #expect(throws: XlessError.self) { try StorePushPart.parse(["screenshots"]) }
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does more\n", "en-US/subtitle.txt", in: dir)
    var m = manifest(dir)
    m.app.review?.notes = "New notes"
    let t = RoutedTransport(fakeApp())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.review]))
    #expect(plan.changes.map(\.subject) == ["App Review details"])
    #expect(!t.requests.contains { $0.url!.path.contains("appInfoLocalizations") }, "a part not chosen is not even read")
}

// MARK: - The demo account's password

@Test func theDemoPasswordIsSentOnlyWhenTheDemoAccountChanges() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.review?.notes = "New notes"
    let t = RoutedTransport(fakeApp())
    let secrets = FakeSecrets(["XLESS_DEMO_PASSWORD": "demo-pass-1"])
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.review]))
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, sender: sender(t, secrets))
    #expect(attributes(request(t, "PATCH /v1/appStoreReviewDetails/R1")!) as? [String: String] == ["notes": "New notes"])
    #expect(secrets.read.isEmpty)

    let again = RoutedTransport(fakeApp())
    let options = StorePush.Options(parts: [.review], resendDemoAccount: true)
    let (resend, _) = try await pusher(again).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: options)
    #expect(resend.changes.map(\.text) == ["~ App Review details: demoAccountPassword (from XLESS_DEMO_PASSWORD)"])
    try await pusher(again).apply(resend, app: fakeASCApp, manifest: manifest(dir), dir: dir, options: options, sender: sender(again, secrets))
    #expect(attributes(request(again, "PATCH /v1/appStoreReviewDetails/R1")!) as? [String: String] == ["demoAccountName": "demo@example.com", "demoAccountPassword": "demo-pass-1"])
    #expect(secrets.read == ["XLESS_DEMO_PASSWORD"], "read once")
}

@Test func theDemoPasswordNeverLeaks() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let password = "s3cr3t-Pa55"
    var m = manifest(dir)
    m.app.review?.demoAccount?.name = "demo2@example.com"
    var routes = fakeApp()
    // Apple's answer repeats what it was sent (a server error, which a password-bearing request does not retry).
    routes["PATCH /v1/appStoreReviewDetails/R1"] = (500, #"{"errors":[{"status":"500","code":"UNEXPECTED","title":"failed","detail":"could not sign in demo2@example.com with \#(password)"}]}"#)
    let t = RoutedTransport(routes)
    let trace = Notes()
    let traced = TracingTransport(t, trace: HTTPTrace { trace.say($0) })
    let notes = Notes()
    let push = pusher(traced, notes)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir)
    var shown = report.planText + (try ASCOutput.json(report))
    var failure = ""
    do {
        try await withStage(.account) {
            _ = try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, sender: sender(traced, FakeSecrets(["XLESS_DEMO_PASSWORD": password])))
        }
        Issue.record("Apple's 500 should fail the push")
    } catch { failure = "\(error)" }
    shown += failure + notes.lines.joined() + trace.lines.joined()
    #expect(failure.contains("could not sign in demo2@example.com with \(HTTPTrace.placeholder)"))
    #expect(!shown.contains(password))
    #expect(t.requests.filter { $0.url!.path == "/v1/appStoreReviewDetails/R1" }.count == 1, "sent once")
    #expect(t.requests.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains(password) }.count == 1)
    #expect(trace.lines.contains { $0.contains("\"demoAccountPassword\":\"\(HTTPTrace.placeholder)\"") })
}

@Test func aMissingDemoPasswordSendsNothing() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does more\n", "en-US/subtitle.txt", in: dir)
    var m = manifest(dir)
    m.app.review?.demoAccount?.name = "demo2@example.com"
    let t = RoutedTransport(synced())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir)
    #expect(plan.changes.count == 2)
    await #expect(throws: XlessError.self) {
        _ = try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, sender: sender(t))
    }
    #expect(writes(t).isEmpty, "the secret is read before the first write")
}

@Test func whatIsPlannedAgainstANewVersionIsShownAndItsDeletionsAsked() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "1.2"
    let t = RoutedTransport(liveOnly())
    t.onRequest = { r, t in
        guard r.httpMethod == "POST", r.url!.path == "/v1/appStoreVersions" else { return }
        // Apple copies the live version's localizations, it-IT included, onto the new version.
        t.routes["POST /v1/appStoreVersions"] = (201, single(#"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2"}}"#))
        t.routes["/v1/apps/123/appStoreVersions"] = (200, list([
            #"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION","copyright":"2026 Example Inc.","releaseType":"SCHEDULED","earliestReleaseDate":"2026-12-01T08:00:00Z"}}"#,
        ]))
        t.routes["/v1/appStoreVersions/V3/appStoreVersionLocalizations"] = (200, list([
            #"{"type":"appStoreVersionLocalizations","id":"VL7","attributes":{"locale":"it-IT","description":"Fa cose."}}"#,
        ]))
    }
    let options = StorePush.Options(parts: [.text], prune: true)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: options)
    #expect(plan.deletes.isEmpty && plan.notes.isEmpty, "the new version's locales are not known yet")
    var shown: [StorePlan] = []
    let result = try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: options, sender: sender(t),
                                          show: { shown.append($0) }, confirm: { $0.deletes.isEmpty })
    #expect(shown.count == 1 && shown[0].deletes.map(\.subject) == ["version text it-IT"])
    #expect(writes(t) == ["POST /v1/appStoreVersions"], "a no to the deletions sends nothing more")
    #expect(result.sent.map(\.subject) == ["version 1.2 (IOS)"] && result.replanned != nil)
}

@Test func reviewKeysThatAreAbsentAreKeptAndAnEmptyOneClears() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.review?.contact = nil
    m.app.review?.notes = ""
    m.app.review?.demoAccount?.name = nil
    let t = RoutedTransport(fakeApp())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.review]))
    #expect(plan.changes.map(\.text) == ["~ App Review details: notes (17 → 0 characters)"])
    #expect(plan.changes[0].requests[0].body?["data"]?["attributes"] == .object(["notes": .null]))
}

@Test func theDemoPasswordSecretCannotBeAnotherKey() async throws {
    for name in ["ASC_KEY_P8", "ASC_KEY_P8@ABCDE12345", "XLESS_DIST_KEY", "GITHUB_TOKEN", "MY_API_KEY_FILE", "XLESS_APNS_KEY@TEAM"] {
        #expect(ManifestValidator.isReservedSecret(name), "\(name)")
    }
    for name in ["XLESS_DEMO_PASSWORD", "APP_REVIEW_PASSWORD", "DEMO_LOGIN@ABCDE12345"] { #expect(!ManifestValidator.isReservedSecret(name), "\(name)") }
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.review?.demoAccount?.passwordSecret = "ASC_KEY_P8"
    #expect(ManifestValidator.validate(m, at: dir, draft: true).contains { $0.message.contains("names a key or token") })
    await #expect {
        _ = try await pusher(RoutedTransport(fakeApp())).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.review], resendDemoAccount: true))
    } throws: { "\($0)".contains("names a key or token") }
}

@Test func aPendingAccessibilityDraftIsPublished() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(fakeApp())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: .init(parts: [.declarations]))
    #expect(plan.changes.map(\.text) == [#"~ accessibility IPHONE: publish: "draft" → "published""#])
    #expect(plan.changes[0].requests == [.update("accessibilityDeclarations", id: "AC2", attributes: ["publish": .bool(true)])])
}

@Test func phasedReleaseIsAddedOrRemovedWhileItHasNotStarted() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.release?.phased = false
    let (off, _) = try await pusher(RoutedTransport(synced())).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text]))
    #expect(off.changes.map(\.text) == [#"- phased release: phased: "true" → "false""#])
    #expect(off.changes[0].requests == [.delete("appStoreVersionPhasedReleases", id: "P1")])

    var started = synced()
    started["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, single(#"{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"ACTIVE"}}"#))
    let (kept, _) = try await pusher(RoutedTransport(started)).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.text]))
    #expect(kept.changes.isEmpty && kept.notes.contains { $0.contains("has started (ACTIVE)") })

    var none = synced()
    none["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, single(nil))
    let (on, _) = try await pusher(RoutedTransport(none)).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: .init(parts: [.text]))
    #expect(on.changes.map(\.subject) == ["phased release"] && on.changes[0].action == .create)
}

@Test func aCustomLicenceIsUpdatedInPlace() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("New terms.\n", "eula.txt", in: dir)
    var m = manifest(dir)
    m.app.eula = .custom(file: "eula.txt", territories: .only(["USA", "GBR"]))
    let (plan, _) = try await pusher(RoutedTransport(fakeApp())).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.declarations]))
    let eula = plan.changes.first { $0.subject == "licence agreement" }!
    #expect(eula.text == "~ licence agreement\n    agreementText: \"Terms.\" → \"New terms.\"\n    territories: \"CAN, USA\" → \"GBR, USA\"")
    #expect(eula.requests == [.update("endUserLicenseAgreements", id: "EU1", attributes: ["agreementText": .string("New terms.")],
                                      relationships: ["territories": StoreRequest.links("territories", ["GBR", "USA"])])])
}

@Test func theVersionBeingPreparedTakesTheManifestsVersionString() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "1.2"
    let (plan, report) = try await pusher(RoutedTransport(synced())).plan(app: fakeASCApp, manifest: m, dir: dir)
    #expect(report.versionState == "PREPARE_FOR_SUBMISSION")
    #expect(plan.changes.map(\.text) == [#"~ version 1.2 (IOS): versionString: "1.1" → "1.2""#])
    #expect(plan.changes[0].requests == [.update("appStoreVersions", id: "V2", attributes: ["versionString": .string("1.2")])])
}

@Test func aDeleteThatAlreadyWentThroughIsDone() async throws {
    var routes = fakeApp()
    routes["DELETE /v1/endUserLicenseAgreements/EU1"] = (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"gone"}]}"#)
    let t = RoutedTransport(routes)
    try await sender(t).apply(StoreChange(.delete, .declarations, "licence agreement", requests: [.delete("endUserLicenseAgreements", id: "EU1")]))
    #expect(writes(t) == ["DELETE /v1/endUserLicenseAgreements/EU1"])
}

// MARK: - App Privacy

@Test func privacyIsAPartOfPushSentThroughTheWebSessionAndPublished() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.privacy = emailLinked
    let t = RoutedTransport(synced())
    let fake = FakePrivacy([usage("u0", nil, nil, PrivacyProtection.notCollected)])
    let push = StorePush(resources: ASCResources(client: client(t)), privacy: fake)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir)
    #expect(plan.changes.map(\.text) == [
        "- App Privacy: data not collected",
        "+ App Privacy EMAIL_ADDRESS\n    purposes: \"APP_FUNCTIONALITY\"\n    linkedToYou: \"true\"\n    tracking: \"false\"",
        "~ publish the App Privacy answers of com.example.app",
    ])
    #expect(report.changes.allSatisfy { $0.part == .privacy })
    #expect(plan.deletes.isEmpty)
    let applied = try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, sender: sender(t))
    #expect(applied.sent.count == 3)
    #expect(writes(t) == [], "nothing went through the API key")
    #expect(fake.sent == ["DELETE u0", "POST 123 EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "PATCH PS-123"])
    #expect(try await push.plan(app: fakeASCApp, manifest: m, dir: dir).0.changes.isEmpty)
}

@Test func withoutTheWebSessionPrivacyIsOnlyNoted() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.privacy = emailLinked
    let (plan, _) = try await pusher(RoutedTransport(synced())).plan(app: fakeASCApp, manifest: m, dir: dir)
    #expect(plan.changes.isEmpty)
    #expect(plan.notes == ["privacy is not pushed: App Privacy needs the Apple ID web session (`xless store privacy push`, or keep a session first with `xless auth login --keep 30m`)"])
    m.app.privacy = nil
    #expect(try await pusher(RoutedTransport(synced())).plan(app: fakeASCApp, manifest: m, dir: dir).0.notes.isEmpty, "no privacy key: not managed, nothing said")
}

@Test func privacyNeedsNoVersion() async throws {
    let (root, dir) = try await pulled(synced())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "9.0"
    m.app.privacy = AppYAML.Privacy(collectsData: false)
    let fake = FakePrivacy([usage("u0", nil, nil, PrivacyProtection.notCollected)])
    let push = StorePush(resources: ASCResources(client: client(RoutedTransport(liveOnly()))), privacy: fake)
    let (plan, _) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.privacy]))
    #expect(plan.changes.isEmpty)
}

/// The live 1.0 only; creating 1.2 makes Apple copy 1.0's it-IT text onto it (pulled appstore/ has no it-IT).
private func liveOnlyCopyingItalian(_ t: RoutedTransport) {
    t.onRequest = { r, t in
        guard r.httpMethod == "POST", r.url!.path == "/v1/appStoreVersions" else { return }
        t.routes["POST /v1/appStoreVersions"] = (201, single(#"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2"}}"#))
        t.routes["/v1/apps/123/appStoreVersions"] = (200, list([
            #"{"type":"appStoreVersions","id":"V3","attributes":{"platform":"IOS","versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION","copyright":"2026 Example Inc.","releaseType":"SCHEDULED","earliestReleaseDate":"2026-12-01T08:00:00Z"}}"#,
        ]))
        t.routes["/v1/appStoreVersions/V3/appStoreVersionLocalizations"] = (200, list([
            #"{"type":"appStoreVersionLocalizations","id":"VL7","attributes":{"locale":"it-IT","description":"Fa cose."}}"#,
        ]))
    }
}

@Test func holdingDeletesAfterANewVersionLeavesThemInTheReplannedPlan() async throws {
    // The mechanism `xless provision` reports drift with (#143): what the plan made once the new version exists would
    // delete is held back in `replanned.held`, and the rest is sent.
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "1.2"
    let t = RoutedTransport(liveOnly())
    liveOnlyCopyingItalian(t)
    let options = StorePush.Options(parts: [.text], prune: true, holdDeletes: true)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: options)
    #expect(plan.held.isEmpty, "the new version's locales are not known yet")
    let result = try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: options, sender: sender(t))
    #expect(result.replanned?.held.map(\.subject) == ["version text it-IT"])
    #expect(!writes(t).contains { $0.hasPrefix("DELETE") }, "\(writes(t))")
    #expect(writes(t).contains("POST /v1/appStoreVersionLocalizations"), "the rest is sent: \(writes(t))")
}

@Test func provisionKeepsALocalizationAppleCopiedOntoANewVersionWithANote() async throws {
    // Provision's own options never prune: the copied it-IT text is kept, said in the plan made after the version.
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var m = manifest(dir)
    m.app.version = "1.2"
    let t = RoutedTransport(liveOnly())
    liveOnlyCopyingItalian(t)
    var options = StorePush.Options.provision(today: today)
    options.parts = [.text]
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: options)
    let result = try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: options, sender: sender(t))
    let replanned = try #require(result.replanned)
    #expect(replanned.held.isEmpty && !writes(t).contains { $0.hasPrefix("DELETE") })
    #expect(replanned.notes.contains { $0.contains("it-IT") }, "\(replanned.notes)")
}
