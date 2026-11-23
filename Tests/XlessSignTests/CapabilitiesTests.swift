import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

private let testMap: [String: CapabilityType] = ["com.apple.developer.associated-domains": .associatedDomains]

@Test func mappedKeyNeedsItsCapability() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.associated-domains": ["applinks:example.com"]], platform: .ios, map: testMap)
    #expect(r.types == ["ASSOCIATED_DOMAINS"])
    #expect(r.unmapped.isEmpty)
}

@Test func memoryLimitKeyIsPortalOnlyAndUnmapped() {
    let key = "com.apple.developer.kernel.increased-memory-limit"
    #expect(Capabilities.map(for: .ios)[key] == nil && Capabilities.map(for: .macos)[key] == nil)
    let r = Capabilities.required(entitlements: [key: true], platform: .ios)
    #expect(r.types.isEmpty)
    #expect(r.unmapped == [key])
}

@Test func managedAndUngatedKeysNeedNoCapability() {
    let ents: [String: Any] = ["get-task-allow": false, "application-identifier": "x", "com.apple.security.app-sandbox": true,
                               "com.apple.security.network.client": true]
    let r = Capabilities.required(entitlements: ents, platform: .macos)
    #expect(r.types.isEmpty && r.unmapped.isEmpty)
}

@Test func unknownGatedKeyIsReportedNotRefused() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.foo": true], platform: .ios)
    #expect(r.types.isEmpty)
    #expect(r.unmapped == ["com.apple.developer.foo"])
}

private func client(_ t: MockTransport) -> ASCClient { ASCClient(credentials: testCreds, transport: t, sleep: { _ in }) }

@Test func ensureEnablesMissingCapability() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIdCapabilities","id":"X","attributes":{"capabilityType":"PUSH_NOTIFICATIONS"}}]}"#),
                           (201, #"{"data":{"type":"bundleIdCapabilities","id":"N","attributes":{"capabilityType":"ASSOCIATED_DOMAINS"}}}"#)])
    let changed = try await Capabilities.ensure([CapabilityRequest(.associatedDomains)], bundleIDResourceID: "B1", client: client(t))
    #expect(changed)
    #expect(t.requests.count == 2)
    #expect(t.requests[0].url!.path == "/v1/bundleIds/B1/bundleIdCapabilities")
    #expect(URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "limit" } != true)
    #expect(t.requests[1].httpMethod == "POST")
    #expect(t.requests[1].url!.path == "/v1/bundleIdCapabilities")
    let json = try JSONSerialization.jsonObject(with: t.requests[1].httpBody!) as! NSDictionary
    let expected: NSDictionary = ["data": ["type": "bundleIdCapabilities",
                                           "attributes": ["capabilityType": "ASSOCIATED_DOMAINS"],
                                           "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": "B1"]]]]]
    #expect(json == expected)
}

@Test func ensureLeavesPresentCapabilityAlone() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIdCapabilities","id":"X","attributes":{"capabilityType":"ASSOCIATED_DOMAINS"}}]}"#)])
    let changed = try await Capabilities.ensure([CapabilityRequest(.associatedDomains)], bundleIDResourceID: "B1", client: client(t))
    #expect(!changed)
    #expect(t.requests.count == 1)
}

@Test func ensureWithNothingRequiredMakesNoRequests() async throws {
    let t = MockTransport([])
    #expect(try await Capabilities.ensure([], bundleIDResourceID: "B1", client: client(t)) == false)
    #expect(t.requests.isEmpty)
}

// MARK: Every capability type with an entitlement

@Test func everyCapabilityTypeWithAnEntitlementIsMapped() {
    let mapped = Set(Capabilities.map(for: .ios).values).union(Capabilities.map(for: .macos).values)
    // In-App Purchase has no entitlement; everything else is reachable from some key.
    #expect(Set(CapabilityType.allCases).subtracting(mapped) == [.inAppPurchase])
    // No portal-only key is also mapped.
    for key in Capabilities.portalNames.keys {
        #expect(Capabilities.map(for: .ios)[key] == nil && Capabilities.map(for: .macos)[key] == nil, "\(key)")
    }
}

@Test func iosAndMacOSKeySpellings() {
    let ios = Capabilities.map(for: .ios), mac = Capabilities.map(for: .macos)
    #expect(ios["aps-environment"] == .pushNotifications && mac["aps-environment"] == nil)
    #expect(mac["com.apple.developer.aps-environment"] == .pushNotifications && ios["com.apple.developer.aps-environment"] == nil)
    for key in ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
                "com.apple.developer.ubiquity-kvstore-identifier", "com.apple.developer.ubiquity-container-identifiers"] {
        #expect(ios[key] == .icloud && mac[key] == .icloud, "\(key)")
    }
    #expect(ios["com.apple.developer.applesignin"] == .appleIDAuth && mac["com.apple.developer.applesignin"] == .appleIDAuth)
    #expect(ios["com.apple.developer.in-app-payments"] == .applePay && mac["com.apple.developer.in-app-payments"] == .applePay)
    #expect(ios["com.apple.developer.default-data-protection"] == .dataProtection)
    #expect(ios["com.apple.developer.nfc.readersession.formats"] == .nfcTagReading && mac["com.apple.developer.nfc.readersession.formats"] == nil)
    #expect(ios["com.apple.developer.healthkit"] == .healthKit && ios["com.apple.developer.healthkit.access"] == .healthKit)
    #expect(mac["com.apple.developer.system-extension.install"] == .systemExtensionInstall && ios["com.apple.developer.system-extension.install"] == nil)
    #expect(mac["com.apple.developer.maps"] == .maps)
    #expect(ios["com.apple.security.application-groups"] == .appGroups && mac["com.apple.security.application-groups"] == .appGroups)
}

