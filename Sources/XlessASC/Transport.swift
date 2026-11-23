import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Sends `request` and hands a 2xx response's body to `chunk` piece by piece as it arrives, never holding it whole
    /// (a report download). Any other response's body is returned instead (at most `streamErrorLimit` bytes), for its
    /// error. An error `chunk` throws stops the transfer and is rethrown.
    func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data)
}

/// The most of a non-2xx streamed response's body kept for its error.
public let streamErrorLimit = 1 << 20

extension HTTPTransport {
    /// For transports that only have `send` (test fakes): the body arrives in one piece.
    public func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { return (response, data.prefix(streamErrorLimit)) }
        if !data.isEmpty { try chunk(data) }
        return (response, Data())
    }
}

/// The real transport. Every request goes through one ephemeral session (no cookie storage, no cache) that never
/// follows a redirect by itself: `HTTPRedirect` decides each hop, so the `Authorization` header (the API key's token)
/// never reaches another origin, and an https request is never redirected to plain http.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Body()
        let (response, errorBody) = try await follow(request, errorLimit: Int.max) { data in body.append(data) }
        return ((200..<300).contains(response.statusCode) ? body.data : errorBody, response)
    }

    public func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        try await follow(request, errorLimit: streamErrorLimit, chunk: chunk)
    }

    /// One exchange per hop. A redirect's own body is never handed to `chunk` (it is not a 2xx).
    private func follow(_ first: URLRequest, errorLimit: Int, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        var request = first
        var hops = 0
        while true {
            let (response, errorBody) = try await NoRedirectSession.shared.exchange(request, errorLimit: errorLimit, chunk: chunk)
            guard let next = try HTTPRedirect.next(after: request, response: response) else { return (response, errorBody) }
            hops += 1
            guard hops <= HTTPRedirect.maxHops else { throw URLError(.httpTooManyRedirects) }
            request = next
        }
    }
}

/// A whole body, gathered piece by piece.
private final class Body: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    func append(_ data: Data) { lock.withLock { stored.append(data) } }
    var data: Data { lock.withLock { stored } }
}

/// The one URLSession `URLSessionTransport` uses, and its delegate. Delegate-driven data tasks only: for a task with a
/// completion handler, swift-corelibs-foundation follows redirects without asking the delegate.
final class NoRedirectSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = NoRedirectSession()

    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Ephemeral: nothing of a body (a financial report) is kept in a disk cache.
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Sends `request` without following a redirect: a 2xx body goes to `chunk` as it arrives, any other body (at most
    /// `errorLimit` bytes) comes back with the response.
    func exchange(_ request: URLRequest, errorLimit: Int, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { exchanges[task.taskIdentifier] = Exchange(continuation, errorLimit: errorLimit, chunk: chunk) }
                if Task.isCancelled, lock.withLock({ exchanges.removeValue(forKey: task.taskIdentifier) }) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func exchange(for task: URLSessionTask) -> Exchange? { lock.withLock { exchanges[task.taskIdentifier] } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // the 3xx is the answer; URLSessionTransport decides
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        exchange(for: dataTask)?.response = http
        completionHandler(http == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask), exchange.failure == nil else { return }
        if exchange.isSuccess {
            do { try exchange.chunk(data) } catch {
                exchange.failure = error
                dataTask.cancel()
            }
        } else if exchange.errorBody.count < exchange.errorLimit {
            exchange.errorBody.append(data.prefix(exchange.errorLimit - exchange.errorBody.count))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = lock.withLock({ exchanges.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = exchange.failure {
            exchange.continuation.resume(throwing: failure)
        } else if let error {
            exchange.continuation.resume(throwing: error)
        } else if let response = exchange.response ?? (task.response as? HTTPURLResponse) {
            exchange.continuation.resume(returning: (response, exchange.isSuccess ? Data() : exchange.errorBody))
        } else {
            exchange.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// One task's state; its callbacks arrive one at a time on the session's serial delegate queue.
private final class Exchange: @unchecked Sendable {
    let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
    let errorLimit: Int
    let chunk: @Sendable (Data) throws -> Void
    var response: HTTPURLResponse?
    var errorBody = Data()
    var failure: Error?

    init(_ continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>, errorLimit: Int, chunk: @escaping @Sendable (Data) throws -> Void) {
        self.continuation = continuation; self.errorLimit = errorLimit; self.chunk = chunk
    }

    var isSuccess: Bool { (200..<300).contains(response?.statusCode ?? 0) }
}
