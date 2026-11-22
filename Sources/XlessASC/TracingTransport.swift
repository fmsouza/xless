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
}
