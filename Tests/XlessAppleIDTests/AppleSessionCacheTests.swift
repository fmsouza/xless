import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

/// The kernel keyring, played in memory: values copied in and out, expiry by the test's clock, revocations counted.
final class MemoryKeyStore: SessionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (bytes: [UInt8], until: Date)] = [:]
    let clock: TestClock
    var available = true
    private(set) var timeouts: [String: Int] = [:]

    init(clock: TestClock) { self.clock = clock }

    var isAvailable: Bool { available }

    func put(_ name: String, _ secret: SecretBytes, seconds: Int) throws {
        let bytes = secret.withUnsafeBytes { Array($0) }
        lock.withLock {
            items[name] = (bytes, clock.now.addingTimeInterval(TimeInterval(seconds)))
            timeouts[name] = seconds
        }
    }

    func get(_ name: String) throws -> SecretBytes? {
        lock.withLock {
            guard let item = items[name], item.until > clock.now else { return nil }
            return SecretBytes(copying: item.bytes)
        }
    }

    func revoke(_ name: String) throws -> Bool { lock.withLock { items.removeValue(forKey: name) != nil } }

    func raw(_ name: String) -> [UInt8]? { lock.withLock { items[name]?.bytes } }
    func tamper(_ name: String) { lock.withLock { items[name]?.bytes[20] ^= 0xFF } }
    var names: [String] { lock.withLock { items.keys.sorted() } }
}

final class AppleSessionCacheTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    /// A client whose jar holds Apple's session cookies (`myacinfo` until `expiry`, plus a session cookie).
    func signedInClient(clock: TestClock, expiry: TimeInterval? = 7200) async throws -> AppleWebClient {
        let mock = MockTransport { _ in
            var cookie = "myacinfo=COOKIE-SECRET-1; Domain=.apple.com; Path=/; Secure"
            if let expiry { cookie += "; Max-Age=\(Int(expiry))" }
            return .init(status: 200, headers: ["Set-Cookie": cookie + ", dqsid=COOKIE-SECRET-2; Path=/; Secure"])
        }
        let web = AppleWebClient(transport: mock, userAgent: "t", stage: .account, jar: CookieJar(now: { clock.now }))
        _ = try await web.send(URLRequest(url: URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!))
        return web
    }

    func testKeepsAndRestoresTheSessionSealed() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        let web = try await signedInClient(clock: clock)
        let info = try await cache.keep(web, appleID: "me@example.com", seconds: 1800)
        XCTAssertEqual(info.expires, t0.addingTimeInterval(1800))
        XCTAssertEqual(store.names, ["xless-apple-session", "xless-apple-session-key"])
        XCTAssertEqual(store.timeouts["xless-apple-session"], 1800)
        // Sealed: the cookie values are nowhere in the keyring in clear.
        let blob = String(decoding: store.raw("xless-apple-session") ?? [], as: UTF8.self)
        XCTAssertFalse(blob.contains("COOKIE-SECRET"))
        XCTAssertFalse(blob.contains("me@example.com"))

        let fresh = AppleWebClient(transport: MockTransport { _ in .init(status: 200) }, stage: .account, jar: CookieJar(now: { clock.now }))
        let restored = await cache.restore(into: fresh)
        XCTAssertEqual(restored, info)
        let header = await fresh.cookieSnapshot().map { "\($0.name)=\($0.value)" }.sorted()
        XCTAssertEqual(header, ["dqsid=COOKIE-SECRET-2", "myacinfo=COOKIE-SECRET-1"])
        XCTAssertEqual(cache.info()?.appleID, "me@example.com")
    }

    func testNeverKeptPastTheCookiesOwnExpiry() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        let info = try await cache.keep(try await signedInClient(clock: clock, expiry: 900), appleID: "me@example.com", seconds: 3600)
        XCTAssertEqual(info.expires, t0.addingTimeInterval(900))
        XCTAssertEqual(store.timeouts["xless-apple-session-key"], 900)
        do {
            _ = try await cache.keep(try await signedInClient(clock: clock, expiry: 30), appleID: "me@example.com", seconds: 3600)
            XCTFail("expected an error")
        } catch let e as XlessError { XCTAssertTrue(e.cause.contains("too soon"), e.cause) }
    }

    func testAnExpiredSessionIsDroppedAndTreatedAsNone() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock, expiry: nil), appleID: "me@example.com", seconds: 600)
        clock.now = t0.addingTimeInterval(601)
        XCTAssertNil(cache.info())
        let web = AppleWebClient(transport: MockTransport { _ in .init(status: 200) })
        let restored = await cache.restore(into: web)
        XCTAssertNil(restored)
        let empty = await web.hasCookies
        XCTAssertFalse(empty)
    }

    func testATamperedOrHalfGoneSessionIsRevoked() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", seconds: 600)
        store.tamper("xless-apple-session")
        XCTAssertNil(cache.info())
        XCTAssertEqual(store.names, [])

        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", seconds: 600)
        _ = try store.revoke("xless-apple-session-key")
        XCTAssertNil(cache.info())
        XCTAssertEqual(store.names, [])
    }

    func testForgetSaysWhetherASessionWasKept() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        XCTAssertFalse(cache.forget())
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", seconds: 600)
        XCTAssertTrue(cache.forget())
        XCTAssertNil(cache.info())
    }

    func testKeepNeedsTheKeyring() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        store.available = false
        let cache = AppleSessionCache(store: store, now: { clock.now })
        do {
            _ = try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", seconds: 600)
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("kernel keyring"))
        }
    }

    func testKeepDurations() throws {
        XCTAssertEqual(try KeepDuration.seconds("30m"), 1800)
        XCTAssertEqual(try KeepDuration.seconds("1h"), 3600)
        XCTAssertEqual(try KeepDuration.seconds("90"), 90)
        for bad in ["0", "61m", "2h", "", "m", "-5s", "1.5h", "٣m"] {
            XCTAssertThrowsError(try KeepDuration.seconds(bad), bad)
        }
    }
}

