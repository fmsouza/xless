import Foundation

/// The subset of CBOR (RFC 8949) CTAP2 speaks: what an authenticator sends is decoded with bounds on depth and length,
/// and what xless sends is encoded the way CTAP2 requires ("CTAP2 canonical CBOR": shortest lengths, definite lengths,
/// map keys sorted by their encoded length, then bytewise).
public indirect enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    /// The integer -1 - n.
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null
    case undefined
    case tagged(UInt64, CBOR)
    case float(Double)

    public static func int(_ value: Int) -> CBOR { value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value)) }

    public static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        switch (lhs, rhs) {
        case let (.unsigned(a), .unsigned(b)), let (.negative(a), .negative(b)): return a == b
        case let (.bytes(a), .bytes(b)): return a == b
        case let (.text(a), .text(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.map(a), .map(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null), (.undefined, .undefined): return true
        case let (.tagged(t, a), .tagged(u, b)): return t == u && a == b
        case let (.float(a), .float(b)): return a == b || (a.isNaN && b.isNaN)
        default: return false
        }
    }

    // MARK: Reading values

    public var intValue: Int? {
        switch self {
        case .unsigned(let n): return n <= UInt64(Int.max) ? Int(n) : nil
        case .negative(let n): return n < UInt64(Int.max) ? -1 - Int(n) : nil
        default: return nil
        }
    }
    public var bytesValue: [UInt8]? { if case .bytes(let b) = self { return b }; return nil }
    public var textValue: String? { if case .text(let t) = self { return t }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [CBOR]? { if case .array(let a) = self { return a }; return nil }
    public var mapValue: [(CBOR, CBOR)]? { if case .map(let m) = self { return m }; return nil }

    /// The value under an integer key of a map (nil for a missing key or a value that is not a map).
    public subscript(key: Int) -> CBOR? { self[.int(key)] }
    /// The value under a text key of a map.
    public subscript(key: String) -> CBOR? { self[.text(key)] }
    public subscript(key: CBOR) -> CBOR? { mapValue?.first { $0.0 == key }?.1 }

    // MARK: Encoding

    /// The canonical encoding.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        encode(into: &out)
        return out
    }

    private func encode(into out: inout [UInt8]) {
        switch self {
        case .unsigned(let n): Self.head(0, n, into: &out)
        case .negative(let n): Self.head(1, n, into: &out)
        case .bytes(let b): Self.head(2, UInt64(b.count), into: &out); out += b
        case .text(let t): let u = Array(t.utf8); Self.head(3, UInt64(u.count), into: &out); out += u
        case .array(let a): Self.head(4, UInt64(a.count), into: &out); for v in a { v.encode(into: &out) }
        case .map(let m):
            let entries = m.map { ($0.0.encoded(), $0.1.encoded()) }
                .sorted { a, b in a.0.count != b.0.count ? a.0.count < b.0.count : a.0.lexicographicallyPrecedes(b.0) }
            Self.head(5, UInt64(entries.count), into: &out)
            for (k, v) in entries { out += k; out += v }
        case .bool(let b): out.append(b ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        case .undefined: out.append(0xF7)
        case .tagged(let t, let v): Self.head(6, t, into: &out); v.encode(into: &out)
        case .float(let d):
            out.append(0xFB)
            let bits = d.bitPattern
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64, into out: inout [UInt8]) {
        let m = major << 5
        switch value {
        case 0..<24: out.append(m | UInt8(value))
        case 24...0xFF: out += [m | 24, UInt8(value)]
        case 0x100...0xFFFF: out += [m | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 0x10000...0xFFFF_FFFF:
            out.append(m | 26)
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
        default:
            out.append(m | 27)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
        }
    }

    // MARK: Decoding

    public struct DecodingError: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { "malformed CBOR: \(reason)" }
    }

    /// Decodes exactly one value that fills `bytes` (trailing bytes are an error). Indefinite lengths are refused (CTAP2
    /// never sends them); nesting is limited to `maxDepth`.
    public static func decode(_ bytes: [UInt8], maxDepth: Int = 16) throws -> CBOR {
        var reader = Reader(bytes: bytes, maxDepth: maxDepth)
        let value = try reader.value(depth: 0)
        guard reader.offset == bytes.count else { throw DecodingError(reason: "\(bytes.count - reader.offset) trailing bytes") }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        let maxDepth: Int
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodingError(reason: "truncated") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func take(_ count: UInt64) throws -> [UInt8] {
            guard count <= UInt64(bytes.count - offset) else { throw DecodingError(reason: "truncated") }
            let n = Int(count)
            defer { offset += n }
            return Array(bytes[offset..<offset + n])
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24...27:
                var value: UInt64 = 0
                for _ in 0..<(1 << Int(info - 24)) { value = value << 8 | UInt64(try byte()) }
                return value
            case 31: throw DecodingError(reason: "indefinite length")
            default: throw DecodingError(reason: "reserved additional information \(info)")
            }
        }

        mutating func value(depth: Int) throws -> CBOR {
            guard depth <= maxDepth else { throw DecodingError(reason: "nested deeper than \(maxDepth)") }
            let initial = try byte()
            let major = initial >> 5, info = initial & 0x1F
            switch major {
            case 0: return .unsigned(try argument(info))
            case 1: return .negative(try argument(info))
            case 2: return .bytes(try take(try argument(info)))
            case 3:
                guard let text = String(bytes: try take(try argument(info)), encoding: .utf8) else {
                    throw DecodingError(reason: "text that is not UTF-8")
                }
                return .text(text)
            case 4:
                let count = try argument(info)
                guard count <= UInt64(bytes.count - offset) else { throw DecodingError(reason: "truncated") }
                var items: [CBOR] = []
                for _ in 0..<count { items.append(try value(depth: depth + 1)) }
                return .array(items)
            case 5:
                let count = try argument(info)
                guard count <= UInt64(bytes.count - offset) / 2 else { throw DecodingError(reason: "truncated") }
                var entries: [(CBOR, CBOR)] = []
                for _ in 0..<count {
                    let key = try value(depth: depth + 1)
                    entries.append((key, try value(depth: depth + 1)))
                }
                return .map(entries)
            case 6: return .tagged(try argument(info), try value(depth: depth + 1))
            default:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 23: return .undefined
                case 25: return .float(Self.half(UInt16(try argument(25))))
                case 26: return .float(Double(Float(bitPattern: UInt32(try argument(26)))))
                case 27: return .float(Double(bitPattern: try argument(27)))
                case 24: _ = try byte(); return .undefined // a simple value CTAP2 never uses
                default:
                    if info < 20 { return .undefined }
                    throw DecodingError(reason: "simple value \(info)")
                }
            }
        }

        static func half(_ h: UInt16) -> Double {
            let exponent = Int(h >> 10) & 0x1F, mantissa = Double(h & 0x3FF)
            let magnitude: Double
            switch exponent {
            case 0: magnitude = mantissa * pow(2, -24)
            case 31: magnitude = mantissa == 0 ? .infinity : .nan
            default: magnitude = (mantissa + 1024) * pow(2, Double(exponent - 25))
            }
            return h & 0x8000 != 0 ? -magnitude : magnitude
        }
    }
}
