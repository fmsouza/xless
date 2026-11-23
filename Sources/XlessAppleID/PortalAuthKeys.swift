import Crypto
import Foundation
import XlessCore

// Auth keys (`xless keys`): the `.p8` keys of Certificates, IDs & Profiles > Keys that APNs (token-based), Sign in with
// Apple, DeviceCheck and MusicKit servers sign with. No documented API covers them, so they go through the developer
// portal's web interface on the Apple ID session: `QH65B2/account/auth/key/…` (fastlane: spaceship/portal/portal_client.rb
// L816–885 and portal/key.rb; App Store Connect CLI: internal/web/developer_sign_in_keys.go). Apple serves a key's
// private key once.

/// A service an auth key can sign for. MapKit, WeatherKit and the others are left out: their service IDs are not
/// confirmed anywhere xless can cite.
public enum AuthKeyService: String, Sendable, CaseIterable, Codable {
    case apns
    case deviceCheck = "devicecheck"
    case musicKit = "musickit"
    case signInWithApple = "siwa"

    /// The portal's service ID.
    public var id: String {
        switch self {
        case .apns: "U27F4V844T"
        case .deviceCheck: "DQ8HTZ7739"
        case .musicKit: "6A7HVUVQ3M"
        case .signInWithApple: "APPLE_ID_AUTH_KEY_CONFIGURATION"
        }
    }

    /// What `--service` takes: `apns`, `devicecheck`, `musickit`, `siwa`.
    public var argument: String { rawValue }

    public var displayName: String {
        switch self {
        case .apns: "Apple Push Notifications service (APNs)"
        case .deviceCheck: "DeviceCheck"
        case .musicKit: "MusicKit"
        case .signInWithApple: "Sign in with Apple"
        }
    }

    /// The short name in tables.
    public var shortName: String {
        switch self {
        case .apns: "APNs"
        case .deviceCheck: "DeviceCheck"
        case .musicKit: "MusicKit"
        case .signInWithApple: "Sign in with Apple"
        }
    }

    /// How many keys with this service Apple allows per team, where Apple says: two for APNs.
    public var limit: Int? { self == .apns ? 2 : nil }

    /// `apns`, `APNs`, `device-check`, `music_kit`, `sign-in-with-apple`, `siwa`.
    public init?(argument: String) {
        let t = argument.trimmingCharacters(in: .whitespaces).lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
        switch t {
        case "apns", "push", "pushnotifications": self = .apns
        case "devicecheck": self = .deviceCheck
        case "musickit": self = .musicKit
        case "siwa", "signinwithapple": self = .signInWithApple
        default: return nil
        }
    }

    public init?(id: String) {
        guard let s = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = s
    }

    /// The `serviceConfigurationsRequests` entry that enables it on a new key; `bundleIDs` (bundle ID resource IDs) are
    /// the apps a Sign in with Apple key is for, `musicIDs` (Music ID resource IDs) what a MusicKit key is for
    /// (fastlane: `Key.create(music_id:)`).
    func request(bundleIDs: [String], musicIDs: [String] = []) -> [String: Any] {
        var r: [String: Any] = ["serviceId": id, "isNew": true]
        switch self {
        case .apns:
            r["identifiers"] = [String: Any]()
            r["environment"] = "all"
            r["scope"] = "team"
        case .deviceCheck:
            r["identifiers"] = [String: Any]()
        case .musicKit:
            r["identifiers"] = ["music": musicIDs]
        case .signInWithApple:
            r["identifiers"] = ["bundle": bundleIDs]
        }
        return r
    }
}

/// One auth key of the team, as the portal lists it. Never its private key.
public struct PortalAuthKey: Codable, Sendable, Equatable {
    public struct Service: Codable, Sendable, Equatable {
        /// The portal's service ID (`U27F4V844T`).
        public var id: String
        public var name: String?
        /// Sign in with Apple: the bundle IDs (resource IDs) the key is for.
        public var bundleIDs: [String]

        public init(id: String, name: String? = nil, bundleIDs: [String] = []) {
            self.id = id; self.name = name; self.bundleIDs = bundleIDs
        }
    }

    public var id: String
    public var name: String
    /// nil when the answer did not include them (the listing may leave them out).
    public var services: [Service]?
    /// Whether the portal still offers the one-time download of its private key.
    public var canDownload: Bool
    public var canRevoke: Bool

