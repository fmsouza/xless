import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func resources(_ t: MockTransport) -> ASCResources {
    ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
}
private func bundleIDs(_ t: MockTransport) -> ASCBundleIDs { ASCBundleIDs(resources: resources(t)) }
private func merchantIDs(_ t: MockTransport) -> ASCMerchantIDs { ASCMerchantIDs(resources: resources(t)) }
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }
private func compact(_ r: URLRequest) -> String { String(decoding: r.httpBody ?? Data(), as: UTF8.self) }

/// A bundle ID as App Store Connect returns it (shape of GET /v1/bundleIds).
func bundleIDJSON(_ id: String, _ identifier: String, name: String = "My App", platform: String = "UNIVERSAL") -> String {
    #"{"type":"bundleIds","id":"\#(id)","attributes":{"name":"\#(name)","identifier":"\#(identifier)","platform":"\#(platform)","seedId":"ABCDE12345"},"relationships":{"bundleIdCapabilities":{"links":{"related":"x"}}},"links":{"self":"https://api.appstoreconnect.apple.com/v1/bundleIds/\#(id)"}}"#
}
func capabilityJSON(_ id: String, _ type: String, settings: String? = nil) -> String {
    #"{"type":"bundleIdCapabilities","id":"\#(id)","attributes":{"capabilityType":"\#(type)"\#(settings.map { #","settings":\#($0)"# } ?? "")}}"#
}
func merchantJSON(_ id: String, _ identifier: String, name: String = "Store") -> String {
    #"{"type":"merchantIds","id":"\#(id)","attributes":{"name":"\#(name)","identifier":"\#(identifier)"}}"#
}
func dataList(_ items: [String], next: String? = nil) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"\#(next.map { #","next":"\#($0)""# } ?? "")}}"#
}

// MARK: - Input

@Test func bundleIdentifiersAreChecked() throws {
    #expect(try BundleIdentifier.validate(" com.example.app ") == "com.example.app")
    #expect(try BundleIdentifier.validate("com.example.*") == "com.example.*")
    #expect(try BundleIdentifier.validate("com.Example-1.app") == "com.Example-1.app")
    for bad in ["", "com.example.app.", ".com.example", "com..example", "com.example/app", "com.example*", "com.exämple", "com.*.app"] {
        #expect(throws: IdentifierInputError.self, "\(bad)") { try BundleIdentifier.validate(bad) }
    }
    #expect(BundleIdentifier.isIdentifier("com.example.app") && !BundleIdentifier.isIdentifier("8U3T4X5YZA"))
}