final class AppleWebSessionTests: XCTestCase {
    func testOpenUsesAKeptSessionWithoutPrompting() async throws {
        let clock = TestClock(Date())
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store)
        let mock = MockTransport { _ in .init(status: 200, headers: ["Set-Cookie": "myacinfo=COOKIE-SECRET-1; Domain=.apple.com; Path=/"]) }
        let first = AppleWebClient(transport: mock, stage: .account)
        _ = try await first.send(URLRequest(url: URL(string: "https://idmsa.apple.com/x")!))
        try await cache.keep(first, appleID: "me@example.com", seconds: 600)

        let later = MockTransport { _ in .json(200, PortalWebClientTests.teams) }
        let session = try await AppleWebSession.open(web: AppleWebClient(transport: later, stage: .account), cache: cache) {
            XCTFail("prompted")
            throw XlessError(.account, "no terminal", fix: "")
        }
        XCTAssertEqual(session.appleID, "me@example.com")
        XCTAssertNotNil(session.kept)
        let team = try await session.selectTeam("ZZZZZ99999")
        XCTAssertEqual(team.name, "Jane Doe")
        XCTAssertEqual(later.requests.first?.header("Cookie"), "myacinfo=COOKIE-SECRET-1")
        let portalTeam = await session.portal.teamID
        XCTAssertEqual(portalTeam, "ZZZZZ99999")
    }

    func testOpenSignsInWhenNothingIsKept() async throws {
        let apple = FakeApple()
        let mock = MockTransport { try apple.handle($0) }
        let session = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account),
                                                     cache: AppleSessionCache(store: MemoryKeyStore(clock: TestClock(Date())))) {
            ScriptedPrompter(answers: ["me@example.com", "123456"], secret: FakeApple.password)
        }
        XCTAssertEqual(session.appleID, "me@example.com")
        XCTAssertNil(session.kept)
    }

    /// Nothing the session hands out (errors, info, traces) shows a cookie, `scnt` or CSRF token Apple sent.
    func testNoCookieScntOrCSRFValueInAnyOutput() async throws {
        let secrets = ["COOKIE-SECRET-1", "SCNT-SECRET", "CSRF-SECRET", "SESSION-SECRET"]
        let leaky: [String: String] = ["Set-Cookie": "myacinfo=COOKIE-SECRET-1; Domain=.apple.com; Path=/", "scnt": "SCNT-SECRET",
                                       "csrf": "CSRF-SECRET", "csrf_ts": "1", "X-Apple-ID-Session-Id": "SESSION-SECRET"]
        let statuses = Box([200, 401, 403, 500, 200])
        let mock = MockTransport { _ in
            var s = statuses.value
            let status = s.isEmpty ? 500 : s.removeFirst()
            statuses.value = s
            return status == 403
                ? .json(403, ["errors": [["detail": "Accept the agreement"]]], headers: leaky)
                : .json(status, ["resultCode": status == 200 ? 0 : 1, "teams": []], headers: leaky)
        }
        let lines = Box<[String]>([])
        let trace = HTTPTrace { line in lines.value.append(line) }
        let web = AppleWebClient(transport: TracingAppleTransport(mock, trace: trace), stage: .account)
        let session = AppleWebSession(web: web, appleID: "me@example.com", kept: nil)
        var outputs: [String] = []
        for op in [{ _ = try await session.asc.data("GET", "/olympus/v1/session") },
                   { _ = try await session.asc.data("GET", "/olympus/v1/session") },
                   { _ = try await session.asc.data("GET", "/iris/v1/apps") },
                   { _ = try await session.asc.data("POST", "/iris/v1/apps") },
                   { _ = try await session.selectTeam(nil) },
                   { _ = try await session.portal.jsonAPI("POST", "v1/x") }] as [() async throws -> Void] {
            do { try await op() } catch { outputs.append("\(error)"); outputs.append(XlessError.wrapping(error, stage: .account).description) }
        }
        let store = MemoryKeyStore(clock: TestClock(Date()))
        let cache = AppleSessionCache(store: store)
        try await cache.keep(web, appleID: "me@example.com", seconds: 600)
        outputs.append(String(describing: cache.info()))
        outputs.append(String(decoding: store.raw("xless-apple-session") ?? [], as: UTF8.self))
        outputs += lines.value
        XCTAssertGreaterThan(outputs.count, 8)
        for text in outputs { for s in secrets { XCTAssertFalse(text.contains(s), "\(s) in: \(text)") } }
    }
}
