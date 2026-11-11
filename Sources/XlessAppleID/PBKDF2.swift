import Crypto

/// PBKDF2 with HMAC-SHA256 (RFC 8018 §5.2).
enum PBKDF2 {
    static func sha256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var block: UInt32 = 1
        while out.count < length {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: salt)
            mac.update(data: withUnsafeBytes(of: block.bigEndian) { Array($0) })
            var u = Array(mac.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in t.indices { t[i] ^= u[i] }
                }
            }
            out.append(contentsOf: t.prefix(length - out.count))
            block += 1
        }
        return out
    }
}

/// The password protocols Apple's sign-in offers in `signin/init` (`protocols: ["s2k", "s2k_fo"]`).
public enum SRPPasswordProtocol: String, Decodable, Sendable {
    case s2k, s2k_fo
}

/// The SRP password Apple's sign-in expects: PBKDF2-HMAC-SHA256 over SHA-256(password) (`s2k`), or over that digest's
/// lowercase hex (`s2k_fo`), with the salt and iteration count `signin/init` returned; 32 bytes.
enum ApplePasswordKey {
    static func derive(passwordSHA256: [UInt8], salt: [UInt8], iterations: Int, protocol p: SRPPasswordProtocol) -> [UInt8] {
        switch p {
        case .s2k:
            return PBKDF2.sha256(password: passwordSHA256, salt: salt, iterations: iterations, length: 32)
        case .s2k_fo:
            var hexDigest = Array(passwordSHA256.map { String(format: "%02x", $0) }.joined().utf8)
            defer { hexDigest.resetBytes() }
            return PBKDF2.sha256(password: hexDigest, salt: salt, iterations: iterations, length: 32)
        }
    }
}

extension Array where Element == UInt8 {
    /// Overwrites the buffer with zeros (best effort: copies Swift made earlier are out of reach).
    mutating func resetBytes() {
        for i in indices { self[i] = 0 }
    }
}
