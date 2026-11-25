import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import CXlessWindowsTestSupport
#endif
@testable import XlessAppleID

/// A one-request-per-connection HTTP server on 127.0.0.1, answering each request head with raw response bytes.
final class LoopbackServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    #if os(Windows)
    private let sock: Int
    #else
    private let sock: Int32
    #endif
    private let lock = NSLock()
    private var _heads: [String] = []
    var heads: [String] { lock.withLock { _heads } }
    let respond: @Sendable (String) -> Data

    init(_ respond: @escaping @Sendable (String) -> Data) throws {
        self.respond = respond
        #if os(Windows)
        var free: UInt16 = 0
        sock = xless_test_listen(&free)
        guard sock >= 0 else { throw URLError(.cannotConnectToHost) }
        port = free
        #else
        signal(SIGPIPE, SIG_IGN) // a client that hangs up mid-body must not kill the test process
        #if os(Linux)
        sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        #if !os(Linux)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, size) } }) == 0,
              listen(sock, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var bound = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        #endif
        let thread = Thread { [self] in self.serve() }
        thread.start()
    }

    #if os(Windows)
    deinit { xless_test_stop(sock) }

    private func accept(_ listener: Int, _: Int?, _: Int?) -> Int { xless_test_accept(listener) }
    private func read(_ connection: Int, _ byte: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int { Int(xless_test_receive(connection, byte, count)) }
    private func write(_ connection: Int, _ bytes: UnsafeRawPointer, _ count: Int) -> Int { Int(xless_test_send(connection, bytes, count)) }
    private func close(_ connection: Int) { xless_test_finish(connection) }
    #else
    deinit { close(sock) }
    #endif

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func serve() {
        while true {
            let c = accept(sock, nil, nil)
            if c < 0 { return }
            var head = Data()
            var byte: UInt8 = 0
            while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
                if read(c, &byte, 1) <= 0 { break }
                head.append(byte)
            }
            let text = String(decoding: head, as: UTF8.self)
            lock.withLock { _heads.append(text) }
            let reply = respond(text)
            reply.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(c, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(c)
        }
    }

    static func reply(_ status: String, _ headers: [String: String] = [:], body: Data = Data()) -> Data {
        var h = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        return Data((h + "\r\n").utf8) + body
    }
}

final class URLSessionAppleTransportTests: XCTestCase {
    var dir: URL!
    let transport = URLSessionAppleTransport()
    let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        transport.invalidate()
        try? FileManager.default.removeItem(at: dir)
    }

    #if !os(Windows)
    /// swift-corelibs-foundation aborts the process ("_MultiHandle deallocated with non-zero retain count") when a
    /// session's curl multi handle is freed while curl still watches one of its sockets (`xless live-check` died that
    /// way after its last line, on a real account). A session that ends lives on until the process exits instead.
    func testAnEndedTransportIsNeverDeallocated() async throws {
        let server = try LoopbackServer { _ in LoopbackServer.reply("200 OK", body: Data("ok".utf8)) }
        weak var ended: URLSessionAppleTransport?
        do {
            let t = URLSessionAppleTransport()
            _ = try await t.send(URLRequest(url: server.url("/a")))
            t.invalidate()
            ended = t
        }
        try await Task.sleep(nanoseconds: 500_000_000) // the session finishes invalidating on its own queue
        XCTAssertNotNil(ended, "the transport, and so its session, must outlive invalidate() until the process exits")
    }
    #endif

    func testInvalidateCancelsARequestInFlight() async throws {
        let server = try LoopbackServer { _ in Thread.sleep(forTimeInterval: 3); return LoopbackServer.reply("200 OK") }
        let t = URLSessionAppleTransport()
        let request = Task { try await t.send(URLRequest(url: server.url("/slow"))) }
        try await Task.sleep(nanoseconds: 300_000_000)
        t.invalidate()
        do {
            _ = try await request.value
            XCTFail("a request in flight when the transport ends must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    func testOKReplacesTheFileAndReportsProgress() async throws {
        let body = big
        let server = try LoopbackServer { _ in LoopbackServer.reply("200 OK", ["Content-Type": "application/octet-stream"], body: body) }
        let file = dir.appendingPathComponent("f")
        try Data("old contents".utf8).write(to: file)
        let seen = Recorder()
        let (_, response) = try await transport.download(URLRequest(url: server.url("/f")), to: file, progress: seen.add)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(seen.values.last, Int64(body.count), "progress is the bytes in the file")
    }

    func testPartialContentAppends() async throws {
        let server = try LoopbackServer { _ in
            LoopbackServer.reply("206 Partial Content", ["Content-Type": "application/octet-stream", "Content-Range": "bytes 5-8/9"], body: Data("tail".utf8))
        }
        let file = dir.appendingPathComponent("f")
        try Data("head-".utf8).write(to: file)
        let seen = Recorder()
        _ = try await transport.download(URLRequest(url: server.url("/f")), to: file, progress: seen.add)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "head-tail")
        XCTAssertEqual(seen.values.last, 9, "progress counts what was already in the file")
    }

    func testPartialContentAtAnotherOffsetIsRefused() async throws {
        for range in ["bytes 2-5/6", nil] {
            let server = try LoopbackServer { _ in
                var h = ["Content-Type": "application/octet-stream"]
                h["Content-Range"] = range
                return LoopbackServer.reply("206 Partial Content", h, body: Data("tail".utf8))
            }
            let file = dir.appendingPathComponent("f")
            try Data("head-".utf8).write(to: file)
            do {
                _ = try await transport.download(URLRequest(url: server.url("/f")), to: file) { _ in }
                XCTFail("expected an error for Content-Range \(range ?? "none")")
            } catch let e as UnexpectedRange {
                XCTAssertEqual(e.expectedStart, 5)
            }
            XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "head-")
        }
    }

    func testHTMLIsReturnedNotWritten() async throws {
        let server = try LoopbackServer { _ in LoopbackServer.reply("200 OK", ["Content-Type": "text/html; charset=utf-8"], body: Data("<html>no</html>".utf8)) }
        let file = dir.appendingPathComponent("f")
        try Data("keep".utf8).write(to: file)
        let (body, _) = try await transport.download(URLRequest(url: server.url("/f")), to: file) { _ in }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "<html>no</html>")
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "keep")
    }

    func testRedirectsAreNotFollowed() async throws {
        let server = try LoopbackServer { head in
            head.hasPrefix("GET /start") ? LoopbackServer.reply("302 Found", ["Location": "/next"]) : LoopbackServer.reply("200 OK")
        }
        let (_, response) = try await transport.send(URLRequest(url: server.url("/start")))
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Location"), "/next")
        XCTAssertEqual(server.heads.count, 1)
    }

    func testSendReturnsTheBody() async throws {
        let server = try LoopbackServer { _ in LoopbackServer.reply("200 OK", ["Content-Type": "application/json"], body: Data("{\"a\":1}".utf8)) }
        let (data, _) = try await transport.send(URLRequest(url: server.url("/x")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"a\":1}")
    }

    func testUnwritableDestinationIsAnError() async throws {
        let body = big
        let server = try LoopbackServer { _ in LoopbackServer.reply("200 OK", ["Content-Type": "application/octet-stream"], body: body) }
        let file = dir.appendingPathComponent("missing/dir/f")
        do {
            _ = try await transport.download(URLRequest(url: server.url("/f")), to: file) { _ in }
            XCTFail("expected an error")
        } catch {}
    }

    /// The transport never follows a redirect itself (swift-corelibs-foundation would resend every header to the new
    /// host): the 3xx is the answer, and `AppleWebClient` decides the next hop and its headers.
    func testARedirectComesBackUnfollowed() async throws {
        let target = try LoopbackServer { _ in LoopbackServer.reply("200 OK", ["Content-Type": "text/plain"], body: Data("other".utf8)) }
        let server = try LoopbackServer { _ in
            LoopbackServer.reply("302 Found", ["Location": "http://localhost:\(target.port)/elsewhere"], body: Data())
        }
        var request = URLRequest(url: server.url("/start"))
        request.setValue("session-cookie=1", forHTTPHeaderField: "Cookie")
        let (_, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Location"), "http://localhost:\(target.port)/elsewhere")
        XCTAssertTrue(target.heads.isEmpty, "nothing reached the other host")
    }

    #if os(Linux)
    /// A full disk mid-download (/dev/full fails every write with ENOSPC) is an error, not a crash.
    func testDiskFullIsAnError() async throws {
        let body = big
        let server = try LoopbackServer { _ in LoopbackServer.reply("206 Partial Content", ["Content-Type": "application/octet-stream"], body: body) }
        do {
            _ = try await transport.download(URLRequest(url: server.url("/f")), to: URL(fileURLWithPath: "/dev/full")) { _ in }
            XCTFail("expected an error")
        } catch {}
    }
    #endif
}
