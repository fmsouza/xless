import Foundation

/// The two encodings of an entitlements dictionary that Xcode links into a simulator executable (Swift Build's
/// `LD_ENTITLEMENTS_SECTION` / `LD_ENTITLEMENTS_SECTION_DER`: `__TEXT,__entitlements` and `__TEXT,__ents_der`). A
/// simulator app is signed ad hoc with empty entitlements; the simulator reads the app's entitlements from these
/// sections instead. Measured black-box against Xcode 27.0's `<product>-Simulated.xcent(.der)` and `codesign
/// --generate-entitlement-der` (docs/react-native.md, "Simulator builds").
public enum EntitlementsEncoding {
    /// An XML property list (Xcode's layout: tab indentation, keys sorted).
    public static func xml(_ value: JSON) -> Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        write(value, indent: 0, into: &out)
        out += "</plist>\n"
        return Data(out.utf8)
    }

    private static func write(_ v: JSON, indent: Int, into out: inout String) {
        let pad = String(repeating: "\t", count: indent)
        switch v {
        case .string(let s): out += "\(pad)<string>\(escape(s))</string>\n"
        case .int(let i): out += "\(pad)<integer>\(i)</integer>\n"
        case .bool(let b): out += "\(pad)<\(b ? "true" : "false")/>\n"
        case .array(let items):
            if items.isEmpty { out += "\(pad)<array/>\n"; return }
            out += "\(pad)<array>\n"
            for item in items { write(item, indent: indent + 1, into: &out) }
            out += "\(pad)</array>\n"
        case .object(let dict):
            if dict.isEmpty { out += "\(pad)<dict/>\n"; return }
            out += "\(pad)<dict>\n"
            for key in dict.keys.sorted() {
                out += "\(pad)\t<key>\(escape(key))</key>\n"
                write(dict[key]!, indent: indent + 1, into: &out)
            }
            out += "\(pad)</dict>\n"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacing(scalar: "&", with: "&amp;").replacing(scalar: "<", with: "&lt;").replacing(scalar: ">", with: "&gt;")
    }

    /// The DER form `codesign --generate-entitlement-der` writes: `[APPLICATION 16] { INTEGER 1, dict }`, where a
    /// dictionary is `[CONTEXT 16]` holding one `SEQUENCE { UTF8String key, value }` per entry, keys sorted by their
    /// UTF-8 bytes; strings are `UTF8String`, booleans `BOOLEAN` (`FF`/`00`), integers minimal two's-complement
    /// `INTEGER`s, arrays `SEQUENCE`s.
    public static func der(_ value: JSON) -> Data {
        Data(tlv(0x70, [0x02, 0x01, 0x01] + encode(value)))
    }

    private static func encode(_ v: JSON) -> [UInt8] {
        switch v {
        case .string(let s): return tlv(0x0C, Array(s.utf8))
        case .bool(let b): return [0x01, 0x01, b ? 0xFF : 0x00]
        case .int(let i): return tlv(0x02, integer(i))
        case .array(let items): return tlv(0x30, items.flatMap(encode))
        case .object(let dict):
            let entries = dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                .flatMap { tlv(0x30, tlv(0x0C, Array($0.utf8)) + encode(dict[$0]!)) }
            return tlv(0xB0, entries)
        }
    }

    /// Big-endian two's complement with no redundant leading byte (`0` → `00`, `128` → `00 80`, `-1` → `FF`).
    static func integer(_ i: Int) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int64(i).bigEndian, Array.init)
        while bytes.count > 1, (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return bytes
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let n = content.count
        let length: [UInt8]
        if n < 0x80 {
            length = [UInt8(n)]
        } else {
            var b: [UInt8] = []
            var m = n
            while m > 0 { b.insert(UInt8(m & 0xFF), at: 0); m >>= 8 }
            length = [0x80 | UInt8(b.count)] + b
        }
        return [tag] + length + content
    }
}
