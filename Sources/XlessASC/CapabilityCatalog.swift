import Foundation

// The bundle-ID capabilities App Store Connect's API can enable (`CapabilityType` in Apple's OpenAPI spec 4.6.1,
// openapi.oas.json of 2026-11-19) and the three settings it takes (`CapabilitySetting.key` / `CapabilityOption.key`).
// Used by `xless bundle-ids capabilities` and by the `sign` stage (docs/apple-account.md#xless-bundle-ids).

/// A capability type as the API spells it. Anything else is refused by Apple (409 ENTITY_ERROR.ATTRIBUTE.TYPE).
public enum CapabilityType: String, Codable, Sendable, CaseIterable {
    case icloud = "ICLOUD"
    case inAppPurchase = "IN_APP_PURCHASE"
    case gameCenter = "GAME_CENTER"
    case pushNotifications = "PUSH_NOTIFICATIONS"
    case wallet = "WALLET"
    case interAppAudio = "INTER_APP_AUDIO"
    case maps = "MAPS"
    case associatedDomains = "ASSOCIATED_DOMAINS"
    case personalVPN = "PERSONAL_VPN"
    case appGroups = "APP_GROUPS"
    case healthKit = "HEALTHKIT"
    case homeKit = "HOMEKIT"
    case wirelessAccessoryConfiguration = "WIRELESS_ACCESSORY_CONFIGURATION"
    case applePay = "APPLE_PAY"
    case dataProtection = "DATA_PROTECTION"
    case siriKit = "SIRIKIT"
    case networkExtensions = "NETWORK_EXTENSIONS"
    case multipath = "MULTIPATH"
    case hotSpot = "HOT_SPOT"
    case nfcTagReading = "NFC_TAG_READING"
    case classKit = "CLASSKIT"
    case autofillCredentialProvider = "AUTOFILL_CREDENTIAL_PROVIDER"
    case accessWiFiInformation = "ACCESS_WIFI_INFORMATION"
    case networkCustomProtocol = "NETWORK_CUSTOM_PROTOCOL"
    case coreMediaHLSLowLatency = "COREMEDIA_HLS_LOW_LATENCY"
    case systemExtensionInstall = "SYSTEM_EXTENSION_INSTALL"
    case userManagement = "USER_MANAGEMENT"
    case appleIDAuth = "APPLE_ID_AUTH"

    /// The API's name in any case, with `-` for `_` (`push-notifications`).
    public init?(argument: String) {
        self.init(rawValue: argument.uppercased().replacingOccurrences(of: "-", with: "_"))
    }

    /// The name the developer portal shows.
    public var displayName: String {
        switch self {
        case .icloud: "iCloud"
        case .inAppPurchase: "In-App Purchase"
        case .gameCenter: "Game Center"
        case .pushNotifications: "Push Notifications"
        case .wallet: "Wallet"
        case .interAppAudio: "Inter-App Audio"
        case .maps: "Maps"
        case .associatedDomains: "Associated Domains"
        case .personalVPN: "Personal VPN"
        case .appGroups: "App Groups"
        case .healthKit: "HealthKit"
        case .homeKit: "HomeKit"
        case .wirelessAccessoryConfiguration: "Wireless Accessory Configuration"
        case .applePay: "Apple Pay Payment Processing"
        case .dataProtection: "Data Protection"
        case .siriKit: "SiriKit"
        case .networkExtensions: "Network Extensions"
        case .multipath: "Multipath"
        case .hotSpot: "Hotspot"
        case .nfcTagReading: "NFC Tag Reading"
        case .classKit: "ClassKit"
        case .autofillCredentialProvider: "AutoFill Credential Provider"
        case .accessWiFiInformation: "Access Wi-Fi Information"
        case .networkCustomProtocol: "Custom Network Protocol"
        case .coreMediaHLSLowLatency: "Low Latency HLS"
        case .systemExtensionInstall: "System Extension"
        case .userManagement: "User Management"
        case .appleIDAuth: "Sign in with Apple"
        }
    }

    /// The one setting this capability takes, if any.
    public var settingKey: CapabilitySettingKey? { CapabilitySettingKey.allCases.first { $0.capability == self } }

    /// What a capability that needs another identifier still needs after it is enabled: the API enables the capability
    /// but cannot link the identifier.
    public var linkedIdentifier: String? {
        switch self {
        case .appGroups: "an app group"
        case .icloud: "an iCloud container"
        case .applePay: "a merchant ID"
        default: nil
        }
    }

