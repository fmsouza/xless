import CXlessProcess
import Foundation
import XlessCore

/// The agent's protocol. A change that an older or newer xless would not understand takes a new version; the header, and
/// `lock` with an empty body, never change.
enum AgentProtocol {
    static let version: UInt16 = 2
}

enum AgentCode: UInt16 {
    // requests
    case hello = 1, prove = 2
    case status = 10, get = 11, put = 12, drop = 13, lock = 14, join = 15
    /// From the command that starts an agent, over the channel it made for it only.
    case configure = 20
    // answers
    case welcome = 100, verdict = 101, ok = 110, refused = 111
}

/// `XLAG`, the version, what it is, the body's length (big-endian), the body.
enum AgentFrame {
    static let magic: [UInt8] = [0x58, 0x4C, 0x41, 0x47]
    static let headerSize = 12

    struct Header: Equatable {
        let version: UInt16
        let code: UInt16
        let length: Int
    }

    /// The header `bytes` start with, nil until it is whole.
    static func header(_ bytes: UnsafeRawBufferPointer) throws -> Header? {
        guard bytes.count >= headerSize else { return nil }
        guard zip(bytes, magic).allSatisfy({ $0 == $1 }) else { throw AgentError.malformed("it does not start as one") }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
        let length = Int(u16(8)) << 16 | Int(u16(10))
        return Header(version: u16(4), code: u16(6), length: length)
    }
}

/// Builds a message in one buffer that is zeroed whenever it is outgrown or released.
struct WireWriter {
    private var buffer = SecretPages(count: 4096)
    private var length = AgentFrame.headerSize

    init() {}

    private mutating func reserve(_ n: Int) {
        guard length + n > buffer.count else { return }
        let larger = SecretPages(count: max(buffer.count * 2, length + n))
        buffer.withUnsafeBytes { from in larger.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: from[..<length])) } }
        buffer = larger
    }

    private mutating func append(_ bytes: UnsafeRawBufferPointer) {
        reserve(bytes.count)
        buffer.withUnsafeMutableBytes { UnsafeMutableRawBufferPointer(rebasing: $0[length...]).copyMemory(from: bytes) }
        length += bytes.count
    }

    mutating func put(_ v: UInt8) { withUnsafeBytes(of: v) { append($0) } }
    mutating func put(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { append($0) } }
    mutating func put(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { append($0) } }
    mutating func put(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { append($0) } }
    mutating func put(_ v: Int64) { put(UInt64(bitPattern: v)) }
    mutating func put(_ v: Int) { put(Int64(v)) }
    mutating func put(_ v: Bool) { put(UInt8(v ? 1 : 0)) }
    mutating func put(bytes: [UInt8]) { put(UInt32(bytes.count)); bytes.withUnsafeBytes { append($0) } }
    mutating func put(_ text: String) { put(bytes: Array(text.utf8)) }
    mutating func put(secret: SecretBytes) { put(UInt32(secret.count)); secret.withUnsafeBytes { append($0) } }
    mutating func put(secret: SecretPages) { put(UInt32(secret.count)); secret.withUnsafeBytes { append($0) } }

    /// The whole message, in pages of its own.
    func frame(code: AgentCode, version: UInt16 = AgentProtocol.version) -> SecretPages {
        let out = SecretPages(count: length)
        out.withUnsafeMutableBytes { to in
            buffer.withUnsafeBytes { to.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[..<length])) }
            to.copyBytes(from: AgentFrame.magic)
            func put16(_ v: UInt16, _ at: Int) { to[at] = UInt8(v >> 8); to[at + 1] = UInt8(v & 0xFF) }
            put16(version, 4)
            put16(code.rawValue, 6)
            let body = length - AgentFrame.headerSize
            put16(UInt16(truncatingIfNeeded: body >> 16), 8)
            put16(UInt16(truncatingIfNeeded: body), 10)
        }
        return out
    }
}

/// Reads a message's body; whatever it claims, never outside it.
struct WireReader {
    private let body: UnsafeRawBufferPointer
    private var at = 0

    init(_ body: UnsafeRawBufferPointer) { self.body = body }

    private mutating func take(_ n: Int) throws -> UnsafeRawBufferPointer {
        guard n >= 0, n <= body.count - at else { throw AgentError.malformed("it is shorter than it says") }
        defer { at += n }
        return UnsafeRawBufferPointer(rebasing: body[at..<at + n])
    }

    private mutating func number(_ size: Int) throws -> UInt64 { try take(size).reduce(0) { $0 << 8 | UInt64($1) } }

    mutating func uint8() throws -> UInt8 { UInt8(try number(1)) }
    mutating func uint16() throws -> UInt16 { UInt16(try number(2)) }
    mutating func uint32() throws -> UInt32 { UInt32(try number(4)) }
    mutating func uint64() throws -> UInt64 { try number(8) }
    mutating func int64() throws -> Int64 { Int64(bitPattern: try number(8)) }
    mutating func int() throws -> Int { Int(try int64()) }
    mutating func bool() throws -> Bool { try uint8() != 0 }

    private mutating func field(max: Int) throws -> UnsafeRawBufferPointer {
        let n = Int(try uint32())
        guard n <= max else { throw AgentError.malformed("a field of \(n) bytes") }
        return try take(n)
    }

    mutating func bytes(max: Int) throws -> [UInt8] { Array(try field(max: max)) }

    mutating func string(max: Int) throws -> String {
        guard let s = String(data: Data(try field(max: max)), encoding: .utf8) else { throw AgentError.malformed("text that is not UTF-8") }
        return s
    }

    mutating func secret(max: Int) throws -> SecretBytes { SecretBytes(copying: try field(max: max)) }

    /// The body has nothing more.
    func end() throws {
        guard at == body.count else { throw AgentError.malformed("it is longer than it says") }
    }
}
