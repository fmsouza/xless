import Foundation
import XlessASC
import XlessCore

// What signing has on the Apple account, for `sign` and `xless provision`: bundle IDs, their capabilities and profiles.

extension ProfileType {
    /// A Developer ID build embeds a `MAC_APP_DIRECT` profile; a Mac App Store (TestFlight) build needs `MAC_APP_STORE`.
    public static func `for`(platform: Platform, distribution: Distribution) -> ProfileType {
        platform == .ios ? .iosAppStore : distribution == .appStore ? .macAppStore : .macAppDirect
    }
}

/// A capability enabled on a bundle ID: its type (API value) and the option chosen for each setting.
public struct SigningCapability: Sendable, Equatable {
    public var id: String
    public var type: String
    public var settings: [String: String]
    public init(id: String, type: String, settings: [String: String]) { self.id = id; self.type = type; self.settings = settings }
}

extension SigningCapability {
    init(_ c: ASCBundleIDCapability) { self.init(id: c.id, type: c.capabilityType, settings: c.chosenSettings) }
}

/// A provisioning profile with what decides whether signing can use it: state, expiry, bundle ID, certificates, content.
public struct SigningProfile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var state: String?
    public var expires: Date?
    public var bundleID: String?
    public var certificateIDs: [String]
    public var content: Data?

    public init(id: String, name: String, type: String, state: String? = nil, expires: Date? = nil, bundleID: String? = nil,
                certificateIDs: [String] = [], content: Data? = nil) {
        self.id = id; self.name = name; self.type = type; self.state = state; self.expires = expires; self.bundleID = bundleID
        self.certificateIDs = certificateIDs; self.content = content
    }

    /// The name xless gives the profiles it makes for signing, and `xless profiles create`'s default: `xless <identifier> <TYPE>`.
    /// Only a profile of this name is ever replaced by `sign`.
    public static func name(bundleID: String, type: ProfileType) -> String { "xless \(bundleID) \(type.rawValue)" }
}

/// Reading and adding to the account. Nothing here deletes or changes what exists, but `enable(_:on:identifier:)`, which
/// sets the settings of a capability that is enabled already (`provision`).
public protocol SigningAccount: Sendable {
    /// The resource ID of the bundle ID registered with exactly this identifier.
    func bundleID(_ identifier: String) async throws -> String?
    /// Registers the identifier as a universal bundle ID (or finds it registered); its resource ID.
    func register(bundleID identifier: String) async throws -> String
    func capabilities(of bundleResourceID: String) async throws -> [SigningCapability]
    /// Enables the capability with its settings, or changes them when it is enabled already.
    func enable(_ request: CapabilityRequest, on bundleResourceID: String, identifier: String) async throws
    /// The profiles named exactly `name` of `type`, with their certificates and content.
    func profiles(named name: String, type: ProfileType) async throws -> [SigningProfile]
    func createProfile(name: String, type: ProfileType, bundleResourceID: String, bundleID identifier: String, certificateID: String) async throws -> SigningProfile
}

/// The documented App Store Connect API, with the API key, for `sign` and `provision` alike. A create (a bundle ID, a
/// capability, a profile) is sent again only after reading shows nothing was made. `stage`: the stage of its errors.
public struct APISigningAccount: SigningAccount {
    public let resources: ASCResources
    public let stage: Stage

    public init(resources: ASCResources, stage: Stage) { self.resources = resources; self.stage = stage }

    var bundleIDs: ASCBundleIDs { ASCBundleIDs(resources: resources) }
    var profiles: ASCProfiles { ASCProfiles(resources: resources) }

    public func bundleID(_ identifier: String) async throws -> String? { try await bundleIDs.find(identifier: identifier)?.id }

    /// UNIVERSAL, whatever the platform: the same identifier then carries the iOS (IOS_APP_STORE) and the macOS
    /// (MAC_APP_DIRECT) profile.
    public func register(bundleID identifier: String) async throws -> String {
        try await bundleIDs.create(identifier: identifier, name: PortalName.bundleID(for: identifier), platform: .universal).bundleID.id
    }

    public func capabilities(of bundleResourceID: String) async throws -> [SigningCapability] {
        try await bundleIDs.capabilities(of: bundleResourceID).map(SigningCapability.init)
    }

