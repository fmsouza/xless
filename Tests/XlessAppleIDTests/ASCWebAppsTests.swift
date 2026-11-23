import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class ASCWebAppsTests: XCTestCase {
    let request = AppCreateRequest(name: "Example", bundleID: "com.example.app", sku: "EX1", primaryLocale: "en-US", platforms: ["IOS"])

    func apps(_ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (ASCWebApps, MockTransport) {
        let mock = MockTransport(handler)
        return (ASCWebApps(asc: ASCWebClient(web: AppleWebClient(transport: mock, stage: .account))), mock)
    }

    func testTheDocumentIsTheNewAppDialogsCompoundDocument() throws {
        let doc = String(decoding: try ASCWebApps.document(request), as: UTF8.self)
        XCTAssertEqual(doc, #"{"data":{"attributes":{"bundleId":"com.example.app","primaryLocale":"en-US","sku":"EX1"},"relationships":{"appInfos":{"data":[{"id":"${new-appInfo-id}","type":"appInfos"}]},"appStoreVersions":{"data":[{"id":"${store-version-IOS}","type":"appStoreVersions"}]}},"type":"apps"},"included":[{"id":"${new-appInfo-id}","relationships":{"appInfoLocalizations":{"data":[{"id":"${new-appInfoLocalization-id}","type":"appInfoLocalizations"}]}},"type":"appInfos"},{"attributes":{"locale":"en-US","name":"Example"},"id":"${new-appInfoLocalization-id}","type":"appInfoLocalizations"},{"attributes":{"platform":"IOS","versionString":"1.0"},"id":"${store-version-IOS}","relationships":{"appStoreVersionLocalizations":{"data":[{"id":"${new-IOSVersionLocalization-id}","type":"appStoreVersionLocalizations"}]}},"type":"appStoreVersions"},{"attributes":{"locale":"en-US"},"id":"${new-IOSVersionLocalization-id}","type":"appStoreVersionLocalizations"}]}"#)
    }

    func testEachPlatformGetsAVersionAndTheCompanyNameIsSentWhenGiven() throws {
        var r = request
        r.platforms = ["IOS", "MAC_OS"]
        r.companyName = "Example Ltd"
        r.versionString = "2.0"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ASCWebApps.document(r)) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual((data["attributes"] as? [String: String])?["companyName"], "Example Ltd")
        let versions = try XCTUnwrap(((data["relationships"] as? [String: Any])?["appStoreVersions"] as? [String: Any])?["data"] as? [[String: String]])
        XCTAssertEqual(versions.map { $0["id"] }, ["${store-version-IOS}", "${store-version-MAC_OS}"])
        let included = try XCTUnwrap(object["included"] as? [[String: Any]])
        XCTAssertEqual(included.compactMap { $0["type"] as? String },
                       ["appInfos", "appInfoLocalizations", "appStoreVersions", "appStoreVersionLocalizations", "appStoreVersions", "appStoreVersionLocalizations"])
        let mac = try XCTUnwrap(included.first { ($0["id"] as? String) == "${store-version-MAC_OS}" })
        XCTAssertEqual(mac["attributes"] as? [String: String], ["platform": "MAC_OS", "versionString": "2.0"])
        XCTAssertTrue(included.contains { ($0["id"] as? String) == "${new-MAC_OSVersionLocalization-id}" })
    }

    func testCreateSendsOnePOSTAndReadsTheApp() async throws {
        let (apps, mock) = apps { _ in .json(201, ["data": ["type": "apps", "id": "1234567890", "attributes": ["bundleId": "com.example.app", "sku": "EX1"]]]) }
        guard case .created(let app) = await apps.create(request) else { return XCTFail("expected created") }
        XCTAssertEqual(app, WebApp(id: "1234567890", name: "Example", bundleID: "com.example.app", sku: "EX1"))
        XCTAssertEqual(mock.requests.count, 1)
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://appstoreconnect.apple.com/iris/v1/apps")
        XCTAssertEqual(r.header("X-CSRF-ITC"), "[asc-ui]")
        XCTAssertEqual(r.bodyString, String(decoding: try ASCWebApps.document(request), as: UTF8.self))
    }

    func refusal(_ status: Int, _ errors: [[String: Any]]) async -> (AppCreateRefusal, XlessError)? {
        let body = try! JSONSerialization.data(withJSONObject: ["errors": errors])
        let (apps, mock) = apps { _ in MockTransport.Reply(status: status, headers: ["Content-Type": "application/json"], body: body) }
        let answer = await apps.create(request)
        XCTAssertEqual(mock.requests.count, 1, "a create is never retried")
        guard case .refused(let reason, let error) = answer else { XCTFail("expected a refusal, got \(answer)"); return nil }
        return (reason, error)
    }

    func testANameCollisionIsNamedAsSuch() async throws {
        let r = await refusal(409, [["status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
                                     "detail": "The app name you entered is already being used. If you have trademark rights to this name, submit a claim.",
                                     "source": ["pointer": "/included/1/attributes/name"]]])
        XCTAssertEqual(r?.0, .nameTaken)
        XCTAssertTrue(r?.1.cause.contains("refused the app name \"Example\"") == true, r?.1.cause ?? "")
        XCTAssertTrue(r?.1.fix.contains("--name") == true)
        XCTAssertEqual(r?.1.stage, .account)
    }

    func testSKUAndBundleIDRefusals() async throws {
        let sku = await refusal(409, [["code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "The SKU you entered has already been used."]])
        XCTAssertEqual(sku?.0, .skuTaken)
        XCTAssertTrue(sku?.1.fix.contains("--sku") == true)
        let bundle = await refusal(409, [["code": "ENTITY_ERROR", "detail": "An app with this Bundle ID already exists."]])
        XCTAssertEqual(bundle?.0, .bundleIDTaken)
        let platform = await refusal(409, [["code": "ENTITY_ERROR", "detail": "The bundle ID is not registered for this platform."]])
        XCTAssertEqual(platform?.0, .other, "a bundle refusal that is not about a taken bundle ID keeps Apple's words only")
        let other = await refusal(409, [["code": "ENTITY_ERROR", "detail": "Something else entirely."]])
        XCTAssertEqual(other?.0, .other)
        XCTAssertTrue(other?.1.cause.contains("HTTP 409 to POST /iris/v1/apps") == true, other?.1.cause ?? "")
        let forbidden = await refusal(403, [["code": "FORBIDDEN_ERROR"]])
        XCTAssertTrue(forbidden?.1.fix.contains("App Manager") == true)
        let expired = await refusal(401, [["code": "NOT_AUTHORIZED", "detail": "name already taken"]])
        XCTAssertEqual(expired?.0, .other, "401 is the session, whatever the text")
    }

    func testServerErrorsMissingAnswersAndUnreadableAnswersAreAmbiguous() async throws {
        for reply in [MockTransport.Reply.json(500, ["errors": []]), .json(503, [:]), .json(201, ["data": ["type": "apps"]]),
                      MockTransport.Reply(status: 200, body: Data("<html>".utf8))] {
            let (apps, mock) = apps { _ in reply }
            guard case .ambiguous = await apps.create(request) else { return XCTFail("expected ambiguous for \(reply.status)") }
            XCTAssertEqual(mock.requests.count, 1)
        }
        let (apps, mock) = apps { _ in throw URLError(.networkConnectionLost) }
        guard case .ambiguous(let why) = await apps.create(request) else { return XCTFail("expected ambiguous") }
        XCTAssertTrue(why.contains("did not answer"), why)
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testFindLooksTheBundleIdentifierUpExactly() async throws {
        let (apps, mock) = apps { _ in
            .json(200, ["data": [["type": "apps", "id": "1", "attributes": ["bundleId": "com.example.app.widget", "name": "W"]],
                                 ["type": "apps", "id": "2", "attributes": ["bundleId": "com.example.app", "name": "Example", "sku": "EX1"]]]])
        }
        let found = try await apps.find(bundleID: "com.example.app")
        XCTAssertEqual(found, WebApp(id: "2", name: "Example", bundleID: "com.example.app", sku: "EX1"))
        let url = try XCTUnwrap(mock.requests.first?.url)
        XCTAssertEqual(url.path, "/iris/v1/apps")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "filter[bundleId]", value: "com.example.app")])
        let (none, _) = self.apps { _ in .json(200, ["data": []]) }
        let missing = try await none.find(bundleID: "com.example.app")
        XCTAssertNil(missing)
    }
}
