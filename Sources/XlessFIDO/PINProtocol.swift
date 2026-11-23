import Crypto
import _CryptoExtras
import Foundation
import XlessCore

/// PIN/UV auth protocols one and two (CTAP 2.1, section 6.5): an ECDH key agreement with the authenticator, then
/// AES-256-CBC for the PIN hash and the token, and HMAC-SHA-256 for the request's pinUvAuthParam.
public struct PINProtocol: Sendable {
    public let version: Int

    public init?(version: Int) {
        guard version == 1 || version == 2 else { return nil }
        self.version = version
    }

    /// The shared secret, and the platform's public key as a COSE_Key to send.
    public struct Agreement {
        public let platformKey: CBOR
        let secret: SymmetricKey
    }

    /// Agrees on a secret with the authenticator's key-agreement key (a COSE_Key map).
    public func agree(with authenticatorKey: CBOR) throws -> Agreement {
        guard let x = authenticatorKey[-2]?.bytesValue, let y = authenticatorKey[-3]?.bytesValue, x.count == 32, y.count == 32,
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: [0x04] + x + y) else {
            throw FIDOError.malformed("the key-agreement key is not a P-256 point")
        }
        let mine = P256.KeyAgreement.PrivateKey()
        let shared = try mine.sharedSecretFromKeyAgreement(with: peer)
        let z = shared.withUnsafeBytes { SymmetricKey(data: $0) }
        let secret: SymmetricKey
        if version == 1 {
            secret = z.withUnsafeBytes { SymmetricKey(data: SHA256.hash(data: $0)) }
        } else {
            let salt = [UInt8](repeating: 0, count: 32)
            let hmacKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: z, salt: salt, info: Array("CTAP2 HMAC key".utf8), outputByteCount: 32)
            let aesKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: z, salt: salt, info: Array("CTAP2 AES key".utf8), outputByteCount: 32)
            secret = SymmetricKey(data: hmacKey.withUnsafeBytes { Array($0) } + aesKey.withUnsafeBytes { Array($0) })
        }
        let point = Array(mine.publicKey.x963Representation)
        let cose = CBOR.map([
            (.int(1), .int(2)), (.int(3), .int(-25)), (.int(-1), .int(1)),
            (.int(-2), .bytes(Array(point[1..<33]))), (.int(-3), .bytes(Array(point[33..<65]))),
        ])
        return Agreement(platformKey: cose, secret: secret)
    }

    /// The key AES uses: the whole secret in protocol one, its second half in protocol two.
    private func aesKey(_ secret: SymmetricKey) -> SymmetricKey {
        version == 1 ? secret : secret.withUnsafeBytes { SymmetricKey(data: Array($0[32..<64])) }
    }

    /// The key HMAC uses for `authenticate`: the whole key, except a protocol-two shared secret's first half.
    private func hmacKey(_ key: SymmetricKey) -> SymmetricKey {
        version == 2 && key.bitCount == 512 ? key.withUnsafeBytes { SymmetricKey(data: Array($0[0..<32])) } : key
    }

    public func encrypt(_ agreement: Agreement, _ plaintext: [UInt8]) throws -> [UInt8] {
        let key = aesKey(agreement.secret)
        if version == 1 {
            return Array(try AES._CBC.encrypt(plaintext, using: key, iv: try AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)), noPadding: true))
        }
        let iv = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return iv + Array(try AES._CBC.encrypt(plaintext, using: key, iv: try AES._CBC.IV(ivBytes: iv), noPadding: true))
    }

    public func decrypt(_ agreement: Agreement, _ ciphertext: [UInt8]) throws -> [UInt8] {
        let key = aesKey(agreement.secret)
        let iv: [UInt8], body: [UInt8]
        if version == 1 {
            iv = [UInt8](repeating: 0, count: 16); body = ciphertext
        } else {
            guard ciphertext.count >= 16 else { throw FIDOError.malformed("an encrypted value shorter than its IV") }
            iv = Array(ciphertext[0..<16]); body = Array(ciphertext[16...])
        }
        guard !body.isEmpty, body.count % 16 == 0 else { throw FIDOError.malformed("an encrypted value of \(body.count) bytes") }
        return Array(try AES._CBC.decrypt(body, using: key, iv: try AES._CBC.IV(ivBytes: iv), noPadding: true))
    }

    /// pinUvAuthParam over `message`: the first 16 bytes of the HMAC in protocol one, all 32 in protocol two.
    public func authenticate(key: SymmetricKey, _ message: [UInt8]) -> [UInt8] {
        let mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: hmacKey(key)))
        return version == 1 ? Array(mac[0..<16]) : mac
    }

    /// LEFT(SHA-256(PIN), 16), encrypted for the authenticator. The PIN's bytes are only hashed here.
    public func pinHashEnc(_ agreement: Agreement, pin: SecretBytes) throws -> [UInt8] {
        var digest = pin.withUnsafeBytes { Array(SHA256.hash(data: $0)) }
        defer { for i in digest.indices { digest[i] = 0 } }
        digest.removeLast(16) // in place: LEFT(…, 16) without another copy
        return try encrypt(agreement, digest)
    }
}
