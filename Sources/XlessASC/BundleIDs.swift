import Foundation
import XlessCore

// Bundle IDs (`/v1/bundleIds`) and their capabilities (`/v1/bundleIdCapabilities`), for `xless bundle-ids`
// (docs/apple-account.md#xless-bundle-ids) and the `sign` stage.

/// Attributes xless reads; `init()` is what a resource whose attributes do not decode gets.
public protocol ASCAttributes: Codable, Sendable { init() }

/// A resource as App Store Connect sent it (what `--json` prints, so fields Apple adds survive) and its attributes, typed.
public struct ASCKeptResource<A: ASCAttributes>: Codable, Sendable {
    public var resource: ASCAnyResource
    public var attributes: A

    public init(resource: ASCAnyResource) {
        self.resource = resource
        let json = (try? JSONEncoder().encode(resource.attributes ?? [:])) ?? Data("{}".utf8)
        attributes = (try? JSONDecoder().decode(A.self, from: json)) ?? A()
    }

    public init(from decoder: Decoder) throws { self.init(resource: try ASCAnyResource(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try resource.encode(to: encoder) }

    public var id: String { resource.id }
}

/// App Store Connect's resource IDs are letters and digits.
public func isASCResourceID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
}

/// Something wrong with an identifier or a name; never sent to Apple.
public struct IdentifierInputError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// The names the developer portal accepts for a bundle ID or a merchant ID: ASCII letters, digits and spaces (App Store
/// Connect refuses anything else with HTTP 409).
public enum PortalName {
    public static func validate(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw IdentifierInputError("the name is empty") }
        if name.count > 255 { throw IdentifierInputError("the name is longer than 255 characters") }
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }) else {
            throw IdentifierInputError("\"\(name)\": Apple accepts only ASCII letters, digits and spaces in a name")
        }
    }

    /// The identifier's words: `com.example.my-app` → `com example my app`.
    public static func from(identifier: String) -> String {
        let mapped = String(identifier.unicodeScalars.map { s in s.isASCII && CharacterSet.alphanumerics.contains(s) ? Character(s) : " " })
        return String(mapped.split(separator: " ").joined(separator: " ").prefix(255))
    }

    /// The name xless gives a bundle ID it registers (`sign`, `provision`, `apps create`, `bundle-ids create` without
    /// `--name`): `com.example.my-app` → `xless com example my app`.
    public static func bundleID(for identifier: String) -> String {
        String(("xless " + from(identifier: identifier)).trimmingCharacters(in: .whitespaces).prefix(255))
    }
}

public enum BundleIDPlatform: String, Codable, Sendable, CaseIterable {
    case universal = "UNIVERSAL"
    case ios = "IOS"
    case macOS = "MAC_OS"

    /// `universal`, `ios`, `macos` or `mac`, in any case.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "universal": self = .universal
        case "ios": self = .ios
        case "macos", "mac": self = .macOS
        default: return nil
        }
    }

    public var argument: String {
        switch self { case .universal: "universal"; case .ios: "ios"; case .macOS: "macos" }
    }

    /// The command-line name of an API value; an unknown value as it is.
    public static func display(_ value: String?) -> String {
        guard let value else { return "" }
        return BundleIDPlatform(rawValue: value)?.argument ?? value
    }
}

/// A bundle identifier as the developer portal takes it: reverse-DNS letters, digits, `-` and `.`, or a wildcard ending
/// in `*` (`com.example.*`).
public enum BundleIdentifier {
    public static func validate(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespaces)
        let body = id.hasSuffix("*") ? String(id.dropLast()) : id
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard !id.isEmpty, id.count <= 155, body.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !body.hasPrefix("."), !body.contains(".."), id.hasSuffix("*") ? (body.isEmpty || body.hasSuffix(".")) : !body.hasSuffix(".") else {
            throw IdentifierInputError("\(id.isEmpty ? "an empty identifier" : id) is not a bundle identifier: use letters, digits, - and . (com.example.app), or a wildcard ending in .* (com.example.*)")
        }
        return id
    }

    /// Whether a command argument names a bundle ID by its identifier rather than its resource ID.
    public static func isIdentifier(_ text: String) -> Bool { text.contains(".") || text.contains("*") }
}

public struct ASCBundleIDAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var platform: String?
    public var identifier: String?
    public var seedId: String?
    public init() {}
}

public typealias ASCBundleID = ASCKeptResource<ASCBundleIDAttributes>

extension ASCKeptResource where A == ASCBundleIDAttributes {
    public var identifier: String { attributes.identifier ?? "" }
    public var name: String { attributes.name ?? "" }
}

public struct ASCBundleIDCapabilityAttributes: ASCAttributes, Equatable {
    public var capabilityType: String?
    public var settings: [CapabilitySetting]?
    public init() {}
}

public typealias ASCBundleIDCapability = ASCKeptResource<ASCBundleIDCapabilityAttributes>

extension ASCKeptResource where A == ASCBundleIDCapabilityAttributes {
    public var capabilityType: String { attributes.capabilityType ?? "" }
    /// Each setting's chosen option (`ICLOUD_VERSION=XCODE_6`).
    public var chosenSettings: [String: String] { CapabilitySetting.chosen(attributes.settings ?? []) }
}

/// The bundle-ID operations, on the App Store Connect API key.
public struct ASCBundleIDs: Sendable {
    public static let path = "/v1/bundleIds"
    public static let capabilitiesPath = "/v1/bundleIdCapabilities"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    public enum Creation: Sendable {
        case created(ASCBundleID)
        /// The identifier was already registered on the team: nothing was created.
        case existing(ASCBundleID)
        public var bundleID: ASCBundleID { switch self { case .created(let b), .existing(let b): b } }
    }

