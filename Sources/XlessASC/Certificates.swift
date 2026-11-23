import Foundation
import XlessCore

// Certificates (`/v1/certificates`) of every type, for `xless certs` (docs/apple-account.md#xless-certs), `xless sign
// bootstrap` and the `sign` stage. Revoking is DELETE; the profiles a certificate is in are found through
// `/v1/profiles?include=certificates`.

/// App Store Connect's `CertificateType` (spec 4.6.1): every type the documented API creates, lists and revokes.
public enum CertificateType: String, CaseIterable, Codable, Sendable {
    case applePay = "APPLE_PAY"
    case applePayMerchantIdentity = "APPLE_PAY_MERCHANT_IDENTITY"
    case applePayPSPIdentity = "APPLE_PAY_PSP_IDENTITY"
    case applePayRSA = "APPLE_PAY_RSA"
    case developerIDKext = "DEVELOPER_ID_KEXT"
    case developerIDKextG2 = "DEVELOPER_ID_KEXT_G2"
    case developerIDApplication = "DEVELOPER_ID_APPLICATION"
    case developerIDApplicationG2 = "DEVELOPER_ID_APPLICATION_G2"
    case development = "DEVELOPMENT"
    case distribution = "DISTRIBUTION"
    case identityAccess = "IDENTITY_ACCESS"
    case iosDevelopment = "IOS_DEVELOPMENT"
    case iosDistribution = "IOS_DISTRIBUTION"
    case macAppDistribution = "MAC_APP_DISTRIBUTION"
    case macInstallerDistribution = "MAC_INSTALLER_DISTRIBUTION"
    case macAppDevelopment = "MAC_APP_DEVELOPMENT"
    case passTypeID = "PASS_TYPE_ID"
    case passTypeIDWithNFC = "PASS_TYPE_ID_WITH_NFC"

    /// The API value in any case, with `-`, `_` or spaces (`developer-id-application-g2`), or one of `xless sign
    /// bootstrap`'s kinds: `developer-id` (DEVELOPER_ID_APPLICATION_G2, the current Developer ID Application) and
    /// `installer` (MAC_INSTALLER_DISTRIBUTION).
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch text {
        case "DEVELOPER_ID": self = .developerIDApplicationG2
        case "INSTALLER": self = .macInstallerDistribution
        default:
            guard let type = CertificateType(rawValue: text) else { return nil }
            self = type
        }
    }

    /// The command-line spelling: `developer-id-application-g2`.
    public var argument: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "-") }

    /// The name the developer portal shows.
    public var displayName: String {
        switch self {
        case .applePay: "Apple Pay Payment Processing"
        case .applePayMerchantIdentity: "Apple Pay Merchant Identity"
        case .applePayPSPIdentity: "Apple Pay Payment Service Provider Identity"
        case .applePayRSA: "Apple Pay Payment Processing (China mainland, RSA)"
        case .developerIDKext: "Developer ID Kernel Extension (previous sub-CA)"
        case .developerIDKextG2: "Developer ID Kernel Extension"
        case .developerIDApplication: "Developer ID Application (previous sub-CA)"
        case .developerIDApplicationG2: "Developer ID Application"
        case .development: "Apple Development"
        case .distribution: "Apple Distribution"
        case .identityAccess: "Identity Access"
        case .iosDevelopment: "iOS App Development"
        case .iosDistribution: "iOS Distribution"
        case .macAppDistribution: "Mac App Distribution"
        case .macInstallerDistribution: "Mac Installer Distribution"
        case .macAppDevelopment: "Mac Development"
        case .passTypeID: "Pass Type ID"
        case .passTypeIDWithNFC: "Pass Type ID with NFC"
        }
    }

    /// The identifier a certificate of this type is created for (`relationships` of the create request).
    public enum Relationship: String, Sendable {
        /// An Apple Pay certificate belongs to a merchant ID (`merchantId`).
        case merchantID = "merchantId"
        /// A Wallet pass certificate belongs to a pass type ID (`passTypeId`).
        case passTypeID = "passTypeId"
    }

    public var relationship: Relationship? {
        switch self {
        case .applePay, .applePayMerchantIdentity, .applePayPSPIdentity, .applePayRSA: .merchantID
        case .passTypeID, .passTypeIDWithNFC: .passTypeID
        default: nil
        }
    }

    /// Apple Pay Payment Processing needs an ECC P-256 key ("Select ECC and 256 bit key pair",
    /// developer.apple.com/help/account/certificates/create-a-certificate-signing-request/), which the payment provider
    /// normally generates; xless generates RSA-2048 keys only, so this type needs `--csr`.
    public var needsECCKey: Bool { self == .applePay }

    public var isDeveloperID: Bool {
        [.developerIDApplication, .developerIDApplicationG2, .developerIDKext, .developerIDKextG2].contains(self)
    }

    /// Apple's documented per-team limit, counted over `capGroup`; nil where Apple documents none (App Store Connect
    /// then refuses a certificate too many itself). "You can create up to five Developer ID Application certificates
    /// and up to five Developer ID Installer certificates" (developer.apple.com/help/account/certificates/
    /// create-developer-id-certificates/, read 2026-11-23); developer.apple.com/help/account/certificates/
    /// certificates-overview/ gives no number for the other types.
    public var cap: Int? { capGroup.isEmpty ? nil : 5 }

    /// The types that share this type's limit: both generations of Developer ID Application.
    public var capGroup: [CertificateType] {
        switch self {
        case .developerIDApplication, .developerIDApplicationG2: [.developerIDApplication, .developerIDApplicationG2]
        default: []
        }
    }

    /// The secret-store name of a key xless generates for this type (before any `@<TEAM_ID>`): the names the `sign` stage
    /// reads for the three certificates it signs with, `XLESS_<TYPE>_KEY` for the others.
    public var defaultEntryBase: String {
        switch self {
        case .distribution: "XLESS_DIST_KEY"
        case .developerIDApplication, .developerIDApplicationG2: "XLESS_DEVID_KEY"
        case .macInstallerDistribution: "XLESS_INSTALLER_KEY"
        default: "XLESS_\(rawValue)_KEY"
        }
    }
}

