import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessAppleID
import XlessASC
import XlessCore
@testable import xless

/// Answers GETs from a table of paths (query ignored); a path not in it is an empty list. Records every request.
private final class RoutedGets: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var requests: [URLRequest] = []
    private let lock = NSLock()
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = routes[request.url!.path] ?? (200, #"{"data": [], "links": {}}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// The web side: every answer is `body`; records every request that got through the guard.
private final class RecordingApple: AppleTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var answers: [String: String]
    private let lock = NSLock()
    init(_ answers: [String: String] = [:]) { self.answers = answers }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let body = answers.first { request.url!.path.hasSuffix($0.key) }?.value ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"])!)
    }
    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        Issue.record("downloaded \(request.url!)")
        throw URLError(.badURL)
    }
}

private func one(_ type: String, _ id: String, _ attributes: String = "{}") -> String {
    #"{"data": {"type": "\#(type)", "id": "\#(id)", "attributes": \#(attributes)}, "links": {}}"#
}
private func list(_ type: String, _ id: String, _ attributes: String = "{}") -> String {
    #"{"data": [{"type": "\#(type)", "id": "\#(id)", "attributes": \#(attributes)}], "links": {}}"#
}

private func resources(_ t: HTTPTransport) -> ASCResources {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ASCResources(client: ASCClient(credentials: creds, transport: ReadOnlyTransport(inner: t), sleep: { _ in }))
}

private let app = #"{"name": "Hello", "bundleId": "com.example.hello", "sku": "HELLO1", "primaryLocale": "en-US", "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}"#

