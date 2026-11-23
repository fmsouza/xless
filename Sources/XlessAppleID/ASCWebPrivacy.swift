import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// One App Privacy answer as App Store Connect keeps it (`appDataUsages`): a data category, a purpose and a data
/// protection, any of which may be missing ("Data Not Collected" has only its protection).
public struct WebDataUsage: Sendable, Equatable {
    public var id: String
    public var category: String?
    public var purpose: String?
    public var protection: String?

    public init(id: String, category: String? = nil, purpose: String? = nil, protection: String? = nil) {
        self.id = id; self.category = category; self.purpose = purpose; self.protection = protection
    }
}

/// The IDs App Store Connect accepts in App Privacy answers, each with whether Apple has retired it (`deleted`).
public struct WebPrivacyCatalog: Sendable, Equatable {
    public var categories: [String: Bool]
    public var purposes: [String: Bool]
    public var protections: [String: Bool]

    public init(categories: [String: Bool] = [:], purposes: [String: Bool] = [:], protections: [String: Bool] = [:]) {
        self.categories = categories; self.purposes = purposes; self.protections = protections
    }
}

/// Whether the app's App Privacy answers are published (`appDataUsagesPublishState`).
public struct WebPrivacyPublishState: Sendable, Equatable {
    public var id: String
    /// nil when App Store Connect does not say.
    public var published: Bool?

    public init(id: String, published: Bool?) { self.id = id; self.published = published }
}

/// App Privacy through the Apple ID web session (`/iris/v1`): the documented API has no App Privacy. Undocumented;
/// the requests are the ones App Store Connect's App Privacy page sends, as fastlane (spaceship/connect_api/tunes/tunes.rb,
/// appDataUsage*) and the App Store Connect CLI (internal/web/privacy.go) send them. A create is sent once, never
/// retried (a second attempt after one that went through would answer twice).
public struct ASCWebPrivacy: Sendable {
    public static let page = "https://appstoreconnect.apple.com/apps"
    static let maxPages = 50
    public let asc: ASCWebClient

    public init(asc: ASCWebClient) { self.asc = asc }

    /// The app's answers (every page).
    public func usages(app: String) async throws -> [WebDataUsage] {
        let items = try await list("/iris/v1/apps/\(try Self.segment(app))/dataUsages",
                                   query: [URLQueryItem(name: "include", value: "category,purpose,dataProtection"), URLQueryItem(name: "limit", value: "500")])
        return items.compactMap(Self.usage)
    }

    /// The categories, purposes and data protections App Store Connect knows.
    public func catalog() async throws -> WebPrivacyCatalog {
        func ids(_ items: [[String: Any]]) -> [String: Bool] {
            var out: [String: Bool] = [:]
            for item in items {
                guard let id = item["id"] as? String, !id.isEmpty else { continue }
                out[id] = ((item["attributes"] as? [String: Any])?["deleted"] as? Bool) ?? false
            }
            return out
        }
        let limit = URLQueryItem(name: "limit", value: "200")
        return WebPrivacyCatalog(
            categories: ids(try await list("/iris/v1/appDataUsageCategories", query: [URLQueryItem(name: "include", value: "grouping"), limit])),
            purposes: ids(try await list("/iris/v1/appDataUsagePurposes", query: [limit])),
            protections: ids(try await list("/iris/v1/appDataUsageDataProtections", query: [limit])))
    }

    /// Whether the answers are published; nil when App Store Connect has no publish state for the app (404).
    public func publishState(app: String) async throws -> WebPrivacyPublishState? {
        let path = "/iris/v1/apps/\(try Self.segment(app))/dataUsagePublishState"
        let response = try await asc.send("GET", path)
        if response.status == 404 { return nil }
        guard response.isSuccess else { throw AppleWebFailure.refused(.appStoreConnect, method: "GET", path: path, response: response, page: Self.page) }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let data = object["data"] as? [String: Any], let id = data["id"] as? String, !id.isEmpty else {
            throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a publish state xless cannot read", page: Self.page)
        }
        return WebPrivacyPublishState(id: id, published: (data["attributes"] as? [String: Any])?["published"] as? Bool)
    }

