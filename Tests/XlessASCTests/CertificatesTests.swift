import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func certificates(_ t: MockTransport) -> ASCCertificates {
    ASCCertificates(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

/// A certificate as App Store Connect returns it.
func certificateJSON(_ id: String, type: String = "DISTRIBUTION", expires: String = "2027-03-01T12:00:00.000+0000", content: String? = nil) -> String {
    #"{"type":"certificates","id":"\#(id)","attributes":{"name":"Apple Distribution: Example","certificateType":"\#(type)","displayName":"Example","serialNumber":"5A1B","platform":null,"expirationDate":"\#(expires)","activated":true\#(content.map { #","certificateContent":"\#($0)""# } ?? "")}}"#
}

// MARK: - Types

@Test func theAPIsEighteenCertificateTypes() {
    #expect(CertificateType.allCases.count == 18)
    #expect(Set(CertificateType.allCases.map(\.rawValue)).count == 18)
    #expect(CertificateType(argument: "developer-id-application-g2") == .developerIDApplicationG2)
    #expect(CertificateType(argument: "Mac App Development") == .macAppDevelopment)
    #expect(CertificateType(argument: "distribution") == .distribution)
    #expect(CertificateType(argument: "developer-id") == .developerIDApplicationG2)
    #expect(CertificateType(argument: "installer") == .macInstallerDistribution)
    #expect(CertificateType(argument: "DEVELOPER_ID_INSTALLER") == nil)
    #expect(CertificateType(argument: "nope") == nil)
    for type in CertificateType.allCases { #expect(CertificateType(argument: type.argument) == type) }
    #expect(CertificateType.passTypeIDWithNFC.argument == "pass-type-id-with-nfc")
}

@Test func onlyDeveloperIDApplicationHasADocumentedCap() {
    for type in CertificateType.allCases {
        let developerIDApplication = type == .developerIDApplication || type == .developerIDApplicationG2
        #expect(type.cap == (developerIDApplication ? 5 : nil), "\(type)")
        #expect(type.capGroup.isEmpty == !developerIDApplication)
    }
}

@Test func defaultEntryNamesAreTheOnesSignReads() {
    #expect(CertificateType.distribution.defaultEntryBase == "XLESS_DIST_KEY")
    #expect(CertificateType.developerIDApplication.defaultEntryBase == "XLESS_DEVID_KEY")
    #expect(CertificateType.developerIDApplicationG2.defaultEntryBase == "XLESS_DEVID_KEY")
    #expect(CertificateType.macInstallerDistribution.defaultEntryBase == "XLESS_INSTALLER_KEY")
    #expect(CertificateType.iosDevelopment.defaultEntryBase == "XLESS_IOS_DEVELOPMENT_KEY")
    #expect(CertificateType.applePay.needsECCKey && CertificateType.allCases.filter(\.needsECCKey).count == 1)
}

// MARK: - Create

@Test func everyTypesCreateBody() async throws {
    for type in CertificateType.allCases {
        let t = MockTransport([(201, #"{"data":\#(certificateJSON("NEW1", type: type.rawValue))}"#)])
        let related: String? = type.relationship == nil ? nil : "REL123"
        let created = try await certificates(t).create(type: type, csrPEM: "-----BEGIN CERTIFICATE REQUEST-----\nAA\n-----END CERTIFICATE REQUEST-----\n", relatedID: related)
        #expect(created.id == "NEW1")
        #expect(t.requests.count == 1)
        let r = t.requests[0]
        #expect(r.httpMethod == "POST" && r.url!.path == "/v1/certificates")
        let data = try #require(try body(r)["data"])
        #expect(data["type"]?.string == "certificates")
        #expect(data["attributes"]?["certificateType"]?.string == type.rawValue)
        #expect(data["attributes"]?["csrContent"]?.string?.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----") == true)
        if case .object(let attrs)? = data["attributes"] { #expect(Set(attrs.keys) == ["certificateType", "csrContent"]) }
        switch type.relationship {
        case nil:
            #expect(data["relationships"] == nil, "\(type)")
        case .merchantID?:
            #expect(data["relationships"] == .object(["merchantId": .object(["data": .object(["type": .string("merchantIds"), "id": .string("REL123")])])]), "\(type)")
        case .passTypeID?:
            #expect(data["relationships"] == .object(["passTypeId": .object(["data": .object(["type": .string("passTypeIds"), "id": .string("REL123")])])]), "\(type)")
        }
    }
    #expect(CertificateType.allCases.filter { $0.relationship == .merchantID }.count == 4)
    #expect(CertificateType.allCases.filter { $0.relationship == .passTypeID }.count == 2)
}

@Test func aMissingOrStrayRelationshipIsRefusedBeforeSending() async throws {
    let t = MockTransport([])
    await #expect(throws: XlessError.self) { _ = try await certificates(t).create(type: .applePayMerchantIdentity, csrPEM: "x") }
    await #expect(throws: XlessError.self) { _ = try await certificates(t).create(type: .passTypeID, csrPEM: "x") }
    await #expect(throws: XlessError.self) { _ = try await certificates(t).create(type: .distribution, csrPEM: "x", relatedID: "M1") }
    #expect(t.requests.isEmpty)
}

@Test func aFailedCreateIsSentOnce() async throws {
    let t = MockTransport([(503, #"{"errors":[]}"#)])
    await #expect(throws: (any Error).self) { _ = try await certificates(t).create(type: .development, csrPEM: "x") }
    #expect(t.requests.count == 1)
}

@Test func whichFailuresMayHaveCreatedTheCertificate() {
    #expect(ASCCertificates.isAmbiguous(ASCError(status: 503, items: [])))
    #expect(ASCCertificates.isAmbiguous(ASCError(status: 429, items: [])))
    #expect(ASCCertificates.isAmbiguous(URLError(.timedOut)))
    #expect(ASCCertificates.isAmbiguous(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))))
    #expect(!ASCCertificates.isAmbiguous(ASCError(status: 409, items: [])))
    #expect(!ASCCertificates.isAmbiguous(ASCError(status: 403, items: [])))
    #expect(!ASCCertificates.isAmbiguous(XlessError(.account, "x", fix: "y")))
}

// MARK: - Read, revoke

@Test func listFiltersByTypeAndLeavesTheContentOut() async throws {
    let t = MockTransport([(200, dataList([certificateJSON("B", type: "DISTRIBUTION"), certificateJSON("A", type: "DEVELOPMENT")]))])
    let list = try await certificates(t).list(types: [.distribution, .development])
    #expect(list.map(\.id) == ["A", "B"])
    let q = query(t.requests[0])
    #expect(q.contains("filter[certificateType]=DISTRIBUTION,DEVELOPMENT"))
    #expect(q.contains("fields[certificates]=name,certificateType,displayName,serialNumber,platform,expirationDate,activated"))
    #expect(q.contains("limit=200"))
    #expect(list[1].expires == Date(timeIntervalSince1970: 1_803_902_400))

    let all = MockTransport([(200, dataList([]))])
    _ = try await certificates(all).list(withContent: true)
    #expect(!query(all.requests[0]).contains { $0.hasPrefix("filter") })
    #expect(query(all.requests[0]).contains { $0.hasPrefix("fields[certificates]=") && $0.hasSuffix(",certificateContent") })
}

@Test func getAndRevokeUseTheCertificatesPath() async throws {
    let t = MockTransport([(200, #"{"data":\#(certificateJSON("C1", content: "MAA="))}"#), (204, "")])
    let c = try await certificates(t).get(id: "C1")
    #expect(c.der == Data([0x30, 0x00]))
    try await certificates(t).revoke(id: "C1")
    #expect(t.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == ["GET /v1/certificates/C1", "DELETE /v1/certificates/C1"])
    await #expect(throws: XlessError.self) { try await certificates(MockTransport([])).revoke(id: "../x") }
}

@Test func theProfilesThatContainACertificate() async throws {
    func profile(_ id: String, _ name: String, certs: [String]) -> String {
        let refs = certs.map { #"{"type":"certificates","id":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"profiles","id":"\#(id)","attributes":{"name":"\#(name)","profileType":"IOS_APP_STORE","profileState":"ACTIVE"},"relationships":{"certificates":{"data":[\#(refs)]}}}"#
    }
    let t = MockTransport([(200, dataList([profile("P2", "b", certs: ["C1", "C2"]), profile("P1", "a", certs: ["C1"]), profile("P3", "c", certs: ["C3"])]))])
    let using = try await certificates(t).profiles(using: "C1")
    #expect(using == [ASCCertificateProfile(id: "P1", name: "a", profileType: "IOS_APP_STORE", profileState: "ACTIVE"),
                      ASCCertificateProfile(id: "P2", name: "b", profileType: "IOS_APP_STORE", profileState: "ACTIVE")])
    let q = query(t.requests[0])
    #expect(t.requests[0].url!.path == "/v1/profiles")
    #expect(q.contains("include=certificates") && q.contains("limit[certificates]=50"))
    #expect(q.contains("fields[profiles]=name,profileType,profileState,certificates"))
}

@Test func revokeReadsEveryProfilePageAndEveryCertificateOfAProfile() async throws {
    func refs(_ ids: [String]) -> String { ids.map { #"{"type":"certificates","id":"\#($0)"}"# }.joined(separator: ",") }
    func profile(_ id: String, certs: [String], total: Int?) -> String {
        let meta = total.map { #","meta":{"paging":{"total":\#($0),"limit":50}}"# } ?? ""
        return #"{"type":"profiles","id":"\#(id)","attributes":{"name":"\#(id.lowercased())","profileType":"IOS_APP_STORE","profileState":"ACTIVE"},"relationships":{"certificates":{"data":[\#(refs(certs))]\#(meta)}}}"#
    }
    let fifty = (1...50).map { "X\($0)" }
    let next = "https://api.appstoreconnect.apple.com/v1/profiles?cursor=AB&limit=200"
    let t = MockTransport([
        // Page 1: P1 lists 50 of its 51 certificates (C1 is the 51st), P2 has exactly 50 and says so (nothing more to read),
        // P3 lists 50 and gives no total (it may have more).
        (200, dataList([profile("P1", certs: fifty, total: 51), profile("P2", certs: fifty, total: 50), profile("P3", certs: fifty, total: nil)], next: next)),
        // Page 2 of the profiles: P4 holds C1 in its first 50.
        (200, dataList([profile("P4", certs: ["C1"], total: 1)])),
        // P1's certificates, two pages.
        (200, #"{"data":[\#(refs(fifty))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/profiles/P1/relationships/certificates?cursor=CD"}}"#),
        (200, #"{"data":[\#(refs(["C1"]))],"links":{"self":"x"}}"#),
        // P3's certificates: C1 is not among them.
        (200, #"{"data":[\#(refs(fifty + ["X51"]))],"links":{"self":"x"}}"#),
    ])
    let using = try await certificates(t).profiles(using: "C1")
    #expect(using.map(\.id) == ["P1", "P4"])
    #expect(t.requests.map { $0.url!.path } == ["/v1/profiles", "/v1/profiles", "/v1/profiles/P1/relationships/certificates",
                                                "/v1/profiles/P1/relationships/certificates", "/v1/profiles/P3/relationships/certificates"])
}

@Test func passTypeIDsResolveByIdentifier() async throws {
    let t = MockTransport([(200, dataList([#"{"type":"passTypeIds","id":"PT1","attributes":{"identifier":"pass.com.example.ticket","name":"Ticket"}}"#]))])
    #expect(try await certificates(t).passTypeID("pass.com.example.ticket") == "PT1")
    #expect(query(t.requests[0]).contains("filter[identifier]=pass.com.example.ticket"))
    #expect(try await certificates(MockTransport([])).passTypeID("PT9") == "PT9")
    await #expect(throws: XlessError.self) { _ = try await certificates(MockTransport([(200, dataList([]))])).passTypeID("pass.com.example.none") }
}

@Test func expirationDatesInBothForms() {
    #expect(ASCCertificates.parseDate("2027-03-01T12:00:00.000+0000") == Date(timeIntervalSince1970: 1_803_902_400))
    #expect(ASCCertificates.parseDate("2027-03-01T12:00:00Z") == Date(timeIntervalSince1970: 1_803_902_400))
    #expect(ASCCertificates.parseDate("soon") == nil)
}
