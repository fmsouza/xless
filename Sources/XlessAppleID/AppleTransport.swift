import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange with Apple. Neither call follows redirects (a 3xx comes back as the response) and neither stores
/// or sends cookies: `AppleWebClient` does both, so it decides which host gets which cookie.
public protocol AppleTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a binary 2xx body into `file`: a 206 (Partial Content) is appended, any other 2xx replaces the file.
    /// `progress` gets each written chunk's byte count. Any other response, and an HTML body (Apple's "unauthorized"
    /// page), writes nothing; its body (at most 64 KB) is returned instead.
    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse)
}

/// The real transport: an ephemeral URLSession with no cookie storage, no cache and no automatic redirects, so nothing
/// of the session reaches the disk.
public final class URLSessionAppleTransport: NSObject, AppleTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        let file: URL?
        let progress: (@Sendable (Int64) -> Void)?
        var handle: FileHandle?
        var body = Data()
        var writeError: Error?
        init(_ c: CheckedContinuation<(Data, HTTPURLResponse), Error>, file: URL?, progress: (@Sendable (Int64) -> Void)?) {
            continuation = c; self.file = file; self.progress = progress
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 300 // the wait for more data, not the whole transfer
        config.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Ends the session (it holds this delegate strongly until invalidated).
    public func invalidate() { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run(request, file: nil, progress: nil)
    }

    public func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await run(request, file: file, progress: progress)
    }

    /// An HTML body: what Apple serves instead of a file it will not hand out.
    static func isHTML(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") ?? false
    }

    private func run(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { c in
            let task = session.dataTask(with: request)
            lock.withLock { pending[task.taskIdentifier] = Pending(c, file: file, progress: progress) }
            task.resume()
        }
    }

    private func state(_ task: URLSessionTask) -> Pending? { lock.withLock { pending[task.taskIdentifier] } }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let p = state(dataTask), let file = p.file, let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode), !Self.isHTML(http) {
            do {
                if http.statusCode != 206 || !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
                    }
                }
                let h = try FileHandle(forWritingTo: file)
                h.seekToEndOfFile()
                p.handle = h
            } catch {
                p.writeError = error
                completionHandler(.cancel)
                dataTask.cancel() // swift-corelibs-foundation ignores the .cancel disposition
                return
            }
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = state(dataTask), p.writeError == nil else { return }
        if let h = p.handle {
            do {
                try h.write(contentsOf: data)
            } catch {
                // A full disk or an I/O error: stop the transfer and report it (the old write(_:) API traps instead).
                p.writeError = error
                try? h.close()
                p.handle = nil
                dataTask.cancel()
                return
            }
            p.progress?(Int64(data.count))
        } else if p.file == nil || p.body.count < 64 << 10 {
            p.body.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? p.handle?.synchronize()
        try? p.handle?.close()
        if let e = p.writeError ?? error {
            p.continuation.resume(throwing: e)
        } else if let http = task.response as? HTTPURLResponse {
            p.continuation.resume(returning: (p.body, http))
        } else {
            p.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
