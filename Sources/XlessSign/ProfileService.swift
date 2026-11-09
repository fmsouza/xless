import Foundation
import XlessASC
import XlessCore

public enum ProfileType: String, Sendable {
    case iosAppStore = "IOS_APP_STORE"
    case macDirect = "MAC_APP_DIRECT"
    case macAppStore = "MAC_APP_STORE"
    /// A Developer ID build embeds a `MAC_APP_DIRECT` profile; a Mac App Store (TestFlight) build needs `MAC_APP_STORE`.
    public static func `for`(platform: Platform, distribution: Distribution) -> ProfileType {
        platform == .ios ? .iosAppStore : distribution == .appStore ? .macAppStore : .macDirect
    }
}

struct BundleIDAttributes: Codable, Sendable { var identifier: String?; var name: String?; var platform: String? }
struct ProfileAttributes: Codable, Sendable {
    var name: String?; var profileType: String?; var profileState: String?; var profileContent: String?; var expirationDate: String?
}

public struct ProfileService: Sendable {
    let client: ASCClient
    let now: @Sendable () -> Date

    public init(client: ASCClient, now: @escaping @Sendable () -> Date = { Date() }) { self.client = client; self.now = now }

    /// BundleIdPlatform used when registering a new identifier. Apple's OpenAPI spec (4.5.1) allows IOS, MAC_OS and
    /// UNIVERSAL; UNIVERSAL lets the same identifier carry both the iOS (IOS_APP_STORE) and the macOS (MAC_APP_DIRECT) profile.
    static let registrationPlatform = "UNIVERSAL"

    /// App Store Connect only accepts ASCII letters, digits and spaces in a bundle ID's `name` (HTTP 409 otherwise).
    static func bundleIDName(for identifier: String) -> String {
        let mapped = String(identifier.unicodeScalars.map { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : " " })
        let words = mapped.split(separator: " ").joined(separator: " ")
        return String(("xless " + words).trimmingCharacters(in: .whitespaces).prefix(255))
    }

    /// Returns the resource ID of `identifier`, registering it (as UNIVERSAL, whatever `platform` is) if it does not exist.
    public func ensureBundleID(identifier: String, platform: Platform) async throws -> String {
        let doc: ASCDocument<[ASCResource<BundleIDAttributes>]> = try await client.get(
            "/v1/bundleIds", query: [("filter[identifier]", identifier), ("limit", "200")])
        if let match = doc.data.first(where: { $0.attributes.identifier == identifier }) { return match.id }
        let body = ASCCreate<BundleIDAttributes, ASCNoRelationships>(
            type: "bundleIds", attributes: .init(identifier: identifier, name: Self.bundleIDName(for: identifier), platform: Self.registrationPlatform))
        let created: ASCDocument<ASCResource<BundleIDAttributes>> = try await client.post("/v1/bundleIds", body: body)
        return created.data.id
    }

    /// Returns profile bytes for an ACTIVE profile named "xless <bundle> <type>" that contains `certificateID`
    /// and is valid for 7+ more days; otherwise deletes it and creates a fresh one.
    /// `forceNew` always replaces it (used after a capability was enabled, so the profile carries it).
    public func ensureProfile(bundleIDResourceID: String, certificateID: String, type: ProfileType, bundleIdentifier: String,
                              forceNew: Bool = false) async throws -> Data {
        let name = "xless \(bundleIdentifier) \(type.rawValue)"
        let list: ASCDocument<[ASCResource<ProfileAttributes>]> = try await client.get(
            "/v1/profiles", query: [("filter[name]", name), ("filter[profileType]", type.rawValue), ("limit", "200")])
        for p in list.data where p.attributes.name == name {
            if !forceNew, p.attributes.profileState == "ACTIVE",
               let exp = p.attributes.expirationDate.flatMap(Self.parseDate), exp > now().addingTimeInterval(7 * 86400) {
                let certs: ASCDocument<[ASCRef]> = try await client.get("/v1/profiles/\(p.id)/relationships/certificates")
                if certs.data.contains(where: { $0.id == certificateID }) {
                    let bundle: ASCDocument<ASCRef> = try await client.get("/v1/profiles/\(p.id)/relationships/bundleId")
                    if bundle.data.id == bundleIDResourceID,
                       let content = p.attributes.profileContent.flatMap({ Data(base64Encoded: $0) }) { return content }
                }
            }
            try await client.delete("/v1/profiles/\(p.id)")
        }
        struct Attrs: Codable, Sendable { var name: String; var profileType: String }
        struct Rels: Codable, Sendable { var bundleId: ASCToOne; var certificates: ASCToMany }
        let body = ASCCreate<Attrs, Rels>(type: "profiles", attributes: .init(name: name, profileType: type.rawValue),
                                          relationships: .init(bundleId: .init(.init(type: "bundleIds", id: bundleIDResourceID)),
                                                               certificates: .init([.init(type: "certificates", id: certificateID)])))
        let created: ASCDocument<ASCResource<ProfileAttributes>>
        do { created = try await client.post("/v1/profiles", body: body) } catch let e as ASCError {
            throw XlessError(.sign, "cannot create \(type.rawValue) profile for \(bundleIdentifier): \(e)",
                             fix: type != .iosAppStore ? "if \(bundleIdentifier) was registered for iOS only (before xless registered identifiers as universal), set platforms.macos.bundleID to a separate identifier" : "check the bundle ID and certificate in App Store Connect")
        }
        guard let content = created.data.attributes.profileContent.flatMap({ Data(base64Encoded: $0) }) else {
            throw XlessError(.sign, "App Store Connect returned a profile without content", fix: "re-run; if it persists, delete the profile in the portal")
        }
        return content
    }

    static func parseDate(_ s: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