    /// Creates one answer (sent once); returns its ID when App Store Connect says it.
    @discardableResult
    public func create(app: String, category: String?, purpose: String?, protection: String) async throws -> String? {
        let body = try Self.createDocument(app: app, category: category, purpose: purpose, protection: protection)
        let data = try await asc.data("POST", "/iris/v1/appDataUsages", body: body, page: Self.page)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["data"] as? [String: Any])?["id"] as? String
    }

    /// `{ data: { type: appDataUsages, relationships: { app, category?, purpose?, dataProtection } } }`, keys sorted.
    static func createDocument(app: String, category: String?, purpose: String?, protection: String) throws -> Data {
        func ref(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
        var relationships: [String: Any] = ["app": ref("apps", app), "dataProtection": ref("appDataUsageDataProtections", protection)]
        if let category { relationships["category"] = ref("appDataUsageCategories", category) }
        if let purpose { relationships["purpose"] = ref("appDataUsagePurposes", purpose) }
        return try JSONSerialization.data(withJSONObject: ["data": ["type": "appDataUsages", "relationships": relationships] as [String: Any]],
                                          options: [.sortedKeys])
    }

    /// Deletes one answer; one already gone (404) is done.
    public func delete(id: String) async throws {
        let path = "/iris/v1/appDataUsages/\(try Self.segment(id))"
        let response = try await asc.send("DELETE", path)
        guard response.isSuccess || response.status == 404 else {
            throw AppleWebFailure.refused(.appStoreConnect, method: "DELETE", path: path, response: response, page: Self.page)
        }
    }

    /// Publishes the answers (`published: true`).
    public func publish(stateID: String) async throws {
        let id = try Self.segment(stateID)
        let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "appDataUsagesPublishState", "id": stateID,
                                                                        "attributes": ["published": true]] as [String: Any]],
                                              options: [.sortedKeys])
        _ = try await asc.data("PATCH", "/iris/v1/appDataUsagesPublishState/\(id)", body: body, page: Self.page)
    }

    // MARK: Reading

    /// Every page of a list, following `links.next` within App Store Connect's web interface.
    func list(_ start: String, query start0: [URLQueryItem]) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var path = start, query = start0
        for _ in 0..<Self.maxPages {
            let data = try await asc.data("GET", path, query: query, page: Self.page)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = object["data"] as? [[String: Any]] else {
                throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a body xless cannot read", page: Self.page)
            }
            items += page
            guard let next = (object["links"] as? [String: Any])?["next"] as? String, !next.isEmpty else { return items }
            guard let url = URLComponents(string: next), url.scheme == "https", url.host == ASCWebClient.host, url.path.hasPrefix("/iris/v1/") else {
                throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: path, what: "a next page outside App Store Connect", page: Self.page)
            }
            path = url.path
            query = url.queryItems ?? []
        }
        throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: start, what: "more than \(Self.maxPages) pages", page: Self.page)
    }

    static func usage(_ resource: [String: Any]) -> WebDataUsage? {
        guard let id = resource["id"] as? String, !id.isEmpty else { return nil }
        let relationships = resource["relationships"] as? [String: Any] ?? [:]
        func linked(_ name: String) -> String? {
            guard let data = (relationships[name] as? [String: Any])?["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return WebDataUsage(id: id, category: linked("category"), purpose: linked("purpose"), protection: linked("dataProtection"))
    }

    /// An ID as one path segment; anything that could leave it (a slash, a dot-only name, a control character) is refused.
    static func segment(_ id: String) throws -> String {
        guard !id.isEmpty, id.range(of: "^[A-Za-z0-9._~=+-]+$", options: .regularExpression) != nil, id != ".", id != ".." else {
            throw XlessError(.account, "App Store Connect gave an ID xless cannot put in a URL (\(id.prefix(40)))", fix: "re-run; if it persists, report it")
        }
        return id
    }
}
