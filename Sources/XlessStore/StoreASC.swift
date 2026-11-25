import Foundation
import XlessASC
import XlessCore

// What App Store Connect holds of an app's listing, read through the documented API (the App Store Connect API key):
// the data `store pull` writes and `store push` (#94–#96) compares the manifest with.

public struct StoreVersionAttributes: ASCAttributes, Equatable {
    public var platform: String?
    public var versionString: String?
    public var appStoreState: String?
    public var appVersionState: String?
    public var copyright: String?
    public var releaseType: String?
    public var earliestReleaseDate: String?
    public var createdDate: String?
    public init() {}
}

public struct StoreAppInfoAttributes: ASCAttributes, Equatable {
    public var state: String?
    public var appStoreState: String?
    public init() {}
}

public struct StoreAppInfoLocalizationAttributes: ASCAttributes, Equatable {
    public var locale: String?
    public var name: String?
    public var subtitle: String?
    public var privacyPolicyUrl: String?
    public var privacyChoicesUrl: String?
    public var privacyPolicyText: String?
    public init() {}
}

public struct StoreVersionLocalizationAttributes: ASCAttributes, Equatable {
    public var locale: String?
    public var description: String?
    public var keywords: String?
    public var marketingUrl: String?
    public var promotionalText: String?
    public var supportUrl: String?
    public var whatsNew: String?
    public init() {}
}

/// The review details xless reads. `demoAccountPassword` is deliberately absent, and never asked for.
public struct StoreReviewDetailAttributes: ASCAttributes, Equatable {
    public var contactFirstName: String?
    public var contactLastName: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var demoAccountName: String?
    public var demoAccountRequired: Bool?
    public var notes: String?
    public init() {}

    /// The sparse fieldset sent with every read of review details, so the demo account's password never leaves Apple.
    public static let fields = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName", "demoAccountRequired", "notes"]
}

/// A screenshot or an app preview: what identifies the upload and where Apple serves it.
public struct StoreMediaAttributes: ASCAttributes, Equatable {
    public struct ImageAsset: Codable, Sendable, Equatable {
        public var templateUrl: String?
        public var width: Int?
        public var height: Int?
    }
    public struct DeliveryState: Codable, Sendable, Equatable { public var state: String? }

    public var fileName: String?
    public var fileSize: Int?
    public var sourceFileChecksum: String?
    public var imageAsset: ImageAsset?
    public var videoUrl: String?
    public var previewFrameTimeCode: String?
    public var assetDeliveryState: DeliveryState?
    /// A preview's state (its `assetDeliveryState` is deprecated).
    public var videoDeliveryState: DeliveryState?
    public init() {}

    /// Where the upload is: COMPLETE, FAILED, …
    public var state: String? {
        [videoDeliveryState?.state, assetDeliveryState?.state].contains("FAILED") ? "FAILED" : videoDeliveryState?.state ?? assetDeliveryState?.state
    }
}

/// One screenshot or preview set of a version localization, its items in display order.
public struct StoreRemoteSet: Sendable {
    public var id: String
    public var type: String
    public var items: [ASCKeptResource<StoreMediaAttributes>]
}

public struct StoreEULA: Sendable, Equatable {
    public var text: String
    public var territories: [String]
    /// The agreement's resource ID.
    public var id: String = ""
}

/// One territory's availability (its ID is what `push` updates).
public struct StoreTerritoryAvailability: Sendable, Equatable {
    public var id: String
    public var territory: String
    public var available: Bool
}

public struct StoreAvailability: Sendable, Equatable {
    /// The app availability's resource ID.
    public var id: String
    public var newTerritories: Bool?
    /// Every territory App Store Connect lists for the app, by code.
    public var entries: [StoreTerritoryAvailability]

    /// The territories the app is available in, by code.
    public var available: [String] { entries.filter(\.available).map(\.territory) }
    /// Available in every territory App Store Connect listed.
    public var all: Bool { !entries.isEmpty && entries.allSatisfy(\.available) }
}

