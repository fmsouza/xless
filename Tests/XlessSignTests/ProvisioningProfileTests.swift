import Foundation
import SwiftASN1
import Testing
@testable import XlessCore
@testable import XlessSign

/// A profile's property list, as App Store Connect makes it.
func profilePlist(team: String = "ABCDE12345", appID: String = "ABCDE12345.com.example.app", uuid: String = "11111111-2222-3333-4444-555555555555",
                  mac: Bool = false, devices: [String] = []) -> Data {
    var entitlements: [String: Any] = [mac ? "com.apple.application-identifier" : "application-identifier": appID,
                                       "com.apple.developer.team-identifier": team]
    if !mac { entitlements["get-task-allow"] = false }
    var plist: [String: Any] = ["Name": "xless com.example.app IOS_APP_STORE", "UUID": uuid, "TeamIdentifier": [team], "TeamName": "Example",
                                "ExpirationDate": Date(timeIntervalSince1970: 1_900_000_000), "Entitlements": entitlements]
    if !devices.isEmpty { plist["ProvisionedDevices"] = devices }
    return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

/// A DER CMS SignedData envelope around `content` (no signer: the parser does not look at it).
func cmsDER(_ content: Data, contentType: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 2]) -> Data {
    var s = DER.Serializer()
    let ctx0 = ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
    try! s.appendConstructedNode(identifier: .sequence) { s in
        try s.serialize(contentType)
        try s.appendConstructedNode(identifier: ctx0) { s in
            try s.appendConstructedNode(identifier: .sequence) { s in
                try s.serialize(1)
                try s.appendConstructedNode(identifier: .set) { _ in }
                try s.appendConstructedNode(identifier: .sequence) { s in
                    try s.serialize([1, 2, 840, 113549, 1, 7, 1] as ASN1ObjectIdentifier)
                    try s.appendConstructedNode(identifier: ctx0) { s in try s.serialize(ASN1OctetString(contentBytes: Array(content)[...])) }
                }
                try s.appendConstructedNode(identifier: .set) { _ in }
            }
        }
    }
    return Data(s.serializedBytes)
}

/// The same envelope in BER with indefinite lengths and the content split into two OCTET STRING chunks.
func cmsBER(_ content: Data) -> Data {
    func definite(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        return [tag] + length + body
    }
    func indefinite(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, 0x80] + body + [0, 0] }
    let signedData: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
    let data: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
    let bytes = Array(content), half = bytes.count / 2
    let chunks = indefinite(0x24, definite(0x04, Array(bytes[..<half])) + definite(0x04, Array(bytes[half...])))
    let encap = indefinite(0x30, data + indefinite(0xA0, chunks))
    let signed = indefinite(0x30, [0x02, 0x01, 0x01] + [0x31, 0x00] + encap + [0x31, 0x00])
    return Data(indefinite(0x30, signedData + indefinite(0xA0, signed)))
}

@Test func parsesADERProfile() throws {
    let p = try ProvisioningProfile.parse(cmsDER(profilePlist(devices: ["00008030-001A35E80C42802E"])))
    #expect(p.teamIdentifiers == ["ABCDE12345"])
    #expect(p.applicationIdentifier == "ABCDE12345.com.example.app")
    #expect(p.uuid == "11111111-2222-3333-4444-555555555555")
    #expect(p.provisionedDevices == ["00008030-001A35E80C42802E"])
    #expect(p.expirationDate == Date(timeIntervalSince1970: 1_900_000_000))
}

@Test func parsesABERProfileWithIndefiniteLengthsAndChunks() throws {
    #expect(try ProvisioningProfile.content(ofCMS: cmsBER(profilePlist())) == profilePlist())
    #expect(try ProvisioningProfile.parse(cmsBER(profilePlist())).applicationIdentifier == "ABCDE12345.com.example.app")
}

@Test func refusesWhatIsNotAProfileEnvelope() {
    for bad in [profilePlist(), Data(), Data("garbage".utf8), cmsDER(profilePlist(), contentType: [1, 2, 840, 113549, 1, 7, 1]),
                cmsDER(Data("not a plist".utf8))] {
        #expect(throws: XlessError.self) { _ = try ProvisioningProfile.parse(bad) }
    }
    do { _ = try ProvisioningProfile.parse(profilePlist()); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.stage == .account && e.cause.hasPrefix("the profile is not a CMS envelope"))
    } catch { Issue.record("\(error)") }
}

@Test func verifiesTeamApplicationIdentifierAndUUID() throws {
    let p = try ProvisioningProfile.parse(cmsDER(profilePlist()))
    try p.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.app", uuid: "11111111-2222-3333-4444-555555555555")
    try p.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.app")
    #expect(throws: XlessError.self) { try p.verify(team: "ZZZZZ99999", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.app") }
    #expect(throws: XlessError.self) { try p.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.other") }
    #expect(throws: XlessError.self) { try p.verify(team: "ABCDE12345", appIDPrefix: "ZZZZZ99999", bundleIdentifier: "com.example.app") }
    #expect(throws: XlessError.self) { try p.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.app", uuid: "other") }
}

@Test func verifiesWildcardAndMacProfiles() throws {
    let wildcard = try ProvisioningProfile.parse(cmsDER(profilePlist(appID: "ABCDE12345.com.example.*")))
    try wildcard.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.*")
    let mac = try ProvisioningProfile.parse(cmsDER(profilePlist(mac: true)))
    #expect(mac.applicationIdentifier == "ABCDE12345.com.example.app")
    try mac.verify(team: "ABCDE12345", appIDPrefix: "ABCDE12345", bundleIdentifier: "com.example.app")
}
