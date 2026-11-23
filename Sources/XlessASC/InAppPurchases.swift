import Foundation
import XlessCore

// In-app purchases (consumable, non-consumable, non-renewing subscriptions: /v2/inAppPurchases) and auto-renewable
// subscriptions (/v1/subscriptionGroups, /v1/subscriptions), read through the documented API (the App Store Connect
// API key). `xless iap` and `xless subscriptions` show them; `store pull|push` (XlessStore) read and send them.

public struct ASCInAppPurchaseAttributes: ASCAttributes, Equatable {
    /// The reference name (only App Store Connect shows it).
    public var name: String?
    public var productId: String?
    /// CONSUMABLE, NON_CONSUMABLE or NON_RENEWING_SUBSCRIPTION.
    public var inAppPurchaseType: String?
    public var state: String?
    public var reviewNote: String?
    public var familySharable: Bool?
    public var contentHosting: Bool?
    public init() {}
}

public typealias ASCInAppPurchase = ASCKeptResource<ASCInAppPurchaseAttributes>

public struct ASCSubscriptionGroupAttributes: ASCAttributes, Equatable {
    public var referenceName: String?
    public init() {}
}

public typealias ASCSubscriptionGroup = ASCKeptResource<ASCSubscriptionGroupAttributes>

public struct ASCSubscriptionAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var productId: String?
    public var familySharable: Bool?
    public var state: String?
    /// ONE_WEEK … ONE_YEAR.
    public var subscriptionPeriod: String?
    public var reviewNote: String?
    public var groupLevel: Int?
    public init() {}
}

public typealias ASCSubscription = ASCKeptResource<ASCSubscriptionAttributes>

/// A localization of an in-app purchase, a subscription (name, description) or a subscription group (name,
/// customAppName).
public struct ASCProductLocalizationAttributes: ASCAttributes, Equatable {
    public var locale: String?
    public var name: String?
    public var description: String?
    public var customAppName: String?
    public var state: String?
    public init() {}
}

public typealias ASCProductLocalization = ASCKeptResource<ASCProductLocalizationAttributes>

/// A version of a product's metadata (inAppPurchaseVersions, subscriptionVersions, subscriptionGroupVersions): what
/// a review submission item submits.
public struct ASCProductVersionAttributes: ASCAttributes, Equatable {
    public var version: Int?
    public var state: String?
    public init() {}
}

public typealias ASCProductVersion = ASCKeptResource<ASCProductVersionAttributes>

/// A product's availability: whether new territories are added automatically, and the territories it is sold in.
public struct ASCProductAvailability: Sendable, Equatable, Encodable {
    public var id: String
    public var newTerritories: Bool?
    public var territories: [String]

    public init(id: String, newTerritories: Bool?, territories: [String]) {
        self.id = id; self.newTerritories = newTerritories; self.territories = territories
    }
}

/// One price of a subscription in one territory, from `start` (nil: since ever).
public struct ASCSubscriptionPrice: Sendable, Equatable, Encodable {
    public var id: String
    public var territory: String
    public var start: String?
    public var customerPrice: String?
    public var pointID: String?
    public var preserved: Bool?

    public init(id: String, territory: String, start: String?, customerPrice: String?, pointID: String?, preserved: Bool? = nil) {
        self.id = id; self.territory = territory; self.start = start; self.customerPrice = customerPrice; self.pointID = pointID
        self.preserved = preserved
    }

    /// Each territory's price in effect on `day` (YYYY-MM-DD): the latest that started on or before it.
    public static func current(_ prices: [ASCSubscriptionPrice], on day: String) -> [String: ASCSubscriptionPrice] {
        var out: [String: ASCSubscriptionPrice] = [:]
        for p in prices where (p.start ?? "") <= day {
            if let have = out[p.territory], (have.start ?? "") > (p.start ?? "") { continue }
            out[p.territory] = p
        }
        return out
    }
}

/// The in-app purchase types.
public enum InAppPurchaseType {
    public static let all = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]

    /// consumable / non-consumable / NON_RENEWING_SUBSCRIPTION (any case, - or _) → the API value.
    public static func parse(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "_")
        return all.contains(t) ? t : nil
    }
}

