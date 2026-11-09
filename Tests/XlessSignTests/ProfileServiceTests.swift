import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

let future = "2099-01-01T00:00:00.000+0000"

@Test func reusesExistingBundleID() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIds","id":"B1","attributes":{"identifier":"a.b","platform":"IOS"}},{"type":"bundleIds","id":"B2","attributes":{"identifier":"a.b.c","platform":"IOS"}}]}"#)])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    #expect(try await svc.ensureBundleID(identifier: "a.b", platform: .ios) == "B1")
}

@Test func createsMissingBundleID() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":{"type":"bundleIds","id":"NEW","attributes":{"identifier":"a.b","platform":"IOS"}}}"#)])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    #expect(try await svc.ensureBundleID(identifier: "a.b", platform: .ios) == "NEW")
    #expect(String(decoding: t.requests[1].httpBody!, as: UTF8.self).contains("\"identifier\":\"a.b\""))
}

@Test func bundleIDNameContainsOnlyAlphanumericsAndSpaces() async throws {
    // App Store Connect 409: "xless com.example.helloship" is not a valid name for an app id (alphanumerics and spaces only).
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":{"type":"bundleIds","id":"NEW","attributes":{"identifier":"com.example.helloship","platform":"UNIVERSAL"}}}"#)])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    _ = try await svc.ensureBundleID(identifier: "com.example.helloship", platform: .ios)
    let json = try JSONSerialization.jsonObject(with: t.requests[1].httpBody!) as! [String: Any]
    let attrs = (json["data"] as! [String: Any])["attributes"] as! [String: String]
    #expect(attrs["identifier"] == "com.example.helloship")
    #expect(attrs["name"] == "xless com example helloship")
    #expect(attrs["name"]!.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") })
}

@Test func bundleIDNameSanitizerCollapsesAndBounds() {
    #expect(ProfileService.bundleIDName(for: "a..b-_c") == "xless a b c")
    #expect(ProfileService.bundleIDName(for: "é.ü").allSatisfy { $0.isASCII })
    #expect(ProfileService.bundleIDName(for: String(repeating: "a.", count: 400)).count <= 255)
}

@Test(arguments: Platform.allCases)
func registersNewBundleIDsAsUniversal(platform: Platform) async throws {
    // One identifier serves both the iOS and the macOS build (BundleIdPlatform: IOS, MAC_OS, UNIVERSAL in Apple's OpenAPI spec 4.5.1).
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":{"type":"bundleIds","id":"NEW","attributes":{"identifier":"a.b","platform":"UNIVERSAL"}}}"#)])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    _ = try await svc.ensureBundleID(identifier: "a.b", platform: platform)
    let body = String(decoding: t.requests[1].httpBody!, as: UTF8.self)
    #expect(body.contains("\"platform\":\"UNIVERSAL\""))
}

@Test func reusesActiveProfileContainingCertificate() async throws {
    let content = Data("PROFILE".utf8).base64EncodedString()
    let t = MockTransport([
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(content)","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"B1"}}"#),
    ])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let data = try await svc.ensureProfile(bundleIDResourceID: "B1", certificateID: "C1", type: .iosAppStore, bundleIdentifier: "a.b")
    #expect(data == Data("PROFILE".utf8))
    #expect(t.requests.count == 3)
}

@Test func recreatesProfileMissingCertificate() async throws {
    let content = Data("NEW".utf8).base64EncodedString()
    let t = MockTransport([
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"x","expirationDate":"\#(future)"}}]}"#),
        (200, #"{"data":[{"type":"certificates","id":"OLD"}]}"#),
        (204, ""),
        (201, #"{"data":{"type":"profiles","id":"P2","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(content)","expirationDate":"\#(future)"}}}"#),
    ])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let data = try await svc.ensureProfile(bundleIDResourceID: "B1", certificateID: "C1", type: .iosAppStore, bundleIdentifier: "a.b")
    #expect(data == Data("NEW".utf8))
    #expect(t.requests[2].httpMethod == "DELETE")
    let body = String(decoding: t.requests[3].httpBody!, as: UTF8.self)
    #expect(body.contains("\"C1\"") && body.contains("\"B1\""))
}

