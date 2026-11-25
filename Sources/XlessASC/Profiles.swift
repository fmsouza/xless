import Foundation
import XlessCore

// Provisioning profiles (`/v1/profiles`) of every type, for `xless profiles` (docs/apple-account.md#xless-profiles) and
// the `sign` stage. A profile cannot be edited: renewing one is deleting it and creating it again.

/// App Store Connect's `ProfileType` (spec 4.6.1).
public enum ProfileType: String, CaseIterable, Codable, Sendable {
    case iosAppDevelopment = "IOS_APP_DEVELOPMENT"
    case iosAppStore = "IOS_APP_STORE"
    case iosAppAdHoc = "IOS_APP_ADHOC"
    case iosAppInHouse = "IOS_APP_INHOUSE"
    case macAppDevelopment = "MAC_APP_DEVELOPMENT"
    case macAppStore = "MAC_APP_STORE"
    case macAppDirect = "MAC_APP_DIRECT"
    case tvosAppDevelopment = "TVOS_APP_DEVELOPMENT"
    case tvosAppStore = "TVOS_APP_STORE"
    case tvosAppAdHoc = "TVOS_APP_ADHOC"
    case tvosAppInHouse = "TVOS_APP_INHOUSE"
    case macCatalystAppDevelopment = "MAC_CATALYST_APP_DEVELOPMENT"
    case macCatalystAppStore = "MAC_CATALYST_APP_STORE"
    case macCatalystAppDirect = "MAC_CATALYST_APP_DIRECT"

    /// The API value in any case, with `-`, `_` or spaces between the words (`ios-app-development`).
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        guard let type = ProfileType(rawValue: text) else { return nil }
        self = type
    }

    /// The command-line spelling: `ios-app-development`.
    public var argument: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "-") }

    enum Family { case ios, mac, tvos, catalyst }
    enum Use { case development, store, adHoc, inHouse, direct }

    var family: Family {
        switch self {
        case .iosAppDevelopment, .iosAppStore, .iosAppAdHoc, .iosAppInHouse: .ios
        case .macAppDevelopment, .macAppStore, .macAppDirect: .mac
        case .tvosAppDevelopment, .tvosAppStore, .tvosAppAdHoc, .tvosAppInHouse: .tvos
        case .macCatalystAppDevelopment, .macCatalystAppStore, .macCatalystAppDirect: .catalyst
        }
    }

    var use: Use {
        switch self {
        case .iosAppDevelopment, .macAppDevelopment, .tvosAppDevelopment, .macCatalystAppDevelopment: .development
        case .iosAppStore, .macAppStore, .tvosAppStore, .macCatalystAppStore: .store
        case .iosAppAdHoc, .tvosAppAdHoc: .adHoc
        case .iosAppInHouse, .tvosAppInHouse: .inHouse
        case .macAppDirect, .macCatalystAppDirect: .direct
        }
    }

    /// The name the developer portal shows.
    public var displayName: String {
        let platform = switch family { case .ios: "iOS"; case .mac: "macOS"; case .tvos: "tvOS"; case .catalyst: "Mac Catalyst" }
        let kind = switch use {
        case .development: "App Development"
        case .store: "App Store Connect"
        case .adHoc: "Ad Hoc"
        case .inHouse: "In House"
        case .direct: "Developer ID"
        }
        return "\(platform) \(kind)"
    }

    /// Development and ad hoc profiles list the devices they run on; the others none.
    public var usesDevices: Bool { use == .development || use == .adHoc }

    /// The platform of the devices a profile of this type lists (`IOS` covers tvOS too).
    public var devicePlatform: DevicePlatform { family == .mac || family == .catalyst ? .macOS : .ios }

    /// Whether a registered device (by its `deviceClass`) belongs in a profile of this type: Apple TVs in tvOS profiles
    /// only, every other iOS-platform device in iOS profiles, any Mac in macOS and Mac Catalyst ones.
    public func accepts(deviceClass: String?) -> Bool {
        switch family {
        case .tvos: deviceClass == "APPLE_TV"
        case .ios: deviceClass != "APPLE_TV"
        case .mac, .catalyst: true
        }
    }

    /// The certificate types a profile of this type can contain.
    public var certificateTypes: [CertificateType] {
        let mac = family == .mac || family == .catalyst
        switch use {
        case .development: return [.development, mac ? .macAppDevelopment : .iosDevelopment]
        case .store, .adHoc, .inHouse: return [.distribution, mac ? .macAppDistribution : .iosDistribution]
        case .direct: return [.developerIDApplicationG2, .developerIDApplication]
        }
    }

    /// Whether a bundle ID registered for `platform` (`IOS`, `MAC_OS`, `UNIVERSAL`) can have a profile of this type:
    /// macOS profiles need a macOS or universal identifier; iOS, tvOS and Mac Catalyst ones an iOS or universal one.
    /// An unknown platform is left for App Store Connect to judge.
    public func accepts(bundlePlatform: String?) -> Bool {
        switch bundlePlatform {
        case "IOS"?: family != .mac
        case "MAC_OS"?: family == .mac
        default: true
        }
    }
}