/// The auto-renewable subscription periods.
public enum SubscriptionPeriod {
    public static let all = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
}

/// A product ID (`com.example.coins100`): letters, digits, dots, dashes and underscores; also a file name of the
/// manifest, so never `.`/`..` or a dot file.
public enum ProductID {
    public static func isProductID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && !text.hasPrefix(".")
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    public static func validate(_ text: String) throws {
        guard isProductID(text) else {
            throw IdentifierInputError("\(text) is not a product ID: use letters, digits, dots, dashes and underscores (e.g. com.example.coins100)")
        }
    }
}

/// Reads of an app's in-app purchases and subscriptions.
public struct ASCProducts: Sendable {
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    // MARK: - In-app purchases

    /// Every in-app purchase of the app, by product ID.
    public func inAppPurchases(app appID: String) async throws -> [ASCInAppPurchase] {
        try await resources.list("/v1/apps/\(appID)/inAppPurchasesV2", as: ASCInAppPurchase.self).items
            .sorted { ($0.attributes.productId ?? "") < ($1.attributes.productId ?? "") }
    }

    public func inAppPurchase(id: String) async throws -> ASCInAppPurchase {
        try await resources.get("/v2/inAppPurchases/\(id)", as: ASCInAppPurchase.self).data
    }

    public func iapLocalizations(_ id: String) async throws -> [ASCProductLocalization] {
        try await resources.list("/v2/inAppPurchases/\(id)/inAppPurchaseLocalizations", as: ASCProductLocalization.self).items
    }

    public func iapVersions(_ id: String) async throws -> [ASCProductVersion] {
        try await resources.list("/v2/inAppPurchases/\(id)/versions", as: ASCProductVersion.self).items
    }

    /// The App Review screenshot; nil when there is none.
    public func iapScreenshot(_ id: String) async throws -> ASCAnyResource? {
        try await optionalOne("/v2/inAppPurchases/\(id)/appStoreReviewScreenshot")
    }

    public func iapAvailability(_ id: String) async throws -> ASCProductAvailability? {
        try await availability("/v2/inAppPurchases/\(id)/inAppPurchaseAvailability", territories: "/v1/inAppPurchaseAvailabilities")
    }

    /// The in-app purchase a command names: its product ID, or its resource ID.
    public func resolveIAP(_ text: String, app appID: String) async throws -> ASCInAppPurchase {
        let all = try await inAppPurchases(app: appID)
        if let found = all.first(where: { $0.attributes.productId == text }) ?? all.first(where: { $0.id == text }) { return found }
        throw XlessError(.account, "the app has no in-app purchase \(text)", fix: "`xless iap list --app <app>` lists them (product ID or ID)")
    }

    // MARK: - Subscriptions

    public func groups(app appID: String) async throws -> [ASCSubscriptionGroup] {
        try await resources.list("/v1/apps/\(appID)/subscriptionGroups", as: ASCSubscriptionGroup.self).items
            .sorted { ($0.attributes.referenceName ?? "") < ($1.attributes.referenceName ?? "") }
    }

    public func groupLocalizations(_ id: String) async throws -> [ASCProductLocalization] {
        try await resources.list("/v1/subscriptionGroups/\(id)/subscriptionGroupLocalizations", as: ASCProductLocalization.self).items
    }

    public func groupVersions(_ id: String) async throws -> [ASCProductVersion] {
        try await resources.list("/v1/subscriptionGroups/\(id)/versions", as: ASCProductVersion.self).items
    }

    /// A group's subscriptions, by level then product ID.
    public func subscriptions(group id: String) async throws -> [ASCSubscription] {
        try await resources.list("/v1/subscriptionGroups/\(id)/subscriptions", as: ASCSubscription.self).items
            .sorted { ($0.attributes.groupLevel ?? 0, $0.attributes.productId ?? "") < ($1.attributes.groupLevel ?? 0, $1.attributes.productId ?? "") }
    }