@Test func portalNamesAreLettersDigitsAndSpaces() throws {
    try PortalName.validate("My App 2")
    for bad in ["", "  ", "My-App", "Café", "App!"] { #expect(throws: IdentifierInputError.self, "\(bad)") { try PortalName.validate(bad) } }
    #expect(PortalName.from(identifier: "com.example.my-app") == "com example my app")
    #expect(BundleIDPlatform(argument: "MacOS") == .macOS && BundleIDPlatform(argument: "Universal") == .universal && BundleIDPlatform(argument: "tvos") == nil)
    #expect(BundleIDPlatform.display("MAC_OS") == "macos" && BundleIDPlatform.display("SERVICES") == "SERVICES")
}

@Test func merchantIdentifiersStartWithMerchant() throws {
    #expect(try MerchantIdentifier.validate("merchant.com.example.store") == "merchant.com.example.store")
    for bad in ["", "merchant.", "com.example.store", "merchant..x", "merchant.x.", "merchant.a b"] {
        #expect(throws: IdentifierInputError.self, "\(bad)") { try MerchantIdentifier.validate(bad) }
    }
}

// MARK: - Bundle IDs

@Test func listFollowsPagesAndSortsByIdentifier() async throws {
    let t = MockTransport([
        (200, dataList([bundleIDJSON("B2", "com.example.zeta")], next: "https://api.appstoreconnect.apple.com/v1/bundleIds?cursor=AB&limit=200")),
        (200, dataList([bundleIDJSON("B1", "com.example.alpha")])),
    ])
    let list = try await bundleIDs(t).list(platform: .ios)
    #expect(list.map(\.identifier) == ["com.example.alpha", "com.example.zeta"])
    #expect(query(t.requests[0]) == ["filter[platform]=IOS", "limit=200"])
    #expect(list[0].attributes.seedId == "ABCDE12345")
}

@Test func resolveTakesAnIdentifierOrAnID() async throws {
    let byIdentifier = MockTransport([(200, dataList([bundleIDJSON("B1", "com.example.app.widget"), bundleIDJSON("B2", "com.example.app")]))])
    #expect(try await bundleIDs(byIdentifier).resolve("com.example.app").id == "B2")
    #expect(query(byIdentifier.requests[0]).contains("filter[identifier]=com.example.app"))

    let byID = MockTransport([(200, #"{"data":\#(bundleIDJSON("B7", "com.example.app"))}"#)])
    #expect(try await bundleIDs(byID).resolve("B7").identifier == "com.example.app")
    #expect(byID.requests[0].url!.path == "/v1/bundleIds/B7")

    let missing = MockTransport([(200, dataList([bundleIDJSON("B1", "com.example.app.widget")]))])
    do { _ = try await bundleIDs(missing).resolve("com.example.app"); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account && e.cause == "no bundle ID com.example.app is registered on this team")
        #expect(e.fix.contains("xless bundle-ids create com.example.app"))
    }
    await #expect(throws: XlessError.self) { _ = try await bundleIDs(MockTransport([])).resolve("../apps") }
}

@Test func createPostsOnceUnlessTheIdentifierExists() async throws {
    let t = MockTransport([(200, dataList([])), (201, #"{"data":\#(bundleIDJSON("B9", "com.example.app", name: "com example app"))}"#)])
    let result = try await bundleIDs(t).create(identifier: "com.example.app", name: "com example app", platform: .universal)
    guard case .created(let b) = result else { Issue.record("expected created"); return }
    #expect(b.id == "B9")
    #expect(t.requests.map(\.httpMethod) == ["GET", "POST"])
    #expect(try body(t.requests[1]) == JSONValue.object(["data": .object(["type": .string("bundleIds"), "attributes": .object([
        "identifier": .string("com.example.app"), "name": .string("com example app"), "platform": .string("UNIVERSAL")])])]))

    let known = MockTransport([(200, dataList([bundleIDJSON("B1", "com.example.app")]))])
    guard case .existing(let e) = try await bundleIDs(known).create(identifier: "com.example.app", name: "X", platform: .ios) else {
        Issue.record("expected existing"); return
    }
    #expect(e.id == "B1" && known.requests.count == 1)
}

@Test func deletingABundleIDSendsDelete() async throws {
    let t = MockTransport([(204, "")])
    let b = ASCBundleID(resource: ASCAnyResource(type: "bundleIds", id: "B1"))
    try await bundleIDs(t).delete(b)
    #expect(t.requests[0].httpMethod == "DELETE" && t.requests[0].url!.path == "/v1/bundleIds/B1")
}

@Test func aBundleIDKeepsEveryFieldAppleSent() throws {
    let b = try JSONDecoder().decode(ASCBundleID.self, from: Data(bundleIDJSON("B1", "com.example.app").utf8))
    let out = try JSONDecoder().decode(JSONValue.self, from: Data(try ASCOutput.json(b).utf8))
    #expect(out["links"]?["self"] != nil && out["relationships"] != nil && out["attributes"]?["seedId"] == .string("ABCDE12345"))
}

// MARK: - Capabilities

