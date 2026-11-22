import Crypto
import Foundation
import XlessCore

/// One App Store Connect API key (a team key, `keyType` PUBLIC_API) as App Store Connect's web interface lists it.
/// Never its private key.
public struct ASCAPIKeyInfo: Codable, Sendable, Equatable {
    public var id: String
    public var nickname: String?
    public var roles: [String]
    public var isActive: Bool
    public var allAppsVisible: Bool
    /// Whether App Store Connect still offers the one-time download of the private key.
    public var canDownload: Bool
    public var keyType: String?
    public var lastUsed: String?
    public var revokingDate: String?
    /// Who generated / revoked it (a person's name or Apple ID), when App Store Connect includes it.
    public var createdBy: String?
    public var revokedBy: String?
    /// The provider's public ID, the key's issuer ID, when App Store Connect includes it.
    public var issuerID: String?

    public init(id: String, nickname: String? = nil, roles: [String] = [], isActive: Bool = true, allAppsVisible: Bool = true,
                canDownload: Bool = false, keyType: String? = nil, lastUsed: String? = nil, revokingDate: String? = nil,
                createdBy: String? = nil, revokedBy: String? = nil, issuerID: String? = nil) {
        self.id = id; self.nickname = nickname; self.roles = roles; self.isActive = isActive; self.allAppsVisible = allAppsVisible
        self.canDownload = canDownload; self.keyType = keyType; self.lastUsed = lastUsed; self.revokingDate = revokingDate
        self.createdBy = createdBy; self.revokedBy = revokedBy; self.issuerID = issuerID
    }
}

/// Why the one-time download of a new key's private key failed. Either way the key exists at Apple and xless does not
/// have it: it can never be downloaded again (Apple serves it once), so it should be revoked.
public enum APIKeyDownloadError: Error, Sendable, Equatable {
    /// No answer (the connection failed or was cut): Apple may have served the key, and it is gone with the connection.
    case noAnswer(String)
    /// Apple answered with this status and did not serve the key.
    case refused(status: Int, message: String?)
    /// Apple answered 2xx, but not with a usable P-256 private key.
    case unreadable(String)
}

/// App Store Connect API keys through the Apple ID web session (`/iris/v1/apiKeys`): the documented API cannot create,
/// list or revoke them. Undocumented; the shapes are the ones App Store Connect's Integrations page uses (App Store
/// Connect CLI: internal/web/api_keys.go; RevenueCat cli: internal/appleconnect/keys.go).
public struct ASCAPIKeys: Sendable {
    public static let page = "https://appstoreconnect.apple.com/access/integrations/api"
    static let path = "/iris/v1/apiKeys"
    static let include = "createdBy,revokedBy,provider"
    static let maxPages = 50
    public let asc: ASCWebClient

    public init(asc: ASCWebClient) { self.asc = asc }