public struct ASCCertificateAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var certificateType: String?
    public var displayName: String?
    public var serialNumber: String?
    public var platform: String?
    public var expirationDate: String?
    public var certificateContent: String?
    public var activated: Bool?
    public init() {}
}

public typealias ASCCertificate = ASCKeptResource<ASCCertificateAttributes>

extension ASCKeptResource where A == ASCCertificateAttributes {
    public var certificateType: String { attributes.certificateType ?? "" }
    /// The certificate itself (DER), when the response carried `certificateContent`.
    public var der: Data? { attributes.certificateContent.flatMap { Data(base64Encoded: $0) } }
    /// `expirationDate` (`2027-03-01T12:00:00.000+0000`, or ISO 8601 without fractions).
    public var expires: Date? { attributes.expirationDate.flatMap(ASCCertificates.parseDate) }
}

/// A profile that contains a certificate (what revoking it breaks).
public struct ASCCertificateProfile: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var profileType: String?
    public var profileState: String?
    public init(id: String, name: String, profileType: String? = nil, profileState: String? = nil) {
        self.id = id; self.name = name; self.profileType = profileType; self.profileState = profileState
    }
}

/// The certificate operations, on the App Store Connect API key.
public struct ASCCertificates: Sendable {
    public static let path = "/v1/certificates"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    static let listedFields = ["name", "certificateType", "displayName", "serialNumber", "platform", "expirationDate", "activated"]

