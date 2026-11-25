import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XlessASC

#if !os(Windows) // URLSession and a server on sockets: Windows gets a transport of its own
/// A real HTTP server on 127.0.0.1 that records each request (head and body) and answers from `respond`.
final class RecordingServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String] // names in lower case
        let body: Data
    }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var seen: [Request] = []
    var requests: [Request] { lock.withLock { seen } }

    init(respond: @escaping @Sendable (Request) -> (Int, [String: String], Data)) throws {
        #if canImport(Darwin)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        fd = listener
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                guard let request = Self.read(client) else { close(client); continue }
                lock.withLock { seen.append(request) }
                let (status, headers, body) = respond(request)
                var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                for (k, v) in headers { head += "\(k): \(v)\r\n" }
                let reply = Data((head + "\r\n").utf8) + body
                _ = reply.withUnsafeBytes { pointer in
                    #if canImport(Glibc)
                    send(client, pointer.baseAddress, reply.count, Int32(MSG_NOSIGNAL))
                    #else
                    send(client, pointer.baseAddress, reply.count, 0)
                    #endif
                }
                close(client)
            }
        }
    }

    private static func read(_ client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let wanted = Int(headers["content-length"] ?? "0") ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= wanted {
                    return Request(method: first.first.map(String.init) ?? "", path: first.dropFirst().first.map(String.init) ?? "/",
                                   headers: headers, body: Data(body.prefix(wanted)))
                }
            }
            let n = readSocket(client, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }

    func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
}

private func readSocket(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Foundation.read(fd, buffer, count)
}
#endif

private func request(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    r.httpBody = body
    r.setValue("Bearer secret-jwt", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    r.setValue("upload-token", forHTTPHeaderField: "X-Custom-Header")
    return r
}

#if !os(Windows)
@Test func aRedirectToAnotherHostDoesNotCarryTheAuthorizationHeader() async throws {
    let target = try RecordingServer { _ in (200, ["Content-Type": "text/plain"], Data("report".utf8)) }
    defer { target.stop() }
    // Same machine, another host name and port: another origin.
    let origin = try RecordingServer { _ in (302, ["Location": "http://localhost:\(target.port)/file?sig=1"], Data()) }
    defer { origin.stop() }

    let (data, response) = try await URLSessionTransport().send(request("http://127.0.0.1:\(origin.port)/v1/report"))
    #expect(response.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "report")
    #expect(origin.requests.first?.headers["authorization"] == "Bearer secret-jwt")
    let followed = try #require(target.requests.first)
    #expect(followed.path == "/file?sig=1")
    #expect(followed.headers["authorization"] == nil)
    #expect(followed.headers["x-custom-header"] == nil) // only Accept, User-Agent and Range follow to another host
    #expect(followed.headers["accept"] == "application/json")
}

@Test func aStreamedDownloadFollowsTheRedirectWithoutTheAuthorizationHeader() async throws {
    let target = try RecordingServer { _ in (200, ["Content-Type": "application/a-gzip"], Data(repeating: 7, count: 300_000)) }
    defer { target.stop() }
    let origin = try RecordingServer { _ in (307, ["Location": "http://localhost:\(target.port)/blob"], Data("moved".utf8)) }
    defer { origin.stop() }

    let got = Got()
    let (response, errorBody) = try await URLSessionTransport().stream(request("http://127.0.0.1:\(origin.port)/v1/salesReports")) { got.add($0) }
    #expect(response.statusCode == 200 && errorBody.isEmpty)
    #expect(got.count == 300_000) // the 307's own body is not part of the report
    #expect(target.requests.first?.headers["authorization"] == nil)
}

@Test func aRedirectWithinTheSameOriginKeepsTheAuthorizationHeader() async throws {
    let server = try RecordingServer { r in
        r.path == "/v1/apps" ? (301, ["Location": "/v1/apps/"], Data()) : (200, [:], Data("{}".utf8))
    }
    defer { server.stop() }
    let (_, response) = try await URLSessionTransport().send(request("http://127.0.0.1:\(server.port)/v1/apps"))
    #expect(response.statusCode == 200)
    #expect(server.requests.map(\.path) == ["/v1/apps", "/v1/apps/"])
    #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Bearer secret-jwt" && $0.headers["x-custom-header"] == "upload-token" })
}

@Test func aSeeOtherAfterAPostBecomesAGetWithoutABody() async throws {
    let server = try RecordingServer { r in
        r.path == "/create" ? (303, ["Location": "/result"], Data()) : (200, [:], Data("done".utf8))
    }
    defer { server.stop() }
    var post = request("http://127.0.0.1:\(server.port)/create", method: "POST", body: Data(#"{"a":1}"#.utf8))
    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await URLSessionTransport().send(post)
    let followed = try #require(server.requests.last)
    #expect(followed.method == "GET" && followed.path == "/result")
    #expect(followed.body.isEmpty && followed.headers["content-type"] == nil)
}

@Test func endlessRedirectsFail() async throws {
    let server = try RecordingServer { r in (302, ["Location": r.path + "x"], Data()) }
    defer { server.stop() }
    await #expect(throws: TooManyRedirects.self) {
        _ = try await URLSessionTransport().send(request("http://127.0.0.1:\(server.port)/a"))
    }
    #expect(server.requests.count == HTTPRedirect.maxHops + 1)
}

@Test func errorBodiesComeBackWhole() async throws {
    let big = Data(repeating: UInt8(ascii: "e"), count: 2 << 20)
    let server = try RecordingServer { _ in (500, [:], big) }
    defer { server.stop() }
    let (data, response) = try await URLSessionTransport().send(request("http://127.0.0.1:\(server.port)/v1/apps"))
    #expect(response.statusCode == 500 && data == big)
}

@Test func aBodyIsNeverRedirectedToAnotherHost() async throws {
    let target = try RecordingServer { _ in (200, [:], Data()) }
    defer { target.stop() }
    let origin = try RecordingServer { _ in (307, ["Location": "http://localhost:\(target.port)/v1/betaAppReviewDetails/1"], Data()) }
    defer { origin.stop() }
    let patch = request("http://127.0.0.1:\(origin.port)/v1/betaAppReviewDetails/1", method: "PATCH", body: Data(#"{"demoAccountPassword":"pw"}"#.utf8))
    await #expect(throws: RedirectRefused(host: "localhost", reason: .bodyToAnotherOrigin)) {
        _ = try await URLSessionTransport().send(patch)
    }
    #expect(target.requests.isEmpty)
}

@Test func aCancelledRequestEnds() async throws {
    // It answers only at the end of the test, or long after a slow machine would have cancelled it.
    let end = DispatchSemaphore(value: 0)
    let server = try RecordingServer { _ in _ = end.wait(timeout: .now() + 60); return (200, [:], Data()) }
    defer { end.signal(); server.stop() }
    let started = Date()
    let task = Task { try await URLSessionTransport().send(request("http://127.0.0.1:\(server.port)/slow")) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(Date().timeIntervalSince(started) < 50)
}

private final class Got: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ data: Data) { lock.withLock { total += data.count } }
    var count: Int { lock.withLock { total } }
}

#endif

// MARK: the rule itself

private func response(_ status: Int, location: String?, for url: String) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: location.map { ["Location": $0] } ?? [:])!
}

