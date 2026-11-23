import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

private func ref(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }

final class ASCWebPrivacyTests: XCTestCase {
    func privacy(_ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (ASCWebPrivacy, MockTransport) {
        let mock = MockTransport(handler)
        return (ASCWebPrivacy(asc: ASCWebClient(web: AppleWebClient(transport: mock, stage: .account))), mock)
    }


    func testUsagesFollowEveryPageAndReadTheRelationships() async throws {
        let (p, mock) = privacy { r in
            if r.url!.query?.contains("cursor=2") == true {
                return .json(200, ["data": [["type": "appDataUsages", "id": "u2", "relationships": ["dataProtection": ref("appDataUsageDataProtections", "DATA_NOT_COLLECTED")]]]])
            }
            return .json(200, ["data": [["type": "appDataUsages", "id": "u1", "relationships": [
                "category": ref("appDataUsageCategories", "EMAIL_ADDRESS"), "purpose": ref("appDataUsagePurposes", "APP_FUNCTIONALITY"),
                "dataProtection": ref("appDataUsageDataProtections", "DATA_LINKED_TO_YOU")]]],
                               "links": ["next": "https://appstoreconnect.apple.com/iris/v1/apps/123/dataUsages?cursor=2"]])
        }
        let usages = try await p.usages(app: "123")
        XCTAssertEqual(usages, [WebDataUsage(id: "u1", category: "EMAIL_ADDRESS", purpose: "APP_FUNCTIONALITY", protection: "DATA_LINKED_TO_YOU"),
                                WebDataUsage(id: "u2", protection: "DATA_NOT_COLLECTED")])
        let first = try XCTUnwrap(URLComponents(url: mock.requests[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(first.path, "/iris/v1/apps/123/dataUsages")
        XCTAssertEqual(first.queryItems?.first { $0.name == "include" }?.value, "category,purpose,dataProtection")
        XCTAssertEqual(mock.requests.count, 2)
    }

    func testANextPageOutsideAppStoreConnectIsRefused() async {
        let (p, _) = privacy { _ in .json(200, ["data": [], "links": ["next": "https://evil.example.com/iris/v1/x"]]) }
        do { _ = try await p.usages(app: "123"); XCTFail("followed a foreign next page") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("a next page outside App Store Connect"), e.cause)
        } catch { XCTFail("\(error)") }
    }

    func testTheCatalogReadsTheThreeListsWithWhatIsRetired() async throws {
        let (p, mock) = privacy { r in
            switch r.url!.path {
            case "/iris/v1/appDataUsageCategories":
                return .json(200, ["data": [["type": "appDataUsageCategories", "id": "NAME", "attributes": ["deleted": false]],
                                            ["type": "appDataUsageCategories", "id": "OLD", "attributes": ["deleted": true]]]])
            case "/iris/v1/appDataUsagePurposes": return .json(200, ["data": [["type": "appDataUsagePurposes", "id": "ANALYTICS"]]])
            default: return .json(200, ["data": [["type": "appDataUsageDataProtections", "id": "DATA_LINKED_TO_YOU"]]])
            }
        }
        let catalog = try await p.catalog()
        XCTAssertEqual(catalog, WebPrivacyCatalog(categories: ["NAME": false, "OLD": true], purposes: ["ANALYTICS": false], protections: ["DATA_LINKED_TO_YOU": false]))
        XCTAssertEqual(mock.requests.map { $0.url!.path }, ["/iris/v1/appDataUsageCategories", "/iris/v1/appDataUsagePurposes", "/iris/v1/appDataUsageDataProtections"])
        XCTAssertTrue(mock.requests[0].url!.query!.contains("include=grouping"))
    }

    func testCreateSendsOnePOSTWithTheRelationships() async throws {
        let (p, mock) = privacy { _ in .json(201, ["data": ["type": "appDataUsages", "id": "new1"]]) }
        let id = try await p.create(app: "123", category: "EMAIL_ADDRESS", purpose: nil, protection: "DATA_USED_TO_TRACK_YOU")
        XCTAssertEqual(id, "new1")
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://appstoreconnect.apple.com/iris/v1/appDataUsages")
        XCTAssertEqual(r.bodyString, #"{"data":{"relationships":{"app":{"data":{"id":"123","type":"apps"}},"category":{"data":{"id":"EMAIL_ADDRESS","type":"appDataUsageCategories"}},"dataProtection":{"data":{"id":"DATA_USED_TO_TRACK_YOU","type":"appDataUsageDataProtections"}}},"type":"appDataUsages"}}"#)
    }

    func testARefusedCreateIsNotRetriedAndSaysWhy() async {
        let (p, mock) = privacy { _ in .json(409, ["errors": [["status": "409", "code": "STATE_ERROR", "title": "The request cannot be fulfilled", "detail": "Data not collected cannot be combined"]]]) }
        do { _ = try await p.create(app: "123", category: nil, purpose: nil, protection: "DATA_NOT_COLLECTED"); XCTFail("expected a refusal") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("409"), e.cause)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testDeleteTakesAnAlreadyGoneAnswerAsDone() async throws {
        let (p, mock) = privacy { _ in MockTransport.Reply(status: 404) }
        try await p.delete(id: "u1")
        XCTAssertEqual(mock.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(mock.requests.first?.url?.path, "/iris/v1/appDataUsages/u1")
    }

    func testIDsThatWouldLeaveTheirPathSegmentAreRefused() async {
        let (p, mock) = privacy { _ in .json(200, [:]) }
        for id in ["../apps", "a/b", "", ".."] {
            do { try await p.delete(id: id); XCTFail("sent \(id)") } catch {}
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testPublishStateAndPublish() async throws {
        let (p, mock) = privacy { r in
            if r.httpMethod == "GET" {
                return .json(200, ["data": ["type": "appDataUsagesPublishState", "id": "PS1", "attributes": ["published": false, "lastPublished": NSNull()]]])
            }
            return .json(200, ["data": ["type": "appDataUsagesPublishState", "id": "PS1", "attributes": ["published": true]]])
        }
        let state = try await p.publishState(app: "123")
        XCTAssertEqual(state, WebPrivacyPublishState(id: "PS1", published: false))
        try await p.publish(stateID: "PS1")
        XCTAssertEqual(mock.requests.map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["GET /iris/v1/apps/123/dataUsagePublishState", "PATCH /iris/v1/appDataUsagesPublishState/PS1"])
        XCTAssertEqual(mock.requests[1].bodyString, #"{"data":{"attributes":{"published":true},"id":"PS1","type":"appDataUsagesPublishState"}}"#)
    }

    func testNoPublishStateIsNil() async throws {
        let (p, _) = privacy { _ in MockTransport.Reply(status: 404) }
        let state = try await p.publishState(app: "123")
        XCTAssertNil(state)
    }
}
