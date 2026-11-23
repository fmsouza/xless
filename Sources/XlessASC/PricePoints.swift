import Foundation
import XlessCore

// An app's price points: the prices App Store Connect lets an app take in one territory (GET
// /v1/apps/{id}/appPricePoints), and what one of them becomes in every other territory (GET
// /v3/appPricePoints/{id}/equalizations). A price schedule names price points, never amounts, so a price written by a
// person ("0.99") is resolved to the point with exactly that customer price.

/// One price point: its customer price and proceeds in the territory's currency.
public struct ASCPricePoint: Sendable, Equatable, Encodable {
    public var id: String
    public var territory: String
    public var currency: String?
    /// As App Store Connect writes it ("0.0", "0.99", "150").
    public var customerPrice: String
    public var proceeds: String?

    public init(id: String, territory: String, currency: String?, customerPrice: String, proceeds: String?) {
        self.id = id; self.territory = territory; self.currency = currency; self.customerPrice = customerPrice; self.proceeds = proceeds
    }

    public var price: Decimal? { CustomerPrice.parse(customerPrice) }
}

/// A customer price as people and App Store Connect write it.
public enum CustomerPrice {
    /// `free` → 0; "0.99" → 0.99; anything else (a currency sign, a comma, a minus) → nil.
    public static func parse(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "free" { return 0 }
        guard t.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// `free` for a zero price, else the price as written.
    public static func display(_ text: String) -> String { parse(text) == 0 ? "free" : text }
}

/// Reads of an app's price points.
public struct ASCPricePoints: Sendable {
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    static let query = ASCQuery(fields: [("territories", ["currency"])], include: ["territory"])

    /// Every price point of `app` (its resource ID) in `territory`, cheapest first.
    public func list(app: String, territory: String) async throws -> [ASCPricePoint] {
        try await list(path: "/v1/apps/\(app)/appPricePoints", territory: territory)
    }

    /// Every price point the listing at `path` has in `territory` (an app's, an in-app purchase's
    /// `/v2/inAppPurchases/{id}/pricePoints`, a subscription's `/v1/subscriptions/{id}/pricePoints`), cheapest first.
    public func list(path: String, territory: String) async throws -> [ASCPricePoint] {
        var q = Self.query
        q.filters = [("territory", territory)]
        let listing = try await resources.list(path, query: q, as: ASCAnyResource.self)
        return Self.points(listing, territory: territory)
    }

    /// The price point `id` in every other territory, by territory.
    public func equalizations(of id: String) async throws -> [ASCPricePoint] {
        try await equalizations(path: "/v3/appPricePoints/\(id)/equalizations")
    }

    /// The equalizations at `path` (`/v1/subscriptionPricePoints/{id}/equalizations`), by territory.
    public func equalizations(path: String) async throws -> [ASCPricePoint] {
        let listing = try await resources.list(path, query: Self.query, as: ASCAnyResource.self)
        return Self.points(listing, territory: nil).sorted { $0.territory < $1.territory }
    }

    static func points(_ listing: ASCListing<ASCAnyResource>, territory: String?) -> [ASCPricePoint] {
        let points = listing.items.compactMap { item -> ASCPricePoint? in
            guard let price = item.attributes?["customerPrice"]?.string else { return nil }
            let code = item.relationships?["territory"]?["data"]?["id"]?.string ?? territory ?? ""
            let currency = listing.included.first { $0.type == "territories" && $0.id == code }?.attributes?["currency"]?.string
            return ASCPricePoint(id: item.id, territory: code, currency: currency, customerPrice: price, proceeds: item.attributes?["proceeds"]?.string)
        }
        return points.sorted { ($0.price ?? 0) < ($1.price ?? 0) }
    }

    /// The point whose customer price is exactly `price` (`free` or "0.99"); otherwise an error naming the nearest
    /// points below and above it. `app` is how the fix names the app (its bundle ID or ID); `command`, the command that
    /// lists the points (default `xless apps price-points <app>`), `--territory` appended.
    public static func resolve(_ price: String, in points: [ASCPricePoint], territory: String, app: String, command: String? = nil) throws -> ASCPricePoint {
        let lister = command ?? "xless apps price-points \(app)"
        guard let wanted = CustomerPrice.parse(price) else {
            throw XlessError(.account, "\(price) is not a price: write `free` or the customer price, e.g. 0.99", fix: "use a number with a dot, without a currency sign")
        }
        if let found = points.first(where: { $0.price == wanted }) { return found }
        guard !points.isEmpty else {
            throw XlessError(.account, "App Store Connect lists no price point in \(territory) for this app",
                             fix: "check the territory code (`\(lister) --territory USA`)")
        }
        let sorted = points.sorted { ($0.price ?? 0) < ($1.price ?? 0) }
        let below = sorted.last { ($0.price ?? 0) < wanted }, above = sorted.first { ($0.price ?? 0) > wanted }
        let nearest = [below, above].compactMap { $0?.customerPrice }
        guard !nearest.isEmpty else {
            throw XlessError(.account, "\(price) is not a price point in \(territory)",
                             fix: "`\(lister) --territory \(territory)` lists every price point")
        }
        let named = nearest.count == 2 ? "the nearest are \(nearest[0]) and \(nearest[1])" : "the nearest is \(nearest[0])"
        throw XlessError(.account, "\(price) is not a price point in \(territory); \(named)",
                         fix: "use \(nearest.count == 2 ? "one of them" : "it") (`\(lister) --territory \(territory)` lists every price point)")
    }
}