@Test func anHttpsRequestIsNeverRedirectedToPlainHttp() {
    let r = request("https://api.appstoreconnect.apple.com/v1/salesReports")
    #expect(throws: RedirectRefused(host: "example.com")) {
        _ = try HTTPRedirect.next(after: r, response: response(302, location: "http://example.com/x?sig=secret", for: "https://api.appstoreconnect.apple.com/v1/salesReports"))
    }
    #expect(RedirectRefused(host: "example.com").description == "refused a redirect from https to a non-https address (example.com)")
}

@Test func temporaryAndPermanentRedirectsKeepTheMethodAndTheBody() throws {
    for status in [307, 308] {
        let r = request("https://api.appstoreconnect.apple.com/v1/a", method: "PATCH", body: Data("{}".utf8))
        let next = try #require(try HTTPRedirect.next(after: r, response: response(status, location: "/v1/b", for: "https://api.appstoreconnect.apple.com/v1/a")))
        #expect(next.httpMethod == "PATCH" && next.httpBody == Data("{}".utf8))
        #expect(next.url?.absoluteString == "https://api.appstoreconnect.apple.com/v1/b")
        #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer secret-jwt")
    }
}

@Test func anotherPortOrSchemeIsAnotherOrigin() throws {
    let r = request("https://api.appstoreconnect.apple.com/v1/a")
    for location in ["https://api.appstoreconnect.apple.com:8443/v1/a", "https://API.example.com/v1/a"] {
        let next = try #require(try HTTPRedirect.next(after: r, response: response(302, location: location, for: "https://api.appstoreconnect.apple.com/v1/a")))
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
    }
    let explicitPort = try #require(try HTTPRedirect.next(after: r, response: response(302, location: "https://API.appstoreconnect.apple.com:443/v1/b", for: "https://api.appstoreconnect.apple.com/v1/a")))
    #expect(explicitPort.value(forHTTPHeaderField: "Authorization") == "Bearer secret-jwt")
}

@Test func responsesThatAreNoUsableRedirectAreAnswers() throws {
    let r = request("https://api.appstoreconnect.apple.com/v1/a")
    #expect(try HTTPRedirect.next(after: r, response: response(200, location: "/x", for: "https://api.appstoreconnect.apple.com/v1/a")) == nil)
    #expect(try HTTPRedirect.next(after: r, response: response(304, location: "/x", for: "https://api.appstoreconnect.apple.com/v1/a")) == nil)
    #expect(try HTTPRedirect.next(after: r, response: response(302, location: nil, for: "https://api.appstoreconnect.apple.com/v1/a")) == nil)
}
