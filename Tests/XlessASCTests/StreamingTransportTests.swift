import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
@testable import XlessASC

/// A one-thread HTTP/1.0 server on 127.0.0.1: answers each connection with `respond(path)`'s status and body, the body
/// written in pieces with pauses, so a client sees it arrive in several reads.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init(respond: @escaping @Sendable (String) -> (Int, Data)) throws {
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
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var request = [UInt8](repeating: 0, count: 4096)
                let n = read(client, &request, request.count)
                let line = String(decoding: request.prefix(max(n, 0)), as: UTF8.self).split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (status, body) = respond(path)
                let head = "HTTP/1.0 \(status) X\r\nContent-Length: \(body.count)\r\nContent-Type: application/a-gzip\r\nConnection: close\r\n\r\n"
                #if canImport(Darwin)
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                // A client that hangs up mid-body must not kill the test process with SIGPIPE.
                func put(_ pointer: UnsafeRawPointer?, _ count: Int) -> Bool {
                    #if canImport(Glibc)
                    return send(client, pointer, count, Int32(MSG_NOSIGNAL)) == count
                    #else
                    return send(client, pointer, count, 0) == count
                    #endif
                }
                _ = head.withCString { put($0, strlen($0)) }
                var offset = 0
                while offset < body.count {
                    let piece = body.subdata(in: offset..<min(offset + 16384, body.count))
                    guard piece.withUnsafeBytes({ put($0.baseAddress, piece.count) }) else { break }
                    offset += piece.count
                    usleep(2000)
                }
                close(client)
            }
        }
    }

    func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
}

@Test func theURLSessionTransportHandsTheBodyOverAsItArrives() async throws {
    let text = reportText(lines: 20000)
    let gz = storedGzip(text) // incompressible framing: ~1.3 MB on the wire
    let server = try LoopbackServer { path in
        path == "/report" ? (200, gz) : (404, Data(#"{"errors":[{"status":"404","detail":"no report"}]}"#.utf8))
    }
    defer { server.stop() }
    let base = "http://127.0.0.1:\(server.port)"

    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var pieces = 0
        var decoder: GzipDecoder?
        var out = Data()
    }
    let got = Collected()
    got.decoder = GzipDecoder { [got] in got.out.append($0) }
    let (ok, okBody) = try await URLSessionTransport().stream(URLRequest(url: URL(string: base + "/report")!)) { data in
        try got.lock.withLock {
            got.pieces += 1
            try got.decoder!.write(data)
        }
    }
    try got.decoder!.finish()
    #expect(ok.statusCode == 200 && okBody.isEmpty)
    #expect(got.out == text)
    #expect(got.pieces > 1)

    let (missing, body) = try await URLSessionTransport().stream(URLRequest(url: URL(string: base + "/nope")!)) { _ in Issue.record("a 404 body is no report") }
    #expect(missing.statusCode == 404)
    #expect(String(decoding: body, as: UTF8.self).contains("no report"))

    struct Full: Error {}
    await #expect(throws: Full.self) {
        _ = try await URLSessionTransport().stream(URLRequest(url: URL(string: base + "/report")!)) { _ in throw Full() }
    }
}