    public enum Enabling: Sendable {
        case enabled(ASCBundleIDCapability)
        /// Enabled already, with other settings: they were changed.
        case updated(ASCBundleIDCapability)
        /// Enabled already with these settings: nothing was sent.
        case unchanged(ASCBundleIDCapability)
        public var capability: ASCBundleIDCapability { switch self { case .enabled(let c), .updated(let c), .unchanged(let c): c } }
    }

    /// Every bundle ID of the team (every page), by identifier.
    public func list(platform: BundleIDPlatform? = nil) async throws -> [ASCBundleID] {
        let filters = platform.map { [("platform", $0.rawValue)] } ?? []
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: filters), as: ASCBundleID.self)
        return listing.items.sorted { ($0.identifier.lowercased(), $0.id) < ($1.identifier.lowercased(), $1.id) }
    }

    public func get(id: String) async throws -> ASCBundleID {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a bundle ID's ID", fix: "use an ID or an identifier from `xless bundle-ids list`")
        }
        let single: ASCSingle<ASCBundleID> = try await resources.get("\(Self.path)/\(id)", as: ASCBundleID.self)
        return single.data
    }

    /// The bundle ID registered with exactly this identifier (Apple's filter also matches longer ones).
    public func find(identifier: String) async throws -> ASCBundleID? {
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: [("identifier", identifier)]), as: ASCBundleID.self)
        return listing.items.first { $0.identifier == identifier }
    }

    /// The bundle ID a command names: an identifier (`com.example.app`, looked up) or a resource ID.
    public func resolve(_ text: String) async throws -> ASCBundleID {
        guard BundleIdentifier.isIdentifier(text) else { return try await get(id: text) }
        do { _ = try BundleIdentifier.validate(text) } catch let e as IdentifierInputError {
            throw XlessError(.account, e.description, fix: "use an ID or an identifier from `xless bundle-ids list`")
        }
        guard let found = try await find(identifier: text) else {
            throw XlessError(.account, "no bundle ID \(text) is registered on this team",
                             fix: "check the identifier with `xless bundle-ids list`, or register it with `xless bundle-ids create \(text)`")
        }
        return found
    }

    /// Registers an identifier unless the team has it already (then nothing is sent). The POST is sent once.
    public func create(identifier: String, name: String, platform: BundleIDPlatform) async throws -> Creation {
        if let existing = try await find(identifier: identifier) { return .existing(existing) }
        struct Attributes: Encodable, Sendable { var identifier: String; var name: String; var platform: String }
        let created: ASCSingle<ASCBundleID> = try await resources.create(
            Self.path, type: "bundleIds", attributes: Attributes(identifier: identifier, name: name, platform: platform.rawValue))
        return .created(created.data)
    }

    public func delete(_ bundleID: ASCBundleID) async throws { try await resources.delete("\(Self.path)/\(bundleID.id)") }

    /// The capabilities enabled on a bundle ID. The endpoint refuses `limit` (HTTP 400 PARAMETER_ERROR.ILLEGAL), so the
    /// page size is Apple's; further pages are followed.
    public func capabilities(of bundleIDResourceID: String) async throws -> [ASCBundleIDCapability] {
        try await resources.list("\(Self.path)/\(bundleIDResourceID)/bundleIdCapabilities", as: ASCBundleIDCapability.self,
                                 sendsLimit: false).items
    }

    /// Enables `type` with `settings` (its default setting when none is given) on a bundle ID. Enabled already:
    /// nothing is sent when no setting is given or every given one has that option, else the capability's settings are
    /// changed (PATCH). `existing`: the bundle ID's capabilities, when the caller has them.
    public func enable(_ type: CapabilityType, settings: [CapabilitySetting] = [], on bundleIDResourceID: String,
                       existing: [ASCBundleIDCapability]? = nil) async throws -> Enabling {
        let have: [ASCBundleIDCapability]
        if let existing { have = existing } else { have = try await capabilities(of: bundleIDResourceID) }
        struct Attributes: Encodable, Sendable { var capabilityType: String; var settings: [CapabilitySetting]? }
        if let current = have.first(where: { $0.capabilityType == type.rawValue }) {
            let chosen = current.chosenSettings
            if CapabilitySetting.chosen(settings).allSatisfy({ chosen[$0.key] == $0.value }) { return .unchanged(current) }
            let updated: ASCSingle<ASCBundleIDCapability> = try await resources.update(
                "\(Self.capabilitiesPath)/\(current.id)", type: "bundleIdCapabilities", id: current.id,
                attributes: Attributes(capabilityType: type.rawValue, settings: settings))
            return .updated(updated.data)
        }
        struct Relationships: Encodable, Sendable { var bundleId: ASCToOne }
        let sent = settings.isEmpty ? CapabilitySetting.defaults(for: type) : settings
        let attributes = Attributes(capabilityType: type.rawValue, settings: sent.isEmpty ? nil : sent)
        let created: ASCSingle<ASCBundleIDCapability> = try await resources.create(
            Self.capabilitiesPath, type: "bundleIdCapabilities", attributes: attributes,
            relationships: Relationships(bundleId: ASCToOne(ASCRef(type: "bundleIds", id: bundleIDResourceID))))
        return .enabled(created.data)
    }

    /// Disables a capability: deletes it from the bundle ID.
    public func disable(_ capability: ASCBundleIDCapability) async throws {
        try await resources.delete("\(Self.capabilitiesPath)/\(capability.id)")
    }
}