/// A manual price of the price schedule: from `start` (nil: since ever) until `end` (nil: until changed).
public struct StorePrice: Sendable, Equatable {
    public var territory: String
    public var start: String?
    public var end: String?
    /// As App Store Connect writes it ("0.0", "0.99").
    public var customerPrice: String
    public var pointID: String

    public init(territory: String, start: String?, end: String?, customerPrice: String, pointID: String) {
        self.territory = territory; self.start = start; self.end = end; self.customerPrice = customerPrice; self.pointID = pointID
    }

    /// In effect on `day` (YYYY-MM-DD).
    public func current(on day: String) -> Bool { (start.map { $0 <= day } ?? true) && (end.map { $0 > day } ?? true) }
}

public struct StorePriceSchedule: Sendable, Equatable {
    public var id: String
    public var baseTerritory: String?
    public var prices: [StorePrice]
    /// Some prices could not be read (no price point in App Store Connect's answer): replacing the schedule would drop them.
    public var incomplete = false

    public init(id: String, baseTerritory: String?, prices: [StorePrice], incomplete: Bool = false) {
        self.id = id; self.baseTerritory = baseTerritory; self.prices = prices; self.incomplete = incomplete
    }

    /// The prices in effect on `day` and those to come (from a later day), each territory's current one first.
    public func live(on day: String) -> [StorePrice] {
        prices.filter { $0.current(on: day) || ($0.start.map { $0 > day } ?? false) }
    }

    /// app.yml's `pricing` for this schedule on `day`.
    public func pricing(today day: String) -> AppYAML.Pricing {
        guard let base = baseTerritory else { return AppYAML.Pricing() }
        var out = AppYAML.Pricing(baseTerritory: base)
        var others: [String: String] = [:]
        var changes: [AppYAML.Pricing.Change] = []
        for price in prices {
            if price.current(on: day) {
                if price.territory == base { out.price = CustomerPrice.display(price.customerPrice) } else { others[price.territory] = CustomerPrice.display(price.customerPrice) }
            } else if let start = price.start, start > day {
                changes.append(AppYAML.Pricing.Change(date: start, territory: price.territory == base ? nil : price.territory,
                                                      price: CustomerPrice.display(price.customerPrice)))
            }
        }
        if !others.isEmpty { out.territories = SortedMap(others) }
        if !changes.isEmpty { out.changes = changes.sorted { ($0.date, $0.territory ?? "") < ($1.date, $1.territory ?? "") } }
        return out
    }

    /// The territory an App Store Connect price point ID names: its IDs are base64 JSON such as {"s":"…","t":"USA","p":"…"}.
    static func territory(ofPoint id: String) -> String? {
        var text = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = object["t"] as? String, t.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
        return t
    }
}

/// An optional part of the listing: its value, absent from App Store Connect (404, or no data), or not readable with
/// this API key's role (403). `pull` writes an absent part's default and keeps the manifest's own value of a forbidden one.
public enum StorePart<T: Sendable>: Sendable {
    case value(T)
    case absent
    case forbidden

    public var value: T? { if case .value(let v) = self { return v }; return nil }
}