    public func subscription(id: String) async throws -> ASCSubscription {
        try await resources.get("/v1/subscriptions/\(id)", as: ASCSubscription.self).data
    }

    public func subscriptionLocalizations(_ id: String) async throws -> [ASCProductLocalization] {
        try await resources.list("/v1/subscriptions/\(id)/subscriptionLocalizations", as: ASCProductLocalization.self).items
    }

    public func subscriptionVersions(_ id: String) async throws -> [ASCProductVersion] {
        try await resources.list("/v1/subscriptions/\(id)/versions", as: ASCProductVersion.self).items
    }

    public func subscriptionScreenshot(_ id: String) async throws -> ASCAnyResource? {
        try await optionalOne("/v1/subscriptions/\(id)/appStoreReviewScreenshot")
    }

    public func subscriptionAvailability(_ id: String) async throws -> ASCProductAvailability? {
        try await availability("/v1/subscriptions/\(id)/subscriptionAvailability", territories: "/v1/subscriptionAvailabilities")
    }

    /// Every price the subscription has had or will have, in every territory.
    public func subscriptionPrices(_ id: String) async throws -> [ASCSubscriptionPrice] {
        let listing = try await resources.list("/v1/subscriptions/\(id)/prices", query: ASCQuery(include: ["territory", "subscriptionPricePoint"]),
                                               as: ASCAnyResource.self)
        return listing.items.compactMap { item in
            let point = item.relationships?["subscriptionPricePoint"]?["data"]?["id"]?.string
            let included = point.flatMap { p in listing.included.first { $0.type == "subscriptionPricePoints" && $0.id == p } }
            guard let territory = item.relationships?["territory"]?["data"]?["id"]?.string
                ?? included?.relationships?["territory"]?["data"]?["id"]?.string else { return nil }
            let preserved: Bool? = { if case .bool(let b)? = item.attributes?["preserved"] { return b }; return nil }()
            return ASCSubscriptionPrice(id: item.id, territory: territory, start: item.attributes?["startDate"]?.string,
                                        customerPrice: included?.attributes?["customerPrice"]?.string, pointID: point, preserved: preserved)
        }.sorted { ($0.territory, $0.start ?? "") < ($1.territory, $1.start ?? "") }
    }

    /// Every subscription of the app, with its group.
    public func allSubscriptions(app appID: String) async throws -> [(group: ASCSubscriptionGroup, subscription: ASCSubscription)] {
        var out: [(ASCSubscriptionGroup, ASCSubscription)] = []
        for group in try await groups(app: appID) {
            for s in try await subscriptions(group: group.id) { out.append((group, s)) }
        }
        return out
    }

    /// The subscription a command names: its product ID, or its resource ID.
    public func resolveSubscription(_ text: String, app appID: String) async throws -> (group: ASCSubscriptionGroup, subscription: ASCSubscription) {
        let all = try await allSubscriptions(app: appID)
        if let found = all.first(where: { $0.subscription.attributes.productId == text }) ?? all.first(where: { $0.subscription.id == text }) { return found }
        throw XlessError(.account, "the app has no subscription \(text)", fix: "`xless subscriptions list --app <app>` lists them (product ID or ID)")
    }

    // MARK: - Shared

    func optionalOne(_ path: String) async throws -> ASCAnyResource? {
        do { return try await resources.get(path, as: ASCAnyResource?.self).data } catch let e as ASCError where e.status == 404 { return nil }
    }

    func availability(_ path: String, territories base: String) async throws -> ASCProductAvailability? {
        guard let a = try await optionalOne(path) else { return nil }
        let newTerritories: Bool? = { if case .bool(let b)? = a.attributes?["availableInNewTerritories"] { return b }; return nil }()
        let codes = try await resources.list("\(base)/\(a.id)/availableTerritories", as: ASCRef.self).items.map(\.id)
        return ASCProductAvailability(id: a.id, newTerritories: newTerritories, territories: codes.sorted())
    }

    /// The versions a review submission can take: being prepared, or ready for review.
    public static let submittableVersionStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW"]
}