private func profileJSON(id: String, content: String = "x", exp: String) -> String {
    #"{"data":[{"type":"profiles","id":"\#(id)","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(content)","expirationDate":"\#(exp)"}}]}"#
}
private let created = #"{"data":{"type":"profiles","id":"P2","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"TkVX","expirationDate":"2099-01-01T00:00:00.000+0000"}}}"#

@Test func recreatesProfileForDifferentBundleID() async throws {
    let t = MockTransport([
        (200, profileJSON(id: "P1", exp: future)),
        (200, #"{"data":[{"type":"certificates","id":"C1"}]}"#),
        (200, #"{"data":{"type":"bundleIds","id":"OTHER"}}"#),
        (204, ""),
        (201, created),
    ])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let data = try await svc.ensureProfile(bundleIDResourceID: "B1", certificateID: "C1", type: .iosAppStore, bundleIdentifier: "a.b")
    #expect(data == Data("NEW".utf8))
    #expect(t.requests[3].httpMethod == "DELETE")
}

@Test func recreatesExpiredAndNearExpiryProfiles() async throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!
    for exp in ["2026-10-01T00:00:00.000+0000", "2026-10-18T00:00:00.000+0000"] {
        let t = MockTransport([(200, profileJSON(id: "P1", exp: exp)), (204, ""), (201, created)])
        let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), now: { now })
        let data = try await svc.ensureProfile(bundleIDResourceID: "B1", certificateID: "C1", type: .iosAppStore, bundleIdentifier: "a.b")
        #expect(data == Data("NEW".utf8))
        #expect(t.requests[1].httpMethod == "DELETE")
    }
}

@Test func parsesAllASCDateFormats() {
    for s in ["2027-05-01T10:20:30.123+0000", "2027-05-01T10:20:30+0000", "2027-05-01T10:20:30.123Z",
              "2027-05-01T10:20:30Z", "2027-05-01T12:20:30.123+02:00", "2027-05-01T12:20:30+02:00"] {
        let d = ProfileService.parseDate(s)
        #expect(d != nil, "\(s)")
        if let d { #expect(Int(d.timeIntervalSince1970) / 60 == Int(ISO8601DateFormatter().date(from: "2027-05-01T10:20:30Z")!.timeIntervalSince1970) / 60, "\(s)") }
    }
    #expect(ProfileService.parseDate("garbage") == nil)
}

@Test func forceNewReplacesAnOtherwiseReusableProfile() async throws {
    let content = Data("PROFILE".utf8).base64EncodedString()
    let t = MockTransport([
        (200, #"{"data":[{"type":"profiles","id":"P1","attributes":{"name":"xless a.b IOS_APP_STORE","profileState":"ACTIVE","profileType":"IOS_APP_STORE","profileContent":"\#(content)","expirationDate":"\#(future)"}}]}"#),
        (204, ""),
        (201, #"{"data":{"type":"profiles","id":"P2","attributes":{"profileContent":"\#(Data("FRESH".utf8).base64EncodedString())"}}}"#),
    ])
    let svc = ProfileService(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
    let data = try await svc.ensureProfile(bundleIDResourceID: "B1", certificateID: "C1", type: .iosAppStore, bundleIdentifier: "a.b", forceNew: true)
    #expect(data == Data("FRESH".utf8))
    #expect(t.requests.map { $0.httpMethod ?? "" } == ["GET", "DELETE", "POST"])
}

@Test func profileTypeFollowsPlatformAndDistribution() {
    #expect(ProfileType.for(platform: .ios, distribution: .appStore) == .iosAppStore)
    #expect(ProfileType.for(platform: .macos, distribution: .developerID) == .macDirect)
    #expect(ProfileType.for(platform: .macos, distribution: .appStore) == .macAppStore)
    #expect(ProfileType.macAppStore.rawValue == "MAC_APP_STORE")
}
