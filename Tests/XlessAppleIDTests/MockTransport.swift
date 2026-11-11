import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessAppleID

/// A scripted Apple: `handler` answers each request; every request is recorded.
final class MockTransport: AppleTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Reply {
            var h = headers
            h["Content-Type"] = "application/json"
            return Reply(status: status, headers: h, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: @Sendable (URLRequest) throws -> Reply

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let r = try handler(request)
        return (r.body, response(request, r))
    }

    func download(_ request: URLRequest, to file: URL, append: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        lock.withLock { _requests.append(request) }
        let r = try handler(request)
        if (200..<300).contains(r.status) {
            if append, let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(r.body); h.closeFile()
            } else {
                try r.body.write(to: file)
            }
            progress(Int64(r.body.count))
        }
        return response(request, r)
    }

    private func response(_ request: URLRequest, _ r: Reply) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
    }
}

extension URLRequest {
    var bodyString: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    func header(_ name: String) -> String? { value(forHTTPHeaderField: name) }
}