/// Reads of the listing's parts.
public struct StoreASC: Sendable {
    public let resources: ASCResources
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, say: @escaping @Sendable (String) -> Void = { _ in }) {
        self.resources = resources; self.say = say
    }

    /// Runs a read of an optional part: absent on 404 (or nil), forbidden on 403 with a note naming the part.
    func optional<T: Sendable>(_ part: String, _ read: () async throws -> T?) async throws -> StorePart<T> {
        do { return try await read().map { .value($0) } ?? .absent } catch let e as ASCError where e.status == 404 { return .absent } catch let e as ASCError where e.status == 403 {
            say("note: this API key may not read the \(part) (HTTP 403); app.yml keeps what it had for it")
            return .forbidden
        }
    }

    func all<A: ASCAttributes>(_ path: String, query: ASCQuery = ASCQuery(), as: A.Type) async throws -> [ASCKeptResource<A>] {
        try await resources.list(path, query: query, as: ASCKeptResource<A>.self).items
    }

    /// The single resource at `path`; nil when its document's `data` is null.
    func one(_ path: String, query: ASCQuery = ASCQuery()) async throws -> ASCSingle<ASCAnyResource?> {
        try await resources.get(path, query: query, as: ASCAnyResource?.self)
    }

    public func versions(of appID: String) async throws -> [ASCKeptResource<StoreVersionAttributes>] {
        try await ASCApps(resources: resources).versions(of: appID, as: StoreVersionAttributes.self)
    }

    public static let categoryRelationships = ["primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo",
                                               "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo"]

    /// The app infos, with their category relationships' linkage.
    public func appInfos(of appID: String) async throws -> [ASCKeptResource<StoreAppInfoAttributes>] {
        try await ASCApps(resources: resources).infos(of: appID, include: Self.categoryRelationships, as: StoreAppInfoAttributes.self)
    }

    public func appInfoLocalizations(of infoID: String) async throws -> [ASCKeptResource<StoreAppInfoLocalizationAttributes>] {
        try await all("/v1/appInfos/\(infoID)/appInfoLocalizations", as: StoreAppInfoLocalizationAttributes.self)
    }

    /// The age rating declaration's answers, Apple's attribute names as they are (null answers left out).
    public func ageRating(of infoID: String) async throws -> StorePart<[String: JSONValue]> {
        switch try await ageRatingDeclaration(of: infoID) {
        case .value(let d): return d.attributes.map { .value($0) } ?? .absent
        case .absent: return .absent
        case .forbidden: return .forbidden
        }
    }

    /// The age rating declaration itself (its ID is what `push` updates).
    public func ageRatingDeclaration(of infoID: String) async throws -> StorePart<ASCAnyResource> {
        try await optional("age rating declaration") { try await one("/v1/appInfos/\(infoID)/ageRatingDeclaration").data }
    }

    public func versionLocalizations(of versionID: String) async throws -> [ASCKeptResource<StoreVersionLocalizationAttributes>] {
        try await all("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", as: StoreVersionLocalizationAttributes.self)
    }

    /// Review details without the demo account's password (a sparse fieldset that leaves it out).
    public func reviewDetail(of versionID: String) async throws -> StorePart<StoreReviewDetailAttributes> {
        switch try await reviewDetailResource(of: versionID) {
        case .value(let d): return .value(d.attributes)
        case .absent: return .absent
        case .forbidden: return .forbidden
        }
    }

    /// The review details with their ID, read the same way (never the password).
    public func reviewDetailResource(of versionID: String) async throws -> StorePart<ASCKeptResource<StoreReviewDetailAttributes>> {
        try await optional("App Review details") {
            let query = ASCQuery(fields: [("appStoreReviewDetails", StoreReviewDetailAttributes.fields)])
            return try await one("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail", query: query).data
                .map { ASCKeptResource<StoreReviewDetailAttributes>(resource: $0) }
        }
    }

    /// Whether the version has a phased release (absent: it has none).
    public func phasedRelease(of versionID: String) async throws -> StorePart<Bool> {
        switch try await phasedReleaseResource(of: versionID) {
        case .value: return .value(true)
        case .absent: return .absent
        case .forbidden: return .forbidden
        }
    }

    /// The version's phased release (its ID and state).
    public func phasedReleaseResource(of versionID: String) async throws -> StorePart<ASCAnyResource> {
        try await optional("phased release") { try await ASCRelease(resources: resources).phasedRelease(of: versionID)?.resource }
    }

    /// The categories App Store Connect offers for `platform`: each top-level category ID → its subcategory IDs.
    public func categories(platform: String) async throws -> [String: Set<String>] {
        let query = ASCQuery(filters: [("platforms", platform)], include: ["subcategories"],
                             extra: [("exists[parent]", "false"), ("limit[subcategories]", "50")])
        var out: [String: Set<String>] = [:]
        for c in try await resources.list("/v1/appCategories", query: query, as: ASCAnyResource.self).items {
            var subs: Set<String> = []
            if case .array(let items)? = c.relationships?["subcategories"]?["data"] {
                for item in items { if let id = item["id"]?.string { subs.insert(id) } }
            }
            out[c.id] = subs
        }
        return out
    }

    public func screenshotSets(of localizationID: String) async throws -> [StoreRemoteSet] {
        var sets: [StoreRemoteSet] = []
        for set in try await resources.list("/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets", as: ASCAnyResource.self).items {
            let items = try await all("/v1/appScreenshotSets/\(set.id)/appScreenshots", as: StoreMediaAttributes.self)
            sets.append(StoreRemoteSet(id: set.id, type: set.attributes?["screenshotDisplayType"]?.string ?? "UNKNOWN", items: items))
        }
        return sets
    }

    public func previewSets(of localizationID: String) async throws -> [StoreRemoteSet] {
        var sets: [StoreRemoteSet] = []
        for set in try await resources.list("/v1/appStoreVersionLocalizations/\(localizationID)/appPreviewSets", as: ASCAnyResource.self).items {
            let items = try await all("/v1/appPreviewSets/\(set.id)/appPreviews", as: StoreMediaAttributes.self)
            sets.append(StoreRemoteSet(id: set.id, type: set.attributes?["previewType"]?.string ?? "UNKNOWN", items: items))
        }
        return sets
    }

    /// Every territory App Store Connect knows (three-letter codes).
    public func territories() async throws -> StorePart<[String]> {
        try await optional("territories") { try await resources.list("/v1/territories", as: ASCRef.self).items.map(\.id) }
    }

    /// The custom licence agreement (text and territories); nil for Apple's standard one.
    public func eula(of appID: String) async throws -> StorePart<StoreEULA> {
        try await optional("licence agreement") {
            guard let eula = try await one("/v1/apps/\(appID)/endUserLicenseAgreement").data else { return nil }
            let territories = try await resources.list("/v1/endUserLicenseAgreements/\(eula.id)/territories", as: ASCRef.self).items.map(\.id)
            return StoreEULA(text: eula.attributes?["agreementText"]?.string ?? "", territories: territories, id: eula.id)
        }
    }

    /// The export compliance answers of the app's most recent encryption declaration.
    public func encryption(of appID: String) async throws -> StorePart<[String: JSONValue]> {
        switch try await encryptionDeclaration(of: appID) {
        case .value(let d): return d.attributes.map { .value($0) } ?? .value([:])
        case .absent: return .absent
        case .forbidden: return .forbidden
        }
    }

    /// The app's most recent encryption declaration.
    public func encryptionDeclaration(of appID: String) async throws -> StorePart<ASCAnyResource> {
        try await optional("encryption declarations") {
            try await ASCBuilds(resources: resources).declarations(appID: appID).first?.resource
        }
    }

    /// The document uploaded for an encryption declaration; nil when it has none.
    public func encryptionDocument(of declarationID: String) async throws -> ASCKeptResource<StoreMediaAttributes>? {
        do {
            return try await resources.get("/v1/appEncryptionDeclarations/\(declarationID)/appEncryptionDeclarationDocument", as: ASCAnyResource?.self).data
                .map { ASCKeptResource<StoreMediaAttributes>(resource: $0) }
        } catch let e as ASCError where e.status == 404 { return nil }
    }

    /// The files attached for App Review.
    public func reviewAttachments(of detailID: String) async throws -> [ASCKeptResource<StoreMediaAttributes>] {
        try await all("/v1/appStoreReviewDetails/\(detailID)/appStoreReviewAttachments", as: StoreMediaAttributes.self)
    }

    /// Accessibility declarations: device family → state and answers.
    public func accessibility(of appID: String) async throws -> StorePart<[ASCAnyResource]> {
        try await optional("accessibility declarations") {
            try await resources.list("/v1/apps/\(appID)/accessibilityDeclarations", as: ASCAnyResource.self).items
        }
    }

    /// The app's price schedule: its base territory and every manual price (past ones included).
    public func priceSchedule(of appID: String) async throws -> StorePart<StorePriceSchedule> {
        try await optional("price schedule") {
            try await schedule("/v1/apps/\(appID)/appPriceSchedule", manualPrices: { "/v1/appPriceSchedules/\($0)/manualPrices" },
                               point: "appPricePoint", pointType: "appPricePoints")
        }
    }

    /// An in-app purchase's price schedule, read like the app's.
    public func iapPriceSchedule(of iapID: String) async throws -> StorePart<StorePriceSchedule> {
        try await optional("in-app purchase price schedule") {
            try await schedule("/v2/inAppPurchases/\(iapID)/iapPriceSchedule", manualPrices: { "/v1/inAppPurchasePriceSchedules/\($0)/manualPrices" },
                               point: "inAppPurchasePricePoint", pointType: "inAppPurchasePricePoints")
        }
    }

    /// The schedule at `path`: its base territory and every manual price (`point`: the price's relationship to its
    /// price point, of type `pointType`).
    func schedule(_ path: String, manualPrices: (String) -> String, point pointRelationship: String, pointType: String) async throws -> StorePriceSchedule? {
        guard let schedule = try await one(path, query: ASCQuery(include: ["baseTerritory"])).data else { return nil }
        let base = schedule.relationships?["baseTerritory"]?["data"]?["id"]?.string
        guard let base else { return StorePriceSchedule(id: schedule.id, baseTerritory: nil, prices: []) }
        let listing = try await resources.list(manualPrices(schedule.id),
                                               query: ASCQuery(include: [pointRelationship, "territory"]), as: ASCAnyResource.self)
        var prices: [StorePrice] = []
        var unread = 0
        for item in listing.items {
            guard let point = item.relationships?[pointRelationship]?["data"]?["id"]?.string,
                  let included = listing.included.first(where: { $0.type == pointType && $0.id == point }),
                  let customer = included.attributes?["customerPrice"]?.string else { unread += 1; continue }
            let territory = item.relationships?["territory"]?["data"]?["id"]?.string
                ?? included.relationships?["territory"]?["data"]?["id"]?.string
                ?? StorePriceSchedule.territory(ofPoint: point) ?? base
            prices.append(StorePrice(territory: territory, start: item.attributes?["startDate"]?.string, end: item.attributes?["endDate"]?.string,
                                     customerPrice: customer, pointID: point))
        }
        if unread > 0 {
            say("note: \(unread) price\(unread == 1 ? "" : "s") of the price schedule came without \(unread == 1 ? "its" : "their") price point; they are left out")
        }
        return StorePriceSchedule(id: schedule.id, baseTerritory: base, prices: prices, incomplete: unread > 0)
    }

    /// The price schedule as app.yml writes it: base territory, its current price, the other territories' current
    /// manual prices and the changes to come (past prices are history and left out).
    public func pricing(of appID: String, today: Date = Date()) async throws -> StorePart<AppYAML.Pricing> {
        switch try await priceSchedule(of: appID) {
        case .value(let schedule): return .value(schedule.pricing(today: Self.day(today)))
        case .absent: return .absent
        case .forbidden: return .forbidden
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Availability: whether new territories are added automatically, and each territory's availability.
    public func availability(of appID: String) async throws -> StorePart<StoreAvailability> {
        try await optional("availability") {
            guard let availability = try await one("/v1/apps/\(appID)/appAvailabilityV2").data else { return nil }
            let newTerritories: Bool? = { if case .bool(let b)? = availability.attributes?["availableInNewTerritories"] { return b }; return nil }()
            let listing = try await resources.list("/v2/appAvailabilities/\(availability.id)/territoryAvailabilities",
                                                   query: ASCQuery(include: ["territory"]), as: ASCAnyResource.self)
            let entries = listing.items.compactMap { item -> StoreTerritoryAvailability? in
                guard let territory = item.relationships?["territory"]?["data"]?["id"]?.string else { return nil }
                let available: Bool = { if case .bool(true)? = item.attributes?["available"] { return true }; return false }()
                return StoreTerritoryAvailability(id: item.id, territory: territory, available: available)
            }
            return StoreAvailability(id: availability.id, newTerritories: newTerritories, entries: entries.sorted { $0.territory < $1.territory })
        }
    }
}
