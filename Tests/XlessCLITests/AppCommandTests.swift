import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessAppleID
import XlessASC
import XlessCore
@testable import xless

private func app(_ id: String, _ bundle: String, name: String = "Example", sku: String = "EX1", locale: String = "en-US", rights: String? = nil) -> String {
    #"{"type":"apps","id":"\#(id)","attributes":{"name":"\#(name)","bundleId":"\#(bundle)","sku":"\#(sku)","primaryLocale":"\#(locale)"\#(rights.map { #","contentRightsDeclaration":"\#($0)""# } ?? "")}}"#
}
private func listing(_ items: [String]) -> String { #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"}}"# }

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false) -> AppCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return AppCLI(apps: ASCApps(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))), json: json, say: { _ in })
}

private let request = AppCreateRequest(name: "Example", bundleID: "com.example.app", sku: "EX1", primaryLocale: "en-US", platforms: ["IOS"])
private let made = AppSummary(id: "1234567890", name: "Example", bundleId: "com.example.app", sku: "EX1", primaryLocale: "en-US")

/// The documented API's side, scripted.
private final class FakeAPI: AppCreationAPI, @unchecked Sendable {
    var app: AppSummary?
    var hasBundle = true
    var calls: [String] = []
    init(app: AppSummary? = nil, hasBundle: Bool = true) { self.app = app; self.hasBundle = hasBundle }
    func findApp(bundleID: String) async throws -> AppSummary? { calls.append("find \(bundleID)"); return app }
    func hasBundleID(_ identifier: String) async throws -> Bool { calls.append("has \(identifier)"); return hasBundle }
    func registerBundleID(_ identifier: String) async throws { calls.append("register \(identifier)"); hasBundle = true }
}

/// The web session's side, scripted: `found` answers each lookup in turn (the last one repeats).
private final class FakeWeb: AppCreationWeb, @unchecked Sendable {
    var found: [Result<AppSummary?, XlessError>]
    var answer: AppCreateAnswer
    var bundleError: XlessError?
    var calls: [String] = []
    init(found: [Result<AppSummary?, XlessError>] = [.success(nil)], answer: AppCreateAnswer = .created(WebApp(id: "1234567890", name: "Example", bundleID: "com.example.app", sku: "EX1", primaryLocale: "en-US")),
         bundleError: XlessError? = nil) {
        self.found = found; self.answer = answer; self.bundleError = bundleError
    }
    func findApp(bundleID: String) async throws -> AppSummary? {
        calls.append("find \(bundleID)")
        let next = found.count > 1 ? found.removeFirst() : found[0]
        return try next.get()
    }
    func requireBundleID(_ identifier: String) async throws {
        calls.append("bundle \(identifier)")
        if let bundleError { throw bundleError }
    }
    func create(_ request: AppCreateRequest) async -> AppCreateAnswer { calls.append("create \(request.bundleID)"); return answer }
}

private func creation(api: FakeAPI?, web: FakeWeb, answer: Bool = true, said: Said = Said(), asked: Said = Said()) -> AppCreation {
    AppCreation(api: api, web: { web }, confirm: { q, _ in asked.lines.append(q); return answer }, say: { said.lines.append($0) })
}

// MARK: - Arguments

@Test func appsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = try! #require(help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive))
    #expect(help[group.upperBound...].contains("apps"), "\(help)")
}

@Test func appArgumentsAreCheckedBeforeAnythingIsSent() throws {
    func refused(_ type: any ParsableCommand.Type, _ args: [String]) -> String {
        do { _ = try type.parseAsRoot(args); return "" } catch { return type.message(for: error) }
    }
    let base = ["--bundle-id", "com.example.app", "--name", "Example", "--sku", "EX1", "--locale", "en-us"]
    let ok = try AppsCreateCommand.parse(base + ["--platform", "ios,macos", "--platform", "mac", "--company-name", "Example Ltd"]).request()
    #expect(ok == AppCreateRequest(name: "Example", bundleID: "com.example.app", sku: "EX1", primaryLocale: "en-US", platforms: ["IOS", "MAC_OS"],
                                   versionString: "1.0", companyName: "Example Ltd"))
    #expect(try AppsCreateCommand.parse(base).request().platforms == ["IOS"])
    #expect(refused(AppsCreateCommand.self, ["--bundle-id", "com.example.*", "--name", "Example", "--sku", "EX1", "--locale", "en-US"]).contains("wildcard"))
    #expect(refused(AppsCreateCommand.self, base.dropLast(2) + ["--locale", "english"]).contains("english is not a locale"))
    #expect(refused(AppsCreateCommand.self, ["--bundle-id", "com.example.app", "--name", "E", "--sku", "EX1", "--locale", "en-US"]).contains("2 to 30"))
    #expect(refused(AppsCreateCommand.self, ["--bundle-id", "com.example.app", "--name", "Example", "--sku", "_EX", "--locale", "en-US"]).contains("not starting with"))
    #expect(refused(AppsCreateCommand.self, base + ["--platform", "tvos"]).contains("--platform tvos: use ios or macos"))
    #expect(refused(AppsCreateCommand.self, base + ["--app-version", "1.0.0.1"]).contains("is not a version"))
    #expect(refused(AppsShowCommand.self, ["12a4"]).contains("neither an app ID"))
    #expect(refused(AppsUpdateCommand.self, ["com.example.app"]).contains("nothing to update"))
    #expect(refused(AppsUpdateCommand.self, ["com.example.app", "--content-rights", "maybe"]).contains("--content-rights maybe"))
    let update = try AppsUpdateCommand.parse(["123", "--primary-locale", "DE-de", "--content-rights", "none", "--bundle-id", "com.example.other"]).parsed()
    #expect(update.locale == "de-DE" && update.rights == .doesNotUseThirdPartyContent && update.bundleID == "com.example.other")
}

