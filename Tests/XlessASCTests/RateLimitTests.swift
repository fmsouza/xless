import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC

/// A transport whose responses carry headers.
final class HeaderTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, [String: String], String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, [String: String], String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, headers, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.withLock { stored } }
    var sink: @Sendable (String) -> Void { { [self] line in lock.withLock { stored.append(line) } } }
}

private let ok = #"{"data":{"type":"x","id":"1"}}"#

@Test func rateLimitHeaderParses() {
    #expect(ASCRateLimit.parse("user-hour-lim:3600;user-hour-rem:3599;") == ASCRateLimit(limit: 3600, remaining: 3599))
    #expect(ASCRateLimit.parse(" user-hour-rem:12 ; user-hour-lim:3500") == ASCRateLimit(limit: 3500, remaining: 12))
    #expect(ASCRateLimit.parse("garbage") == nil)
    #expect(ASCRateLimit.parse("user-hour-lim:3600;") == nil)
}

@Test func theMonitorWarnsOnceWhenTheHourlyBudgetIsNearlySpent() async throws {
    let lines = Lines()
    let monitor = ASCRateLimitMonitor(warn: lines.sink)
    let t = HeaderTransport([
        (200, ["X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:1000;"], ok),
        (200, ["X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:360;"], ok),
        (200, ["X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:359;"], ok),
    ])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in }, rateLimits: monitor)
    for _ in 0..<3 { let _: ASCDocument<ASCRef> = try await c.get("/v1/x") }
    #expect(monitor.latest == ASCRateLimit(limit: 3600, remaining: 359))
    #expect(lines.all.count == 1)
    #expect(lines.all.first?.contains("360 of 3600") == true)
}

@Test func a429WaitsForRetryAfter() async throws {
    let t = HeaderTransport([(429, ["Retry-After": "7"], "{}"), (200, [:], ok)])
    let rec = SleepRecorder()
    let c = ASCClient(credentials: testCreds, transport: t, sleep: rec.fn)
    let _: ASCDocument<ASCRef> = try await c.get("/v1/x")
    #expect(rec.durations == [.seconds(7)])
}

@Test func aLongRetryAfterGivesUpAtOnceAndSaysHowLong() async throws {
    let t = HeaderTransport([(429, ["Retry-After": "3600"], #"{"errors":[{"status":"429","code":"RATE_LIMIT_EXCEEDED"}]}"#), (200, [:], ok)])
    let rec = SleepRecorder()
    let c = ASCClient(credentials: testCreds, transport: t, sleep: rec.fn)
    do { let _: ASCDocument<ASCRef> = try await c.get("/v1/x"); Issue.record("expected throw") }
    catch let e as ASCError {
        #expect(e.status == 429)
        #expect(e.retryAfter == 3600)
    }
    #expect(t.requests.count == 1)
    #expect(rec.durations.isEmpty)
}

@Test func errorsCarryTheRequestAndTheSourcePointer() async throws {
    let body = #"{"errors":[{"status":"409","code":"ENTITY_ERROR.ATTRIBUTE.INVALID","title":"An attribute value is invalid.","detail":"already used","source":{"pointer":"/data/attributes/name"}}]}"#
    let t = HeaderTransport([(409, [:], body)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    do { let _: ASCEmpty = try await c.patch("/v1/apps/1", body: ASCToMany([])); Issue.record("expected throw") }
    catch let e as ASCError {
        #expect(e.method == "PATCH" && e.path == "/v1/apps/1")
        #expect(e.items.first?.source?.pointer == "/data/attributes/name")
        #expect(e.description.contains("(/data/attributes/name)"))
    }
}

@Test func requestReturnsStatusHeadersAndBody() async throws {
    let t = HeaderTransport([(200, ["Content-Type": "application/json"], ok)])
    let c = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let r = try await c.request("GET", "/v1/x", query: [("limit", "1")])
    #expect(r.status == 200)
    #expect(r.header("content-type") == "application/json")
    #expect(String(decoding: r.data, as: UTF8.self) == ok)
}
