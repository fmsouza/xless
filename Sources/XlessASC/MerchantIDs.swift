import Foundation
import XlessCore

// Merchant IDs (`/v1/merchantIds`), the identifiers Apple Pay payments are made to, for `xless merchant-ids`
// (docs/apple-account.md#xless-merchant-ids). Linking one to a bundle ID's Apple Pay capability is not in the API.

/// A merchant identifier: `merchant.` then reverse-DNS letters, digits, `-` and `.` (`merchant.com.example.store`).
public enum MerchantIdentifier {
    public static func validate(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespaces)
        let rest = id.hasPrefix("merchant.") ? String(id.dropFirst("merchant.".count)) : ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard !rest.isEmpty, id.count <= 155, rest.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !rest.hasPrefix("."), !rest.hasSuffix("."), !rest.contains("..") else {
            throw IdentifierInputError("\(id.isEmpty ? "an empty identifier" : id) is not a merchant identifier: it starts with merchant. and goes on in reverse-DNS form (merchant.com.example.store)")
        }
        return id
    }
}

public struct ASCMerchantIDAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var identifier: String?
    public init() {}
}

public typealias ASCMerchantID = ASCKeptResource<ASCMerchantIDAttributes>

extension ASCKeptResource where A == ASCMerchantIDAttributes {
    public var identifier: String { attributes.identifier ?? "" }
    public var name: String { attributes.name ?? "" }
}

/// The merchant-ID operations, on the App Store Connect API key.
public struct ASCMerchantIDs: Sendable {
    public static let path = "/v1/merchantIds"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    public enum Creation: Sendable {
        case created(ASCMerchantID)
        /// The identifier was already registered on the team: nothing was created.
        case existing(ASCMerchantID)
        public var merchantID: ASCMerchantID { switch self { case .created(let m), .existing(let m): m } }
    }

    /// Every merchant ID of the team (every page), by identifier.
    public func list() async throws -> [ASCMerchantID] {
        let listing = try await resources.list(Self.path, as: ASCMerchantID.self)
        return listing.items.sorted { ($0.identifier.lowercased(), $0.id) < ($1.identifier.lowercased(), $1.id) }
    }

    public func get(id: String) async throws -> ASCMerchantID {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a merchant ID's ID", fix: "use an ID or an identifier from `xless merchant-ids list`")
        }
        let single: ASCSingle<ASCMerchantID> = try await resources.get("\(Self.path)/\(id)", as: ASCMerchantID.self)
        return single.data
    }

    /// The merchant ID registered with exactly this identifier.
    public func find(identifier: String) async throws -> ASCMerchantID? {
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: [("identifier", identifier)]), as: ASCMerchantID.self)
        return listing.items.first { $0.identifier == identifier }
    }

    /// The merchant ID a command names: its identifier (`merchant.…`, looked up) or its resource ID.
    public func resolve(_ text: String) async throws -> ASCMerchantID {
        guard text.contains(".") else { return try await get(id: text) }
        do { _ = try MerchantIdentifier.validate(text) } catch let e as IdentifierInputError {
            throw XlessError(.account, e.description, fix: "use an ID or an identifier from `xless merchant-ids list`")
        }
        guard let found = try await find(identifier: text) else {
            throw XlessError(.account, "no merchant ID \(text) is registered on this team",
                             fix: "check the identifier with `xless merchant-ids list`, or register it with `xless merchant-ids create \(text) --name …`")
        }
        return found
    }

    /// Registers a merchant identifier unless the team has it already (then nothing is sent). The POST is sent once.
    public func create(identifier: String, name: String) async throws -> Creation {
        if let existing = try await find(identifier: identifier) { return .existing(existing) }
        struct Attributes: Encodable, Sendable { var identifier: String; var name: String }
        let created: ASCSingle<ASCMerchantID> = try await resources.create(Self.path, type: "merchantIds",
                                                                          attributes: Attributes(identifier: identifier, name: name))
        return .created(created.data)
    }

    public func delete(_ merchantID: ASCMerchantID) async throws { try await resources.delete("\(Self.path)/\(merchantID.id)") }
}
