import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
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

@Test func pulledManifestPushesNothing() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(fakeApp())
    let push = pusher(t)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    #expect(plan.changes.isEmpty)
    #expect(report.planText == "com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION):\nnothing to push: App Store Connect already matches the manifest\n")
    let secrets = FakeSecrets(["XLESS_DEMO_PASSWORD": "demo-pass-1"])
    #expect(try await push.apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, sender: sender(t, secrets)) == 0)
    #expect(writes(t).isEmpty, "a no-op push makes no write call")
    #expect(secrets.read.isEmpty, "nor reads the demo password")
}

@Test func planShowsWhatDiffersAndADryRunSendsNothing() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does more\n", "en-US/subtitle.txt", in: dir)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("en-US/whats_new.txt"))
    try write(String(repeating: "Long text. ", count: 10) + "\n", "en-US/description.txt", in: dir)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("de-DE"))
    try write("Exemple\n", "fr-FR/name.txt", in: dir)
    try write("Fait des choses.\n", "fr-FR/description.txt", in: dir)
    let t = RoutedTransport(fakeApp())
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
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: dir.appendingPathComponent("de-DE"))
    let t = RoutedTransport(fakeApp())
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
    #expect(applied == 5)
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
    var routes = fakeApp()
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
    #expect(throws: XlessError.self) { try StorePushPart.parse(["media"]) }
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
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does more\n", "en-US/subtitle.txt", in: dir)
    var m = manifest(dir)
    m.app.review?.demoAccount?.name = "demo2@example.com"
    let t = RoutedTransport(fakeApp())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir)
    #expect(plan.changes.count == 2)
    await #expect(throws: XlessError.self) {
        _ = try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, sender: sender(t))
    }
    #expect(writes(t).isEmpty, "the secret is read before the first write")
}
