import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessASC

final class TraceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func append(_ s: String) { lock.withLock { all.append(s) } }
    var text: String { lock.withLock { all.joined(separator: "\n") } }
}

/// An ASCClient on a traced transport: the request and response show, the JWT never does.
@Test func tracedAPICallsHideTheBearerToken() async throws {
    let mock = MockTransport([(200, #"{"data":[{"type":"apps","id":"1","attributes":{"name":"A"}}]}"#)])
    let lines = TraceLines()
    let client = ASCClient(credentials: testCreds, transport: TracingTransport(mock, trace: HTTPTrace { lines.append($0) }), sleep: { _ in })
    let _: ASCDocument<[ASCResource<Named>]> = try await client.get("/v1/apps", query: [("filter[bundleId]", "a.b")])
    let bearer = try #require(mock.requests.first?.value(forHTTPHeaderField: "Authorization"))
    let jwt = String(bearer.dropFirst("Bearer ".count))
    #expect(!lines.text.contains(jwt))
    #expect(!lines.text.contains("Bearer"))
    #expect(lines.text.contains("> GET https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D=a.b"))
    #expect(lines.text.contains("> Authorization: <redacted>"))
    #expect(lines.text.contains(#"< {"data":[{"attributes":{"name":"A"},"id":"1","type":"apps"}]}"#))
}

/// Storage uploads go through `raw` to presigned URLs: their query (the signature) never shows; failures are traced.
@Test func tracedUploadsHidePresignedQueriesAndTraceFailures() async throws {
    let mock = MockTransport(steps: [.failure(.timedOut), .response(200, "")])
    let lines = TraceLines()
    let client = ASCClient(credentials: testCreds, transport: TracingTransport(mock, trace: HTTPTrace { lines.append($0) }), sleep: { _ in })
    var put = URLRequest(url: URL(string: "https://store-031.blobstore.apple.com/up/part1?X-Amz-Signature=FAKE-SIG")!)
    put.httpMethod = "PUT"
    put.httpBody = Data([0x00, 0x01, 0x02])
    _ = try await client.raw(put)
    #expect(!lines.text.contains("FAKE-SIG"))
    #expect(lines.text.contains("! https://store-031.blobstore.apple.com/up/part1?<redacted> failed: URLError -1001"))
    #expect(lines.text.contains("> <3 bytes>"))
}
