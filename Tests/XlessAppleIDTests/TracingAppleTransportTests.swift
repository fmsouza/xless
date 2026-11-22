import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class TracingAppleTransportTests: XCTestCase {
    /// A whole sign-in (SRP, two-factor code, trust) traced: the exchanges are all there, and no password, SRP value,
    /// session header, cookie or code is.
    func testASignInTraceShowsTheExchangesAndNoCredential() async throws {
        let apple = FakeApple()
        let lines = Lines()
        let traced = TracingAppleTransport(MockTransport { try apple.handle($0) }, trace: HTTPTrace { lines.append($0) })
        let prompter = ScriptedPrompter(answers: ["me@example.com", "123456"], secret: FakeApple.password)
        try await AppleSignIn(client: AppleWebClient(transport: traced), prompter: prompter).run()
        let text = lines.text

        XCTAssertTrue(text.contains("> POST https://idmsa.apple.com/appleauth/auth/signin/complete"), text)
        XCTAssertTrue(text.contains(#""m1":"<redacted>""#), text)
        XCTAssertTrue(text.contains(#""a":"<redacted>""#), text)
        XCTAssertTrue(text.contains(#""securityCode":"<redacted>""#), text)
        for secret in [FakeApple.password, "123456", "ctoken", "myacinfo", "trusted;"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked:\n\(text)")
        }
        for line in text.split(separator: "\n") where ["scnt:", "Session-Id:", "Cookie:", "X-Apple-HC:"].contains(where: line.contains) {
            XCTAssertTrue(line.hasSuffix(": <redacted>"), String(line))
        }
    }

    func testADownloadTracesTheResponseButNotTheFile() async throws {
        let mock = MockTransport { _ in .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data("FILE-CONTENT".utf8)) }
        let lines = Lines()
        let traced = TracingAppleTransport(mock, trace: HTTPTrace { lines.append($0) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await traced.download(URLRequest(url: URL(string: "https://download.developer.apple.com/x.xip?sig=abc")!), to: file) { _ in }
        XCTAssertEqual(lines.text, """
        > GET https://download.developer.apple.com/x.xip?<redacted>
        < 200 https://download.developer.apple.com/x.xip?<redacted>
        < Content-Type: application/octet-stream
        """)
    }

    func testAFailedExchangeIsTracedAndRethrown() async {
        let lines = Lines()
        let traced = TracingAppleTransport(MockTransport { _ in throw URLError(.notConnectedToInternet) }, trace: HTTPTrace { lines.append($0) })
        do {
            _ = try await traced.send(URLRequest(url: URL(string: "https://idmsa.apple.com/appleauth/auth")!))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertTrue(lines.text.hasSuffix("! https://idmsa.apple.com/appleauth/auth failed: URLError -1009"), lines.text)
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func append(_ s: String) { lock.withLock { all.append(s) } }
    var text: String { lock.withLock { all.joined(separator: "\n") } }
}
