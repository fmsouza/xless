import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request outside a resource's service: what `xless api` was asked to send, the requests of `store push`'s plan, a media
/// file. `ASCClient`'s own calls stay inside XlessASC, so everything else has this name in its file (PathOwnersTests lists
/// the files that may).
public struct ASCDirectRequests: Sendable {
    private let client: ASCClient

    public init(client: ASCClient) { self.client = client }
    public init(resources: ASCResources) { client = resources.client }

    /// `ASCClient.request`: the response as received; a non-2xx one throws `ASCError`.
    public func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
                        maxAttempts: Int = ASCClient.maxAttempts) async throws -> ASCResponse {
        try await client.request(method, path, query: query, body: body, maxAttempts: maxAttempts)
    }

    /// `ASCClient.download`: `request` as it is, without credentials, its body handed to a sink as it arrives.
    public func download(_ request: URLRequest, open: () throws -> @Sendable (Data) throws -> Void) async throws {
        try await client.download(request, open: open)
    }
}