/// One of each thing an account has, so every app-scoped check runs.
private func account() -> RoutedGets {
    RoutedGets([
        "/v1/apps": (200, list("apps", "6470000001", app)),
        "/v1/apps/6470000001": (200, one("apps", "6470000001", app)),
        "/v1/bundleIds": (200, list("bundleIds", "BID1", #"{"identifier": "com.example.hello", "name": "Hello", "platform": "IOS"}"#)),
        "/v1/certificates": (200, list("certificates", "CERT1", #"{"name": "Apple Distribution", "certificateType": "DISTRIBUTION"}"#)),
        "/v1/certificates/CERT1": (200, one("certificates", "CERT1", #"{"name": "Apple Distribution", "certificateType": "DISTRIBUTION", "certificateContent": "MIIB"}"#)),
        "/v1/apps/6470000001/appInfos": (200, list("appInfos", "INFO1", #"{"state": "PREPARE_FOR_SUBMISSION"}"#)),
        "/v1/apps/6470000001/appStoreVersions": (200, list("appStoreVersions", "VER1", #"{"platform": "IOS", "versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION"}"#)),
        "/v1/appStoreVersions/VER1/appStoreVersionLocalizations": (200, list("appStoreVersionLocalizations", "LOC1", #"{"locale": "en-US"}"#)),
        "/v1/appStoreVersions/VER1/appStoreReviewDetail": (200, one("appStoreReviewDetails", "RD1")),
        "/v1/appStoreVersions/VER1/appStoreVersionPhasedRelease": (200, #"{"data": null}"#),
        "/v1/appStoreVersions/VER1/relationships/build": (200, #"{"data": null}"#),
        "/v1/appStoreVersions/VER1/build": (200, #"{"data": null}"#),
        "/v1/appInfos/INFO1/ageRatingDeclaration": (404, #"{"errors": [{"status": "404", "code": "NOT_FOUND", "title": "x", "detail": "x"}]}"#),
        "/v1/apps/6470000001/appPriceSchedule": (404, #"{"errors": [{"status": "404", "code": "NOT_FOUND", "title": "x", "detail": "x"}]}"#),
        "/v1/apps/6470000001/appAvailabilityV2": (404, #"{"errors": [{"status": "404", "code": "NOT_FOUND", "title": "x", "detail": "x"}]}"#),
        "/v1/apps/6470000001/endUserLicenseAgreement": (404, #"{"errors": [{"status": "404", "code": "NOT_FOUND", "title": "x", "detail": "x"}]}"#),
        "/v1/apps/6470000001/betaAppReviewDetail": (200, one("betaAppReviewDetails", "BRD1")),
        "/v1/apps/6470000001/betaLicenseAgreement": (200, one("betaLicenseAgreements", "BLA1")),
        "/v1/builds": (200, list("builds", "BUILD1", #"{"version": "42", "processingState": "VALID"}"#)),
        "/v1/builds/BUILD1": (200, one("builds", "BUILD1", #"{"version": "42", "processingState": "VALID"}"#)),
        "/v1/reviewSubmissions": (200, list("reviewSubmissions", "SUB1", #"{"state": "READY_FOR_REVIEW", "platform": "IOS"}"#)),
    ])
}

@Test func everyAPICheckReadsAndNoneWrites() async throws {
    let t = account()
    let lines = await LiveCheck(api: resources(t)).run()
    let failures = lines.filter { $0.status == .fail }
    #expect(failures.isEmpty, "\(failures)")
    #expect(t.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    let checks = Set(lines.map(\.check))
    for wanted in ["GET /v1/apps", "GET /v1/certificates", "GET /v1/certificates/{id}", "GET /v1/profiles?include=certificates", "GET /v1/builds/{id}?include=…",
                   "GET /v1/reviewSubmissions/{id}/items", "GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets",
                   "GET /v1/bundleIds/{id}/bundleIdCapabilities", "GET /v1/apps/{id}/webhooks"] {
        #expect(checks.contains(wanted), "\(wanted) not checked")
    }
    #expect(lines.contains { $0.area == "web" && $0.status == .skip })
}

@Test func fieldsXlessReadsThatNeverCameAreAWarning() async throws {
    let lines = await LiveCheck(api: resources(account())).run()
    let apps = try #require(lines.first { $0.check == "GET /v1/apps" })
    #expect(apps.status == .ok, "\(apps)")
    let certificates = try #require(lines.first { $0.check == "GET /v1/certificates" })
    #expect(certificates.status == .warn)
    #expect(certificates.detail.contains("never sent"))
    #expect(certificates.detail.contains("expirationDate"))
}

@Test func anAnswerXlessCannotReadFailsThatCheckOnly() async throws {
    let t = account()
    t.routes["/v1/devices"] = (200, #"{"data": "not a list"}"#)
    let lines = await LiveCheck(api: resources(t)).run()
    let devices = try #require(lines.first { $0.check == "GET /v1/devices" })
    #expect(devices.status == .fail)
    #expect(lines.filter { $0.status == .fail }.count == 1)
    #expect(LiveCheck.text(lines).contains("1 failed"))
}

@Test func anAccountWithoutAppsSkipsTheAppChecks() async throws {
    let lines = await LiveCheck(api: resources(RoutedGets([:]))).run()
    #expect(lines.contains { $0.check == "the endpoints of an app" && $0.status == .skip })
    #expect(!lines.contains { $0.check.contains("{id}") })
}

@Test func withNeitherHalfEverythingIsSkipped() async {
    let lines = await LiveCheck(apiSkip: "no API key: none here", webSkip: "no kept session").run()
    #expect(lines.map(\.status) == [.skip, .skip])
    #expect(lines[0].detail == "no API key: none here")
}

@Test func theWebHalfSendsOnlyReads() async throws {
    let apple = RecordingApple([
        "/olympus/v1/session": #"{"provider": {"providerId": 1, "name": "Team", "publicProviderId": "pp"}, "availableProviders": []}"#,
        "listTeams.action": #"{"resultCode": 0, "teams": [{"teamId": "ABCDE12345", "name": "Team"}]}"#,
    ])
    let web = AppleWebClient(transport: ReadOnlyAppleTransport(inner: apple), stage: .account)
    let session = AppleWebSession(web: web, appleID: "someone", kept: nil)
    await session.portal.use(team: "ABCDE12345")
    let lines = await LiveCheck(web: session, app: "com.example.hello").run()
    #expect(lines.first { $0.check == "GET /olympus/v1/session" }?.status == .ok)
    #expect(lines.first { $0.check == "POST QH65B2/account/listTeams.action" }?.status == .ok)
    #expect(lines.contains { $0.check == "GET /iris/v1/apps?filter[bundleId]" })
    #expect(!lines.contains { $0.detail.contains("refused to send") }, "\(lines.filter { $0.detail.contains("refused") })")
    for r in apple.requests where r.httpMethod == "POST" {
        let override = r.value(forHTTPHeaderField: "X-HTTP-Method-Override")
        #expect(override == "GET" || ReadOnlyGuard.isReadingAction(r.url!.path) || r.url!.path == "/olympus/v1/session", "\(r.url!)")
    }
}

@Test(arguments: ["POST", "PATCH", "PUT", "DELETE"])
func theAPIGuardRefusesEveryWrite(method: String) async throws {
    let t = RoutedGets([:])
    var r = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/bundleIds")!)
    r.httpMethod = method
    await #expect(throws: XlessError.self) { _ = try await ReadOnlyTransport(inner: t).send(r) }
    #expect(t.requests.isEmpty)
}

@Test(arguments: [
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/addApplicationGroup.action", nil, false),
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/auth/key/v2/create", nil, false),
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/auth/key/revoke", nil, false),
    ("PATCH", "https://developer.apple.com/services-account/v1/bundleIds/X", nil, false),
    ("POST", "https://appstoreconnect.apple.com/iris/v1/apiKeys", nil, false),
    ("DELETE", "https://appstoreconnect.apple.com/iris/v1/appDataUsages/1", nil, false),
    ("POST", "https://developer.apple.com/services-account/v1/cloudContainers", "GET", true),
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/listTeams.action", nil, true),
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/auth/key/list", nil, true),
    ("POST", "https://developer.apple.com/services-account/QH65B2/account/auth/key/get", nil, true),
    ("POST", "https://appstoreconnect.apple.com/olympus/v1/session", nil, true),
    ("GET", "https://appstoreconnect.apple.com/iris/v1/apiKeys", nil, true),
] as [(String, String, String?, Bool)])
func theWebGuardLetsOnlyReadsThrough(method: String, url: String, override: String?, allowed: Bool) {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    if let override { r.setValue(override, forHTTPHeaderField: "X-HTTP-Method-Override") }
    let passed = (try? ReadOnlyGuard.checkWeb(r)) != nil
    #expect(passed == allowed)
}

@Test func liveCheckNeedsTheOptIn() async throws {
    await #expect(throws: (any Error).self) { try await LiveCheckCommand.parse([]).run() }
}