public struct ASCProfileAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var platform: String?
    public var profileType: String?
    public var profileState: String?
    public var profileContent: String?
    public var uuid: String?
    public var createdDate: String?
    public var expirationDate: String?
    public init() {}
}

public typealias ASCProfile = ASCKeptResource<ASCProfileAttributes>

extension ASCKeptResource where A == ASCProfileAttributes {
    public var name: String { attributes.name ?? "" }
    public var profileType: String { attributes.profileType ?? "" }
    /// The profile itself (a CMS envelope around a plist), when the response carried `profileContent`.
    public var content: Data? { attributes.profileContent.flatMap { Data(base64Encoded: $0) } }
    public var expires: Date? { attributes.expirationDate.flatMap(ASCDate.parse) }
    /// The resource ID of the profile's bundle ID, when the response carried the linkage (`include=bundleId`).
    public var bundleIDResourceID: String? { resource.relationships?["bundleId"]?["data"]?["id"]?.string }
}

/// A page of profiles and the bundle IDs they are for (by resource ID).
public struct ASCProfileListing: Sendable {
    public var profiles: [ASCProfile]
    public var bundleIDs: [String: ASCBundleID]

    public func bundleID(of profile: ASCProfile) -> ASCBundleID? { profile.bundleIDResourceID.flatMap { bundleIDs[$0] } }
}

/// The profile operations, on the App Store Connect API key.
public struct ASCProfiles: Sendable {
    public static let path = "/v1/profiles"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    static let listedFields = ["name", "platform", "profileType", "profileState", "uuid", "createdDate", "expirationDate", "bundleId"]
    static let bundleIDFields = ["identifier", "name", "platform", "seedId"]

    /// Every profile of `types` (all types when empty), every page, with their bundle IDs, by name. `profileContent`
    /// is left out (it is the whole profile); `get(id:withContent:)` fetches it.
    public func list(types: [ProfileType] = [], name: String? = nil) async throws -> ASCProfileListing {
        var filters = types.isEmpty ? [] : [("profileType", types.map(\.rawValue).joined(separator: ","))]
        if let name { filters.append(("name", name)) }
        let query = ASCQuery(filters: filters, fields: [("profiles", Self.listedFields), ("bundleIds", Self.bundleIDFields)], include: ["bundleId"])
        let listing = try await resources.list(Self.path, query: query, as: ASCProfile.self)
        var bundles: [String: ASCBundleID] = [:]
        for r in listing.included where r.type == "bundleIds" { bundles[r.id] = ASCBundleID(resource: r) }
        let sorted = listing.items.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        return ASCProfileListing(profiles: sorted, bundleIDs: bundles)
    }

    /// The profiles named exactly `name` (Apple's filter may match more loosely), of `type` when given.
    public func find(name: String, type: ProfileType? = nil) async throws -> [ASCProfile] {
        try await list(types: type.map { [$0] } ?? [], name: name).profiles.filter { $0.name == name && (type == nil || $0.profileType == type?.rawValue) }
    }

