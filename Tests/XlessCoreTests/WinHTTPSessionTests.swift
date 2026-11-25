#if os(Windows)
import CXlessWindowsTestSupport
import Foundation
import FoundationNetworking
import Testing
@testable import XlessCore

// Against servers on 127.0.0.1 (Tests/windows/https.test.ps1 has what TLS refuses).

private struct Received: Sendable {
    var head = ""
    var body = Data()
    func header(_ name: String) -> String? {
        head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("\(name.lowercased()):") }.map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
    }
    var line: String { head.components(separatedBy: "\r\n").first ?? "" }
}

/// Gives every connection to `serve`, one after the other.
private final class Server: @unchecked Sendable {
    let port: UInt16
    private let listener: Int
    private let lock = NSLock()
    private var seen: [Received] = []
    var requests: [Received] { lock.withLock { seen } }

    init(_ serve: @escaping @Sendable (Int, Received) -> Void) throws {
        var free: UInt16 = 0
        listener = xless_test_listen(&free)
        guard listener >= 0 else { throw URLError(.cannotConnectToHost) }
        port = free
        Thread.detachNewThread { [self] in
            while true {
                let connection = xless_test_accept(listener)
                if connection < 0 { return }
                guard let request = Self.receive(connection) else { xless_test_close(connection); continue }
                lock.withLock { seen.append(request) }
                serve(connection, request)
                xless_test_finish(connection)
            }
        }
    }

    func stop() { xless_test_stop(listener) }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private static func receive(_ connection: Int) -> Received? {
        var all = Data()
        var piece = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let end = all.range(of: Data("\r\n\r\n".utf8)) {
                var request = Received(head: String(decoding: all[..<end.lowerBound], as: UTF8.self))
                request.body = Data(all[end.upperBound...])
                if request.body.count >= Int(request.header("Content-Length") ?? "0") ?? 0 { return request }
            }
            let got = xless_test_receive(connection, &piece, piece.count)
            if got <= 0 { return nil }
            all.append(contentsOf: piece.prefix(Int(got)))
        }
    }
}

/// What keeps a server silent until the test has what it waits for: no test is about how long that takes.
private final class Gate: Sendable {
    private let opened = DispatchSemaphore(value: 0)
    func wait() {
        _ = opened.wait(timeout: .now() + 240)
        opened.signal()
    }
    func open() { opened.signal() }
}

private func put(_ connection: Int, _ text: String) { put(connection, Data(text.utf8)) }
private func put(_ connection: Int, _ data: Data) { _ = data.withUnsafeBytes { xless_test_send(connection, $0.baseAddress, $0.count) } }
private func answer(_ connection: Int, _ status: String = "200 OK", _ headers: String = "", body: Data = Data()) {
    put(connection, Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(headers)\r\n".utf8) + body)
}

private final class Pieces: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Data] = []
    @Sendable func add(_ data: Data) { lock.withLock { all.append(data) } }
    var data: Data { lock.withLock { all.reduce(into: Data()) { $0.append($1) } } }
    var count: Int { lock.withLock { all.count } }
}

private func send(_ request: URLRequest, env: [String: String] = [:], idle: TimeInterval = 60) async throws -> (HTTPURLResponse, Pieces) {
    let pieces = Pieces()
    let response = try await WinHTTPSession(env: env).exchange(request, idle: idle, response: { _ in }, body: pieces.add)
    return (response, pieces)
}

private func code(_ body: () async throws -> Void) async -> URLError.Code? {
    do { try await body() } catch { return (error as? URLError)?.code }
    return nil
}

