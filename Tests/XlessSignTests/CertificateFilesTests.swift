import Testing
import Foundation
import X509
import SwiftASN1
import Crypto
@testable import XlessSign
@testable import XlessCore

@Test func aCSRIsTakenAsPEMOrDER() throws {
    let key = try SigningKey.generate()
    let pem = try key.csrPEM(commonName: "hsm")
    let fromPEM = try CSRFile.pem(from: Data(pem.replacingOccurrences(of: "\n", with: "\r\n").utf8), path: "a.csr")
    #expect(fromPEM.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
    #expect(try CertificateSigningRequest(pemEncoded: fromPEM).publicKey == Certificate.PrivateKey(key.rsa).publicKey)
    var der = DER.Serializer()
    try der.serialize(try CertificateSigningRequest(pemEncoded: pem))
    #expect(try CSRFile.pem(from: Data(der.serializedBytes), path: "a.der") == fromPEM)
    // An ECC key's CSR (Apple Pay payment processing) works too.
    let ecc = P256.Signing.PrivateKey()
    let eccCSR = try CertificateSigningRequest(version: .v1, subject: DistinguishedName { CommonName("pay") }, privateKey: .init(ecc),
                                               attributes: .init(), signatureAlgorithm: .ecdsaWithSHA256)
    #expect(try CSRFile.pem(from: Data(eccCSR.serializeAsPEM().pemString.utf8), path: "pay.csr").contains("CERTIFICATE REQUEST"))
}

@Test func anythingElseIsRefusedWithoutQuotingIt() throws {
    let key = try SigningKey.generate()
    for bad in [Data("hello".utf8), Data(key.pem.utf8), Data(), Data([0x30, 0x03, 0x02, 0x01, 0x00])] {
        do { _ = try CSRFile.pem(from: bad, path: "x.csr"); Issue.record("accepted") } catch let e as XlessError {
            #expect(e.stage == .account && e.cause.contains("x.csr is not a certificate signing request"))
            #expect(!e.description.contains("PRIVATE KEY"))
        }
    }
}

@Test func expiryAndTeamComeFromTheCertificate() throws {
    let key = try SigningKey.generate()
    let facts = try #require(CertificateFacts(der: Data(try selfSigned(key, team: "ABCDE12345"))))
    #expect(facts.teamID == "ABCDE12345")
    #expect(try #require(facts.expires).timeIntervalSinceNow > 3000)
    #expect(CertificateFacts(der: Data(try selfSigned(key)))?.teamID == nil)
    #expect(CertificateFacts(der: Data([0x30, 0x00])) == nil)
}
