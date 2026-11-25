import Crypto
import _CryptoExtras
import Foundation
import SwiftASN1
import X509
#if canImport(Glibc)
import Glibc
#endif
import XlessCore

/// RSA-2048 key used for Apple Distribution / Developer ID certificates.
public struct SigningKey: Sendable {
    public let rsa: _RSA.Signing.PrivateKey

    public static func generate() throws -> SigningKey {
        SigningKey(rsa: try _RSA.Signing.PrivateKey(keySize: .bits2048))
    }

    init(rsa: _RSA.Signing.PrivateKey) { self.rsa = rsa }

    public init(pem: String) throws {
        do { rsa = try _RSA.Signing.PrivateKey(pemRepresentation: PEM.normalize(pem)) } catch {
            throw XlessError(.sign, "signing key is not an RSA private key PEM", fix: "use the key written by `xless sign bootstrap`")
        }
    }

    public var pem: String { rsa.pemRepresentation }

    public func csrPEM(commonName: String) throws -> String {
        let pk = Certificate.PrivateKey(rsa)
        let csr = try CertificateSigningRequest(
            version: .v1, subject: try DistinguishedName { CommonName(commonName) },
            privateKey: pk, attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha256WithRSAEncryption)
        return try csr.serializeAsPEM().pemString
    }

    public func matches(certificateDER: [UInt8]) throws -> Bool {
        let cert = try Certificate(derEncoded: certificateDER)
        return cert.publicKey == Certificate.PrivateKey(rsa).publicKey
    }
}

extension SigningKey {
    /// Writes the PEM to a new file (O_EXCL, mode 0600). Fails if the path already exists; never overwrites.
    public func writeExclusively(toPath path: String) throws {
        try Self.writeExclusively(Data(pem.utf8), toPath: path, mode: 0o600)
    }

    /// Creates `path` with O_CREAT|O_EXCL|O_NOFOLLOW, writes `data`, and forces `mode` regardless of umask.
    public static func writeExclusively(_ data: Data, toPath path: String, mode: mode_t) throws {
        let fd = open(path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, mode)
        guard fd >= 0 else {
            let why = errno == EEXIST ? "already exists" : String(cString: strerror(errno))
            throw XlessError(.sign, "cannot create \(path): \(why)", fix: "choose another path; never overwrite a stored key")
        }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
        }
        let closed = close(fd) == 0
        guard ok, closed else {
            unlink(path)
            throw XlessError(.sign, "could not write \(path): \(String(cString: strerror(errno)))", fix: "check disk space and permissions")
        }
    }
}