    /// Key IDs are short upper-case alphanumerics (`2X9R4HXF34`); anything else never reaches a URL path.
    public static func isKeyID(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Creates a team key. `appIDs` empty: all apps; else only those apps (App Store Connect app IDs). Sent once.
    public func create(nickname: String, roles: [String], appIDs: [String] = []) async throws -> ASCAPIKeyInfo {
        var data: [String: Any] = [
            "type": "apiKeys",
            "attributes": ["nickname": nickname, "roles": roles, "allAppsVisible": appIDs.isEmpty, "keyType": "PUBLIC_API"] as [String: Any],
        ]
        if !appIDs.isEmpty {
            data["relationships"] = ["visibleApps": ["data": appIDs.map { ["type": "apps", "id": $0] }]]
        }
        let body = try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
        let response = try await asc.send("POST", Self.path, body: body)
        guard response.isSuccess else {
            if response.status == 403 { throw Self.createForbidden(message: AppleWebFailure.message(response.data)) }
            throw AppleWebFailure.refused(.appStoreConnect, method: "POST", path: Self.path, response: response, page: Self.page)
        }
        guard let key = Self.parseOne(response.data) else {
            throw XlessError(.account, "App Store Connect created an API key but its answer has no key ID xless can read",
                             fix: "check App Store Connect > Users and Access > Integrations (\(Self.page)) and revoke the new key there: its private key cannot be downloaded again")
        }
        return key
    }

    static func createForbidden(message: String?) -> XlessError {
        XlessError(.account, "App Store Connect refused to create an API key (HTTP 403\(message.map { ": \($0)" } ?? ""))",
                   fix: "only the Account Holder, or an Admin the Account Holder allowed to generate API keys, can create team keys; the Account Holder may first have to request API access once at \(page)")
    }

    /// The one-time download of a key's private key: one request, never retried (Apple serves the key once; a retry
    /// after an unanswered request could only fail). The PEM goes straight into `SecretBytes`.
    public func downloadPrivateKey(id: String) async throws -> SecretBytes {
        guard Self.isKeyID(id) else { throw APIKeyDownloadError.unreadable("a key ID xless does not accept (\(id.prefix(64)))") }
        let response: AppleWebResponse
        do {
            response = try await asc.send("GET", "\(Self.path)/\(id)", query: [URLQueryItem(name: "fields[apiKeys]", value: "privateKey")])
        } catch {
            throw APIKeyDownloadError.noAnswer(XlessError.wrapping(error, stage: .account).cause)
        }
        guard response.isSuccess else {
            throw APIKeyDownloadError.refused(status: response.status, message: AppleWebFailure.message(response.data))
        }
        return try Self.privateKey(from: response.data, id: id)
    }

    /// The `privateKey` attribute (base64 of the PEM, or the PEM itself) as a validated P-256 PKCS#8 PEM.
    static func privateKey(from body: Data, id: String) throws -> SecretBytes {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [String: Any] else { throw APIKeyDownloadError.unreadable("a body xless cannot read") }
        guard (data["id"] as? String) == id else { throw APIKeyDownloadError.unreadable("a different key than the one created") }
        guard let encoded = ((data["attributes"] as? [String: Any])?["privateKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !encoded.isEmpty else {
            throw APIKeyDownloadError.unreadable("no private key")
        }
        var pem: Data
        if encoded.contains("PRIVATE KEY") {
            pem = Data(encoded.utf8)
        } else if let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            pem = decoded
        } else {
            throw APIKeyDownloadError.unreadable("a private key that is not base64")
        }
        // Some answers wrap the PEM in a JSON string.
        if pem.first == UInt8(ascii: "\""), let unquoted = try? JSONDecoder().decode(String.self, from: pem) {
            pem.withUnsafeMutableBytes { SecretBytes.zero($0) }
            pem = Data(unquoted.utf8)
        }
        let secret = SecretBytes(wiping: &pem)
        let text = secret.utf8String()
        guard text.contains("-----BEGIN PRIVATE KEY-----"),
              (try? P256.Signing.PrivateKey(pemRepresentation: PEM.normalize(text))) != nil else {
            secret.wipe()
            throw APIKeyDownloadError.unreadable("something that is not a P-256 private key (.p8)")
        }
        return secret
    }

    /// One key, with who created and revoked it.
    public func get(id: String) async throws -> ASCAPIKeyInfo {
        guard Self.isKeyID(id) else {
            throw XlessError(.account, "\(id) is not an API key ID", fix: "pass the key ID shown by `xless auth api-key list` (e.g. 2X9R4HXF34)")
        }
        let path = "\(Self.path)/\(id)"
        let response = try await asc.send("GET", path, query: [URLQueryItem(name: "include", value: Self.include)])
        if response.status == 404 {
            throw XlessError(.account, "App Store Connect has no API key \(id) for this team",
                             fix: "check the ID with `xless auth api-key list` (and --team)")
        }
        guard response.isSuccess else {
            throw AppleWebFailure.refused(.appStoreConnect, method: "GET", path: path, response: response, page: Self.page)
        }
        guard let key = Self.parseOne(response.data) else {
            throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a body xless cannot read", page: Self.page)
        }
        return key
    }

    /// Every team key of the current provider, following `links.next`.
    public func list() async throws -> [ASCAPIKeyInfo] {
        var keys: [ASCAPIKeyInfo] = []
        var path = Self.path
        var query = [URLQueryItem(name: "include", value: Self.include)]
        for _ in 0..<Self.maxPages {
            let data = try await asc.data("GET", path, query: query, page: Self.page)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["data"] as? [[String: Any]] else {
                throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a body xless cannot read", page: Self.page)
            }
            let included = object["included"] as? [[String: Any]] ?? []
            keys += items.compactMap { Self.parse($0, included: included) }
            guard let next = (object["links"] as? [String: Any])?["next"] as? String, !next.isEmpty else { return keys }
            guard let url = URLComponents(string: next), url.scheme == "https", url.host == ASCWebClient.host,
                  url.path.hasPrefix("/iris/v1/") else {
                throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a next page outside App Store Connect", page: Self.page)
            }
            path = url.path
            query = url.queryItems ?? []
        }
        throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: Self.path, what: "more than \(Self.maxPages) pages", page: Self.page)
    }