@Test(arguments: [0, 1 << 10, 64 << 10, (64 << 10) + 1, 10 << 20])
func aBodyOfAnySizeIsSentWhole(size: Int) async throws {
    let server = try Server { connection, request in answer(connection, body: Data("\(request.body.count)".utf8)) }
    defer { server.stop() }
    var request = URLRequest(url: server.url("/upload"))
    request.httpMethod = "PUT"
    request.httpBody = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
    request.setValue("image/png", forHTTPHeaderField: "Content-Type")
    let (response, body) = try await send(request)
    #expect(response.statusCode == 200 && body.data == Data("\(size)".utf8))
    let seen = try #require(server.requests.first)
    #expect(seen.line == "PUT /upload HTTP/1.1" && seen.header("Content-Length") == "\(size)" && seen.header("Content-Type") == "image/png")
    #expect(seen.body == request.httpBody)
}

@Test func aRequestIsSentAsItIs() async throws {
    let server = try Server { connection, _ in answer(connection, "200 OK", "X-Two: 1\r\nX-Two: 2\r\n", body: Data("ok".utf8)) }
    defer { server.stop() }
    let target = "/v1/a%2Fb/%C3%A9;x=1?filter%5Bid%5D=a%20b&sig=A%2BB%2F%3D%3D&plain=[x]|y+z"
    let url = URL(string: "http://127.0.0.1:\(server.port)/v1/a%2Fb/%C3%A9;x=1?filter%5Bid%5D=a%20b&sig=A%2BB%2F%3D%3D&plain=%5Bx%5D%7Cy+z")!
    var request = URLRequest(url: url)
    request.setValue("Bearer made-up", forHTTPHeaderField: "Authorization")
    let (response, body) = try await send(request)
    #expect(body.data == Data("ok".utf8) && response.value(forHTTPHeaderField: "x-two") == "1, 2")
    let seen = try #require(server.requests.first)
    #expect(seen.line == "GET " + target.replacingOccurrences(of: "[x]|", with: "%5Bx%5D%7C") + " HTTP/1.1")
    #expect(seen.header("Authorization") == "Bearer made-up" && seen.header("Host") == "127.0.0.1:\(server.port)")
    #expect(seen.header("User-Agent") == "xless" && seen.header("Cookie") == nil && seen.header("Content-Length") == nil)
    // Nothing of a line of one's own in a header.
    var bad = URLRequest(url: server.url("/"))
    bad.setValue("a\r\nX-Injected: 1", forHTTPHeaderField: "X-A")
    if bad.value(forHTTPHeaderField: "X-A")?.contains("\r") == true { #expect(await code { _ = try await send(bad) } == .badURL) }
}

@Test func noCookieIsKeptAndNoRedirectFollowed() async throws {
    let server = try Server { connection, _ in answer(connection, "302 Found", "Location: /next\r\nSet-Cookie: s=1; Path=/\r\n") }
    defer { server.stop() }
    let session = try WinHTTPSession(env: [:])
    for _ in 1...2 {
        let response = try await session.exchange(URLRequest(url: server.url("/start")), response: { _ in }, body: { _ in })
        #expect(response.statusCode == 302 && response.value(forHTTPHeaderField: "Location") == "/next" && response.value(forHTTPHeaderField: "Set-Cookie") == "s=1; Path=/")
    }
    #expect(server.requests.map(\.line) == ["GET /start HTTP/1.1", "GET /start HTTP/1.1"])
    #expect(server.requests.allSatisfy { $0.header("Cookie") == nil })
}

@Test func noNameOrPasswordOfWindowsIsSentToAServerThatAsks() async throws {
    let server = try Server { connection, _ in answer(connection, "401 Unauthorized", "WWW-Authenticate: Negotiate\r\nWWW-Authenticate: NTLM\r\nWWW-Authenticate: Basic realm=x\r\n") }
    defer { server.stop() }
    let (response, _) = try await send(URLRequest(url: server.url("/")))
    #expect(response.statusCode == 401)
    #expect(server.requests.count == 1 && server.requests[0].header("Authorization") == nil)
}

@Test func theBodyComesAsItArrivesAndAnErrorEndsIt() async throws {
    let server = try Server { connection, _ in
        put(connection, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        for i in 0..<5 {
            put(connection, "5\r\nabc\(i)\n\r\n")
            Thread.sleep(forTimeInterval: 0.2)
        }
        put(connection, "0\r\n\r\n")
    }
    defer { server.stop() }
    let (_, pieces) = try await send(URLRequest(url: server.url("/")))
    #expect(String(decoding: pieces.data, as: UTF8.self) == "abc0\nabc1\nabc2\nabc3\nabc4\n" && pieces.count > 1)
    struct Full: Error {}
    await #expect(throws: Full.self) {
        _ = try await WinHTTPSession(env: [:]).exchange(URLRequest(url: server.url("/")), response: { _ in }, body: { _ in throw Full() })
    }
    await #expect(throws: Full.self) {
        _ = try await WinHTTPSession(env: [:]).exchange(URLRequest(url: server.url("/")), response: { _ in throw Full() }, body: { _ in })
    }
}

