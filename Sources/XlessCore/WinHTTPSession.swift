#if os(Windows)
import CXlessWindows
import Foundation
import FoundationNetworking

/// HTTP on Windows, where Foundation's own cannot send more than 64 KB (swift-corelibs-foundation #5532): WinHTTP, with the system's TLS
/// (1.2 or later), certificates and proxy. Like the URLSession of the other systems: nothing is stored, no cookie kept or sent, no
/// redirect followed. No name or password of Windows goes to a server or a proxy, and what a proxy answers instead of the server is an error.
public final class WinHTTPSession: @unchecked Sendable {
    /// For the life of the process.
    public static let shared = Result { try WinHTTPSession(env: ProcessInfo.processInfo.environment) }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Exchange] = [:]

    public init(env: [String: String]) throws {
        let proxy = try WinHTTPProxy(env: env)
        var code: UInt32 = 0
        let (kind, list, bypass): (Int32, String, String) = switch proxy {
        case .system: (Int32(XLESS_HTTP_PROXY_SYSTEM.rawValue), "", "")
        case .none: (Int32(XLESS_HTTP_PROXY_NONE.rawValue), "", "")
        case .named(let list, let bypass): (Int32(XLESS_HTTP_PROXY_NAMED.rawValue), list, bypass)
        }
        guard let handle = list.withWide({ list in bypass.withWide { xless_http_open(kind, list, $0, &code) } }) else {
            throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "WinHTTP cannot be used: \(WindowsError.text(code))"])
        }
        self.handle = handle
    }

    deinit { xless_http_close(handle) }

    /// Sends `request` and gives its answer to `response`, then the body to `body` piece by piece as it arrives; an error that either
    /// throws ends the transfer and is thrown. `idle`: how long nothing may happen, unless the request says more. A cancelled task's
    /// request ends at once.
    public func exchange(_ request: URLRequest, idle: TimeInterval = 60, response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                         body: @escaping @Sendable (Data) throws -> Void) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let exchange = Exchange()
        lock.withLock { running[ObjectIdentifier(exchange)] = exchange }
        defer { lock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(exchange)) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                // A thread of its own: every step of it waits.
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try exchange.run(handle, request, idle: idle, response: response, body: body) })
                }
                thread.stackSize = 1 << 20
                thread.start()
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    /// Every request that is under way fails as cancelled.
    public func cancelAll() { lock.withLock { Array(running.values) }.forEach { $0.cancel() } }

    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: OpaquePointer?
        private var cancelled = false

        func cancel() {
            lock.withLock {
                cancelled = true
                if let handle { xless_http_cancel(handle) }
            }
        }

        func run(_ session: OpaquePointer, _ request: URLRequest, idle: TimeInterval, response: (HTTPURLResponse) throws -> Void, body: (Data) throws -> Void) throws -> HTTPURLResponse {
            let wire = try WinHTTPRequest(request)
            let seconds = max(idle, request.timeoutInterval)
            var code: UInt32 = 0
            let begun = wire.withRequest(timeout: UInt32(min(max(seconds, 1), 86400) * 1000)) { xless_http_begin(session, $0, &code) }
            guard let begun else { throw failure(code, wire, nil) }
            let usable = lock.withLock { () -> Bool in
                handle = begun
                return !cancelled
            }
            defer {
                lock.withLock { handle = nil }
                xless_http_end(begun)
            }
            func check(_ code: UInt32) throws { if code != 0 { throw failure(code, wire, begun) } }
            guard usable else { throw URLError(.cancelled) }

            let sent = wire.body
            try check(xless_http_send(begun, UInt32(sent.count)))
            var offset = sent.startIndex
            while offset < sent.endIndex {
                let end = min(offset + (64 << 10), sent.endIndex)
                try check(sent[offset..<end].withUnsafeBytes { xless_http_write(begun, $0.baseAddress, $0.count) })
                offset = end
            }
            var status: Int32 = 0
            try check(xless_http_receive(begun, &status))
            let headers = WinHTTPHeaders.parse(rawHeaders(begun))
            // A proxy's own answer is no server's, over plain HTTP too.
            if status == 407 { throw URLError(.cannotConnectToHost, userInfo: wire.info("the proxy wants a name and a password, which xless never sends it")) }
            guard let answer = HTTPURLResponse(url: wire.url, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
            try response(answer)

            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            defer { buffer.withUnsafeMutableBytes { SecretBytes.zero($0) } }
            var received: Int64 = 0
            while true {
                let got = buffer.withUnsafeMutableBytes { xless_http_read(begun, $0.baseAddress, $0.count, &code) }
                if got < 0 { throw failure(code, wire, begun) }
                if got == 0 { break }
                received += got
                try body(Data(buffer[0..<Int(got)]))
            }
            // Cut short is not whole, whatever WinHTTP made of it; of a body that was packed the length is another one.
            if wire.method != "HEAD", ![204, 304].contains(status), answer.value(forHTTPHeaderField: "Content-Encoding") == nil,
               let length = answer.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length != received {
                throw URLError(.networkConnectionLost, userInfo: wire.info("the connection ended after \(received) of \(length) bytes"))
            }
            return answer
        }

        private func rawHeaders(_ exchange: OpaquePointer) -> String {
            var text = [UInt16](repeating: 0, count: 8 << 10)
            var length = xless_http_headers(exchange, &text, text.count)
            if length > text.count {
                text = [UInt16](repeating: 0, count: length)
                length = xless_http_headers(exchange, &text, text.count)
            }
            return length <= text.count ? String(decoding: text.prefix(length), as: UTF16.self) : ""
        }

        private func failure(_ code: UInt32, _ request: WinHTTPRequest, _ exchange: OpaquePointer?) -> any Error {
            if lock.withLock({ cancelled }) { return URLError(.cancelled) }
            let secure = exchange.map { xless_http_secure_failure($0) } ?? 0
            let (kind, why) = WinHTTPFailure.of(code, secure: secure)
            return URLError(kind, userInfo: request.info("\(why) (\(request.host))"))
        }
    }
}

