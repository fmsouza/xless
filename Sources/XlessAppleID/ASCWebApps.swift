import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// What `xless apps create` asks App Store Connect for: one app record, its name in the primary locale, and a first
/// App Store version per platform. Checked by the caller (XlessASC's `AppName`, `AppSKU`, `AppLocale`).
public struct AppCreateRequest: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var sku: String
    public var primaryLocale: String
    /// App Store Connect platform values, `IOS` / `MAC_OS`, in order, without repeats.
    public var platforms: [String]
    public var versionString: String
    public var companyName: String?

    public init(name: String, bundleID: String, sku: String, primaryLocale: String, platforms: [String], versionString: String = "1.0",
                companyName: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.sku = sku; self.primaryLocale = primaryLocale; self.platforms = platforms
        self.versionString = versionString; self.companyName = companyName
    }
}

/// An app record as App Store Connect's web interface answers it.
public struct WebApp: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var bundleID: String
    public var sku: String?
    public var primaryLocale: String?

    public init(id: String, name: String? = nil, bundleID: String, sku: String? = nil, primaryLocale: String? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.sku = sku; self.primaryLocale = primaryLocale
    }
}

/// Why App Store Connect refused to create an app, as far as its answer says.
public enum AppCreateRefusal: Sendable, Equatable {
    /// App names are unique across the whole App Store.
    case nameTaken
    /// SKUs are unique within a team.
    case skuTaken
    /// The bundle ID already has an app record, or cannot take one.
    case bundleIDTaken
    case other
}

/// The outcome of the single create request.
public enum AppCreateAnswer: Sendable {
    case created(WebApp)
    /// A definite refusal: nothing was created. `error` is what to tell the user.
    case refused(AppCreateRefusal, error: XlessError)
    /// No answer, a server error or an answer xless cannot read: the app may or may not exist. Look it up.
    case ambiguous(String)
}

/// App records through the Apple ID web session (`/iris/v1/apps`): the documented API can read and update apps but not
/// create them. Undocumented; the request document is the one App Store Connect's New App dialog sends, as fastlane
/// (spaceship/connect_api/tunes/tunes.rb `post_app`), the App Store Connect CLI (internal/web/apps.go) and RevenueCat's
/// CLI (internal/appleconnect/apps.go) send it.
public struct ASCWebApps: Sendable {
    public static let page = "https://appstoreconnect.apple.com/apps"
    static let path = "/iris/v1/apps"
    public let asc: ASCWebClient

    public init(asc: ASCWebClient) { self.asc = asc }

