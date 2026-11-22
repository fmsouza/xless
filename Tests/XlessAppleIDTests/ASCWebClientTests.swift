import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class ASCWebClientTests: XCTestCase {
    func client(_ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (ASCWebClient, MockTransport) {
        let mock = MockTransport(handler)
        return (ASCWebClient(web: AppleWebClient(transport: mock, stage: .account)), mock)
    }

    func accountError(_ op: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> XlessError? {
        do {
            try await op()
            XCTFail("expected an error", file: file, line: line)
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account, file: file, line: line)
            return e
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return nil
    }

    func testSendsAppStoreConnectsHeaders() async throws {
        let (asc, mock) = client { _ in .json(200, ["data": []]) }
        _ = try await asc.data("GET", "/iris/v1/apps", query: [URLQueryItem(name: "limit", value: "1")])
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://appstoreconnect.apple.com/iris/v1/apps?limit=1")
        XCTAssertEqual(r.header("X-CSRF-ITC"), "[asc-ui]")
        XCTAssertEqual(r.header("X-Requested-With"), "XMLHttpRequest")
        XCTAssertEqual(r.header("Origin"), "https://appstoreconnect.apple.com")
        XCTAssertEqual(r.header("Referer"), "https://appstoreconnect.apple.com/")
        XCTAssertEqual(r.header("Content-Type"), "application/json")
        XCTAssertNil(r.header("csrf"))
    }

    func testEchoesTheNewestCSRFTokens() async throws {
        let n = ByteCounter(0)
        let (asc, mock) = client { _ in
            switch n.add(1) {
            case 1: return .json(200, [:], headers: ["csrf": "tok1", "csrf_ts": "111"])
            case 2: return .json(200, [:])
            default: return .json(200, [:], headers: ["csrf": "tok2", "csrf_ts": "222"])
            }
        }
        for _ in 0..<4 { _ = try await asc.data("GET", "/olympus/v1/session") }
        XCTAssertEqual(mock.requests.map { $0.header("csrf") }, [nil, "tok1", "tok1", "tok2"])
        XCTAssertEqual(mock.requests.map { $0.header("csrf_ts") }, [nil, "111", "111", "222"])
    }

    func testRefusesPathsOutsideIrisAndOlympus() async {
        let (asc, mock) = client { _ in .json(200, [:]) }
        _ = await accountError { _ = try await asc.data("GET", "/v1/apps") }
        _ = await accountError { _ = try await asc.data("GET", "/iris/v1/../../x") }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testA401SaysTheSessionExpired() async {
        let (asc, _) = client { _ in .init(status: 401) }
        let e = await accountError { _ = try await asc.session() }
        XCTAssertTrue(e?.cause.contains("App Store Connect's web interface refused the Apple ID session for GET /olympus/v1/session") ?? false, e?.cause ?? "")
        XCTAssertTrue(e?.fix.contains("xless auth logout") ?? false)
    }

    func testOtherFailuresNameTheFamilyAndSayItIsUndocumented() async {
        let (asc, _) = client { _ in .json(500, ["errors": [["code": "UNEXPECTED_ERROR", "detail": "Something went wrong"]]]) }
        let e = await accountError { _ = try await asc.data("POST", "/iris/v1/apps", body: Data("{}".utf8), page: "https://appstoreconnect.apple.com/apps") }
        XCTAssertEqual(e?.cause, "App Store Connect's web interface answered HTTP 500 to POST /iris/v1/apps: UNEXPECTED_ERROR — Something went wrong")
        XCTAssertTrue(e?.fix.contains("undocumented") ?? false)
        XCTAssertTrue(e?.fix.hasSuffix("https://appstoreconnect.apple.com/apps") ?? false, e?.fix ?? "")
    }

    func testARefusalAboutAgreementsPointsToTheAgreementsPage() async {
        let (asc, _) = client { _ in .json(403, ["errors": [["detail": "You must accept the latest Program License Agreement."]]]) }
        let e = await accountError { _ = try await asc.data("GET", "/iris/v1/apps") }
        XCTAssertTrue(e?.cause.contains("agreements") ?? false)
        XCTAssertTrue(e?.fix.contains("https://appstoreconnect.apple.com/agreements") ?? false)
        XCTAssertTrue(e?.fix.contains("never accepts") ?? false)
    }

    func testSwitchingPostsTheProviderAndConfirmsIt() async throws {
        let current = Box(1)
        let (asc, mock) = client { r in
            if r.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [String: Int]]
                current.value = body["provider"]!["providerId"]!
                return .init(status: 200)
            }
            let id = current.value
            return .json(200, ["provider": ["providerId": id, "name": "P\(id)"],
                               "availableProviders": [["providerId": 1, "name": "P1"], ["providerId": 2, "name": "P2"]]])
        }
        let after = try await asc.switchProvider(to: 2)
        XCTAssertEqual(after.provider?.providerId, 2)
        XCTAssertEqual(mock.requests.map { "\($0.httpMethod!) \($0.url!.path)" }, ["POST /olympus/v1/session", "GET /olympus/v1/session"])
        XCTAssertEqual(mock.requests[0].bodyString, #"{"provider":{"providerId":2}}"#)
    }

    func testASwitchAppleDidNotMakeIsAnError() async {
        let (asc, _) = client { r in
            r.httpMethod == "POST" ? .init(status: 200) : .json(200, ["provider": ["providerId": 1, "name": "P1"]])
        }
        let e = await accountError { try await asc.switchProvider(to: 2) }
        XCTAssertTrue(e?.cause.contains("did not switch to provider 2") ?? false, e?.cause ?? "")
    }

    func testPendingAgreementsAreReadAsPlainText() async {
        let (asc, _) = client { _ in .json(200, [["message": "<b>Review</b> the  updated <a href='x'>Paid Apps</a> agreement."]]) }
        let pending = await asc.pendingAgreements()
        XCTAssertEqual(pending, ["Review the updated Paid Apps agreement."])
        let (silent, _) = client { _ in .init(status: 500) }
        let unknown = await silent.pendingAgreements()
        XCTAssertNil(unknown)
    }
}