    /// Every type, for a refusal: `ICLOUD, IN_APP_PURCHASE, …`.
    public static var list: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// A capability setting's key, its options and the option xless sends when none is chosen.
public enum CapabilitySettingKey: String, Codable, Sendable, CaseIterable {
    case icloudVersion = "ICLOUD_VERSION"
    case dataProtectionPermissionLevel = "DATA_PROTECTION_PERMISSION_LEVEL"
    case appleIDAuthAppConsent = "APPLE_ID_AUTH_APP_CONSENT"

    public var capability: CapabilityType {
        switch self {
        case .icloudVersion: .icloud
        case .dataProtectionPermissionLevel: .dataProtection
        case .appleIDAuthAppConsent: .appleIDAuth
        }
    }

    public var options: [String] {
        switch self {
        case .icloudVersion: ["XCODE_5", "XCODE_6"]
        case .dataProtectionPermissionLevel: ["COMPLETE_PROTECTION", "PROTECTED_UNLESS_OPEN", "PROTECTED_UNTIL_FIRST_USER_AUTH"]
        case .appleIDAuthAppConsent: ["PRIMARY_APP_CONSENT"]
        }
    }

    /// iCloud: CloudKit (Xcode 6 and later), what Xcode enables; Data Protection: complete, Xcode's default; Sign in with
    /// Apple: the app is its own primary app (the only option).
    public var defaultOption: String {
        switch self {
        case .icloudVersion: "XCODE_6"
        case .dataProtectionPermissionLevel: "COMPLETE_PROTECTION"
        case .appleIDAuthAppConsent: "PRIMARY_APP_CONSENT"
        }
    }
}

/// A `--setting` that cannot be sent; never sent to Apple.
public struct CapabilitySettingError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// One capability setting, as the API reads and writes it: `{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6",
/// "enabled": true}]}`. Apple returns more fields (name, description, …) when it lists a capability; they are kept as
/// read but only `key` and `options` are sent.
public struct CapabilitySetting: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var key: String
        public var enabled: Bool?
        public init(key: String, enabled: Bool? = true) { self.key = key; self.enabled = enabled }
    }

    public var key: String
    public var options: [Option]

    public init(key: String, options: [Option]) { self.key = key; self.options = options }

    enum CodingKeys: String, CodingKey { case key, options }

    /// `options` is optional in Apple's schema: a setting without it reads as one with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
    }
    public init(_ key: CapabilitySettingKey, _ option: String) { self.init(key: key.rawValue, options: [Option(key: option)]) }

    /// What `enable` sends when no `--setting` is given: the capability's setting with its default option.
    public static func defaults(for type: CapabilityType) -> [CapabilitySetting] {
        type.settingKey.map { [CapabilitySetting($0, $0.defaultOption)] } ?? []
    }

    /// `KEY=OPTION` arguments (any case) for `type`, checked against it. Only what is given: the defaults are what
    /// `ASCBundleIDs.enable` sends when it creates the capability without settings.
    public static func parse(_ arguments: [String], for type: CapabilityType) throws -> [CapabilitySetting] {
        var chosen: [CapabilitySettingKey: String] = [:]
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw CapabilitySettingError("--setting \(argument): write it as KEY=OPTION, e.g. ICLOUD_VERSION=XCODE_6")
            }
            guard let key = CapabilitySettingKey(rawValue: parts[0]) else {
                throw CapabilitySettingError("unknown setting \(parts[0]): the API knows \(CapabilitySettingKey.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let own = type.settingKey else { throw CapabilitySettingError("\(type.rawValue) takes no setting") }
            guard own == key else { throw CapabilitySettingError("\(type.rawValue) takes \(own.rawValue), not \(key.rawValue)") }
            guard key.options.contains(parts[1]) else {
                throw CapabilitySettingError("\(key.rawValue) takes \(key.options.joined(separator: " or ")), not \(parts[1])")
            }
            guard chosen[key] == nil else { throw CapabilitySettingError("\(key.rawValue) is given twice") }
            chosen[key] = parts[1]
        }
        return chosen.map { CapabilitySetting($0.key, $0.value) }
    }

    /// Each setting's chosen option: the one marked enabled, else the only one listed (unless marked disabled).
    public static func chosen(_ settings: [CapabilitySetting]) -> [String: String] {
        var out: [String: String] = [:]
        for setting in settings {
            if let option = setting.options.first(where: { $0.enabled == true }) ?? (setting.options.count == 1 && setting.options[0].enabled != false ? setting.options.first : nil) {
                out[setting.key] = option.key
            }
        }
        return out
    }
}