    /// The JSON:API compound document: the app (sku, primaryLocale, bundleId, companyName when given) with an app info
    /// holding the name in the primary locale, and one App Store version per platform with a localization in that
    /// locale. The `${…}` IDs are placeholders App Store Connect replaces with the IDs it creates. Keys sorted.
    public static func document(_ r: AppCreateRequest) throws -> Data {
        func ref(_ type: String, _ id: String) -> [String: Any] { ["type": type, "id": id] }
        let infoID = "${new-appInfo-id}", infoLocalizationID = "${new-appInfoLocalization-id}"
        var included: [[String: Any]] = [
            ["type": "appInfos", "id": infoID,
             "relationships": ["appInfoLocalizations": ["data": [ref("appInfoLocalizations", infoLocalizationID)]]]],
            ["type": "appInfoLocalizations", "id": infoLocalizationID, "attributes": ["locale": r.primaryLocale, "name": r.name]],
        ]
        var versions: [[String: Any]] = []
        for platform in r.platforms {
            let versionID = "${store-version-\(platform)}", localizationID = "${new-\(platform)VersionLocalization-id}"
            included.append(["type": "appStoreVersions", "id": versionID,
                             "attributes": ["platform": platform, "versionString": r.versionString],
                             "relationships": ["appStoreVersionLocalizations": ["data": [ref("appStoreVersionLocalizations", localizationID)]]]])
            included.append(["type": "appStoreVersionLocalizations", "id": localizationID, "attributes": ["locale": r.primaryLocale]])
            versions.append(ref("appStoreVersions", versionID))
        }
        var attributes: [String: Any] = ["sku": r.sku, "primaryLocale": r.primaryLocale, "bundleId": r.bundleID]
        if let company = r.companyName { attributes["companyName"] = company }
        let data: [String: Any] = ["type": "apps", "attributes": attributes,
                                   "relationships": ["appStoreVersions": ["data": versions], "appInfos": ["data": [ref("appInfos", infoID)]]]]
        return try JSONSerialization.data(withJSONObject: ["data": data, "included": included], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The app record with exactly this bundle identifier, if the current provider has one.
    public func find(bundleID: String) async throws -> WebApp? {
        let data = try await asc.data("GET", Self.path, query: [URLQueryItem(name: "filter[bundleId]", value: bundleID)], page: Self.page)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else {
            throw AppleWebFailure.malformed(.appStoreConnect, method: "GET", path: Self.path, what: "a body xless cannot read", page: Self.page)
        }
        return items.compactMap(Self.parse).first { $0.bundleID == bundleID }
    }

    /// Sends the create request once (never retried: a second attempt after one that went through would fail on the
    /// unique name and SKU, or worse) and says what became of it.
    public func create(_ request: AppCreateRequest) async -> AppCreateAnswer {
        let body: Data
        do { body = try Self.document(request) } catch { return .refused(.other, error: XlessError.wrapping(error, stage: .account)) }
        let response: AppleWebResponse
        do { response = try await asc.send("POST", Self.path, body: body) } catch {
            return .ambiguous("App Store Connect did not answer (\(XlessError.wrapping(error, stage: .account).cause))")
        }
        if response.isSuccess {
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let data = object["data"] as? [String: Any], var app = Self.parse(data) else {
                return .ambiguous("App Store Connect answered HTTP \(response.status) without an app xless can read")
            }
            if app.bundleID.isEmpty { app.bundleID = request.bundleID }
            if app.name == nil { app.name = request.name }
            return .created(app)
        }
        if [408, 429].contains(response.status) || response.status >= 500 {
            return .ambiguous("App Store Connect answered HTTP \(response.status)")
        }
        return Self.refusal(response, request: request)
    }

    // MARK: Refusals

    static func refusal(_ response: AppleWebResponse, request r: AppCreateRequest) -> AppCreateAnswer {
        let message = AppleWebFailure.message(response.data)
        let said = message.map { ": \($0)" } ?? ""
        if response.status == 403 {
            return .refused(.other, error: XlessError(
                .account, "App Store Connect refused to create the app (HTTP 403\(said))",
                fix: "creating apps needs an Apple ID with the Account Holder, Admin or App Manager role on this team; ask the Account Holder"))
        }
        let reason = response.status == 401 ? .other : classify(response.data)
        switch reason {
        case .nameTaken:
            return .refused(reason, error: XlessError(
                .account, "App Store Connect refused the app name \"\(r.name)\"\(said)",
                fix: "app names are unique across the whole App Store and this one is taken (or reserved): pick another with --name; the name can be changed later"))
        case .skuTaken:
            return .refused(reason, error: XlessError(
                .account, "App Store Connect refused the SKU \(r.sku)\(said)",
                fix: "a SKU is used once per team, even by a removed app: pick another with --sku"))
        case .bundleIDTaken:
            return .refused(reason, error: XlessError(
                .account, "App Store Connect refused the bundle ID \(r.bundleID)\(said)",
                fix: "a bundle ID has one app record, even a removed one: check `xless apps list` and App Store Connect > Apps > Removed Apps (\(page)), or use another bundle ID"))
        case .other:
            return .refused(.other, error: AppleWebFailure.refused(.appStoreConnect, method: "POST", path: path, response: response, page: page))
        }
    }

    /// What a refusal is about, from Apple's error text and the field it points at.
    static func classify(_ body: Data) -> AppCreateRefusal {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]] else { return .other }
        for e in errors {
            let text = [e["code"], e["title"], e["detail"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            let pointer = (((e["source"] as? [String: Any])?["pointer"] as? String) ?? "").lowercased()
            if text.contains("sku") || pointer.hasSuffix("/sku") { return .skuTaken }
            if text.contains("bundle") || pointer.hasSuffix("/bundleid") { return .bundleIDTaken }
            let taken = ["already", "in use", "being used", "not available", "unavailable", "taken"].contains { text.contains($0) }
            if (text.contains("name") && taken) || pointer.hasSuffix("/name") { return .nameTaken }
        }
        return .other
    }

    static func parse(_ resource: [String: Any]) -> WebApp? {
        guard let id = resource["id"] as? String, !id.isEmpty, !id.hasPrefix("${") else { return nil }
        let a = resource["attributes"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { (a[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return WebApp(id: id, name: string("name"), bundleID: string("bundleId") ?? "", sku: string("sku"), primaryLocale: string("primaryLocale"))
    }
}
