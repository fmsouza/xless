import Foundation
import XlessASC
import XlessCore

/// A capability to enable on a bundle ID, with the settings the entitlements imply.
public struct CapabilityRequest: Sendable, Equatable {
    public var type: CapabilityType
    public var settings: [CapabilitySetting]
    public init(_ type: CapabilityType, settings: [CapabilitySetting] = []) { self.type = type; self.settings = settings }
}

/// What a bundle's entitlements need: the capabilities xless enables, and the gated keys it cannot enable.
public struct CapabilityNeeds: Sendable, Equatable {
    public var requests: [CapabilityRequest]
    public var unmapped: [String]
    /// The capability types, as the API spells them.
    public var types: [String] { requests.map(\.type.rawValue) }
}

/// Bundle-ID capabilities that the app's entitlements require; a profile only carries an entitlement once the matching
/// capability is enabled on the identifier.
public enum Capabilities {
    /// Gated entitlement key → the capability type that grants it, on the platforms where Apple spells the key that way.
    /// Every type is a value of the API's `CapabilityType` (Apple's OpenAPI spec 4.6.1; `CapabilityType` in XlessASC);
    /// the two types with no entitlement (In-App Purchase, Maps on iOS) are enabled with `xless bundle-ids capabilities`
    /// only. Keys with no type (App Attest, Declared Age Range, the increased memory limit, …) are portal-only: they are
    /// enabled by hand in the developer portal and reach the profile through the refresh in `SignStage` (ruling R13).
    /// App groups, iCloud containers and merchant IDs: the API enables the capability but cannot assign the identifier.
    static let entries: [(key: String, type: CapabilityType, platforms: Set<Platform>)] = [
        ("aps-environment", .pushNotifications, [.ios]),
        ("com.apple.developer.aps-environment", .pushNotifications, [.macos]),
        ("com.apple.developer.icloud-container-identifiers", .icloud, [.ios, .macos]),
        ("com.apple.developer.icloud-container-development-container-identifiers", .icloud, [.ios, .macos]),
        ("com.apple.developer.icloud-container-environment", .icloud, [.ios, .macos]),
        ("com.apple.developer.icloud-services", .icloud, [.ios, .macos]),
        ("com.apple.developer.ubiquity-container-identifiers", .icloud, [.ios, .macos]),
        ("com.apple.developer.ubiquity-kvstore-identifier", .icloud, [.ios, .macos]),
        ("com.apple.developer.game-center", .gameCenter, [.ios, .macos]),
        ("com.apple.developer.pass-type-identifiers", .wallet, [.ios, .macos]),
        ("inter-app-audio", .interAppAudio, [.ios]),
        ("com.apple.developer.maps", .maps, [.macos]),
        ("com.apple.developer.associated-domains", .associatedDomains, [.ios, .macos]),
        ("com.apple.developer.networking.vpn.api", .personalVPN, [.ios, .macos]),
        ("com.apple.security.application-groups", .appGroups, [.ios, .macos]),
        ("com.apple.developer.healthkit", .healthKit, [.ios]),
        ("com.apple.developer.healthkit.access", .healthKit, [.ios]),
        ("com.apple.developer.healthkit.background-delivery", .healthKit, [.ios]),
        ("com.apple.developer.homekit", .homeKit, [.ios, .macos]),
        ("com.apple.external-accessory.wireless-configuration", .wirelessAccessoryConfiguration, [.ios]),
        ("com.apple.developer.in-app-payments", .applePay, [.ios, .macos]),
        ("com.apple.developer.default-data-protection", .dataProtection, [.ios]),
        ("com.apple.developer.siri", .siriKit, [.ios, .macos]),
        ("com.apple.developer.networking.networkextension", .networkExtensions, [.ios, .macos]),
        ("com.apple.developer.networking.multipath", .multipath, [.ios]),
        ("com.apple.developer.networking.HotspotConfiguration", .hotSpot, [.ios]),
        ("com.apple.developer.nfc.readersession.formats", .nfcTagReading, [.ios]),
        ("com.apple.developer.ClassKit-environment", .classKit, [.ios]),
        ("com.apple.developer.authentication-services.autofill-credential-provider", .autofillCredentialProvider, [.ios, .macos]),
        ("com.apple.developer.networking.wifi-info", .accessWiFiInformation, [.ios]),
        ("com.apple.developer.networking.custom-protocol", .networkCustomProtocol, [.ios]),
        ("com.apple.developer.coremedia.hls.low-latency", .coreMediaHLSLowLatency, [.ios, .macos]),
        ("com.apple.developer.system-extension.install", .systemExtensionInstall, [.macos]),
        ("com.apple.developer.user-management", .userManagement, [.ios]),
        ("com.apple.developer.applesignin", .appleIDAuth, [.ios, .macos]),
    ]

