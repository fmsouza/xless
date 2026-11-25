import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import XlessCore
#endif

/// One HTTP exchange with Apple. Neither call follows redirects (a 3xx comes back as the response) and neither stores
/// or sends cookies: `AppleWebClient` does both, so it decides which host gets which cookie.
public protocol AppleTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a binary 2xx body into `file`: a 206 (Partial Content) is appended, any other 2xx replaces the file. A 206
    /// whose `Content-Range` does not start where the file ends writes nothing and throws `UnexpectedRange`.
    /// `progress` gets the bytes in the file so far. Any other response, and an HTML body (Apple's "unauthorized"
    /// page), writes nothing; its body (at most 64 KB) is returned instead.
    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse)
}

/// A 206 that would not continue the file where it ends (its `Content-Range` starts elsewhere, or is missing).
public struct UnexpectedRange: Error, Sendable {
    public let expectedStart: Int64
    public let contentRange: String?
}

extension URLSessionAppleTransport {
    /// An HTML body: what Apple serves instead of a file it will not hand out.
    static func isHTML(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") ?? false
    }

    /// Where a binary 2xx body goes in a file of `existingSize` bytes: 0 (replace) for a 200, `existingSize` (append) for
    /// a 206 whose `Content-Range: bytes <start>-…` starts there, nil for any other 206.
    static func writeOffset(_ response: HTTPURLResponse, existingSize: Int64) -> Int64? {
        guard response.statusCode == 206 else { return 0 }
        guard let start = contentRange(response)?.start, start == existingSize else { return nil }
        return start
    }

    /// `Content-Range: bytes <start>-<end>/<total>` (start nil for `bytes */<total>`, total nil for `/*`).
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64?, total: Int64?)? {
        guard let v = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces),
              v.lowercased().hasPrefix("bytes "), let slash = v.lastIndex(of: "/") else { return nil }
        let range = v[v.index(v.startIndex, offsetBy: 6)..<slash].trimmingCharacters(in: .whitespaces)
        let total = Int64(v[v.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        if range == "*" { return (nil, total) }
        guard let dash = range.firstIndex(of: "-"), let start = Int64(range[..<dash]) else { return nil }
        return (start, total)
    }
}

/// The file a download goes to, once its response has come.
private final class DownloadedFile {
    private let handle: FileHandle
    private(set) var written: Int64

    /// Nil: this response's body goes to no file.
    init?(_ response: HTTPURLResponse, to file: URL) throws {
        guard (200..<300).contains(response.statusCode), !URLSessionAppleTransport.isHTML(response) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard let start = URLSessionAppleTransport.writeOffset(response, existingSize: size) else {
            throw UnexpectedRange(expectedStart: size, contentRange: response.value(forHTTPHeaderField: "Content-Range"))
        }
        if start == 0 {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        written = start
    }

    /// A full disk or an I/O error is thrown (the old write(_:) API traps instead).
    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        written += Int64(data.count)
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}

#if os(Windows)
/// The real transport: WinHTTP (`WinHTTPSession`), with no cookie storage, no cache and no automatic redirects, so nothing of the session
/// reaches the disk.
public final class URLSessionAppleTransport: AppleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Result<WinHTTPSession, any Error>?

    public init() {}

    private func session() throws -> WinHTTPSession {
        try lock.withLock {
            if let opened { return try opened.get() }
            let new = Result { try WinHTTPSession(env: ProcessInfo.processInfo.environment) }
            opened = new
            return try new.get()
        }
    }

    /// Ends the transport's work: every request still in flight is cancelled.
    public func invalidate() { (try? lock.withLock { opened }?.get())?.cancelAll() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = Answer(file: nil, progress: nil)
        let response = try await session().exchange(request, idle: 300, response: answer.begin, body: answer.add)
        return (answer.body, response)
    }

    public func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let answer = Answer(file: file, progress: progress)
        defer { answer.end() }
        let response = try await session().exchange(request, idle: 300, response: answer.begin, body: answer.add)
        return (answer.body, response)
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let file: URL?
        private let progress: (@Sendable (Int64) -> Void)?
        private var download: DownloadedFile?
        private var stored = Data()

        init(file: URL?, progress: (@Sendable (Int64) -> Void)?) { self.file = file; self.progress = progress }

        var body: Data { lock.withLock { stored } }

        @Sendable func begin(_ response: HTTPURLResponse) throws {
            guard let file else { return }
            try lock.withLock { download = try DownloadedFile(response, to: file) }
        }

        @Sendable func add(_ data: Data) throws {
            try lock.withLock {
                if let download {
                    try download.write(data)
                    progress?(download.written)
                } else if file == nil || stored.count < 64 << 10 {
                    stored.append(data)
                }
            }
        }

        func end() { lock.withLock { download?.close(); download = nil } }
    }
}
#else
/// The real transport: an ephemeral URLSession with no cookie storage, no cache and no automatic redirects, so nothing
/// of the session reaches the disk.
public final class URLSessionAppleTransport: NSObject, AppleTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        let file: URL?
        let progress: (@Sendable (Int64) -> Void)?
        var download: DownloadedFile?
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

    /// Ends the transport's work: every request still in flight is cancelled. The session itself is never invalidated,
    /// so it and this delegate (which it holds strongly) live until the process exits: on Linux, freeing a session's
    /// curl multi handle while curl still watches one of its sockets aborts the process in swift-corelibs-foundation
    /// ("_MultiHandle deallocated with non-zero retain count", swiftlang/swift-corelibs-foundation#5203). The API
    /// transport's session (`NoRedirectSession.shared`) already lives that long.
    public func invalidate() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run(request, file: nil, progress: nil)
    }

    public func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await run(request, file: file, progress: progress)
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
        if let p = state(dataTask), let file = p.file, let http = response as? HTTPURLResponse {
            do { p.download = try DownloadedFile(http, to: file) } catch {
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
        if let download = p.download {
            do { try download.write(data) } catch {
                // A full disk or an I/O error: stop the transfer and report it.
                p.writeError = error
                download.close()
                p.download = nil
                dataTask.cancel()
                return
            }
            p.progress?(download.written)
        } else if p.file == nil || p.body.count < 64 << 10 {
            p.body.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        p.download?.close()
        if let e = p.writeError ?? error {
            p.continuation.resume(throwing: e)
        } else if let http = task.response as? HTTPURLResponse {
            p.continuation.resume(returning: (p.body, http))
        } else {
            p.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
#endif
