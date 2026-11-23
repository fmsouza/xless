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

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        try Task.checkCancellation()
        let delegate = StreamingDelegate(chunk: chunk)
        // Ephemeral: nothing of the body (a financial report) is kept in a disk cache.
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

/// The delegate of one streamed request: its callbacks arrive one at a time on the session's serial queue.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let chunk: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var failure: Error?

    init(chunk: @escaping @Sendable (Data) throws -> Void) { self.chunk = chunk }

    func start(_ continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>) {
        lock.withLock { self.continuation = continuation }
    }

    private var isSuccess: Bool { (200..<300).contains(response?.statusCode ?? 0) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(self.response == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if isSuccess {
            do { try chunk(data) } catch {
                failure = error
                dataTask.cancel()
            }
        } else if errorBody.count < streamErrorLimit {
            errorBody.append(data.prefix(streamErrorLimit - errorBody.count))
        }
    }

    /// A redirect to another host is followed without the request's `Authorization` header: the API key's token is
    /// only ever sent to the host it was made for.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<(HTTPURLResponse, Data), Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success((response, isSuccess ? Data() : errorBody))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        let continuation = lock.withLock { () -> CheckedContinuation<(HTTPURLResponse, Data), Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