    public init(id: String, name: String, services: [Service]?, canDownload: Bool = false, canRevoke: Bool = true) {
        self.id = id; self.name = name; self.services = services; self.canDownload = canDownload; self.canRevoke = canRevoke
    }

    /// The services xless knows, in the portal's order.
    public var serviceKinds: [AuthKeyService] { (services ?? []).compactMap { AuthKeyService(id: $0.id) } }

    /// The services as people read them: `APNs, DeviceCheck`; unknown ones by their service ID.
    public var serviceNames: String {
        guard let services, !services.isEmpty else { return "-" }
        return services.map { AuthKeyService(id: $0.id)?.shortName ?? $0.name ?? $0.id }.joined(separator: ", ")
    }
}

/// The team's auth keys through the developer portal's web interface.
public struct PortalAuthKeys: Sendable {
    public static let page = "https://developer.apple.com/account/resources/authkeys/list"
    static let listPath = "QH65B2/account/auth/key/list"
    static let getPath = "QH65B2/account/auth/key/get"
    static let createPath = "QH65B2/account/auth/key/v2/create"
    static let downloadPath = "QH65B2/account/auth/key/download"
    static let revokePath = "QH65B2/account/auth/key/revoke"
    static let pageSize = 500
    static let maxPages = 20
    public let portal: PortalWebClient

    public init(portal: PortalWebClient) { self.portal = portal }

