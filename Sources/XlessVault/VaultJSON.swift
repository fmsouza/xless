import Foundation

/// A JSON value the store file holds but this xless does not know (a field a newer xless added). Kept as it was read
/// and written back on every rewrite, so an older xless never drops what a newer one recorded.
public indirect enum VaultJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([VaultJSON])
    case object([String: VaultJSON])

    public init(from decoder: any Decoder) throws {
        if var a = try? decoder.unkeyedContainer() {
            var items: [VaultJSON] = []
            while !a.isAtEnd { items.append(try a.decode(VaultJSON.self)) }
            self = .array(items)
            return
        }
        if let o = try? decoder.container(keyedBy: VaultJSONKey.self) {
            var members: [String: VaultJSON] = [:]
            for key in o.allKeys { members[key.stringValue] = try o.decode(VaultJSON.self, forKey: key) }
            self = .object(members)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .integer(i) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .array(let items):
            var a = encoder.unkeyedContainer()
            for item in items { try a.encode(item) }
        case .object(let members):
            var o = encoder.container(keyedBy: VaultJSONKey.self)
            for (k, v) in members { try o.encode(v, forKey: VaultJSONKey(k)) }
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .integer(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .number(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        }
    }

    /// The members of `decoder`'s object whose keys are not in `known`.
    static func unknownMembers(of decoder: any Decoder, known: Set<String>) throws -> [String: VaultJSON] {
        let o = try decoder.container(keyedBy: VaultJSONKey.self)
        var out: [String: VaultJSON] = [:]
        for key in o.allKeys where !known.contains(key.stringValue) { out[key.stringValue] = try o.decode(VaultJSON.self, forKey: key) }
        return out
    }

    /// Writes `members` next to the known keys (never over one of them).
    static func encode(_ members: [String: VaultJSON], to encoder: any Encoder, known: Set<String>) throws {
        var o = encoder.container(keyedBy: VaultJSONKey.self)
        for (k, v) in members where !known.contains(k) { try o.encode(v, forKey: VaultJSONKey(k)) }
    }
}

struct VaultJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
