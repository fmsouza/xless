import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// A developer team, as the portal lists it (`teamId` is the 10-character team ID).
public struct PortalTeam: Codable, Sendable, Equatable {
    public let teamId: String
    public let name: String
    public let type: String?
    public let status: String?

    public init(teamId: String, name: String, type: String? = nil, status: String? = nil) {
        self.teamId = teamId; self.name = name; self.type = type; self.status = status
    }
}

/// The developer portal's web interface (`https://developer.apple.com/services-account/…`), through the Apple ID session:
/// for app groups, iCloud containers and auth keys, which the App Store Connect API does not cover. The newer
/// `v1/…` JSON:API endpoints first (`jsonAPI`); the older `QH65B2/….action` form posts (`legacy`) only where nothing newer
/// exists. Undocumented: the calls are the ones the portal's pages make (fastlane: spaceship/portal/portal_client.rb).
/// A write first obtains the `csrf` / `csrf_ts` tokens from a listing (`primeCSRF`), and every answer's tokens go back
/// on the next request.
public actor PortalWebClient {
    public static let base = "https://developer.apple.com/services-account/"
    public let web: AppleWebClient
    /// The team every call works on (`use(team:)`); the teams listing needs none.
    public private(set) var teamID: String?
    private var csrf = CSRFTokens()

    public init(web: AppleWebClient, teamID: String? = nil) {
        self.web = web
        self.teamID = teamID
    }

    public func use(team: String) { teamID = team }

    /// The teams this Apple ID belongs to (`QH65B2/account/listTeams.action`).
    public func teams() async throws -> [PortalTeam] {
        struct Listing: Decodable { let teams: [PortalTeam]? }
        let path = "QH65B2/account/listTeams.action"
        let data = try await legacy(path, team: false)
        guard let teams = (try? JSONDecoder().decode(Listing.self, from: data))?.teams else {
            throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: Self.display(path), what: "no list of teams")
        }
        return teams
    }

    /// A `QH65B2/….action` form post (with `teamId` unless `team` is false). Answers with `resultCode` other than 0 are
    /// errors. Returns the JSON body.
    public func legacy(_ path: String, form: [(String, String)] = [], team: Bool = true, page: String? = nil) async throws -> Data {
        var fields = form
        if team { fields.append(("teamId", try requireTeam())) }
        let body = Data(Self.formEncoded(fields).utf8)
        let response = try await send("POST", path, body: body, headers: ["Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"])
        try check(response, method: "POST", path: path, page: page)
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: Self.display(path),
                                            what: "a body that is not JSON (the session may have expired)", page: page)
        }
        if let code = (object["resultCode"] as? NSNumber)?.intValue, code != 0 {
            let message = AppleWebFailure.message(response.data)
            if let message, AppleWebFailure.mentionsAgreement(message) { throw AppleWebFailure.agreement(.developerPortal, message: message) }
            throw XlessError(.account, "\(AppleWebFamily.developerPortal.name) refused POST \(Self.display(path)) (result \(code))\(message.map { ": \($0)" } ?? "")",
                             fix: "\(AppleWebFailure.undocumented); meanwhile do it at \(page ?? AppleWebFamily.developerPortal.page)")
        }
        return response.data
    }

    /// A `v1/…` JSON:API call for the selected team. A GET goes as a POST with `X-HTTP-Method-Override: GET` and the
    /// query in the body next to `teamId`, as the portal's pages send it (`urlQuery` stays in the URL: the portal reads
    /// some filters there); other methods send `body` (JSON:API) after `primeCSRF()`. Returns the body of a 2xx answer.
    public func jsonAPI(_ method: String, _ path: String, query: [(String, String)] = [], urlQuery: [(String, String)] = [],
                        body: Data? = nil, page: String? = nil) async throws -> Data {
        let response = try await jsonAPIResponse(method, path, query: query, urlQuery: urlQuery, body: body)
        try check(response, method: method, path: path, page: page)
        return response.data
    }

    /// `jsonAPI` without the status check: the answer as it came, for callers that decide on the status themselves
    /// (`PortalFallback`).
    public func jsonAPIResponse(_ method: String, _ path: String, query: [(String, String)] = [], urlQuery: [(String, String)] = [],
                                body: Data? = nil) async throws -> AppleWebResponse {
        guard path.hasPrefix("v1/"), !path.contains("?") else {
            throw XlessError(.account, "refused a portal request outside services-account/v1 (\(path))", fix: "this is a bug in xless; please report it")
        }
        let team = try requireTeam()
        if method == "GET" {
            let envelope = try JSONSerialization.data(withJSONObject: ["teamId": team, "urlEncodedQueryParams": Self.formEncoded(query)],
                                                      options: [.sortedKeys])
            let target = urlQuery.isEmpty ? path : path + "?" + Self.formEncoded(urlQuery)
            return try await send("POST", target, body: envelope,
                                  headers: ["Content-Type": "application/vnd.api+json", "X-HTTP-Method-Override": "GET"])
        }
        try await primeCSRF()
        let all = query + urlQuery
        let target = all.isEmpty ? path : path + "?" + Self.formEncoded(all)
        return try await send(method, target, body: body, headers: ["Content-Type": "application/vnd.api+json"])
    }

    /// Gets the CSRF tokens a write needs, from a one-item listing (fastlane: portal_client.rb), unless they are held.
    public func primeCSRF() async throws {
        guard csrf.isEmpty else { return }
        _ = try await legacy("QH65B2/account/ios/profile/listProvisioningProfiles.action",
                             form: [("pageNumber", "1"), ("pageSize", "1"), ("sort", "name=asc")])
    }

    func send(_ method: String, _ path: String, body: Data?, headers: [String: String]) async throws -> AppleWebResponse {
        guard (path.hasPrefix("QH65B2/") || path.hasPrefix("v1/")), !path.contains(".."), let url = URL(string: Self.base + path) else {
            throw XlessError(.account, "refused a request outside the developer portal's web interface (\(path))", fix: "this is a bug in xless; please report it")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        csrf.apply(to: &r)
        let (data, http) = try await web.send(r)
        let response = AppleWebResponse(data, http)
        csrf.remember(response)
        return response
    }

    func check(_ response: AppleWebResponse, method: String, path: String, page: String?) throws {
        guard response.isSuccess else {
            throw AppleWebFailure.refused(.developerPortal, method: method, path: Self.display(path), response: response, page: page)
        }
    }

    private func requireTeam() throws -> String {
        guard let teamID else {
            throw XlessError(.account, "no team is selected for the developer portal",
                             fix: "pass --team <TEAM_ID>, or save one with `xless team use <TEAM_ID>` (see `xless team list`)")
        }
        return teamID
    }

    /// `/services-account/<path>` without a query, for messages.
    static func display(_ path: String) -> String {
        "/services-account/" + (path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path)
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }
}