@Test func iCloudKeysNeedOneCapabilityWithCloudKit() {
    let ents: [String: Any] = ["com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.app"],
                               "com.apple.developer.icloud-services": ["CloudKit"],
                               "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)com.example.app"]
    for platform in Platform.allCases {
        let r = Capabilities.required(entitlements: ents, platform: platform)
        #expect(r.requests == [CapabilityRequest(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_6")])], "\(platform)")
        #expect(r.unmapped.isEmpty)
    }
}

@Test func signInWithAppleIsThePrimaryApp() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.applesignin": ["Default"]], platform: .ios)
    #expect(r.requests == [CapabilityRequest(.appleIDAuth, settings: [CapabilitySetting(.appleIDAuthAppConsent, "PRIMARY_APP_CONSENT")])])
}

@Test func dataProtectionTakesItsLevelFromTheEntitlement() {
    func level(_ value: Any) -> [CapabilitySetting] {
        Capabilities.required(entitlements: ["com.apple.developer.default-data-protection": value], platform: .ios).requests.first?.settings ?? []
    }
    #expect(level("NSFileProtectionComplete") == [CapabilitySetting(.dataProtectionPermissionLevel, "COMPLETE_PROTECTION")])
    #expect(level("NSFileProtectionCompleteUnlessOpen") == [CapabilitySetting(.dataProtectionPermissionLevel, "PROTECTED_UNLESS_OPEN")])
    #expect(level("NSFileProtectionCompleteUntilFirstUserAuthentication") == [CapabilitySetting(.dataProtectionPermissionLevel, "PROTECTED_UNTIL_FIRST_USER_AUTH")])
    #expect(level("NSFileProtectionNone") == [CapabilitySetting(.dataProtectionPermissionLevel, "COMPLETE_PROTECTION")])
    #expect(level(true) == [CapabilitySetting(.dataProtectionPermissionLevel, "COMPLETE_PROTECTION")])
}

@Test func capabilitiesWithoutSettingsSendNone() {
    let r = Capabilities.required(entitlements: ["com.apple.developer.game-center": true, "com.apple.developer.siri": true], platform: .macos)
    #expect(r.requests == [CapabilityRequest(.gameCenter), CapabilityRequest(.siriKit)])
}

@Test func ensureSendsTheSettings() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#),
                           (201, #"{"data":{"type":"bundleIdCapabilities","id":"N","attributes":{"capabilityType":"ICLOUD"}}}"#)])
    let changed = try await Capabilities.ensure([CapabilityRequest(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_6")])],
                                                bundleIDResourceID: "B1", client: client(t))
    #expect(changed)
    let json = try JSONSerialization.jsonObject(with: t.requests[1].httpBody!) as! NSDictionary
    let expected: NSDictionary = ["data": ["type": "bundleIdCapabilities",
                                           "attributes": ["capabilityType": "ICLOUD",
                                                          "settings": [["key": "ICLOUD_VERSION", "options": [["key": "XCODE_6", "enabled": true]]]]],
                                           "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": "B1"]]]]]
    #expect(json == expected)
}

@Test func aMappedKeyStillMissingPointsToTheCommand() {
    let e = Entitlements.refusal(.missing(key: "com.apple.developer.icloud-container-identifiers"), platform: .ios, teamID: "T", bundleID: "a.b")
    #expect(e.cause == "entitlement 'com.apple.developer.icloud-container-identifiers' is not granted by the provisioning profile for a.b")
    #expect(e.fix.hasPrefix("check that iCloud is enabled with `xless bundle-ids capabilities a.b list` (enable it with `xless bundle-ids capabilities a.b enable ICLOUD`). iCloud also needs an iCloud container assigned to a.b"))
    #expect(e.fix.hasSuffix(Entitlements.finishFirst))
    let siwa = Entitlements.refusal(.missing(key: "com.apple.developer.applesignin"), platform: .macos, teamID: "T", bundleID: "a.b")
    #expect(siwa.fix == "check that Sign in with Apple is enabled with `xless bundle-ids capabilities a.b list` (enable it with `xless bundle-ids capabilities a.b enable APPLE_ID_AUTH`). Then re-run. \(Entitlements.finishFirst)")
}