    /// One profile and its bundle ID; `withContent` also fetches the profile itself.
    public func get(id: String, withContent: Bool = false) async throws -> (profile: ASCProfile, bundleID: ASCBundleID?) {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a profile ID", fix: "use an ID from `xless profiles list`")
        }
        let fields = Self.listedFields + (withContent ? ["profileContent"] : [])
        let query = ASCQuery(fields: [("profiles", fields), ("bundleIds", Self.bundleIDFields)], include: ["bundleId"])
        let single: ASCSingle<ASCProfile> = try await resources.get("\(Self.path)/\(id)", query: query, as: ASCProfile.self)
        let bundle = single.data.bundleIDResourceID.flatMap { bid in single.included.first { $0.type == "bundleIds" && $0.id == bid } }
        return (single.data, bundle.map(ASCBundleID.init(resource:)))
    }

    /// The IDs of the certificates in a profile, every page.
    public func certificateIDs(of id: String) async throws -> [String] {
        try await resources.relationship("\(Self.path)/\(id)", "certificates").map(\.id)
    }

    /// The resource ID of the profile's bundle ID (for a response without the linkage).
    public func bundleIDResourceID(of id: String) async throws -> String? {
        try await resources.toOneRelationship("\(Self.path)/\(id)", "bundleId")?.id
    }

    /// The IDs of the devices in a profile, every page.
    public func deviceIDs(of id: String) async throws -> [String] {
        try await resources.relationship("\(Self.path)/\(id)", "devices").map(\.id)
    }

    /// The team's profiles that contain the certificate `id` (they stop working once it is revoked): every page of
    /// profiles, and every certificate of each. A listing carries at most 50 of a profile's certificates
    /// (`limit[certificates]`, Apple's maximum); a profile that may hold more (its `meta.paging.total` says so, or, without
    /// a total, it lists 50) and does not list `id` among them is read in full from its certificates relationship.
    public func profiles(holding id: String) async throws -> [ASCCertificateProfile] {
        let query = ASCQuery(fields: [("profiles", ["name", "profileType", "profileState", "certificates"]), ("certificates", ["certificateType"])],
                             include: ["certificates"], extra: [("limit[certificates]", "\(Self.includedCertificates)")])
        let listing = try await resources.list(Self.path, query: query, as: ASCAnyResource.self)
        var found: [ASCCertificateProfile] = []
        for profile in listing.items {
            let relationship = profile.relationships?["certificates"]
            guard case .array(let refs)? = relationship?["data"] else { continue }
            var contains = refs.contains { $0["id"]?.string == id }
            if !contains, Self.mayHoldMore(listed: refs.count, total: relationship?["meta"]?["paging"]?["total"]) {
                contains = try await certificateIDs(of: profile.id).contains(id)
            }
            guard contains else { continue }
            found.append(ASCCertificateProfile(id: profile.id, name: profile.attributes?["name"]?.string ?? "",
                                               profileType: profile.attributes?["profileType"]?.string,
                                               profileState: profile.attributes?["profileState"]?.string))
        }
        return found.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// How many of a profile's certificates a profile listing includes (Apple's maximum for `limit[certificates]`).
    static let includedCertificates = 50

    /// Whether a profile listing `listed` certificates may hold more: its total says so, or it has no total and is full.
    static func mayHoldMore(listed: Int, total: JSONValue?) -> Bool {
        switch total {
        case .int(let n)?: n > listed
        case .double(let n)?: Int(n) > listed
        default: listed >= includedCertificates
        }
    }

    struct CreateAttributes: Encodable, Sendable { var name: String; var profileType: String }
    struct CreateRelationships: Encodable, Sendable { var bundleId: ASCToOne; var certificates: ASCToMany; var devices: ASCToMany? }

    /// Creates a profile. `deviceIDs` is sent only when not empty. The POST is sent once, never retried.
    public func create(name: String, type: ProfileType, bundleIDResourceID: String, certificateIDs: [String],
                       deviceIDs: [String] = []) async throws -> ASCProfile {
        let relationships = CreateRelationships(
            bundleId: ASCToOne(ASCRef(type: "bundleIds", id: bundleIDResourceID)),
            certificates: ASCToMany(certificateIDs.map { ASCRef(type: "certificates", id: $0) }),
            devices: deviceIDs.isEmpty ? nil : ASCToMany(deviceIDs.map { ASCRef(type: "devices", id: $0) }))
        let attributes = CreateAttributes(name: name, profileType: type.rawValue)
        let created: ASCSingle<ASCProfile> = try await resources.create(Self.path, type: "profiles", attributes: attributes, relationships: relationships)
        return created.data
    }

    public func delete(id: String) async throws {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a profile ID", fix: "use an ID from `xless profiles list`")
        }
        try await resources.delete("\(Self.path)/\(id)")
    }
}