    /// Every certificate of `types` (all types when empty), every page, by type then expiry. `withContent` also fetches
    /// each certificate's DER (`certificateContent`), which listings otherwise leave out.
    public func list(types: [CertificateType] = [], withContent: Bool = false) async throws -> [ASCCertificate] {
        let filters = types.isEmpty ? [] : [("certificateType", types.map(\.rawValue).joined(separator: ","))]
        let fields = Self.listedFields + (withContent ? ["certificateContent"] : [])
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: filters, fields: [("certificates", fields)]), as: ASCCertificate.self)
        return listing.items.sorted {
            ($0.certificateType, $0.attributes.expirationDate ?? "", $0.id) < ($1.certificateType, $1.attributes.expirationDate ?? "", $1.id)
        }
    }

    public func get(id: String) async throws -> ASCCertificate {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a certificate ID", fix: "use an ID from `xless certs list`")
        }
        let single: ASCSingle<ASCCertificate> = try await resources.get("\(Self.path)/\(id)", as: ASCCertificate.self)
        return single.data
    }

    struct CreateAttributes: Encodable, Sendable { var csrContent: String; var certificateType: String }
    struct CreateRelationships: Encodable, Sendable { var merchantId: ASCToOne?; var passTypeId: ASCToOne? }

    /// Creates a certificate of `type` from a CSR (PEM). The POST is sent once, never retried: a retry whose first attempt
    /// went through would burn a second certificate. `relatedID` is the merchant ID's or pass type ID's resource ID for the
    /// types that belong to one (`type.relationship`), and must be nil for the others.
    public func create(type: CertificateType, csrPEM: String, relatedID: String? = nil) async throws -> ASCCertificate {
        let relationships: CreateRelationships?
        switch (type.relationship, relatedID) {
        case (nil, nil): relationships = nil
        case (.merchantID?, let id?): relationships = CreateRelationships(merchantId: ASCToOne(ASCRef(type: "merchantIds", id: id)))
        case (.passTypeID?, let id?): relationships = CreateRelationships(passTypeId: ASCToOne(ASCRef(type: "passTypeIds", id: id)))
        case (let needed?, nil):
            throw XlessError(.account, "a \(type.rawValue) certificate belongs to a \(needed == .merchantID ? "merchant ID" : "pass type ID")",
                             fix: needed == .merchantID ? "pass --merchant-id (see `xless merchant-ids list`)" : "pass --pass-type-id")
        case (nil, _?):
            throw XlessError(.account, "a \(type.rawValue) certificate belongs to no merchant ID or pass type ID",
                             fix: "drop --merchant-id / --pass-type-id")
        }
        let created: ASCSingle<ASCCertificate> = try await resources.create(
            Self.path, type: "certificates", attributes: CreateAttributes(csrContent: csrPEM, certificateType: type.rawValue),
            relationships: relationships)
        return created.data
    }

    /// The resource ID of the pass type ID a command names: its identifier (`pass.com.example.ticket`, looked up) or the
    /// resource ID itself.
    public func passTypeID(_ text: String) async throws -> String {
        guard text.contains(".") else {
            guard isASCResourceID(text) else {
                throw XlessError(.account, "\(text) is neither a pass type identifier nor a pass type ID's ID", fix: "use pass.<reverse-DNS> or its resource ID")
            }
            return text
        }
        let listing = try await resources.list("/v1/passTypeIds", query: ASCQuery(filters: [("identifier", text)]), as: ASCAnyResource.self)
        guard let found = listing.items.first(where: { $0.attributes?["identifier"]?.string == text }) else {
            throw XlessError(.account, "no pass type ID \(text) is registered on this team",
                             fix: "check the identifier (`xless api GET /v1/passTypeIds`), or register it at developer.apple.com/account/resources/identifiers")
        }
        return found.id
    }

    /// Revokes the certificate (DELETE). Apple has no undo.
    public func revoke(id: String) async throws {
        guard isASCResourceID(id) else {
            throw XlessError(.account, "\(id) is not a certificate ID", fix: "use an ID from `xless certs list`")
        }
        try await resources.delete("\(Self.path)/\(id)")
    }

    /// The team's profiles that contain the certificate `id` (they stop working once it is revoked): every page of
    /// profiles, and every certificate of each. A listing carries at most 50 of a profile's certificates
    /// (`limit[certificates]`, Apple's maximum); a profile that may hold more (its `meta.paging.total` says so, or, without
    /// a total, it lists 50) and does not list `id` among them is read in full from its certificates relationship.
    public func profiles(using id: String) async throws -> [ASCCertificateProfile] {
        let query = ASCQuery(fields: [("profiles", ["name", "profileType", "profileState", "certificates"]), ("certificates", ["certificateType"])],
                             include: ["certificates"], extra: [("limit[certificates]", "\(Self.includedCertificates)")])
        let listing = try await resources.list("/v1/profiles", query: query, as: ASCAnyResource.self)
        var found: [ASCCertificateProfile] = []
        for profile in listing.items {
            let relationship = profile.relationships?["certificates"]
            guard case .array(let refs)? = relationship?["data"] else { continue }
            var contains = refs.contains { $0["id"]?.string == id }
            if !contains, Self.mayHoldMore(listed: refs.count, total: relationship?["meta"]?["paging"]?["total"]) {
                contains = try await resources.relationship("/v1/profiles/\(profile.id)", "certificates").contains { $0.id == id }
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

    /// After a create POST was sent, only a definite App Store Connect refusal (4xx other than 429) proves no
    /// certificate was made. Transport errors, 429/5xx, an undecodable 2xx body or cancellation are all ambiguous.
    /// (`XlessError` comes from xless itself before anything was sent, e.g. building the JWT.)
    public static func isAmbiguous(_ error: Error) -> Bool {
        if let e = error as? ASCError { return !(400..<500).contains(e.status) || e.status == 429 }
        return !(error is XlessError)
    }

    /// `2027-03-01T12:00:00.000+0000` (what App Store Connect sends) or plain ISO 8601.
    public static func parseDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
