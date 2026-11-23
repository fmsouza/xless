import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func apps(_ t: MockTransport) -> ASCApps {
    ASCApps(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}

/// An app as App Store Connect returns it (shape of GET /v1/apps).
func appJSON(_ id: String, _ bundleID: String, name: String = "My App", sku: String = "SKU1", locale: String = "en-US",
             contentRights: String? = nil) -> String {
    #"{"type":"apps","id":"\#(id)","attributes":{"name":"\#(name)","bundleId":"\#(bundleID)","sku":"\#(sku)","primaryLocale":"\#(locale)"\#(contentRights.map { #","contentRightsDeclaration":"\#($0)""# } ?? "")},"links":{"self":"x"}}"#
}

// MARK: - Input

@Test func appArgumentsAreAnAppIDOrABundleIdentifier() {
    #expect(AppArgument.isAppID("1234567890"))
    #expect(!AppArgument.isAppID("com.example.app") && !AppArgument.isAppID("12a4") && !AppArgument.isAppID(""))
    #expect(throws: IdentifierInputError.self) { try AppArgument.validate("12a4") }
    #expect(throws: IdentifierInputError.self) { try AppArgument.validate("com.example.*") }
    #expect(throws: IdentifierInputError.self) { try AppArgument.validate("../v1/users") }
    #expect(throws: Never.self) { try AppArgument.validate("com.example.app") }
    #expect(throws: Never.self) { try AppArgument.validate("1234567890") }
}

@Test func skusAreLettersDigitsAndThreeMarks() throws {
    #expect(try AppSKU.validate(" my-app_1.0 ") == "my-app_1.0")
    for bad in ["", "-app", ".app", "_app", "my app", "café", String(repeating: "a", count: 256)] {
        #expect(throws: IdentifierInputError.self, "\(bad)") { try AppSKU.validate(bad) }
    }
}

@Test func appNamesAreTwoToThirtyCharacters() throws {
    #expect(try AppName.validate(" Café Run ") == "Café Run")
    #expect(try AppName.validate(String(repeating: "é", count: 30)).count == 30)
    for bad in ["", " ", "A", String(repeating: "a", count: 31)] { #expect(throws: IdentifierInputError.self, "\(bad)") { try AppName.validate(bad) } }
}

@Test func localesAreNormalisedToAppStoreConnectsSpelling() throws {
    #expect(try AppLocale.normalize("en-us") == "en-US")
    #expect(try AppLocale.normalize("ZH-HANS") == "zh-Hans")
    #expect(try AppLocale.normalize("ja") == "ja")
    #expect(try AppLocale.normalize("fr-BE") == "fr-BE", "a well-formed locale xless does not know goes to Apple as it is")
    for bad in ["", "english", "en_US", "e", "en-"] { #expect(throws: IdentifierInputError.self, "\(bad)") { try AppLocale.normalize(bad) } }
}

@Test func contentRightsAndPlatformsTakeCommandLineNames() {
    #expect(AppContentRights(argument: "uses-third-party-content") == .usesThirdPartyContent)
    #expect(AppContentRights(argument: "DOES_NOT_USE_THIRD_PARTY_CONTENT") == .doesNotUseThirdPartyContent)
    #expect(AppContentRights(argument: "none") == .doesNotUseThirdPartyContent && AppContentRights(argument: "uses") == .usesThirdPartyContent)
    #expect(AppContentRights(argument: "maybe") == nil)
    #expect(AppPlatform(argument: "iOS") == .ios && AppPlatform(argument: "mac") == .macOS && AppPlatform(argument: "tvos") == nil)
    #expect(AppPlatform.macOS.rawValue == "MAC_OS" && AppPlatform.display("IOS") == "ios" && AppPlatform.display("TV_OS") == "TV_OS")
}

// MARK: - Requests

@Test func listReadsEveryPageSortedByName() async throws {
    let t = MockTransport([(200, dataList([appJSON("2", "com.example.zeta", name: "Zeta")], next: "https://api.appstoreconnect.apple.com/v1/apps?cursor=Y")),
                           (200, dataList([appJSON("1", "com.example.alpha", name: "alpha")]))])
    let list = try await apps(t).list()
    #expect(list.map(\.id) == ["1", "2"])
    #expect(t.requests[0].url!.path == "/v1/apps" && query(t.requests[0]) == ["limit=200"])
    #expect(list[1].bundleID == "com.example.zeta" && list[1].name == "Zeta" && list[1].attributes.sku == "SKU1")
}

@Test func findMatchesTheBundleIdentifierExactly() async throws {
    let t = MockTransport([(200, dataList([appJSON("1", "com.example.app.extra"), appJSON("2", "com.example.app")]))])
    let found = try await apps(t).find(bundleID: "com.example.app")
    #expect(found?.id == "2")
    #expect(query(t.requests[0]) == ["filter[bundleId]=com.example.app", "limit=200"])
    let none = MockTransport([(200, dataList([appJSON("1", "com.example.app.extra")]))])
    #expect(try await apps(none).find(bundleID: "com.example.app") == nil)
}

@Test func resolveTakesAnIDOrABundleIdentifier() async throws {
    let byID = MockTransport([(200, #"{"data":\#(appJSON("1234567890", "com.example.app"))}"#)])
    #expect(try await apps(byID).resolve("1234567890").bundleID == "com.example.app")
    #expect(byID.requests[0].url!.path == "/v1/apps/1234567890")

    let byBundle = MockTransport([(200, dataList([appJSON("9", "com.example.app")]))])
    #expect(try await apps(byBundle).resolve("com.example.app").id == "9")

    let missing = MockTransport([(200, dataList([]))])
    do { _ = try await apps(missing).resolve("com.example.app"); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.stage == .account && e.cause.contains("no app record for com.example.app"))
        #expect(e.fix.contains("xless apps create --bundle-id com.example.app"))
    }
}

@Test func infosAndVersionsAreTheAppsRelationships() async throws {
    let t = MockTransport([
        (200, dataList([#"{"type":"appInfos","id":"I1","attributes":{"state":"PREPARE_FOR_SUBMISSION","appStoreAgeRating":"FOUR_PLUS"}}"#])),
        (200, dataList([#"{"type":"appStoreVersions","id":"V1","attributes":{"platform":"IOS","versionString":"1.0","appVersionState":"PREPARE_FOR_SUBMISSION","createdDate":"2026-11-23T10:00:00-08:00"}}"#])),
    ])
    let infos = try await apps(t).infos(of: "1")
    let versions = try await apps(t).versions(of: "1")
    #expect(infos.first?.attributes.state == "PREPARE_FOR_SUBMISSION" && infos.first?.attributes.appStoreAgeRating == "FOUR_PLUS")
    #expect(versions.first?.attributes.versionString == "1.0" && versions.first?.attributes.platform == "IOS")
    #expect(t.requests.map { $0.url!.path } == ["/v1/apps/1/appInfos", "/v1/apps/1/appStoreVersions"])
}

@Test func updateSendsOnlyWhatChanges() async throws {
    let current = ASCApp(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(appJSON("1", "com.example.app", locale: "en-US").utf8)))
    let t = MockTransport([(200, #"{"data":\#(appJSON("1", "com.example.app", locale: "de-DE", contentRights: "USES_THIRD_PARTY_CONTENT"))}"#)])
    let updated = try await apps(t).update(current, primaryLocale: "de-DE", contentRights: .usesThirdPartyContent, bundleID: "com.example.app")
    #expect(updated?.attributes.primaryLocale == "de-DE")
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "PATCH" && t.requests[0].url!.path == "/v1/apps/1")
    let sent = try JSONDecoder().decode(JSONValue.self, from: t.requests[0].httpBody ?? Data())
    let expected = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"data":{"attributes":{"contentRightsDeclaration":"USES_THIRD_PARTY_CONTENT","primaryLocale":"de-DE"},"id":"1","type":"apps"}}"#.utf8))
    #expect(sent == expected)

    let none = MockTransport([])
    #expect(try await apps(none).update(current, primaryLocale: "en-US", contentRights: nil, bundleID: "com.example.app") == nil)
    #expect(none.requests.isEmpty)
}
