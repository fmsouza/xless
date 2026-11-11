import Crypto
import Foundation

/// The proof of work Apple's sign-in asks for in the `X-Apple-HC` header of `signin/complete`, from the
/// `X-Apple-HC-Bits` and `X-Apple-HC-Challenge` headers of `GET signin?widgetKey=…`. Apple's variant of hashcash:
/// `1:<bits>:<yyMMddHHmmss>:<challenge>::<counter>` with a decimal counter and no random part, whose SHA-1 starts
/// with at least `bits` zero bits.
enum Hashcash {
    static func mint(challenge: String, bits: Int, date: String) -> String {
        let prefix = "1:\(bits):\(date):\(challenge)::"
        var counter = 0
        while true {
            let stamp = prefix + String(counter)
            if leadingZeroBits(Array(Insecure.SHA1.hash(data: Array(stamp.utf8)))) >= bits { return stamp }
            counter += 1
        }
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss"
        return f.string(from: date)
    }

    private static func leadingZeroBits(_ digest: [UInt8]) -> Int {
        var n = 0
        for byte in digest {
            if byte == 0 { n += 8; continue }
            return n + byte.leadingZeroBitCount
        }
        return n
    }
}
