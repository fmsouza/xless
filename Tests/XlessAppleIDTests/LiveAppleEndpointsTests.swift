import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessAppleID

/// Opt-in (XLESS_LIVE_APPLE=1): checks, against Apple itself, the unauthenticated first steps the sign-in relies on: the
/// widget key from App Store Connect's sign-out redirect and the hashcash challenge. No Apple ID or password is sent.
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
}
