import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// An `HTTPTransport` that shows every exchange on a redacted `HTTPTrace` (`--verbose`): wrap the transport an
/// `ASCClient` is given, and its API calls and storage uploads (`raw`) are all traced, never their credentials.
public struct TracingTransport: HTTPTransport {
    let inner: HTTPTransport
    let trace: HTTPTrace

    public init(_ inner: HTTPTransport, trace: HTTPTrace) { self.inner = inner; self.trace = trace }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        trace.request(request)
        do {
            let (data, response) = try await inner.send(request)
            trace.response(response, body: data)
            return (data, response)
        } catch {
            trace.failure(url: request.url, error: error)
            throw error
        }
    }

    /// The request and the response's headers are traced; a streamed body only by its size.
    public func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        trace.request(request)
        let counted = ByteCounter()
        do {
            let (response, body) = try await inner.stream(request) { data in
                counted.add(data.count)
                try chunk(data)
            }
            trace.response(response, body: body.isEmpty ? nil : body)
            if (200..<300).contains(response.statusCode) { trace.note("< (\(counted.total) bytes streamed)") }
            return (response, body)
        } catch {
            trace.failure(url: request.url, error: error)
            throw error
        }
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var total: Int { lock.withLock { count } }
}