    /// Revokes a key (`isActive: false`). Apple cannot undo it.
    public func revoke(id: String) async throws {
        guard Self.isKeyID(id) else {
            throw XlessError(.account, "\(id) is not an API key ID", fix: "pass the key ID shown by `xless auth api-key list`")
        }
        let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "apiKeys", "id": id, "attributes": ["isActive": false]] as [String: Any]],
                                              options: [.sortedKeys])
        _ = try await asc.data("PATCH", "\(Self.path)/\(id)", body: body, page: Self.page)
    }

    // MARK: Parsing

    static func parseOne(_ body: Data) -> ASCAPIKeyInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        return parse(data, included: object["included"] as? [[String: Any]] ?? [])
    }

    static func parse(_ resource: [String: Any], included: [[String: Any]]) -> ASCAPIKeyInfo? {
        guard let id = resource["id"] as? String, !id.isEmpty else { return nil }
        let a = resource["attributes"] as? [String: Any] ?? [:]
        let relationships = resource["relationships"] as? [String: Any] ?? [:]
        func linked(_ name: String) -> (type: String?, id: String)? {
            guard let data = (relationships[name] as? [String: Any])?["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
            return (data["type"] as? String, id)
        }
        func person(_ name: String) -> String? {
            guard let ref = linked(name) else { return nil }
            let match = included.first { ($0["id"] as? String) == ref.id && (ref.type == nil || ($0["type"] as? String) == ref.type) }
            let attrs = match?["attributes"] as? [String: Any] ?? [:]
            let full = [attrs["firstName"], attrs["lastName"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " ")
            if !full.isEmpty { return full }
            return ["name", "username", "userName", "email"].lazy.compactMap { attrs[$0] as? String }.first { !$0.isEmpty } ?? ref.id
        }
        func string(_ key: String) -> String? { (a[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let issuer = ((a["provider"] as? [String: Any])?["id"] as? String) ?? linked("provider")?.id
        return ASCAPIKeyInfo(id: id, nickname: string("nickname"), roles: a["roles"] as? [String] ?? [],
                             isActive: a["isActive"] as? Bool ?? true, allAppsVisible: a["allAppsVisible"] as? Bool ?? true,
                             canDownload: a["canDownload"] as? Bool ?? false, keyType: string("keyType"), lastUsed: string("lastUsed"),
                             revokingDate: string("revokingDate"), createdBy: person("createdBy"), revokedBy: person("revokedBy"),
                             issuerID: issuer.flatMap { $0.isEmpty ? nil : $0 })
    }
}
