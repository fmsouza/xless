import Testing
import Foundation
import X509
import SwiftASN1
import Crypto
import _CryptoExtras
@testable import XlessSign
#if os(Windows)
import XlessCore
#endif

@Test func generatesKeyAndParsableCSR() throws {
    let key = try SigningKey.generate()
    let csrPEM = try key.csrPEM(commonName: "xless")
    let csr = try CertificateSigningRequest(pemEncoded: csrPEM)
    #expect(csr.publicKey == Certificate.PrivateKey(key.rsa).publicKey)
    let reloaded = try SigningKey(pem: "\n\(key.pem)\n")
    #expect(reloaded.pem == key.pem)
}

/// Self-signed cert from `key` stands in for Apple's issued certificate. `team`: the subject carries it as its OU, as
/// Apple's do (rcodesign reads the signature's team from it).
func selfSigned(_ key: SigningKey, team: String? = nil) throws -> [UInt8] {
    let pk = Certificate.PrivateKey(key.rsa)
    let name = try team.map { team in try DistinguishedName { CommonName("Apple Distribution: Test (\(team))"); OrganizationalUnitName(team) } }
        ?? DistinguishedName { CommonName("test") }
    let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: pk.publicKey,
                               notValidBefore: Date(), notValidAfter: Date().addingTimeInterval(3600),
                               issuer: name, subject: name, signatureAlgorithm: .sha256WithRSAEncryption,
                               extensions: Certificate.Extensions(), issuerPrivateKey: pk)
    var ser = DER.Serializer(); try ser.serialize(cert); return ser.serializedBytes
}

@Test func matchesOnlyItsOwnCertificate() throws {
    let a = try SigningKey.generate(), b = try SigningKey.generate()
    #expect(try a.matches(certificateDER: selfSigned(a)))
    #expect(try !a.matches(certificateDER: selfSigned(b)))
}

@Test func acceptsCRLFAndEscapedNewlinePEM() throws {
    let key = try SigningKey.generate()
    let crlf = key.pem.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(try SigningKey(pem: crlf).pem == key.pem)
    let escaped = key.pem.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\\n")
    #expect(!escaped.contains("\n"))
    #expect(try SigningKey(pem: escaped).pem == key.pem)
}

@Test func writeExclusivelyCreates0600AndNeverOverwrites() throws {
    let path = NSTemporaryDirectory() + "xless-key-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let key = try SigningKey.generate()
    try key.writeExclusively(toPath: path)
    #if os(Windows)
    // Nobody else's, or it would not be read.
    #expect(try PrivateFile.read(path, .anyDrive, limit: 1 << 16) == Data(key.pem.utf8))
    #else
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #endif
    #expect(try SigningKey(pem: String(contentsOfFile: path, encoding: .utf8)).pem == key.pem)
    #expect(throws: (any Error).self) { try SigningKey.generate().writeExclusively(toPath: path) }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == key.pem)
}