// MARK: - list, show, update

@Test func appsListPrintsATableOrAppleShape() async throws {
    let t = FakeTransport([(200, listing([app("2", "com.example.zeta", name: "Zeta"), app("1", "com.example.alpha", name: "Alpha", locale: "de-DE")]))])
    #expect(try await cli(t).list() == """
    ID  NAME   BUNDLE ID          SKU  PRIMARY LOCALE
    1   Alpha  com.example.alpha  EX1  de-DE
    2   Zeta   com.example.zeta   EX1  en-US

    """)
    let j = FakeTransport([(200, listing([app("1", "com.example.alpha")]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(j, json: true).list().utf8))
    #expect(doc["data"]?[0]?["attributes"]?["bundleId"] == .string("com.example.alpha"))
    let empty = try await cli(FakeTransport([(200, listing([]))])).list()
    #expect(empty.contains("xless apps create"))
}

@Test func showPrintsTheRecordItsInfosAndVersions() async throws {
    func script() -> FakeTransport {
        FakeTransport([(200, listing([app("9", "com.example.app", rights: "DOES_NOT_USE_THIRD_PARTY_CONTENT")])),
                       (200, listing([#"{"type":"appInfos","id":"I1","attributes":{"state":"PREPARE_FOR_SUBMISSION","appStoreAgeRating":"FOUR_PLUS"}}"#])),
                       (200, listing([#"{"type":"appStoreVersions","id":"V1","attributes":{"platform":"IOS","versionString":"1.0","appVersionState":"PREPARE_FOR_SUBMISSION","createdDate":"2026-11-23"}}"#]))])
    }
    let out = try await cli(script()).show("com.example.app")
    #expect(out.contains("CONTENT RIGHTS  does-not-use-third-party-content"), "\(out)")
    #expect(out.contains("I1        PREPARE_FOR_SUBMISSION  FOUR_PLUS"), "\(out)")
    #expect(out.contains("V1          ios       1.0      PREPARE_FOR_SUBMISSION  2026-11-23"), "\(out)")
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(script(), json: true).show("com.example.app").utf8))
    #expect(doc["data"]?["id"] == .string("9") && doc["appInfos"]?[0]?["id"] == .string("I1") && doc["appStoreVersions"]?[0]?["id"] == .string("V1"))
}

@Test func updateSaysWhatChangedOrThatNothingWasSent() async throws {
    let t = FakeTransport([(200, #"{"data":\#(app("9", "com.example.app"))}"#),
                           (200, #"{"data":\#(app("9", "com.example.app", locale: "de-DE", rights: "USES_THIRD_PARTY_CONTENT"))}"#)])
    let out = try await cli(t).update("9", primaryLocale: "de-DE", contentRights: .usesThirdPartyContent, bundleID: nil)
    #expect(out == "updated Example (9): primary locale en-US → de-DE, content rights none → uses-third-party-content\n")
    #expect(t.requests.map { $0.httpMethod ?? "" } == ["GET", "PATCH"])
    let same = FakeTransport([(200, #"{"data":\#(app("9", "com.example.app"))}"#)])
    #expect(try await cli(same).update("9", primaryLocale: "en-US", contentRights: nil, bundleID: "com.example.app") == "Example (9) already has these values; nothing was sent\n")
    #expect(same.requests.count == 1)
}

// MARK: - create

@Test func anExistingAppIsReportedAndNothingIsSent() async throws {
    let api = FakeAPI(app: AppSummary(id: "77", name: "Other", bundleId: "com.example.app", sku: "OLD", primaryLocale: "en-US"))
    let web = FakeWeb()
    let said = Said()
    var signedIn = false
    let c = AppCreation(api: api, web: { signedIn = true; return web }, confirm: { _, _ in Issue.record("asked"); return false }, say: { said.lines.append($0) })
    let result = try #require(try await c.run(request))
    #expect(result.existing.map(\.id) == ["77"] && result.created.isEmpty)
    #expect(!signedIn, "an existing app needs no sign-in when the API key finds it")
    #expect(result.text == "com.example.app already has an app record: Other (77), SKU OLD; nothing was sent\n")
    #expect(said.lines.contains { $0.contains("its name is \"Other\"") && $0.contains("its SKU is OLD") })
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try ASCOutput.json(result).utf8))
    #expect(doc["existing"]?[0]?["bundleId"] == .string("com.example.app") && doc["created"] == .array([]))
}

@Test func withAKeyTheAppIsCreatedOnceThroughTheWebSession() async throws {
    let api = FakeAPI()
    let web = FakeWeb()
    let result = try #require(try await creation(api: api, web: web).run(request))
    #expect(result.created == [made])
    #expect(api.calls == ["find com.example.app", "has com.example.app"])
    #expect(web.calls == ["create com.example.app"], "the key did the lookups; the web session only creates")
    #expect(result.text == "created app Example (1234567890) for com.example.app, SKU EX1\n")
}

@Test func aMissingBundleIDIsOfferedAndRegisteredFirst() async throws {
    let api = FakeAPI(hasBundle: false)
    let web = FakeWeb()
    let asked = Said()
    _ = try await creation(api: api, web: web, asked: asked).run(request)
    #expect(api.calls == ["find com.example.app", "has com.example.app", "register com.example.app"])
    #expect(asked.lines.first?.contains("Register it now (universal, named \"com example app\")") == true)
    #expect(web.calls == ["create com.example.app"])

    let declined = FakeAPI(hasBundle: false)
    let web2 = FakeWeb()
    let said = Said()
    #expect(try await creation(api: declined, web: web2, answer: false, said: said).run(request) == nil)
    #expect(!declined.calls.contains("register com.example.app") && web2.calls.isEmpty)
    #expect(said.lines == ["cancelled; nothing was sent"])
}

@Test func withoutAKeyTheWebSessionLooksUpFirst() async throws {
    let web = FakeWeb()
    _ = try await creation(api: nil, web: web).run(request)
    #expect(web.calls == ["find com.example.app", "bundle com.example.app", "create com.example.app"])

    let existing = FakeWeb(found: [.success(made)])
    #expect(try await creation(api: nil, web: existing).run(request)?.existing == [made])
    #expect(existing.calls == ["find com.example.app"])

    let noBundle = FakeWeb(bundleError: XlessError(.account, "the team has no bundle ID com.example.app", fix: "register it with `xless bundle-ids create com.example.app`"))
    await #expect(throws: XlessError.self) { _ = try await creation(api: nil, web: noBundle).run(request) }
    #expect(!noBundle.calls.contains("create com.example.app"))
}

@Test func aRefusalIsThrownAsIs() async throws {
    let error = XlessError(.account, "App Store Connect refused the app name \"Example\"", fix: "pick another with --name")
    let web = FakeWeb(answer: .refused(.nameTaken, error: error))
    do { _ = try await creation(api: FakeAPI(), web: web).run(request); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e == error)
    }
    #expect(web.calls == ["create com.example.app"], "no lookup after a definite refusal")
}

@Test func anUnclearAnswerIsSettledByLookingTheAppUp() async throws {
    let found = FakeWeb(found: [.success(made)], answer: .ambiguous("App Store Connect answered HTTP 502"))
    let said = Said()
    #expect(try await creation(api: FakeAPI(), web: found, said: said).run(request)?.created == [made])
    #expect(found.calls == ["create com.example.app", "find com.example.app"])
    #expect(said.lines == ["note: App Store Connect answered HTTP 502, but the app for com.example.app exists"])

    let absent = FakeWeb(found: [.success(nil)], answer: .ambiguous("App Store Connect did not answer (timed out)"))
    do { _ = try await creation(api: FakeAPI(), web: absent).run(request); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause == "App Store Connect did not answer (timed out), and App Store Connect has no app for com.example.app: nothing was created")
        #expect(e.fix == "re-run the same `xless apps create`")
    }

    let unknown = FakeWeb(found: [.failure(XlessError(.account, "x", fix: "y"))], answer: .ambiguous("App Store Connect answered HTTP 500"))
    do { _ = try await creation(api: FakeAPI(), web: unknown).run(request); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause.contains("could not check whether the app for com.example.app was created"))
        #expect(e.fix.contains("xless apps show com.example.app"))
    }
}
