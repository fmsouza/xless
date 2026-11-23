import XlessCore

/// The credential-helper protocol's JSON: flat objects whose values are strings. Built and parsed straight in
/// `SecretBytes`, so a secret never passes through a `String`, `Data` or a JSON library's own copies.
///
/// Writing escapes only `"`, `\` and the control characters (U+0000–U+001F, U+007F); other UTF-8 is written as it is.
/// Reading accepts every JSON string escape, `\uXXXX` surrogate pairs included, and whitespace between tokens.
enum HelperJSON {
    struct Malformed: Error {}

    /// `{"k":"v",…}`, one line, the members in the given order.
    static func object(_ members: [(String, SecretBytes)]) -> SecretBytes {
        let keys = members.map { SecretBytes(utf8: $0.0) }
        var size = 2 + max(0, members.count - 1) // braces, commas
        for (i, m) in members.enumerated() { size += quotedLength(keys[i]) + 1 + quotedLength(m.1) }
        let out = SecretBytes(count: size)
        out.withUnsafeMutableBytes { buf in
            var at = 0
            func put(_ b: UInt8) { buf[at] = b; at += 1 }
            put(UInt8(ascii: "{"))
            for (i, m) in members.enumerated() {
                if i > 0 { put(UInt8(ascii: ",")) }
                quote(keys[i], put)
                put(UInt8(ascii: ":"))
                quote(m.1, put)
            }
            put(UInt8(ascii: "}"))
        }
        return out
    }

    static func needsEscape(_ b: UInt8) -> Bool { b < 0x20 || b == 0x7f || b == UInt8(ascii: "\"") || b == UInt8(ascii: "\\") }

    static func shortEscape(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "\""): UInt8(ascii: "\"")
        case UInt8(ascii: "\\"): UInt8(ascii: "\\")
        case 0x0a: UInt8(ascii: "n")
        case 0x0d: UInt8(ascii: "r")
        case 0x09: UInt8(ascii: "t")
        case 0x08: UInt8(ascii: "b")
        case 0x0c: UInt8(ascii: "f")
        default: nil
        }
    }

    static func quotedLength(_ s: SecretBytes) -> Int {
        s.withUnsafeBytes { bytes in
            2 + bytes.reduce(0) { n, b in n + (needsEscape(b) ? (shortEscape(b) == nil ? 6 : 2) : 1) }
        }
    }

    static func quote(_ s: SecretBytes, _ put: (UInt8) -> Void) {
        let hex = Array("0123456789abcdef".utf8)
        put(UInt8(ascii: "\""))
        s.withUnsafeBytes { bytes in
            for b in bytes {
                guard needsEscape(b) else { put(b); continue }
                put(UInt8(ascii: "\\"))
                if let short = shortEscape(b) { put(short); continue }
                for c in [UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(b >> 4)], hex[Int(b & 0xf)]] { put(c) }
            }
        }
        put(UInt8(ascii: "\""))
    }

    /// The members of a flat JSON object whose values are all strings, in order (surrounding whitespace allowed).
    /// Anything else — another type of value, a nested object, trailing bytes, an invalid escape — is `Malformed`.
    static func members(_ bytes: UnsafeRawBufferPointer) throws -> [(key: String, value: SecretBytes)] {
        var p = Parser(bytes: bytes)
        p.skipSpace()
        try p.expect(UInt8(ascii: "{"))
        var out: [(key: String, value: SecretBytes)] = []
        p.skipSpace()
        if p.peek == UInt8(ascii: "}") {
            p.at += 1
        } else {
            while true {
                p.skipSpace()
                let key = try p.string()
                p.skipSpace()
                try p.expect(UInt8(ascii: ":"))
                p.skipSpace()
                let value = try p.string()
                out.append((key.utf8String(), value))
                p.skipSpace()
                if p.peek == UInt8(ascii: ",") { p.at += 1; continue }
                try p.expect(UInt8(ascii: "}"))
                break
            }
        }
        p.skipSpace()
        guard p.at == bytes.count else { throw Malformed() }
        return out
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        var at = 0

        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func skipSpace() {
            while let b = peek, b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d { at += 1 }
        }

        mutating func expect(_ b: UInt8) throws {
            guard peek == b else { throw Malformed() }
            at += 1
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Malformed() }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[at]
                at += 1
                let d: UInt8
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
                default: throw Malformed()
                }
                v = v << 4 | UInt32(d)
            }
            return v
        }

        /// A JSON string, decoded. Decoding never lengthens a string, so it fits a buffer of the raw length.
        mutating func string() throws -> SecretBytes {
            try expect(UInt8(ascii: "\""))
            let start = at
            var end = at
            while end < bytes.count, bytes[end] != UInt8(ascii: "\"") { end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1 }
            guard end < bytes.count else { throw Malformed() }
            let buffer = SecretBytes(count: end - start)
            var n = 0
            try buffer.withUnsafeMutableBytes { out in
                func put(_ b: UInt8) { out[n] = b; n += 1 }
                while at < end {
                    let b = bytes[at]
                    at += 1
                    guard b >= 0x20 else { throw Malformed() } // a raw control character
                    guard b == UInt8(ascii: "\\") else { put(b); continue }
                    guard at < end else { throw Malformed() }
                    let e = bytes[at]
                    at += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): put(e)
                    case UInt8(ascii: "n"): put(0x0a)
                    case UInt8(ascii: "r"): put(0x0d)
                    case UInt8(ascii: "t"): put(0x09)
                    case UInt8(ascii: "b"): put(0x08)
                    case UInt8(ascii: "f"): put(0x0c)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xd800...0xdbff).contains(scalar) {
                            guard at + 2 <= end, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else { throw Malformed() }
                            at += 2
                            let low = try hex4()
                            guard (0xdc00...0xdfff).contains(low) else { throw Malformed() }
                            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00)
                        } else if (0xdc00...0xdfff).contains(scalar) {
                            throw Malformed()
                        }
                        guard let u = Unicode.Scalar(scalar) else { throw Malformed() }
                        for unit in UTF8.encode(u)! { put(unit) }
                    default:
                        throw Malformed()
                    }
                }
            }
            at = end + 1
            defer { buffer.wipe() }
            return buffer.prefix(n)
        }
    }
}
