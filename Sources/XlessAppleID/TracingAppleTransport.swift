import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// An `AppleTransport` that shows every exchange of the Apple ID web session on a redacted `HTTPTrace` (`--verbose`).
/// It sits under `AppleWebClient`, so it sees each redirect hop with the cookies the client attached, and hides them.
/// A download's file content is never traced, only the response (and the body Apple sent instead of a file).
public struct TracingAppleTransport: AppleTransport {
    let inner: AppleTransport
    let trace: HTTPTrace

    public init(_ inner: AppleTransport, trace: HTTPTrace) { self.inner = inner; self.trace = trace }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await traced(request) { try await inner.send(request) }
    }

    public func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await traced(request) { try await inner.download(request, to: file, progress: progress) }
    }

    private func traced(_ request: URLRequest, _ exchange: () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        trace.request(request)
        do {
            let (data, response) = try await exchange()
            trace.response(response, body: data)
            return (data, response)
        } catch {
            trace.failure(url: request.url, error: error)
            throw error
        }
    }
}
