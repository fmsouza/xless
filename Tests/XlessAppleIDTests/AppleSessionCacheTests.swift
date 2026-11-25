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

    /// The longest it keeps anything (the kernel keyring: an hour).
    var longest = HoldDuration.maximum
    private(set) var used: [String] = []

    func allowed(_ hold: SecretHold) -> Int { min(hold.seconds, longest) }

    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {
        let bytes = secret.withUnsafeBytes { Array($0) }
        lock.withLock {
            items[name] = (bytes, clock.now.addingTimeInterval(TimeInterval(hold.seconds)))
            timeouts[name] = hold.seconds
        }
    }

    func get(_ name: String, using: Bool) throws -> SecretBytes? {
        lock.withLock {
            if using { used.append(name) }
            guard let item = items[name], item.until > clock.now else { return nil }
            return SecretBytes(copying: item.bytes)
        }
    }

    func revoke(_ name: String) throws -> Bool { lock.withLock { items.removeValue(forKey: name) != nil } }

    func raw(_ name: String) -> [UInt8]? { lock.withLock { items[name]?.bytes } }
    func tamper(_ name: String) { lock.withLock { items[name]?.bytes[20] ^= 0xFF } }
    var names: [String] { lock.withLock { items.keys.sorted() } }
}

/// The secret store's entry, played in memory: opened only when it is unlocked or may be asked for.
final class MemorySavedSession: SavedSession, @unchecked Sendable {
    var bytes: [UInt8]?
    var until: Date?
    var unlocked = true
    private(set) var asked = 0
    var failure: XlessError?

    func save(_ plain: SecretBytes, expires: Date) throws {
        if let failure { throw failure }
        bytes = plain.withUnsafeBytes { Array($0) }
        until = expires
    }
    func load(asking: Bool) throws -> SecretBytes? {
        guard let bytes else { return nil }
        if !unlocked {
            guard asking else { return nil }
            asked += 1
            if let failure { throw failure }
        }
        return SecretBytes(copying: bytes)
    }
    var expires: Date? { until }
    func remove() throws -> Bool {
        defer { bytes = nil; until = nil }
        return bytes != nil
    }
}

