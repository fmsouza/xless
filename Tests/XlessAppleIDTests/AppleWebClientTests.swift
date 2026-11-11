import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessAppleID

final class AppleWebClientTests: XCTestCase {
    func testCookieFromARedirectHopIsSentOnTheNextHop() async throws {
        let mock = MockTransport { r in
            switch r.url!.path {
            case "/start": return .init(status: 302, headers: ["Location": "/next", "Set-Cookie": "hop=1; Path=/"])
            case "/next": return .init(status: 200, body: Data("ok".utf8))
            default: return .init(status: 404)
            }
        }
        let client = AppleWebClient(transport: mock)
        let (data, response) = try await client.send(URLRequest(url: URL(string: "https://developer.apple.com/start")!))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(mock.requests.last?.header("Cookie"), "hop=1")
    }

    func testRedirectToOtherHostGetsNoAppleCookies() async throws {
        let mock = MockTransport { r in
            if r.url!.host == "developer.apple.com" {
                return .init(status: 302, headers: ["Location": "https://cdn.example.net/file", "Set-Cookie": "myacinfo=secret; Domain=.apple.com"])
            }
            return .init(status: 200)
        }
        let client = AppleWebClient(transport: mock)
        var request = URLRequest(url: URL(string: "https://developer.apple.com/start")!)
        request.setValue("session", forHTTPHeaderField: "X-Apple-ID-Session-Id")
        _ = try await client.send(request)
        let last = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(last.url?.host, "cdn.example.net")
        XCTAssertNil(last.header("Cookie"))
        XCTAssertNil(last.header("X-Apple-ID-Session-Id"))
    }

    func testRefusesARedirectToPlainHTTP() async {
        let mock = MockTransport { _ in .init(status: 302, headers: ["Location": "http://developer.apple.com/x"]) }
        let client = AppleWebClient(transport: mock)
        do {
            _ = try await client.send(URLRequest(url: URL(string: "https://developer.apple.com/start")!))
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testStopsAfterTenRedirects() async {
        let mock = MockTransport { _ in .init(status: 302, headers: ["Location": "/again"]) }
        let client = AppleWebClient(transport: mock)
        do {
            _ = try await client.send(URLRequest(url: URL(string: "https://developer.apple.com/start")!))
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(mock.requests.count, 11)
    }

    func testSeeOtherTurnsAPostIntoAGet() async throws {
        let mock = MockTransport { r in
            r.url!.path == "/post" ? .init(status: 303, headers: ["Location": "/result"]) : .init(status: 200)
        }
        let client = AppleWebClient(transport: mock)
        var request = URLRequest(url: URL(string: "https://developer.apple.com/post")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        _ = try await client.send(request)
        XCTAssertEqual(mock.requests.last?.httpMethod, "GET")
        XCTAssertNil(mock.requests.last?.httpBody)
    }

    func testNoFollowReturnsTheRedirect() async throws {
        let mock = MockTransport { _ in .init(status: 302, headers: ["Location": "https://x.apple.com/?widgetKey=k"]) }
        let client = AppleWebClient(transport: mock)
        let (_, response) = try await client.send(URLRequest(url: URL(string: "https://appstoreconnect.apple.com/logout")!), followRedirects: false)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testSetsTheUserAgent() async throws {
        let mock = MockTransport { _ in .init(status: 200) }
        let client = AppleWebClient(transport: mock, userAgent: "xless/test")
        _ = try await client.send(URLRequest(url: URL(string: "https://developer.apple.com/")!))
        XCTAssertEqual(mock.requests.first?.header("User-Agent"), "xless/test")
    }
}
