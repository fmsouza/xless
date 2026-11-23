import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

func certJSON(id: String, der: [UInt8], type: String = "DISTRIBUTION") -> String {
    #"{"type":"certificates","id":"\#(id)","attributes":{"certificateType":"\#(type)","certificateContent":"\#(Data(der).base64EncodedString())","name":"c","expirationDate":"2030-01-01T00:00:00.000+0000"}}"#
}

@Test func findsMatchingCertificate() async throws {
    let key = try SigningKey.generate(), other = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "1", der: try selfSigned(other))),\#(certJSON(id: "2", der: try selfSigned(key)))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    #expect(try await svc.find(matching: key, kind: .distribution).id == "2")
    #expect(t.requests[0].url!.absoluteString.contains("filter%5BcertificateType%5D=DISTRIBUTION"))
}

@Test func noMatchExplainsBootstrap() async throws {
    let key = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    do { _ = try await svc.find(matching: key, kind: .distribution); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sign); #expect(e.fix.contains("bootstrap")) }
}

@Test func bootstrapRefusesWhenCertificatesExistUnlessAllowed() async throws {
    let existing = try selfSigned(try SigningKey.generate())
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "1", der: existing))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    await #expect(throws: XlessError.self) { _ = try await svc.bootstrap(kind: .distribution, allowNew: false) }
}

@Test func bootstrapRefusesAtTheDocumentedCapEvenWhenAllowed() async throws {
    // Five Developer ID Application certificates (Apple's documented limit); no POST is sent.
    let cap = try #require(CertificateKind.developerID.cap)
    #expect(cap == 5)
    let certs = try (1...cap).map { certJSON(id: "\($0)", der: try selfSigned(try SigningKey.generate()), type: "DEVELOPER_ID_APPLICATION_G2") }
    let t = MockTransport([(200, #"{"data":[\#(certs.joined(separator: ","))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    await #expect(throws: XlessError.self) { _ = try await svc.bootstrap(kind: .developerID, allowNew: true) }
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func onlyDeveloperIDHasADocumentedCap() {
    // Apple documents no number for Apple Distribution or Mac Installer Distribution: App Store Connect decides.
    #expect(CertificateKind.distribution.cap == nil && CertificateKind.installer.cap == nil)
    #expect(CertificateKind.developerID.certificateType == .developerIDApplicationG2)
    #expect(CertificateKind.allCases.allSatisfy { $0.certificateType.rawValue == $0.createType })
}

@Test func bootstrapCreatesWhenNoneExist() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":\#(certJSON(id: "new", der: [0x30, 0x00]))}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let (key, cert) = try await svc.bootstrap(kind: .distribution, allowNew: false)
    #expect(cert.id == "new")
    #expect(key.pem.contains("PRIVATE KEY"))
    let body = String(decoding: t.requests[1].httpBody!, as: UTF8.self)
    #expect(body.contains("CERTIFICATE REQUEST") && body.contains("DISTRIBUTION"))
}

@Test func ambiguousCreateSendsOnePostAndExplains() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#), (503, #"{"errors":[]}"#), (200, #"{"data":[\#(certJSON(id: "1", der: [0x30, 0x00]))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    do { _ = try await svc.bootstrap(kind: .distribution, allowNew: false); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.cause.contains("ambiguous"))
        #expect(e.fix.contains("xless certs list --type distribution") && e.fix.contains("--allow-new"))
        #expect(e.isAmbiguousCertificateCreation)
    }
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func bootstrapWithProvidedKeyUsesItsCSR() async throws {
    let key = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":\#(certJSON(id: "n", der: [0x30, 0x00]))}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let cert = try await svc.bootstrap(kind: .distribution, allowNew: false, key: key)
    #expect(cert.id == "n")
}

@Test func undecodable2xxCreateIsAmbiguous() async throws {
    // The POST was accepted but the body can't be read: the certificate may exist, so the key must be kept.
    let t = MockTransport([(200, #"{"data":[]}"#), (201, "<html>not json</html>"), (200, #"{"data":[]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    do { _ = try await svc.bootstrap(kind: .distribution, allowNew: false, key: try SigningKey.generate()); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.isAmbiguousCertificateCreation) }
    catch { Issue.record("not an XlessError: \(error)") }
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func definite4xxCreateIsNotAmbiguous() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#), (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR"}]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    do { _ = try await svc.bootstrap(kind: .distribution, allowNew: false, key: try SigningKey.generate()); Issue.record("expected throw") }
    catch let e as XlessError { #expect(!e.isAmbiguousCertificateCreation) }
    catch let e as ASCError { #expect(e.status == 409) }
}

@Test func installerKindIsTheMacInstallerDistributionCertificate() async throws {
    #expect(CertificateKind.installer.rawValue == "installer")
    #expect(CertificateKind.installer.secretName == "XLESS_INSTALLER_KEY")
    #expect(CertificateKind.installer.createType == "MAC_INSTALLER_DISTRIBUTION")
    let key = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "I1", der: try selfSigned(key), type: "MAC_INSTALLER_DISTRIBUTION"))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    #expect(try await svc.find(matching: key, kind: .installer).id == "I1")
    #expect(t.requests[0].url!.absoluteString.contains("MAC_INSTALLER_DISTRIBUTION"))
}

@Test func listFollowsEveryPage() async throws {
    let key = try SigningKey.generate()
    let next = #""links":{"next":"https://api.appstoreconnect.apple.com/v1/certificates?cursor=2&filter%5BcertificateType%5D=DISTRIBUTION&limit=200"}"#
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "1", der: try selfSigned(try SigningKey.generate())))],\#(next)}"#),
                           (200, #"{"data":[\#(certJSON(id: "2", der: try selfSigned(key)))]}"#)])
    let svc = CertificateService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    #expect(try await svc.list(.distribution).map(\.id) == ["1", "2"])
    #expect(t.requests[0].url!.absoluteString.contains("limit=200"))
    #expect(t.requests[1].url!.absoluteString.contains("cursor=2"))
}