private func hold(_ seconds: Int) -> SecretHold { SecretHold(seconds: seconds, idle: seconds, maximum: 86400) }

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

    func testASessionIsSavedForAfterARebootOnlyWhenAskedFor() async throws {
        let clock = TestClock(t0)
        let saved = MemorySavedSession()
        let cache = AppleSessionCache(store: MemoryKeyStore(clock: clock), saved: saved, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(1800))
        XCTAssertNil(saved.bytes)
        let info = try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(1800), acrossReboots: true)
        XCTAssertEqual(saved.until, info.expires)

        // After a reboot nothing is held: the saved one is opened.
        let after = AppleSessionCache(store: MemoryKeyStore(clock: clock), saved: saved, now: { clock.now })
        XCTAssertEqual(after.info(), info)
        let web = AppleWebClient(transport: MockTransport { _ in .init(status: 200) }, stage: .account, jar: CookieJar(now: { clock.now }))
        let restored = try await after.restore(into: web)
        XCTAssertEqual(restored, info)
        let cookies = await web.cookieSnapshot().map(\.name).sorted()
        XCTAssertEqual(cookies, ["dqsid", "myacinfo"])
        // A session kept without it replaces it.
        try await after.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(1800))
        XCTAssertNil(saved.bytes)
    }

    func testASavedSessionIsOpenedByTheStoreUnlockAloneAndLookingAsksNothing() async throws {
        let clock = TestClock(t0)
        let saved = MemorySavedSession()
        try await AppleSessionCache(store: MemoryKeyStore(clock: clock), saved: saved, now: { clock.now })
            .keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(1800), acrossReboots: true)
        saved.unlocked = false
        let after = AppleSessionCache(store: MemoryKeyStore(clock: clock), saved: saved, now: { clock.now })
        XCTAssertNil(after.info())
        XCTAssertNil(after.remainingHold())
        XCTAssertEqual(after.savedUntil, t0.addingTimeInterval(1800))
        XCTAssertEqual(saved.asked, 0)
        let web = AppleWebClient(transport: MockTransport { _ in .init(status: 200) })
        let restored = try await after.restore(into: web)
        XCTAssertEqual(restored?.appleID, "me@example.com")
        XCTAssertEqual(saved.asked, 1)
        // A passphrase that is not given is that error, not a sign-in.
        saved.failure = XlessError(.config, "wrong passphrase", fix: "-")
        do { _ = try await after.restore(into: web); XCTFail("expected an error") } catch let e as XlessError { XCTAssertEqual(e.cause, "wrong passphrase") }
    }

    func testASavedSessionEndsWithItsHoldAndWithForget() async throws {
        let clock = TestClock(t0)
        let saved = MemorySavedSession()
        let cache = AppleSessionCache(store: MemoryKeyStore(clock: clock), saved: saved, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600), acrossReboots: true)
        XCTAssertTrue(cache.forget())
        XCTAssertNil(saved.bytes)
        XCTAssertFalse(cache.forget())
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600), acrossReboots: true)
        clock.now = t0.addingTimeInterval(601)
        XCTAssertNil(cache.savedUntil)
        let web = AppleWebClient(transport: MockTransport { _ in .init(status: 200) })
        let restored = try await cache.restore(into: web)
        XCTAssertNil(restored)
        XCTAssertNil(saved.bytes) // and it is gone
    }

    func testASessionThatCannotBeSavedIsNotKept() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let saved = MemorySavedSession()
        saved.failure = XlessError(.config, "the store is locked", fix: "unlock it")
        for cache in [AppleSessionCache(store: store, saved: saved, now: { clock.now }), AppleSessionCache(store: store, now: { clock.now })] {
            do {
                try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600), acrossReboots: true)
                XCTFail("expected an error")
            } catch is XlessError {}
            XCTAssertEqual(store.names, [])
        }
    }

    func testARefusedSavedSessionIsSavedAgain() async throws {
        let saved = MemorySavedSession()
        let store = MemoryKeyStore(clock: TestClock(Date()))
        let cache = AppleSessionCache(store: store, saved: saved)
        let old = AppleWebClient(transport: MockTransport { _ in .init(status: 200, headers: ["Set-Cookie": "myacinfo=OLD; Domain=.apple.com; Path=/"]) }, stage: .account)
        _ = try await old.send(URLRequest(url: URL(string: "https://idmsa.apple.com/x")!))
        try await cache.keep(old, appleID: "me@example.com", hold: hold(600), acrossReboots: true)
        let first = saved.bytes
        let apple = FakeApple()
        apple.completeStatus = 200
        let mock = MockTransport { r in
            if r.url?.path == "/olympus/v1/session" || r.url?.host == "developer.apple.com" { return .init(status: 401) }
            var reply = try apple.handle(r)
            if r.url?.path.hasSuffix("/complete") == true { reply.headers["Set-Cookie"] = "myacinfo=NEW; Domain=.apple.com; Path=/; Secure" }
            return reply
        }
        let prompter = ScriptedPrompter(answers: [], secret: FakeApple.password)
        _ = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account), cache: cache) { prompter }
        XCTAssertNotNil(saved.bytes)
        XCTAssertNotEqual(saved.bytes, first)
    }

    func testKeepsAndRestoresTheSessionSealed() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        let web = try await signedInClient(clock: clock)
        let info = try await cache.keep(web, appleID: "me@example.com", hold: hold(1800))
        XCTAssertEqual(info.expires, t0.addingTimeInterval(1800))
        XCTAssertEqual(store.names, ["xless-apple-session", "xless-apple-session-key"])
        XCTAssertEqual(store.timeouts["xless-apple-session"], 1800)
        // Sealed: the cookie values are nowhere in the keyring in clear.
        let blob = String(decoding: store.raw("xless-apple-session") ?? [], as: UTF8.self)
        XCTAssertFalse(blob.contains("COOKIE-SECRET"))
        XCTAssertFalse(blob.contains("me@example.com"))

        let fresh = AppleWebClient(transport: MockTransport { _ in .init(status: 200) }, stage: .account, jar: CookieJar(now: { clock.now }))
        let restored = try await cache.restore(into: fresh)
        XCTAssertEqual(restored, info)
        let header = await fresh.cookieSnapshot().map { "\($0.name)=\($0.value)" }.sorted()
        XCTAssertEqual(header, ["dqsid=COOKIE-SECRET-2", "myacinfo=COOKIE-SECRET-1"])
        XCTAssertEqual(cache.info()?.appleID, "me@example.com")
    }

    func testNeverKeptPastTheCookiesOwnExpiry() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        let info = try await cache.keep(try await signedInClient(clock: clock, expiry: 900), appleID: "me@example.com", hold: hold(3600))
        XCTAssertEqual(info.expires, t0.addingTimeInterval(900))
        XCTAssertEqual(store.timeouts["xless-apple-session-key"], 900)
        do {
            _ = try await cache.keep(try await signedInClient(clock: clock, expiry: 30), appleID: "me@example.com", hold: hold(3600))
            XCTFail("expected an error")
        } catch let e as XlessError { XCTAssertTrue(e.cause.contains("too soon"), e.cause) }
    }

    func testAnExpiredSessionIsDroppedAndTreatedAsNone() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock, expiry: nil), appleID: "me@example.com", hold: hold(600))
        clock.now = t0.addingTimeInterval(601)
        XCTAssertNil(cache.info())
        let web = AppleWebClient(transport: MockTransport { _ in .init(status: 200) })
        let restored = try await cache.restore(into: web)
        XCTAssertNil(restored)
        let empty = await web.hasCookies
        XCTAssertFalse(empty)
    }

    func testATamperedOrHalfGoneSessionIsRevoked() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600))
        store.tamper("xless-apple-session")
        XCTAssertNil(cache.info())
        XCTAssertEqual(store.names, [])

        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600))
        _ = try store.revoke("xless-apple-session-key")
        XCTAssertNil(cache.info())
        XCTAssertEqual(store.names, [])
    }

    func testForgetSaysWhetherASessionWasKept() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        XCTAssertFalse(cache.forget())
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600))
        XCTAssertTrue(cache.forget())
        XCTAssertNil(cache.info())
    }

    func testKeepNeedsSomewhereToKeepIt() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        store.available = false
        let cache = AppleSessionCache(store: store, now: { clock.now })
        do {
            _ = try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600))
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("cannot be kept here"))
        }
    }

    func testAHoldLongerThanTheStoreAllowsIsCutToThat() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        store.longest = 3600
        let cache = AppleSessionCache(store: store, now: { clock.now })
        let info = try await cache.keep(try await signedInClient(clock: clock, expiry: nil), appleID: "me@example.com", hold: hold(28800))
        XCTAssertEqual(info.expires, t0.addingTimeInterval(3600))
        XCTAssertEqual(store.timeouts["xless-apple-session"], 3600)
    }

    func testTheSessionCookieBoundsItNotEveryCookie() async throws {
        // Apple's other cookies (a page's preference, say) may run out long before the session does.
        let clock = TestClock(t0)
        let mock = MockTransport { _ in
            .init(status: 200, headers: ["Set-Cookie": "myacinfo=COOKIE-SECRET-1; Domain=.apple.com; Path=/; Max-Age=20000, dslang=US; Path=/; Max-Age=300"])
        }
        let web = AppleWebClient(transport: mock, userAgent: "t", stage: .account, jar: CookieJar(now: { clock.now }))
        _ = try await web.send(URLRequest(url: URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!))
        let cache = AppleSessionCache(store: MemoryKeyStore(clock: clock), now: { clock.now })
        let info = try await cache.keep(web, appleID: "me@example.com", hold: hold(28800))
        XCTAssertEqual(info.expires, t0.addingTimeInterval(20000))
    }

    func testLookingAtAKeptSessionIsNotUsingIt() async throws {
        let clock = TestClock(t0)
        let store = MemoryKeyStore(clock: clock)
        let cache = AppleSessionCache(store: store, now: { clock.now })
        try await cache.keep(try await signedInClient(clock: clock), appleID: "me@example.com", hold: hold(600))
        XCTAssertNotNil(cache.info())
        XCTAssertEqual(store.used, [])
        _ = try await cache.restore(into: AppleWebClient(transport: MockTransport { _ in .init(status: 200) }))
        XCTAssertEqual(store.used, ["xless-apple-session", "xless-apple-session-key"])
    }

    func testASessionKeptByAnEarlierVersionIsRead() async throws {
        // No idle time in it (a session an older xless put in the keyring).
        let payload = try JSONDecoder().decode(AppleSessionCache.Payload.self, from: Data("""
        {"version":1,"appleID":"me@example.com","created":1,"expires":2,"cookies":[]}
        """.utf8))
        XCTAssertNil(payload.idle)
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
        try await cache.keep(first, appleID: "me@example.com", hold: hold(600))

        let later = MockTransport { r in r.url?.path == "/olympus/v1/session" ? .json(200, [:]) : .json(200, PortalWebClientTests.teams) }
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

    /// A session Apple refuses by now, with the trusted-device cookie of the sign-in that made it.
    func keptRefused(store: MemoryKeyStore, seconds: Int = 600) async throws -> AppleSessionCache {
        let cache = AppleSessionCache(store: store)
        let old = AppleWebClient(transport: MockTransport { _ in
            .init(status: 200, headers: ["Set-Cookie": "myacinfo=OLD; Domain=.apple.com; Path=/, DES5abc=TRUSTED; Domain=.idmsa.apple.com; Path=/; Max-Age=2592000"])
        }, stage: .account)
        _ = try await old.send(URLRequest(url: URL(string: "https://idmsa.apple.com/x")!))
        try await cache.keep(old, appleID: "me@example.com", hold: SecretHold(seconds: seconds, idle: 300, maximum: 86400))
        return cache
    }

    func testASessionAppleRefusesIsSignedInAgainWithTheTrustedDeviceCookieAndNoCode() async throws {
        let store = MemoryKeyStore(clock: TestClock(Date()))
        let cache = try await keptRefused(store: store)
        let apple = FakeApple()
        apple.completeStatus = 200 // Apple knows the device: no second factor
        let signInCookies = Box<[String]>([])
        let mock = MockTransport { r in
            if r.url?.path == "/olympus/v1/session" || r.url?.host == "developer.apple.com" { return .init(status: 401) }
            signInCookies.value.append(r.header("Cookie") ?? "")
            var reply = try apple.handle(r)
            if r.url?.path.hasSuffix("/complete") == true { reply.headers["Set-Cookie"] = "myacinfo=NEW; Domain=.apple.com; Path=/; Secure" }
            return reply
        }
        let prompter = ScriptedPrompter(answers: [], secret: FakeApple.password)
        let session = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account), cache: cache) { prompter }
        XCTAssertEqual(session.appleID, "me@example.com")
        XCTAssertEqual(prompter.prompts, ["Password: "]) // not the Apple ID, not a code
        XCTAssertTrue(prompter.said.contains { $0.contains("me@example.com") && $0.contains("no longer accepts") }, "\(prompter.said)")
        let complete = signInCookies.value.filter { !$0.isEmpty }
        XCTAssertFalse(complete.isEmpty)
        XCTAssertTrue(complete.allSatisfy { $0.contains("DES5abc=TRUSTED") && !$0.contains("OLD") }, "\(complete)")
        // Kept again, no longer than before.
        XCTAssertLessThanOrEqual(try XCTUnwrap(store.timeouts["xless-apple-session"]), 600)
        let again = AppleWebClient(transport: MockTransport { _ in .init(status: 200) })
        _ = try await cache.restore(into: again)
        let cookies = await again.cookieSnapshot().map { "\($0.name)=\($0.value)" }.sorted()
        XCTAssertEqual(cookies, ["DES5abc=TRUSTED", "myacinfo=NEW"])
        XCTAssertNotNil(session.kept)
    }

    func testARefusedSessionThatCannotBeSignedInAgainIsAnErrorAndDropped() async throws {
        let store = MemoryKeyStore(clock: TestClock(Date()))
        let cache = try await keptRefused(store: store)
        let mock = MockTransport { _ in .init(status: 401) }
        do {
            _ = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account), cache: cache) {
                throw XlessError(.account, "no terminal", fix: "")
            }
            XCTFail("expected an error")
        } catch let e as XlessError { XCTAssertEqual(e.cause, "no terminal") }
    }

    func testAnAppleIDWithoutAppStoreConnectKeepsItsSession() async throws {
        // App Store Connect refuses it, the developer portal does not.
        let cache = try await keptRefused(store: MemoryKeyStore(clock: TestClock(Date())))
        let mock = MockTransport { r in r.url?.path == "/olympus/v1/session" ? .init(status: 401) : .json(200, PortalWebClientTests.teams) }
        let session = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account), cache: cache) {
            XCTFail("prompted")
            throw XlessError(.account, "no terminal", fix: "")
        }
        XCTAssertNotNil(session.kept)
    }

    func testANetworkFailureIsNotARefusal() async throws {
        let cache = try await keptRefused(store: MemoryKeyStore(clock: TestClock(Date())))
        let mock = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        let session = try await AppleWebSession.open(web: AppleWebClient(transport: mock, stage: .account), cache: cache) {
            XCTFail("prompted")
            throw XlessError(.account, "no terminal", fix: "")
        }
        XCTAssertNotNil(session.kept)
        XCTAssertNotNil(cache.info())
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
        try await cache.keep(web, appleID: "me@example.com", hold: hold(600))
        outputs.append(String(describing: cache.info()))
        outputs.append(String(decoding: store.raw("xless-apple-session") ?? [], as: UTF8.self))
        outputs += lines.value
        XCTAssertGreaterThan(outputs.count, 8)
        for text in outputs { for s in secrets { XCTAssertFalse(text.contains(s), "\(s) in: \(text)") } }
    }
}
