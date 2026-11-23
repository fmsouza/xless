import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func profiles(_ t: MockTransport) -> ASCProfiles {
    ASCProfiles(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

/// A profile as App Store Connect returns it, linked to bundle ID `bundle`.
func profileJSON(_ id: String, name: String = "xless com.example.app IOS_APP_STORE", type: String = "IOS_APP_STORE", state: String = "ACTIVE",
                 bundle: String = "B1", expires: String = "2027-03-01T12:00:00.000+0000", uuid: String = "11111111-2222-3333-4444-555555555555",
                 content: String? = nil) -> String {
    #"{"type":"profiles","id":"\#(id)","attributes":{"name":"\#(name)","platform":"IOS","profileType":"\#(type)","profileState":"\#(state)","uuid":"\#(uuid)","createdDate":"2026-03-01T12:00:00.000+0000","expirationDate":"\#(expires)"\#(content.map { #","profileContent":"\#($0)""# } ?? "")},"relationships":{"bundleId":{"data":{"type":"bundleIds","id":"\#(bundle)"}}}}"#
}

func seededBundleIDJSON(_ id: String, identifier: String = "com.example.app", platform: String = "UNIVERSAL", seed: String = "ABCDE12345") -> String {
    #"{"type":"bundleIds","id":"\#(id)","attributes":{"identifier":"\#(identifier)","name":"Example","platform":"\#(platform)","seedId":"\#(seed)"}}"#
}

// MARK: - Types

@Test func theAPIsFourteenProfileTypes() {
    #expect(ProfileType.allCases.count == 14)
    #expect(ProfileType(argument: "ios-app-development") == .iosAppDevelopment)
    #expect(ProfileType(argument: "MAC_CATALYST_APP_DIRECT") == .macCatalystAppDirect)
    #expect(ProfileType(argument: " tvos app adhoc") == .tvosAppAdHoc)
    #expect(ProfileType(argument: "development") == nil)
    #expect(ProfileType.iosAppInHouse.argument == "ios-app-inhouse")
    #expect(ProfileType.macAppDirect.displayName == "macOS Developer ID")
    #expect(ProfileType.tvosAppAdHoc.displayName == "tvOS Ad Hoc")
}

@Test(arguments: ProfileType.allCases)
func onlyDevelopmentAndAdHocProfilesListDevices(type: ProfileType) {
    #expect(type.usesDevices == (type.rawValue.hasSuffix("_DEVELOPMENT") || type.rawValue.hasSuffix("_ADHOC")))
}

@Test func devicesOfTheRightKind() {
    #expect(ProfileType.tvosAppDevelopment.devicePlatform == .ios)
    #expect(ProfileType.macCatalystAppDevelopment.devicePlatform == .macOS)
    #expect(ProfileType.macAppDevelopment.devicePlatform == .macOS)
    #expect(ProfileType.tvosAppAdHoc.accepts(deviceClass: "APPLE_TV"))
    #expect(!ProfileType.tvosAppAdHoc.accepts(deviceClass: "IPHONE"))
    #expect(ProfileType.iosAppAdHoc.accepts(deviceClass: "IPAD"))
    #expect(!ProfileType.iosAppAdHoc.accepts(deviceClass: "APPLE_TV"))
    #expect(ProfileType.macAppDevelopment.accepts(deviceClass: "MAC"))
}

@Test func certificateTypesThatFit() {
    #expect(ProfileType.iosAppDevelopment.certificateTypes == [.development, .iosDevelopment])
    #expect(ProfileType.macCatalystAppDevelopment.certificateTypes == [.development, .macAppDevelopment])
    #expect(ProfileType.tvosAppAdHoc.certificateTypes == [.distribution, .iosDistribution])
    #expect(ProfileType.macAppStore.certificateTypes == [.distribution, .macAppDistribution])
    #expect(ProfileType.macAppDirect.certificateTypes == [.developerIDApplicationG2, .developerIDApplication])
    #expect(ProfileType.macCatalystAppDirect.certificateTypes == [.developerIDApplicationG2, .developerIDApplication])
}

@Test func bundlePlatformsThatFit() {
    #expect(ProfileType.macAppStore.accepts(bundlePlatform: "UNIVERSAL"))
    #expect(ProfileType.macAppStore.accepts(bundlePlatform: "MAC_OS"))
    #expect(!ProfileType.macAppStore.accepts(bundlePlatform: "IOS"))
    #expect(ProfileType.macCatalystAppStore.accepts(bundlePlatform: "IOS"))
    #expect(!ProfileType.macCatalystAppStore.accepts(bundlePlatform: "MAC_OS"))
    #expect(!ProfileType.tvosAppStore.accepts(bundlePlatform: "MAC_OS"))
    #expect(ProfileType.iosAppStore.accepts(bundlePlatform: nil))
}

// MARK: - Requests

@Test func listLeavesTheContentOutAndIncludesTheBundleID() async throws {
    let t = MockTransport([(200, #"{"data":[\#(profileJSON("P2", name: "b")),\#(profileJSON("P1", name: "A", bundle: "B2"))],"included":[\#(seededBundleIDJSON("B1")),\#(seededBundleIDJSON("B2", identifier: "com.example.other"))],"links":{"self":"x"}}"#)])
    let listing = try await profiles(t).list(types: [.iosAppStore, .iosAppAdHoc])
    #expect(listing.profiles.map(\.id) == ["P1", "P2"])
    #expect(listing.bundleID(of: listing.profiles[0])?.identifier == "com.example.other")
    #expect(listing.profiles[1].bundleIDResourceID == "B1")
    let q = query(t.requests[0])
    #expect(q.contains("filter[profileType]=IOS_APP_STORE,IOS_APP_ADHOC"))
    #expect(q.contains("include=bundleId"))
    #expect(q.contains { $0.hasPrefix("fields[profiles]=") && !$0.contains("profileContent") && $0.contains("bundleId") })
    #expect(q.contains("fields[bundleIds]=identifier,name,platform,seedId"))
}

@Test func getWithContentAsksForIt() async throws {
    let content = Data("CMS".utf8).base64EncodedString()
    let t = MockTransport([(200, #"{"data":\#(profileJSON("P1", content: content)),"included":[\#(seededBundleIDJSON("B1"))]}"#)])
    let (profile, bundle) = try await profiles(t).get(id: "P1", withContent: true)
    #expect(profile.content == Data("CMS".utf8))
    #expect(bundle?.attributes.seedId == "ABCDE12345")
    #expect(query(t.requests[0]).contains { $0.hasPrefix("fields[profiles]=") && $0.contains("profileContent") })
    await #expect(throws: XlessError.self) { _ = try await profiles(MockTransport([])).get(id: "../v1/apps") }
}

@Test func createSendsDevicesOnlyWhenThereAreSome() async throws {
    let t = MockTransport([(201, #"{"data":\#(profileJSON("P9"))}"#), (201, #"{"data":\#(profileJSON("P10"))}"#)])
    let p = profiles(t)
    _ = try await p.create(name: "n", type: .iosAppAdHoc, bundleIDResourceID: "B1", certificateIDs: ["C1", "C2"], deviceIDs: ["D1"])
    _ = try await p.create(name: "n", type: .iosAppStore, bundleIDResourceID: "B1", certificateIDs: ["C1"])
    let first = try body(t.requests[0])
    #expect(first["data"]?["attributes"]?["profileType"] == .string("IOS_APP_ADHOC"))
    #expect(first["data"]?["relationships"]?["bundleId"]?["data"]?["id"] == .string("B1"))
    #expect(first["data"]?["relationships"]?["certificates"]?["data"]?[1]?["id"] == .string("C2"))
    #expect(first["data"]?["relationships"]?["devices"]?["data"]?[0]?["type"] == .string("devices"))
    #expect(try body(t.requests[1])["data"]?["relationships"]?["devices"] == nil)
    #expect(t.requests.allSatisfy { $0.httpMethod == "POST" && $0.url!.path == "/v1/profiles" })
}

@Test func relationshipsAreReadInFull() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"certificates","id":"C1"}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/profiles/P1/relationships/certificates?cursor=2"}}"#),
        (200, #"{"data":[{"type":"certificates","id":"C2"}]}"#),
        (200, #"{"data":[{"type":"devices","id":"D1"}]}"#),
    ])
    let p = profiles(t)
    #expect(try await p.certificateIDs(of: "P1") == ["C1", "C2"])
    #expect(try await p.deviceIDs(of: "P1") == ["D1"])
}