    /// Key IDs are 1 to 32 ASCII letters and digits (`2X9R4HXF34`); anything else never reaches a URL or a form.
    public static func isKeyID(_ text: String) -> Bool {
        (1...32).contains(text.count) && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    static func checkKeyID(_ id: String) throws {
        guard isKeyID(id) else {
            throw XlessError(.account, "\(id.prefix(64)) is not an auth key ID", fix: "pass the key ID shown by `xless keys list` (e.g. 2X9R4HXF34)")
        }
    }

    /// Every key of the team, with its services (a key the listing shows without them is read on its own).
    public func list() async throws -> [PortalAuthKey] {
        var keys: [PortalAuthKey] = []
        for number in 1...Self.maxPages {
            let data = try await portal.legacy(Self.listPath, form: PortalIdentifiers.pageForm(number, size: Self.pageSize), page: Self.page)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["keys"] as? [[String: Any]] else {
                throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(Self.listPath), what: "no list of keys", page: Self.page)
            }
            for entry in list {
                guard let key = Self.parse(entry) else {
                    throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(Self.listPath),
                                                    what: "a key without a key ID xless accepts", page: Self.page)
                }
                if !keys.contains(where: { $0.id == key.id }) { keys.append(key) }
            }
            let total = (object["totalRecords"] as? NSNumber)?.intValue
            if list.isEmpty || (total.map { keys.count >= $0 } ?? (list.count < Self.pageSize)) {
                var filled: [PortalAuthKey] = []
                // A real key has at least one service: none listed means the listing left them out.
                for key in keys { filled.append((key.services ?? []).isEmpty ? try await get(id: key.id) : key) }
                return filled
            }
        }
        throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(Self.listPath), what: "more than \(Self.maxPages) pages", page: Self.page)
    }

    /// One key, with its services.
    public func get(id: String) async throws -> PortalAuthKey {
        try Self.checkKeyID(id)
        let data = try await portal.legacy(Self.getPath, form: [("keyId", id)], page: Self.page)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["keys"] as? [[String: Any]] else {
            throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(Self.getPath), what: "no key", page: Self.page)
        }
        guard let key = list.compactMap(Self.parse).first(where: { $0.id == id }) else {
            throw XlessError(.account, "the team has no auth key \(id)", fix: "check the ID with `xless keys list` (and --team)")
        }
        return key
    }

    /// Creates a key for `services`; `bundleIDs` are the bundle ID resource IDs of a Sign in with Apple key, `musicIDs`
    /// the Music ID resource IDs of a MusicKit key. Sent once, never retried: an answer that does not come, or a server
    /// error, leaves it unknown whether the key exists.
    public func create(name: String, services: [AuthKeyService], bundleIDs: [String], musicIDs: [String] = []) async throws -> PortalAuthKey {
        try await primeCSRF()
        let team = try await portal.requireTeam()
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "teamId": team,
                                                               "serviceConfigurationsRequests": services.map { $0.request(bundleIDs: bundleIDs, musicIDs: musicIDs) }],
                                              options: [.sortedKeys])
        let display = PortalWebClient.display(Self.createPath)
        let unknown = "a key may have been created anyway: check `xless keys list` and revoke any key you did not get (`xless keys revoke <KEY_ID>`), then re-run"
        let response: AppleWebResponse
        do {
            response = try await portal.send("POST", Self.createPath, body: body, headers: ["Content-Type": "application/json"])
        } catch {
            throw XlessError(.account, "the request to create the auth key got no answer (\(XlessError.wrapping(error, stage: .account).cause))", fix: unknown)
        }
        if response.status >= 500 {
            throw XlessError(.account, "\(AppleWebFamily.developerPortal.name) answered HTTP \(response.status) to POST \(display)", fix: unknown)
        }
        let data = try await portal.checkResult(response, path: Self.createPath, page: Self.page)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (object["keys"] as? [[String: Any]])?.compactMap(Self.parse).first else {
            throw XlessError(.account, "the developer portal accepted the new auth key but its answer names no key xless can read",
                             fix: "check `xless keys list` and revoke the new key (`xless keys revoke <KEY_ID>`): its private key can only be downloaded once (\(AppleWebFailure.undocumented))")
        }
        return key
    }

    /// The one-time download of a key's private key: one request, never retried (Apple serves the key once). The PEM goes
    /// straight into `SecretBytes`.
    public func downloadPrivateKey(id: String) async throws -> SecretBytes {
        guard Self.isKeyID(id) else { throw APIKeyDownloadError.unreadable("a key ID xless does not accept (\(id.prefix(64)))") }
        let response: AppleWebResponse
        do {
            let team = try await portal.requireTeam()
            let path = Self.downloadPath + "?" + PortalWebClient.formEncoded([("teamId", team), ("keyId", id)])
            response = try await portal.send("GET", path, body: nil, headers: [:])
        } catch {
            throw APIKeyDownloadError.noAnswer(XlessError.wrapping(error, stage: .account).cause)
        }
        guard response.isSuccess else {
            throw APIKeyDownloadError.refused(status: response.status, message: AppleWebFailure.message(response.data))
        }
        // An error comes back as the portal's JSON envelope, not a key.
        if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
            if let code = (object["resultCode"] as? NSNumber)?.intValue, code != 0 {
                throw APIKeyDownloadError.refused(status: response.status, message: AppleWebFailure.message(response.data))
            }
            throw APIKeyDownloadError.unreadable("a JSON body instead of a private key")
        }
        return try Self.privateKey(from: response.data)
    }

    /// The body as a validated P-256 PKCS#8 PEM.
    static func privateKey(from body: Data) throws -> SecretBytes {
        var copy = body
        let secret = SecretBytes(wiping: &copy)
        let text = secret.utf8String()
        guard text.contains("-----BEGIN PRIVATE KEY-----"),
              (try? P256.Signing.PrivateKey(pemRepresentation: PEM.normalize(text))) != nil else {
            secret.wipe()
            throw APIKeyDownloadError.unreadable("something that is not a P-256 private key (.p8)")
        }
        return secret
    }

    /// Revokes a key. Apple cannot undo it.
    public func revoke(id: String) async throws {
        try Self.checkKeyID(id)
        try await primeCSRF()
        _ = try await portal.legacy(Self.revokePath, form: [("keyId", id)], page: Self.page)
    }

    /// The CSRF tokens of the keys pages, from a one-item listing (fastlane: `fetch_csrf_token_for_keys`).
    func primeCSRF() async throws {
        _ = try await portal.legacy(Self.listPath, form: PortalIdentifiers.pageForm(1, size: 1), page: Self.page)
    }

    static func parse(_ entry: [String: Any]) -> PortalAuthKey? {
        guard let id = entry["keyId"] as? String, isKeyID(id) else { return nil }
        let services = (entry["services"] as? [[String: Any]])?.compactMap { s -> PortalAuthKey.Service? in
            guard let sid = s["id"] as? String, !sid.isEmpty else { return nil }
            let bundles = (s["configurations"] as? [[String: Any]] ?? []).compactMap { c -> String? in
                guard (c["type"] as? String) == "bundle" else { return nil }
                return c["id"] as? String
            }
            return PortalAuthKey.Service(id: sid, name: (s["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, bundleIDs: bundles)
        }
        return PortalAuthKey(id: id, name: entry["keyName"] as? String ?? "", services: services,
                             canDownload: (entry["canDownload"] as? NSNumber)?.boolValue ?? false,
                             canRevoke: (entry["canRevoke"] as? NSNumber)?.boolValue ?? true)
    }
}