/// What a URLRequest is for WinHTTP.
struct WinHTTPRequest {
    let url: URL
    let method: String
    let host: String
    let port: UInt16
    let https: Bool
    /// The path and the query as the URL has them.
    let target: String
    let headers: String
    let body: Data

    init(_ request: URLRequest) throws {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw URLError(.unsupportedURL) }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        guard let parts, let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { throw URLError(.badURL) }
        self.url = url
        self.host = host
        https = scheme == "https"
        guard let port = UInt16(exactly: parts.port ?? (https ? 443 : 80)), port > 0 else { throw URLError(.badURL) }
        self.port = port
        let path = parts.percentEncodedPath
        target = (path.isEmpty ? "/" : path) + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        method = request.httpMethod ?? "GET"
        guard request.httpBodyStream == nil else { throw URLError(.requestBodyStreamExhausted) }
        body = request.httpBody ?? Data()
        guard body.count <= Int(Int32.max) else { throw URLError(.dataLengthExceedsMaximum) }
        var lines = ""
        var agent = false
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            if ["content-length", "host"].contains(name.lowercased()) { continue } // WinHTTP's to say
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0 != ":" && $0.value != 0x7F }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\t" }) else { throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "the header \(name) cannot be sent"]) }
            if name.lowercased() == "user-agent" { agent = true }
            lines += "\(name): \(value)\r\n"
        }
        if !agent { lines += "User-Agent: xless\r\n" }
        headers = lines
        for text in [method, target, host] where text.unicodeScalars.contains(where: { $0.value <= 0x20 || !$0.isASCII }) { throw URLError(.badURL) }
    }

    /// Never the query, which may hold a signature.
    func info(_ why: String) -> [String: Any] { [NSLocalizedDescriptionKey: why] }

    func withRequest<T>(timeout: UInt32, _ body: (UnsafePointer<xless_http_request>) -> T) -> T {
        method.withWide { method in
            host.withWide { host in
                target.withWide { target in
                    headers.withWide { headers in
                        var request = xless_http_request()
                        request.method = method
                        request.host = host
                        request.target = target
                        request.headers = headers
                        request.port = port
                        request.https = https ? 1 : 0
                        request.timeout_ms = timeout
                        return body(&request)
                    }
                }
            }
        }
    }
}
#endif
