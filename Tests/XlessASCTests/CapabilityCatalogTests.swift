import Foundation
import Testing
@testable import XlessASC

@Test func everyCapabilityTypeOfTheSpecIsKnown() {
    // App Store Connect API 4.6.1, `CapabilityType`.
    let spec = ["ICLOUD", "IN_APP_PURCHASE", "GAME_CENTER", "PUSH_NOTIFICATIONS", "WALLET", "INTER_APP_AUDIO", "MAPS",
                "ASSOCIATED_DOMAINS", "PERSONAL_VPN", "APP_GROUPS", "HEALTHKIT", "HOMEKIT", "WIRELESS_ACCESSORY_CONFIGURATION",
                "APPLE_PAY", "DATA_PROTECTION", "SIRIKIT", "NETWORK_EXTENSIONS", "MULTIPATH", "HOT_SPOT", "NFC_TAG_READING",
                "CLASSKIT", "AUTOFILL_CREDENTIAL_PROVIDER", "ACCESS_WIFI_INFORMATION", "NETWORK_CUSTOM_PROTOCOL",
                "COREMEDIA_HLS_LOW_LATENCY", "SYSTEM_EXTENSION_INSTALL", "USER_MANAGEMENT", "APPLE_ID_AUTH"]
    #expect(CapabilityType.allCases.map(\.rawValue).sorted() == spec.sorted())
    #expect(CapabilityType.allCases.allSatisfy { !$0.displayName.isEmpty })
    #expect(CapabilityType.appleIDAuth.displayName == "Sign in with Apple")
}

@Test func capabilityArgumentsIgnoreCaseAndDashes() {
    #expect(CapabilityType(argument: "icloud") == .icloud)
    #expect(CapabilityType(argument: "Push-Notifications") == .pushNotifications)
    #expect(CapabilityType(argument: "APPLE_ID_AUTH") == .appleIDAuth)
    #expect(CapabilityType(argument: "sign-in-with-apple") == nil)
    #expect(CapabilityType(argument: "") == nil)
}

@Test func onlyThreeCapabilitiesTakeASetting() {
    #expect(CapabilityType.icloud.settingKey == .icloudVersion)
    #expect(CapabilityType.dataProtection.settingKey == .dataProtectionPermissionLevel)
    #expect(CapabilityType.appleIDAuth.settingKey == .appleIDAuthAppConsent)
    #expect(CapabilityType.allCases.filter { $0.settingKey != nil }.count == 3)
    #expect(CapabilitySettingKey.icloudVersion.options == ["XCODE_5", "XCODE_6"])
    #expect(CapabilitySettingKey.dataProtectionPermissionLevel.options == ["COMPLETE_PROTECTION", "PROTECTED_UNLESS_OPEN", "PROTECTED_UNTIL_FIRST_USER_AUTH"])
    #expect(CapabilitySettingKey.appleIDAuthAppConsent.options == ["PRIMARY_APP_CONSENT"])
}

@Test func eachSettingHasADefault() throws {
    #expect(CapabilitySetting.defaults(for: .icloud) == [CapabilitySetting(.icloudVersion, "XCODE_6")])
    #expect(CapabilitySetting.defaults(for: .dataProtection) == [CapabilitySetting(.dataProtectionPermissionLevel, "COMPLETE_PROTECTION")])
    #expect(CapabilitySetting.defaults(for: .appleIDAuth) == [CapabilitySetting(.appleIDAuthAppConsent, "PRIMARY_APP_CONSENT")])
    #expect(CapabilitySetting.defaults(for: .maps) == [])
    // Parsing returns only what was given: an enabled capability keeps its option unless one is named.
    for type in CapabilityType.allCases { #expect(try CapabilitySetting.parse([], for: type) == []) }
}

@Test func aSettingWithoutOptionsStillDecodes() throws {
    let caps = try JSONDecoder().decode(ASCBundleIDCapability.self, from: Data(#"{"type":"bundleIdCapabilities","id":"C1","attributes":{"capabilityType":"ICLOUD","settings":[{"key":"ICLOUD_VERSION"}]}}"#.utf8))
    #expect(caps.capabilityType == "ICLOUD" && caps.chosenSettings.isEmpty)
}

@Test func settingsAreParsedFromKeyEqualsOption() throws {
    #expect(try CapabilitySetting.parse(["icloud_version=xcode_5"], for: .icloud) == [CapabilitySetting(.icloudVersion, "XCODE_5")])
    #expect(try CapabilitySetting.parse(["DATA_PROTECTION_PERMISSION_LEVEL=PROTECTED_UNLESS_OPEN"], for: .dataProtection)
            == [CapabilitySetting(.dataProtectionPermissionLevel, "PROTECTED_UNLESS_OPEN")])
}

@Test func badSettingsAreRefusedWithWhatIsAllowed() {
    func message(_ args: [String], _ type: CapabilityType) -> String {
        do { _ = try CapabilitySetting.parse(args, for: type); return "" } catch { return "\(error)" }
    }
    #expect(message(["ICLOUD_VERSION"], .icloud).contains("KEY=OPTION"))
    #expect(message(["ICLOUD_VERSION=XCODE_7"], .icloud) == "ICLOUD_VERSION takes XCODE_5 or XCODE_6, not XCODE_7")
    #expect(message(["ICLOUD_VERSION=XCODE_6"], .pushNotifications) == "PUSH_NOTIFICATIONS takes no setting")
    #expect(message(["ICLOUD_VERSION=XCODE_6"], .dataProtection) == "DATA_PROTECTION takes DATA_PROTECTION_PERMISSION_LEVEL, not ICLOUD_VERSION")
    #expect(message(["COLOR=RED"], .icloud).contains("unknown setting COLOR"))
    #expect(message(["ICLOUD_VERSION=XCODE_5", "ICLOUD_VERSION=XCODE_6"], .icloud) == "ICLOUD_VERSION is given twice")
}

@Test func settingsEncodeAsTheAPIExpects() throws {
    let json = try ASCOutput.json([CapabilitySetting(.icloudVersion, "XCODE_6")])
    let compact = json.filter { !$0.isWhitespace }
    #expect(compact == #"[{"key":"ICLOUD_VERSION","options":[{"enabled":true,"key":"XCODE_6"}]}]"#)
}

@Test func settingsReadFromAppleKeepTheEnabledOption() throws {
    // GET /v1/bundleIds/{id}/bundleIdCapabilities returns every option with `enabled` set on the chosen one.
    let text = #"[{"key":"DATA_PROTECTION_PERMISSION_LEVEL","name":"Data Protection","options":[{"key":"COMPLETE_PROTECTION","enabled":false},{"key":"PROTECTED_UNLESS_OPEN","enabled":true}]}]"#
    let settings = try JSONDecoder().decode([CapabilitySetting].self, from: Data(text.utf8))
    #expect(CapabilitySetting.chosen(settings) == ["DATA_PROTECTION_PERMISSION_LEVEL": "PROTECTED_UNLESS_OPEN"])
    #expect(CapabilitySetting.chosen([CapabilitySetting(.icloudVersion, "XCODE_6")]) == ["ICLOUD_VERSION": "XCODE_6"])
    // An option without `enabled` counts as chosen when it is the only one.
    let single = try JSONDecoder().decode([CapabilitySetting].self, from: Data(#"[{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_5"}]}]"#.utf8))
    #expect(CapabilitySetting.chosen(single) == ["ICLOUD_VERSION": "XCODE_5"])
}