    public func enable(_ request: CapabilityRequest, on bundleResourceID: String, identifier: String) async throws {
        try await enable(request, on: bundleResourceID, identifier: identifier, existing: nil)
    }

    /// Enables the ones that are not enabled yet, with their settings; one that is, is left as it is, settings included.
    /// Returns whether any was enabled (a profile made before does not carry it).
    public func enableMissing(_ requests: [CapabilityRequest], on bundleResourceID: String, identifier: String) async throws -> Bool {
        if requests.isEmpty { return false }
        let existing = try await bundleIDs.capabilities(of: bundleResourceID)
        let missing = Capabilities.missing(requests, in: existing.map(SigningCapability.init))
        for request in missing { try await enable(request, on: bundleResourceID, identifier: identifier, existing: existing) }
        return !missing.isEmpty
    }

    private func enable(_ request: CapabilityRequest, on bundleResourceID: String, identifier: String, existing: [ASCBundleIDCapability]?) async throws {
        do {
            _ = try await bundleIDs.enable(request.type, settings: request.settings, on: bundleResourceID, existing: existing)
        } catch let e as ASCError where e.status == 409 {
            // Apple refuses a capability the bundle ID's platform or the team's membership cannot have, or one that
            // needs Apple's approval first.
            throw XlessError(stage, "App Store Connect refused to enable \(request.type.rawValue) (\(request.type.displayName)) on \(identifier): \(e)",
                             fix: "if the capability needs Apple's approval or does not apply to this platform, request or enable it at developer.apple.com/account/resources/identifiers, or drop its entitlement (an overlay's entitlements.remove), then re-run")
        }
    }

    public func profiles(named name: String, type: ProfileType) async throws -> [SigningProfile] {
        var out: [SigningProfile] = []
        for listed in try await profiles.find(name: name, type: type) { out.append(try await read(listed.id)) }
        return out
    }

    func read(_ id: String) async throws -> SigningProfile {
        let (p, _) = try await profiles.get(id: id, withContent: true)
        var bundle = p.bundleIDResourceID
        if bundle == nil { bundle = try await profiles.bundleIDResourceID(of: p.id) }
        return SigningProfile(id: p.id, name: p.name, type: p.profileType, state: p.attributes.profileState, expires: p.expires,
                              bundleID: bundle, certificateIDs: try await profiles.certificateIDs(of: p.id), content: p.content)
    }

    public func createProfile(name: String, type: ProfileType, bundleResourceID: String, bundleID identifier: String,
                              certificateID: String) async throws -> SigningProfile {
        try await createProfile(name: name, type: type, bundleResourceID: bundleResourceID, bundleID: identifier, certificateID: certificateID, replacing: [])
    }

    /// `replacing`: the profiles of this name just deleted (a listing may show them a little longer).
    public func createProfile(name: String, type: ProfileType, bundleResourceID: String, bundleID identifier: String,
                              certificateID: String, replacing old: Set<String>) async throws -> SigningProfile {
        func made() async throws -> SigningProfile? {
            for listed in try await profiles.find(name: name, type: type) where !old.contains(listed.id) {
                let p = try await read(listed.id)
                if p.bundleID == bundleResourceID, p.certificateIDs.contains(certificateID) { return p }
            }
            return nil
        }
        do {
            return try await resources.settled(lookup: made, create: {
                let p = try await profiles.create(name: name, type: type, bundleIDResourceID: bundleResourceID, certificateIDs: [certificateID])
                return SigningProfile(id: p.id, name: p.name, type: p.profileType, state: p.attributes.profileState, expires: p.expires,
                                      bundleID: bundleResourceID, certificateIDs: [certificateID], content: p.content)
            })
        } catch let e as ASCError {
            throw XlessError(stage, "cannot create \(type.rawValue) profile for \(identifier): \(e)",
                             fix: type != .iosAppStore ? "if \(identifier) was registered for iOS only (before xless registered identifiers as universal), set platforms.macos.bundleID to a separate identifier" : "check the bundle ID and certificate in App Store Connect")
        }
    }

    public func deleteProfile(id: String) async throws { try await profiles.delete(id: id) }
}
