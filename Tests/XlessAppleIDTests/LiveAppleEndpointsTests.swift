import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

/// Opt-in (XLESS_LIVE_APPLE=1): checks, against Apple itself, the unauthenticated first steps the sign-in relies on (the
/// widget key from App Store Connect's sign-out redirect and the hashcash challenge), and that the App Store Connect and
/// developer portal web clients reach their endpoints and turn a refusal without a session into an `[account]` error.
/// No Apple ID or password is sent.
final class LiveAppleEndpointsTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["XLESS_LIVE_APPLE"] == "1", "set XLESS_LIVE_APPLE=1 to talk to Apple")
    }

    func testWidgetKeyAndHashcashChallenge() async throws {
        let transport = URLSessionAppleTransport()
        defer { transport.invalidate() }
        let client = AppleWebClient(transport: transport)
        var head = URLRequest(url: AppleEndpoints.logout)
        head.httpMethod = "HEAD"
        let (_, logout) = try await client.send(head, followRedirects: false)
        XCTAssertTrue((300..<400).contains(logout.statusCode), "HTTP \(logout.statusCode)")
        let location = try XCTUnwrap(logout.value(forHTTPHeaderField: "Location"))
        let key = try XCTUnwrap(URLComponents(string: location)?.queryItems?.first { $0.name == "widgetKey" }?.value)
        XCTAssertFalse(key.isEmpty)

        var signIn = URLRequest(url: AppleEndpoints.signIn(widgetKey: key))
        signIn.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, hc) = try await client.send(signIn)
        XCTAssertEqual(hc.statusCode, 200)
        XCTAssertNotNil(hc.value(forHTTPHeaderField: "X-Apple-HC-Bits").flatMap { Int($0) })
        XCTAssertFalse((hc.value(forHTTPHeaderField: "X-Apple-HC-Challenge") ?? "").isEmpty)
    }

    func testTheWebClientsRefuseCleanlyWithoutASession() async throws {
        let transport = URLSessionAppleTransport()
        defer { transport.invalidate() }
        let web = AppleWebClient(transport: transport, stage: .account)
        let session = AppleWebSession(web: web, appleID: "nobody", kept: nil)
        let raw = try await session.asc.send("GET", "/olympus/v1/session")
        XCTAssertTrue((400..<500).contains(raw.status), "HTTP \(raw.status)")
        do { _ = try await session.asc.session(); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("App Store Connect's web interface"), e.cause)
        }
        do { _ = try await session.portal.teams(); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("developer portal") || e.cause.contains("agreements"), e.cause)
        }
    }
}