@Test func capabilitiesAreReadWithoutALimit() async throws {
    let t = MockTransport([(200, dataList([capabilityJSON("C1", "ICLOUD", settings: #"[{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_5","enabled":false},{"key":"XCODE_6","enabled":true}]}]"#)]))])
    let caps = try await bundleIDs(t).capabilities(of: "B1")
    #expect(t.requests[0].url!.path == "/v1/bundleIds/B1/bundleIdCapabilities")
    #expect(query(t.requests[0]).isEmpty)
    #expect(caps.map(\.capabilityType) == ["ICLOUD"] && caps[0].chosenSettings == ["ICLOUD_VERSION": "XCODE_6"])
}

@Test func enableCreatesTheCapabilityWithItsSettings() async throws {
    let t = MockTransport([(200, dataList([])), (201, #"{"data":\#(capabilityJSON("C9", "ICLOUD"))}"#)])
    let result = try await bundleIDs(t).enable(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_6")], on: "B1")
    guard case .enabled(let c) = result else { Issue.record("expected enabled"); return }
    #expect(c.id == "C9")
    #expect(t.requests[1].httpMethod == "POST" && t.requests[1].url!.path == "/v1/bundleIdCapabilities")
    #expect(try body(t.requests[1]) == JSONValue.object(["data": .object([
        "type": .string("bundleIdCapabilities"),
        "attributes": .object(["capabilityType": .string("ICLOUD"), "settings": .array([.object([
            "key": .string("ICLOUD_VERSION"), "options": .array([.object(["key": .string("XCODE_6"), "enabled": .bool(true)])])])])]),
        "relationships": .object(["bundleId": .object(["data": .object(["type": .string("bundleIds"), "id": .string("B1")])])]),
    ])]))
}

@Test func enableWithoutSettingsSendsNone() async throws {
    let t = MockTransport([(201, #"{"data":\#(capabilityJSON("C9", "PUSH_NOTIFICATIONS"))}"#)])
    _ = try await bundleIDs(t).enable(.pushNotifications, on: "B1", existing: [])
    #expect(t.requests.count == 1 && !compact(t.requests[0]).contains("settings"))
}

@Test func enablingWhatIsEnabledSendsNothingOrChangesTheSettings() async throws {
    let current = try JSONDecoder().decode(ASCBundleIDCapability.self, from: Data(capabilityJSON("C1", "DATA_PROTECTION",
        settings: #"[{"key":"DATA_PROTECTION_PERMISSION_LEVEL","options":[{"key":"COMPLETE_PROTECTION","enabled":true},{"key":"PROTECTED_UNLESS_OPEN","enabled":false}]}]"#).utf8))
    let same = MockTransport([])
    guard case .unchanged = try await bundleIDs(same).enable(.dataProtection, settings: [CapabilitySetting(.dataProtectionPermissionLevel, "COMPLETE_PROTECTION")],
                                                            on: "B1", existing: [current]) else { Issue.record("expected unchanged"); return }
    guard case .unchanged = try await bundleIDs(same).enable(.dataProtection, on: "B1", existing: [current]) else { Issue.record("expected unchanged"); return }
    #expect(same.requests.isEmpty)

    let other = MockTransport([(200, #"{"data":\#(capabilityJSON("C1", "DATA_PROTECTION"))}"#)])
    guard case .updated = try await bundleIDs(other).enable(.dataProtection, settings: [CapabilitySetting(.dataProtectionPermissionLevel, "PROTECTED_UNLESS_OPEN")],
                                                           on: "B1", existing: [current]) else { Issue.record("expected updated"); return }
    #expect(other.requests[0].httpMethod == "PATCH" && other.requests[0].url!.path == "/v1/bundleIdCapabilities/C1")
    let sent = try body(other.requests[0])
    #expect(sent["data"]?["id"] == .string("C1") && sent["data"]?["type"] == .string("bundleIdCapabilities"))
    #expect(sent["data"]?["attributes"]?["settings"]?[0]?["options"]?[0]?["key"] == .string("PROTECTED_UNLESS_OPEN"))
}

@Test func disableDeletesTheCapability() async throws {
    let t = MockTransport([(204, "")])
    try await bundleIDs(t).disable(ASCBundleIDCapability(resource: ASCAnyResource(type: "bundleIdCapabilities", id: "C1")))
    #expect(t.requests[0].httpMethod == "DELETE" && t.requests[0].url!.path == "/v1/bundleIdCapabilities/C1")
}

// MARK: - Merchant IDs

@Test func merchantIDsAreListedCreatedOnceAndDeleted() async throws {
    let list = MockTransport([(200, dataList([merchantJSON("M2", "merchant.com.b"), merchantJSON("M1", "merchant.com.a")]))])
    #expect(try await merchantIDs(list).list().map(\.id) == ["M1", "M2"])
    #expect(list.requests[0].url!.path == "/v1/merchantIds" && query(list.requests[0]) == ["limit=200"])

    let create = MockTransport([(200, dataList([])), (201, #"{"data":\#(merchantJSON("M3", "merchant.com.c", name: "Shop"))}"#)])
    guard case .created(let m) = try await merchantIDs(create).create(identifier: "merchant.com.c", name: "Shop") else { Issue.record("expected created"); return }
    #expect(m.name == "Shop")
    #expect(try body(create.requests[1]) == JSONValue.object(["data": .object(["type": .string("merchantIds"), "attributes": .object([
        "identifier": .string("merchant.com.c"), "name": .string("Shop")])])]))

    let known = MockTransport([(200, dataList([merchantJSON("M1", "merchant.com.a")]))])
    guard case .existing = try await merchantIDs(known).create(identifier: "merchant.com.a", name: "X") else { Issue.record("expected existing"); return }
    #expect(known.requests.count == 1)

    let resolveAndDelete = MockTransport([(200, dataList([merchantJSON("M1", "merchant.com.a")])), (204, "")])
    let found = try await merchantIDs(resolveAndDelete).resolve("merchant.com.a")
    try await merchantIDs(resolveAndDelete).delete(found)
    #expect(resolveAndDelete.requests[1].httpMethod == "DELETE" && resolveAndDelete.requests[1].url!.path == "/v1/merchantIds/M1")
}
