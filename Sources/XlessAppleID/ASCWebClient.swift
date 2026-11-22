import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// An App Store Connect provider (a team, as App Store Connect numbers it; not the portal's team ID).
public struct OlympusProvider: Codable, Sendable, Equatable {
    public let providerId: Int
    public let name: String
    public let contentTypes: [String]?

    public init(providerId: Int, name: String, contentTypes: [String]? = nil) {
        self.providerId = providerId; self.name = name; self.contentTypes = contentTypes
    }
}

/// `GET /olympus/v1/session`: the provider in use and the ones this Apple ID can switch to.
public struct OlympusSession: Decodable, Sendable, Equatable {
    public let provider: OlympusProvider?
    public let availableProviders: [OlympusProvider]?

    public init(provider: OlympusProvider?, availableProviders: [OlympusProvider]?) {
        self.provider = provider; self.availableProviders = availableProviders
    }

    /// Every provider this Apple ID has (the available ones, else the current one).
    public var providers: [OlympusProvider] {
        if let all = availableProviders, !all.isEmpty { return all }
        return provider.map { [$0] } ?? []
    }
}

/// App Store Connect's own web interface (`https://appstoreconnect.apple.com/iris/v1/…`, `/olympus/v1/…`), through the
/// Apple ID session: for what the documented API cannot do (creating apps, API keys, App Privacy). Undocumented: the
/// headers are the ones App Store Connect's pages send (fastlane: spaceship/connect_api/tunes/client.rb), and the
/// `csrf` / `csrf_ts` tokens of each answer go back on the next request.
public actor ASCWebClient {
    public static let host = "appstoreconnect.apple.com"
    static let origin = "https://appstoreconnect.apple.com"
    public let web: AppleWebClient
    private var csrf = CSRFTokens()

    public init(web: AppleWebClient) { self.web = web }

    /// One request; any status comes back. `path` is `/iris/v1/…` or `/olympus/v1/…`; `body` is JSON.
    public func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> AppleWebResponse {
        guard path.hasPrefix("/iris/v1/") || path.hasPrefix("/olympus/v1/"), !path.contains("..") else {
            throw XlessError(.account, "refused a request outside App Store Connect's web interface (\(path))",
                             fix: "this is a bug in xless; please report it")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw XlessError(.account, "cannot build a URL for \(path)", fix: "this is a bug in xless; please report it")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        for (k, v) in ["Accept": "application/json, text/plain, */*", "Content-Type": "application/json",
                       "X-CSRF-ITC": "[asc-ui]", "X-Requested-With": "XMLHttpRequest",
                       "Origin": Self.origin, "Referer": Self.origin + "/"] {
            r.setValue(v, forHTTPHeaderField: k)
        }
        csrf.apply(to: &r)
        let (data, http) = try await web.send(r)
        let response = AppleWebResponse(data, http)
        csrf.remember(response)
        return response
    }

    /// The body of a 2xx answer; any other is an `[account]` error naming this family (`page`: where to do it meanwhile).
    public func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, page: String? = nil) async throws -> Data {
        let response = try await send(method, path, query: query, body: body)
        guard response.isSuccess else {
            throw AppleWebFailure.refused(.appStoreConnect, method: method, path: path, response: response, page: page)
        }
        return response.data
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                                   page: String? = nil) async throws -> T {
        let data = try await data(method, path, query: query, body: body, page: page)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw AppleWebFailure.malformed(.appStoreConnect, method: method, path: path, what: "a body xless cannot read", page: page)
        }
    }

    static let sessionPath = "/olympus/v1/session"

    /// The provider in use and the ones this Apple ID can switch to.
    public func session() async throws -> OlympusSession {
        try await json(OlympusSession.self, "GET", Self.sessionPath)
    }

    /// Switches the session to `providerId` and reads the session again to confirm it (fastlane: spaceship/client.rb).
    @discardableResult
    public func switchProvider(to providerId: Int) async throws -> OlympusSession {
        let body = try JSONSerialization.data(withJSONObject: ["provider": ["providerId": providerId]], options: [.sortedKeys])
        _ = try await data("POST", Self.sessionPath, body: body)
        let now = try await session()
        guard now.provider?.providerId == providerId else {
            throw XlessError(.account, "App Store Connect did not switch to provider \(providerId) (it is on \(now.provider.map { "\($0.name) (\($0.providerId))" } ?? "none"))",
                             fix: "\(AppleWebFailure.undocumented); meanwhile pick the team in the top right of https://appstoreconnect.apple.com")
        }
        return now
    }

    /// The agreements App Store Connect says are pending (plain text), [] when none, nil when it would not say.
    public func pendingAgreements() async -> [String]? {
        guard let response = try? await send("GET", "/olympus/v1/contractMessages"), response.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: response.data) else { return nil }
        let items = object as? [[String: Any]] ?? ((object as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            let text = ["subject", "title", "message"].compactMap { item[$0] as? String }.first ?? ""
            let plain = AppleWebFailure.plain(text)
            return plain.isEmpty ? nil : plain
        }
    }
}
