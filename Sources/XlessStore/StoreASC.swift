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
    public var assetDeliveryState: DeliveryState?
    public init() {}
}

/// One screenshot or preview set of a version localization, its items in display order.
public struct StoreRemoteSet: Sendable {
    public var id: String
    public var type: String
    public var items: [ASCKeptResource<StoreMediaAttributes>]
}

/// Reads of the listing's parts. A part App Store Connect does not have (404) is nil; so is one the key's role may not
/// read (403), with a note through `say`, since `pull` can do without it.
public struct StoreASC: Sendable {
    public let resources: ASCResources
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, say: @escaping @Sendable (String) -> Void = { _ in }) {
        self.resources = resources; self.say = say
    }

    /// Runs a read of an optional part: nil on 404, and on 403 with a note naming the part.
    func optional<T>(_ part: String, _ read: () async throws -> T?) async throws -> T? {
        do { return try await read() } catch let e as ASCError where e.status == 404 { return nil } catch let e as ASCError where e.status == 403 {
            say("note: this API key may not read the \(part) (HTTP 403); it is left out")
            return nil
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
        try await all("/v1/apps/\(appID)/appStoreVersions", as: StoreVersionAttributes.self)
    }

    public static let categoryRelationships = ["primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo",
                                               "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo"]

    /// The app infos, with their category relationships' linkage.
    public func appInfos(of appID: String) async throws -> [ASCKeptResource<StoreAppInfoAttributes>] {
        try await all("/v1/apps/\(appID)/appInfos", query: ASCQuery(include: Self.categoryRelationships), as: StoreAppInfoAttributes.self)
    }

    public func appInfoLocalizations(of infoID: String) async throws -> [ASCKeptResource<StoreAppInfoLocalizationAttributes>] {
        try await all("/v1/appInfos/\(infoID)/appInfoLocalizations", as: StoreAppInfoLocalizationAttributes.self)
    }

    /// The age rating declaration's answers, Apple's attribute names as they are (null answers left out).
    public func ageRating(of infoID: String) async throws -> [String: JSONValue]? {
        try await optional("age rating declaration") {
            try await one("/v1/appInfos/\(infoID)/ageRatingDeclaration").data?.attributes
        }
    }

    public func versionLocalizations(of versionID: String) async throws -> [ASCKeptResource<StoreVersionLocalizationAttributes>] {
        try await all("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", as: StoreVersionLocalizationAttributes.self)
    }

    /// Review details without the demo account's password (a sparse fieldset that leaves it out).
    public func reviewDetail(of versionID: String) async throws -> StoreReviewDetailAttributes? {
        try await optional("App Review details") {
            let query = ASCQuery(fields: [("appStoreReviewDetails", StoreReviewDetailAttributes.fields)])
            return try await one("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail", query: query).data
                .map { ASCKeptResource<StoreReviewDetailAttributes>(resource: $0).attributes }
        }
    }

    public func phasedRelease(of versionID: String) async throws -> Bool {
        try await optional("phased release") {
            try await one("/v1/appStoreVersions/\(versionID)/appStoreVersionPhasedRelease").data != nil
        } ?? false
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
    public func territories() async throws -> [String] {
        try await resources.list("/v1/territories", as: ASCRef.self).items.map(\.id)
    }

    /// The custom licence agreement (text and territories); nil for Apple's standard one.
    public func eula(of appID: String) async throws -> (text: String, territories: [String])? {
        try await optional("licence agreement") {
            guard let eula = try await one("/v1/apps/\(appID)/endUserLicenseAgreement").data else { return nil }
            let territories = try await resources.list("/v1/endUserLicenseAgreements/\(eula.id)/territories", as: ASCRef.self).items.map(\.id)
            return (eula.attributes?["agreementText"]?.string ?? "", territories)
        }
    }

    /// The export compliance answers of the app's most recent encryption declaration.
    public func encryption(of appID: String) async throws -> [String: JSONValue]? {
        try await optional("encryption declarations") {
            let declarations = try await resources.list("/v1/appEncryptionDeclarations", query: ASCQuery(filters: [("app", appID)]), as: ASCAnyResource.self).items
            let latest = declarations.max { ($0.attributes?["createdDate"]?.string ?? "") < ($1.attributes?["createdDate"]?.string ?? "") }
            return latest?.attributes
        }
    }

    /// Accessibility declarations: device family → state and answers.
    public func accessibility(of appID: String) async throws -> [ASCAnyResource]? {
        try await optional("accessibility declarations") {
            try await resources.list("/v1/apps/\(appID)/accessibilityDeclarations", as: ASCAnyResource.self).items
        }
    }

    /// The price schedule's base territory and the current manual price there (customer price, as Apple writes it).
    public func pricing(of appID: String, today: Date = Date()) async throws -> (baseTerritory: String?, price: String?)? {
        try await optional("price schedule") {
            guard let schedule = try await one("/v1/apps/\(appID)/appPriceSchedule", query: ASCQuery(include: ["baseTerritory"])).data else { return nil }
            let base = schedule.relationships?["baseTerritory"]?["data"]?["id"]?.string
            guard let base else { return (nil, nil) }
            let listing = try await resources.list("/v1/appPriceSchedules/\(schedule.id)/manualPrices",
                                                   query: ASCQuery(filters: [("territory", base)], include: ["appPricePoint"]), as: ASCAnyResource.self)
            let day = Self.day(today)
            let current = listing.items.first { price in
                let start = price.attributes?["startDate"]?.string, end = price.attributes?["endDate"]?.string
                return (start.map { $0 <= day } ?? true) && (end.map { $0 > day } ?? true)
            }
            guard let point = current?.relationships?["appPricePoint"]?["data"]?["id"]?.string,
                  let customer = listing.included.first(where: { $0.id == point })?.attributes?["customerPrice"]?.string else { return (base, nil) }
            return (base, Double(customer) == 0 ? "free" : customer)
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Availability: whether new territories are added automatically, and the territories the app is available in.
    public func availability(of appID: String) async throws -> (newTerritories: Bool?, available: [String], all: Bool)? {
        try await optional("availability") {
            guard let availability = try await one("/v1/apps/\(appID)/appAvailabilityV2").data else { return nil }
            let newTerritories: Bool? = { if case .bool(let b)? = availability.attributes?["availableInNewTerritories"] { return b }; return nil }()
            let listing = try await resources.list("/v2/appAvailabilities/\(availability.id)/territoryAvailabilities",
                                                   query: ASCQuery(include: ["territory"]), as: ASCAnyResource.self)
            var available: [String] = []
            for item in listing.items {
                guard case .bool(true)? = item.attributes?["available"],
                      let territory = item.relationships?["territory"]?["data"]?["id"]?.string else { continue }
                available.append(territory)
            }
            return (newTerritories, available.sorted(), !listing.items.isEmpty && available.count == listing.items.count)
        }
    }
}