    /// The entitlement keys xless enables a capability for on `platform`.
    public static func map(for platform: Platform) -> [String: CapabilityType] {
        Dictionary(uniqueKeysWithValues: entries.filter { $0.platforms.contains(platform) }.map { ($0.key, $0.type) })
    }

    /// Developer-portal names of portal-only capabilities (no API type), for the refusal's fix.
    static let portalNames: [String: String] = [
        "com.apple.developer.devicecheck.appattest-environment": "App Attest",
        "com.apple.developer.declared-age-range": "Declared Age Range",
        "com.apple.developer.kernel.increased-memory-limit": "Increased Memory Limit",
        "com.apple.developer.kernel.extended-virtual-addressing": "Extended Virtual Address Space",
        "com.apple.developer.family-controls": "Family Controls",
        "com.apple.developer.usernotifications.time-sensitive": "Time Sensitive Notifications",
        "com.apple.developer.usernotifications.communication": "Communication Notifications",
        "com.apple.developer.usernotifications.critical-alerts": "Critical Alerts",
        "com.apple.developer.group-session": "Group Activities",
        "com.apple.developer.weatherkit": "WeatherKit",
        "com.apple.developer.healthkit.recalibrate-estimates": "HealthKit Estimate Recalibration",
        "com.apple.developer.fileprovider.testing-mode": "FileProvider TestingMode",
        "com.apple.developer.associated-domains.mdm-managed": "Associated Domains (MDM managed)",
    ]

    /// Keys that need no capability: the ones xless sets itself and the macOS sandbox / hardened-runtime keys.
    public static func isUngated(_ key: String) -> Bool { Entitlements.managedKeys.contains(key) || Entitlements.isUngated(key) }

    /// Data Protection's level from the entitlement's value (`NSFileProtectionComplete…`).
    static let protectionLevels = [
        "NSFileProtectionComplete": "COMPLETE_PROTECTION",
        "NSFileProtectionCompleteUnlessOpen": "PROTECTED_UNLESS_OPEN",
        "NSFileProtectionCompleteUntilFirstUserAuthentication": "PROTECTED_UNTIL_FIRST_USER_AUTH",
    ]

    /// The settings `type` is enabled with for these entitlements: the Data Protection level they name (Complete when
    /// they name none xless knows), CloudKit for iCloud, primary-app consent for Sign in with Apple.
    static func settings(for type: CapabilityType, entitlements: [String: Any]) -> [CapabilitySetting] {
        if type == .dataProtection, let value = entitlements["com.apple.developer.default-data-protection"] as? String,
           let level = protectionLevels[value] {
            return [CapabilitySetting(.dataProtectionPermissionLevel, level)]
        }
        return CapabilitySetting.defaults(for: type)
    }

    /// The capabilities for the mapped gated keys (each once, in key order), and the gated keys xless cannot enable
    /// itself. Unmapped keys are not refused here: they may have been enabled manually in the portal, which
    /// `Entitlements.merge` checks against the profile.
    public static func required(entitlements: [String: Any], platform: Platform,
                                map: [String: CapabilityType]? = nil) -> CapabilityNeeds {
        let map = map ?? Self.map(for: platform)
        var needs = CapabilityNeeds(requests: [], unmapped: [])
        for key in entitlements.keys.sorted() where !isUngated(key) {
            guard let type = map[key] else { needs.unmapped.append(key); continue }
            if !needs.requests.contains(where: { $0.type == type }) {
                needs.requests.append(CapabilityRequest(type, settings: settings(for: type, entitlements: entitlements)))
            }
        }
        return needs
    }

    /// Enables every missing capability in `requests`; true if any was enabled (the profile must then be regenerated).
    /// A capability enabled already is left as it is, settings included.
    /// - Parameter identifier: the bundle identifier, for the error when Apple refuses a capability.
    public static func ensure(_ requests: [CapabilityRequest], bundleIDResourceID: String, identifier: String? = nil,
                              client: ASCClient) async throws -> Bool {
        if requests.isEmpty { return false }
        let bundleIDs = ASCBundleIDs(resources: ASCResources(client: client))
        let existing = try await bundleIDs.capabilities(of: bundleIDResourceID)
        var enabled = false
        for request in requests where !existing.contains(where: { $0.capabilityType == request.type.rawValue }) {
            do {
                _ = try await bundleIDs.enable(request.type, settings: request.settings, on: bundleIDResourceID, existing: existing)
            } catch let e as ASCError where e.status == 409 {
                // Apple refuses a capability the bundle ID's platform or the team's membership cannot have, or one that
                // needs Apple's approval first.
                throw XlessError(.sign, "App Store Connect refused to enable \(request.type.rawValue) (\(request.type.displayName)) on \(identifier ?? "bundle ID \(bundleIDResourceID)"): \(e)",
                                 fix: "if the capability needs Apple's approval or does not apply to this platform, request or enable it at developer.apple.com/account/resources/identifiers, or drop its entitlement (an overlay's entitlements.remove), then re-run")
            }
            enabled = true
        }
        return enabled
    }
}
