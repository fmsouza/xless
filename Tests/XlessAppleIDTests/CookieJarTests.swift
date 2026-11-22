import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessAppleID

final class CookieJarTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }

    func response(_ u: String, _ setCookie: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url(u), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": setCookie])!
    }

    func testDomainCookieReachesSubdomains() {
        let jar = CookieJar()
        jar.store(from: response("https://idmsa.apple.com/x", "myacinfo=abc; Domain=.apple.com; Path=/; Secure; HttpOnly"),
                  for: url("https://idmsa.apple.com/x"))
        XCTAssertEqual(jar.header(for: url("https://download.developer.apple.com/Developer_Tools/a.xip")), "myacinfo=abc")
        XCTAssertEqual(jar.header(for: url("https://apple.com/")), "myacinfo=abc")
    }

    func testHostOnlyCookieStaysOnItsHost() {
        let jar = CookieJar()
        jar.store(from: response("https://idmsa.apple.com/a", "aasp=1; Path=/"), for: url("https://idmsa.apple.com/a"))
        XCTAssertEqual(jar.header(for: url("https://idmsa.apple.com/b")), "aasp=1")
        XCTAssertNil(jar.header(for: url("https://sub.idmsa.apple.com/b")))
        XCTAssertNil(jar.header(for: url("https://developer.apple.com/b")))
    }

    func testNeverSentToLookalikeOrForeignHosts() {
        let jar = CookieJar()
        jar.store(from: response("https://idmsa.apple.com/", "s=1; Domain=apple.com"), for: url("https://idmsa.apple.com/"))
        XCTAssertNil(jar.header(for: url("https://apple.com.evil.com/")))
        XCTAssertNil(jar.header(for: url("https://evilapple.com/")))
        XCTAssertNil(jar.header(for: url("https://cdn.example.net/")))
    }

    func testRejectsDomainTheResponseHostIsNotIn() {
        let jar = CookieJar()
        jar.store(from: response("https://idmsa.apple.com/", "s=1; Domain=evil.com"), for: url("https://idmsa.apple.com/"))
        jar.store(from: response("https://idmsa.apple.com/", "t=1; Domain=com"), for: url("https://idmsa.apple.com/"))
        XCTAssertNil(jar.header(for: url("https://evil.com/")))
        XCTAssertNil(jar.header(for: url("https://idmsa.apple.com/")))
    }

    func testSecureCookiesOnlyOverHTTPS() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "s=1; Secure"), for: url("https://a.apple.com/"))
        XCTAssertNil(jar.header(for: url("http://a.apple.com/")))
    }

    func testMaxAgeZeroAndPastExpiryDelete() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "s=1, t=2"), for: url("https://a.apple.com/"))
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/")), "s=1; t=2")
        jar.store(from: response("https://a.apple.com/", "s=gone; Max-Age=0"), for: url("https://a.apple.com/"))
        jar.store(from: response("https://a.apple.com/", "t=gone; Expires=Wed, 21 Oct 2015 07:28:00 GMT"), for: url("https://a.apple.com/"))
        XCTAssertNil(jar.header(for: url("https://a.apple.com/")))
    }

    func testSeveralCookiesInOneHeaderWithExpiresCommas() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/, b=2; Path=/"),
                  for: url("https://a.apple.com/"))
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/")), "a=1; b=2")
    }

    func testReplacesByNameDomainAndPath() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "s=1; Path=/"), for: url("https://a.apple.com/"))
        jar.store(from: response("https://a.apple.com/", "s=2; Path=/"), for: url("https://a.apple.com/"))
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/")), "s=2")
    }

    func testPathPrefixMatch() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "p=1; Path=/services"), for: url("https://a.apple.com/"))
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/services/x")), "p=1")
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/services")), "p=1")
        XCTAssertNil(jar.header(for: url("https://a.apple.com/servicesX")))
        XCTAssertNil(jar.header(for: url("https://a.apple.com/")))
    }

    func testEmptyAttributesAreIgnored() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "x=y; Path=/;"), for: url("https://a.apple.com/"))
        jar.store(from: response("https://a.apple.com/", "z=w;; Secure; ;"), for: url("https://a.apple.com/"))
        XCTAssertEqual(jar.header(for: url("https://a.apple.com/")), "x=y; z=w")
    }

    func testClearForgetsEverything() {
        let jar = CookieJar()
        jar.store(from: response("https://a.apple.com/", "s=1"), for: url("https://a.apple.com/"))
        jar.clear()
        XCTAssertTrue(jar.isEmpty)
    }
}

final class CookieJarSnapshotTests: XCTestCase {
    func testSnapshotRestoresTheSameHeaders() {
        let jar = CookieJar()
        let u = URL(string: "https://idmsa.apple.com/x")!
        jar.store(from: HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Set-Cookie": "myacinfo=abc; Domain=.apple.com; Path=/; Secure, aasp=1; Path=/"])!, for: u)
        let copy = CookieJar()
        copy.restore(jar.snapshot())
        XCTAssertEqual(copy.header(for: u), jar.header(for: u))
        XCTAssertEqual(copy.header(for: URL(string: "https://developer.apple.com/")!), "myacinfo=abc")
    }

    func testRestoreDropsExpiredCookiesAndReportsTheEarliestExpiry() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(t0)
        let jar = CookieJar(now: { clock.now })
        jar.restore([
            .init(name: "old", value: "1", domain: "apple.com", hostOnly: false, path: "/", secure: true, expires: t0.addingTimeInterval(-1)),
            .init(name: "soon", value: "2", domain: "apple.com", hostOnly: false, path: "/", secure: true, expires: t0.addingTimeInterval(600)),
            .init(name: "later", value: "3", domain: "apple.com", hostOnly: false, path: "/", secure: true, expires: t0.addingTimeInterval(7200)),
            .init(name: "session", value: "4", domain: "apple.com", hostOnly: false, path: "/", secure: true, expires: nil),
        ])
        XCTAssertEqual(jar.snapshot().map(\.name), ["soon", "later", "session"])
        XCTAssertEqual(jar.earliestExpiry, t0.addingTimeInterval(600))
        clock.now = t0.addingTimeInterval(601)
        XCTAssertEqual(jar.earliestExpiry, t0.addingTimeInterval(7200))
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date {
        get { lock.withLock { t } }
        set { lock.withLock { t = newValue } }
    }
}
