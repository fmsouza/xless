import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

func certJSON(id: String, der: [UInt8], type: String = "DISTRIBUTION", expires: String = "2030-01-01T00:00:00.000+0000") -> String {
    #"{"type":"certificates","id":"\#(id)","attributes":{"certificateType":"\#(type)","certificateContent":"\#(Data(der).base64EncodedString())","name":"c","expirationDate":"\#(expires)"}}"#
}

private func certificates(_ t: MockTransport) -> ASCCertificates {
    ASCCertificates(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private let today = ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z")!

@Test func findsTheCertificateOfAKey() async throws {
    let key = try SigningKey.generate(), other = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "1", der: try selfSigned(other))),\#(certJSON(id: "2", der: try selfSigned(key)))]}"#)])
    let found = try await certificates(t).find(for: key, kind: .distribution, now: today)
    #expect(found.certificate.id == "2" && found.der == found.certificate.der)
    #expect(t.requests[0].url!.absoluteString.contains("filter%5BcertificateType%5D=DISTRIBUTION"))
}

@Test func noCertificateForTheKeyExplainsBootstrap() async throws {
    let key = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[]}"#)])
    do { _ = try await certificates(t).find(for: key, kind: .distribution, now: today); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign && e.cause == "no distribution certificate in App Store Connect matches XLESS_DIST_KEY")
        #expect(e.fix == "run `xless sign bootstrap --type distribution` (or check you set the right key)")
    }
}

/// A certificate that expired signs nothing Apple accepts: the error names the day instead of failing at the profile.
@Test func anExpiredCertificateIsRefusedWithItsDay() async throws {
    let key = try SigningKey.generate()
    let expired = certJSON(id: "1", der: try selfSigned(key), expires: "2026-11-24T12:00:00.000+0000")
    let t = MockTransport([(200, #"{"data":[\#(expired)]}"#)])
    do { _ = try await certificates(t).find(for: key, kind: .distribution, now: today); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign && e.cause == "the distribution certificate 1 of XLESS_DIST_KEY expired on 2026-11-24")
        #expect(e.fix.contains("xless sign bootstrap --type distribution"))
    }
    // A valid one for the same key is taken instead.
    let both = MockTransport([(200, #"{"data":[\#(expired),\#(certJSON(id: "2", der: try selfSigned(key)))]}"#)])
    #expect(try await certificates(both).find(for: key, kind: .distribution, now: today).certificate.id == "2")
}

@Test func aCertificateWithoutContentMatchesNothing() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"certificates","id":"1","attributes":{"certificateType":"DISTRIBUTION"}}]}"#)])
    await #expect(throws: XlessError.self) { _ = try await certificates(t).find(for: try SigningKey.generate(), kind: .distribution, now: today) }
}

@Test func onlyDeveloperIDHasADocumentedCap() {
    // Apple documents no number for Apple Distribution or Mac Installer Distribution: App Store Connect decides.
    #expect(CertificateKind.developerID.certificateType.cap == 5)
    #expect(CertificateKind.distribution.certificateType.cap == nil && CertificateKind.installer.certificateType.cap == nil)
    #expect(CertificateKind.developerID.certificateType == .developerIDApplicationG2)
    #expect(CertificateKind.developerID.types == [.developerIDApplicationG2, .developerIDApplication])
    #expect(CertificateKind.allCases.allSatisfy { $0.types.first == $0.certificateType })
}

@Test func installerKindIsTheMacInstallerDistributionCertificate() async throws {
    #expect(CertificateKind.installer.rawValue == "installer")
    #expect(CertificateKind.installer.secretName == "XLESS_INSTALLER_KEY")
    #expect(CertificateKind.installer.certificateType.rawValue == "MAC_INSTALLER_DISTRIBUTION")
    let key = try SigningKey.generate()
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "I1", der: try selfSigned(key), type: "MAC_INSTALLER_DISTRIBUTION"))]}"#)])
    #expect(try await certificates(t).find(for: key, kind: .installer, now: today).certificate.id == "I1")
    #expect(t.requests[0].url!.absoluteString.contains("MAC_INSTALLER_DISTRIBUTION"))
}

@Test func findFollowsEveryPage() async throws {
    let key = try SigningKey.generate()
    let next = #""links":{"next":"https://api.appstoreconnect.apple.com/v1/certificates?cursor=2&filter%5BcertificateType%5D=DISTRIBUTION&limit=200"}"#
    let t = MockTransport([(200, #"{"data":[\#(certJSON(id: "1", der: try selfSigned(try SigningKey.generate())))],\#(next)}"#),
                           (200, #"{"data":[\#(certJSON(id: "2", der: try selfSigned(key)))]}"#)])
    #expect(try await certificates(t).find(for: key, kind: .distribution, now: today).certificate.id == "2")
    #expect(t.requests[0].url!.absoluteString.contains("limit=200"))
    #expect(t.requests[1].url!.absoluteString.contains("cursor=2"))
}