@Test func anAnswerThatIsCutShortIsAnError() async throws {
    let server = try Server { connection, request in
        if request.line.contains("/length") { put(connection, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc") }
        else { put(connection, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n64\r\nabc") }
    }
    defer { server.stop() }
    for path in ["/length", "/chunked"] {
        let failed = await code { _ = try await send(URLRequest(url: server.url(path))) }
        #expect(failed == .networkConnectionLost || failed == .badServerResponse, "\(path): \(String(describing: failed))")
    }
}

@Test func whatIsPackedIsUnpacked() async throws {
    // gzip of "packed\n" in one stored block
    let gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF, 1, 7, 0, 0xF8, 0xFF] + "packed\n".utf8 + [0x43, 0xE0, 0x41, 0x2F, 7, 0, 0, 0])
    let server = try Server { connection, request in
        if request.header("Accept-Encoding")?.contains("gzip") == true { answer(connection, "200 OK", "Content-Encoding: gzip\r\n", body: gzip) } else { answer(connection, body: Data("packed\n".utf8)) }
    }
    defer { server.stop() }
    let (_, body) = try await send(URLRequest(url: server.url("/")))
    #expect(String(decoding: body.data, as: UTF8.self) == "packed\n")
}

@Test func answersWithoutABodyAreWhole() async throws {
    let server = try Server { connection, request in
        if request.line.hasPrefix("HEAD") { put(connection, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n") }
        else { put(connection, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") }
    }
    defer { server.stop() }
    var head = URLRequest(url: server.url("/"))
    head.httpMethod = "HEAD"
    let (response, body) = try await send(head)
    #expect(response.value(forHTTPHeaderField: "Content-Length") == "1000" && body.data.isEmpty)
    var delete = URLRequest(url: server.url("/"))
    delete.httpMethod = "DELETE"
    #expect(try await send(delete).0.statusCode == 204)
}

@Test func nobodyThereAndNoAnswerAreErrors() async throws {
    var free: UInt16 = 0
    let listener = xless_test_listen(&free)
    xless_test_close(listener)
    let refused = URLRequest(url: URL(string: "http://127.0.0.1:\(free)/")!)
    #expect(await code { _ = try await send(refused) } == .cannotConnectToHost)
    let unknown = URLRequest(url: URL(string: "http://no-such-host.invalid/")!)
    let name = await code { _ = try await send(unknown, idle: 30) }
    #expect(name == .cannotFindHost || name == .cannotConnectToHost || name == .timedOut, "\(String(describing: name))")
    let gate = Gate()
    let server = try Server { connection, request in
        if request.line.contains("silent") { gate.wait() } else { xless_test_reset(connection) }
    }
    defer {
        gate.open()
        server.stop()
    }
    #expect(await code { _ = try await send(URLRequest(url: server.url("/reset"))) } == .networkConnectionLost)
    var silent = URLRequest(url: server.url("/silent"))
    silent.timeoutInterval = 2
    #expect(await code { _ = try await send(silent, idle: 2) } == .timedOut)
}

@Test func aTrickledAnswerIsWaitedForAsLongAsItTrickles() async throws {
    let server = try Server { connection, _ in
        put(connection, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\n")
        for byte in "abcdef" {
            Thread.sleep(forTimeInterval: 1.2)
            put(connection, String(byte))
        }
    }
    defer { server.stop() }
    var request = URLRequest(url: server.url("/"))
    request.timeoutInterval = 5
    let (_, body) = try await send(request, idle: 5)
    #expect(body.data == Data("abcdef".utf8))
}

@Test(.timeLimit(.minutes(5))) func aCancelledRequestEndsAtOnce() async throws {
    let gate = Gate()
    defer { gate.open() }
    for path in ["/silent", "/body"] {
        let server = try Server { connection, request in
            if request.line.contains("body") { put(connection, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc") }
            gate.wait()
        }
        defer { server.stop() }
        let task = Task { try await send(URLRequest(url: server.url(path)), idle: 3600) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        // The server is silent until this has ended.
        do {
            _ = try await task.value
            Issue.record("a cancelled request was answered")
        } catch { #expect((error as? URLError)?.code == .cancelled || error is CancellationError, "\(error)") }
    }
    // before it began, and all of a session's
    let server = try Server { connection, _ in answer(connection) }
    defer { server.stop() }
    let early = Task { () async throws -> Void in
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await send(URLRequest(url: server.url("/x")))
    }
    await #expect(throws: CancellationError.self) { try await early.value }
    let session = try WinHTTPSession(env: [:])
    let other = try Server { _, _ in gate.wait() }
    defer { other.stop() }
    let held = Task { try await session.exchange(URLRequest(url: other.url("/")), idle: 3600, response: { _ in }, body: { _ in }) }
    var seen = false
    for _ in 0..<600 where !seen {
        try await Task.sleep(for: .milliseconds(100))
        seen = !other.requests.isEmpty
    }
    #expect(seen)
    session.cancelAll()
    #expect(await code { _ = try await held.value } == .cancelled)
}

@Test func requestsAtOnceAreEachAnswered() async throws {
    let server = try Server { connection, request in answer(connection, body: Data(request.line.utf8)) }
    defer { server.stop() }
    let session = try WinHTTPSession(env: [:])
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<24 {
            group.addTask {
                let pieces = Pieces()
                _ = try await session.exchange(URLRequest(url: server.url("/\(i)")), response: { _ in }, body: pieces.add)
                #expect(String(decoding: pieces.data, as: UTF8.self) == "GET /\(i) HTTP/1.1")
            }
        }
        try await group.waitForAll()
    }
}

@Test func aConnectionIsUsedAgainAndOneThatWasClosedMeanwhileIsNotAnAnswer() async throws {
    var free: UInt16 = 0
    let listener = xless_test_listen(&free)
    defer { xless_test_stop(listener) }
    let port = free
    let connections = Pieces()
    Thread.detachNewThread {
        while true {
            let connection = xless_test_accept(listener)
            if connection < 0 { return }
            connections.add(Data([1]))
            Thread.detachNewThread {
                var piece = [UInt8](repeating: 0, count: 4096)
                while xless_test_receive(connection, &piece, piece.count) > 0 { put(connection, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") }
                xless_test_close(connection)
            }
        }
    }
    let session = try WinHTTPSession(env: [:])
    for _ in 0..<3 {
        let pieces = Pieces()
        _ = try await session.exchange(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!), response: { _ in }, body: pieces.add)
        #expect(pieces.data == Data("ok".utf8))
    }
    #expect(connections.count >= 1)
}

@Test func theProxyOfTheVariablesIsAskedWithoutTheServersSecrets() async throws {
    let proxy = try Server { connection, request in
        if request.line.hasPrefix("CONNECT") { answer(connection, "200 OK", "", body: Data("not a tunnel".utf8)) } else { answer(connection, body: Data("by proxy".utf8)) }
    }
    defer { proxy.stop() }
    let env = ["HTTP_PROXY": "http://127.0.0.1:\(proxy.port)", "HTTPS_PROXY": "http://127.0.0.1:\(proxy.port)", "NO_PROXY": "direct.invalid"]
    let (_, body) = try await send(URLRequest(url: URL(string: "http://some.invalid/a?b=c")!), env: env)
    #expect(String(decoding: body.data, as: UTF8.self) == "by proxy")
    #expect(proxy.requests.first?.line == "GET http://some.invalid/a?b=c HTTP/1.1")
    var secret = URLRequest(url: URL(string: "https://some.invalid/token")!)
    secret.setValue("Bearer made-up", forHTTPHeaderField: "Authorization")
    secret.setValue("k=v", forHTTPHeaderField: "Cookie")
    #expect(await code { _ = try await send(secret, env: env, idle: 10) } != nil, "no TLS, no answer")
    let connect = try #require(proxy.requests.first { $0.line.hasPrefix("CONNECT") })
    #expect(connect.line == "CONNECT some.invalid:443 HTTP/1.1")
    #expect(proxy.requests.filter { $0.line.hasPrefix("CONNECT") }.allSatisfy { !$0.head.contains("made-up") && $0.header("Cookie") == nil && $0.header("Proxy-Authorization") == nil })
    // what NO_PROXY names does not go there
    let before = proxy.requests.count
    #expect(await code { _ = try await send(URLRequest(url: URL(string: "http://direct.invalid/")!), env: env, idle: 20) } != nil)
    #expect(proxy.requests.count == before)
}

@Test(arguments: ["403 Forbidden", "302 Found", "407 Proxy Authentication Required", "500 X"])
func whatAProxyAnswersInsteadOfTheServerIsNoAnswer(status: String) async throws {
    let proxy = try Server { connection, _ in
        answer(connection, status, "Proxy-Authenticate: Negotiate\r\nLocation: https://evil.invalid/\r\n", body: Data(#"{"data":[]}"#.utf8))
    }
    defer { proxy.stop() }
    let env = ["HTTPS_PROXY": "127.0.0.1:\(proxy.port)", "HTTP_PROXY": "127.0.0.1:\(proxy.port)"]
    let failed = await code { _ = try await send(URLRequest(url: URL(string: "https://some.invalid/")!), env: env, idle: 10) }
    #expect(failed != nil, "a proxy's answer to CONNECT was taken for the server's")
    #expect(proxy.requests.allSatisfy { $0.header("Proxy-Authorization") == nil })
    if status.hasPrefix("407") { #expect(await code { _ = try await send(URLRequest(url: URL(string: "http://some.invalid/")!), env: env, idle: 10) } != nil) }
}

private func header(_ name: String, _ value: String) throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:1/")))
    request.setValue(value, forHTTPHeaderField: name)
    return request
}

/// Whether xless refuses `request`. Foundation itself drops some headers that cannot be sent, and then there is nothing to refuse.
private func isRefused(_ request: URLRequest) throws -> Bool {
    do { return try WinHTTPRequest(request).headers == "User-Agent: xless\r\n" && request.allHTTPHeaderFields?.isEmpty != false }
    catch is URLError { return true }
}

@Test func whatCannotBeSentIsRefused() async throws {
    for text in ["ftp://a.invalid/", "file:///C:/x", "https:///x", "http://user:pw@127.0.0.1/"] {
        guard let url = URL(string: text) else { continue }
        #expect(await code { _ = try await send(URLRequest(url: url)) } != nil, "\(text)")
    }
    for value in ["a\r\nX: y", "a\nb", "a\u{0}b", "a\u{7F}b", "a\u{85}b", "caf\u{E9}", "a\u{010D}\u{010A}X: y", "a\u{1F4A9}"] {
        #expect(try isRefused(header("X-A", value)), "\(value.debugDescription)")
        #expect(try isRefused(header("X-\(value)", "a")), "\(value.debugDescription)")
    }
    #expect(try WinHTTPRequest(header("X-A", "a\tb ~!\"")).headers.contains("X-A: a\tb ~!\"\r\n"))
    #expect(throws: XlessError.self) { try WinHTTPSession(env: ["HTTPS_PROXY": "socks5://127.0.0.1:1"]) }
}
#endif
