import Foundation
import XlessCore

// The App Store listing as files (docs/appstore-manifest.md):
//
//   appstore/
//     app.yml                  app-level values (AppYAML)
//     eula.txt                 a custom licence agreement, when app.yml says so
//     media.lock               which App Store Connect asset each local screenshot/preview/attachment is (MediaLock)
//     review/                  App Review attachments, when app.yml's review.attachments names them
//     compliance/              the export compliance document, when app.yml's encryptionDocument names it
//     iap/, subscriptions/     in-app purchases and auto-renewable subscriptions (Products.swift)
//     <locale>/                text files (LocaleListing), screenshots/<display type>/, previews/<preview type>/
//
// Values are App Store Connect's own spellings (IOS, AFTER_APPROVAL, APP_IPHONE_67…), so nothing is translated between
// the files and the API. `store pull` writes the directory, `store validate` checks it, `store push` sends it
// (App Privacy, `privacy:`, through the Apple ID web session).

/// The whole manifest: `app.yml` and every locale directory.
public struct StoreManifest: Sendable, Equatable {
    public var app: AppYAML
    /// Locale (as the directory is spelled) → its listing.
    public var locales: [String: LocaleListing]
    /// Top-level `app.yml` keys xless does not model, kept as YAML text in file order; `pull` writes them back unchanged.
    public var extras: [(key: String, yaml: String)]
    /// In-app purchases and subscriptions (`iap/`, `subscriptions/`).
    public var products: StoreProducts

    public init(app: AppYAML = AppYAML(), locales: [String: LocaleListing] = [:], extras: [(key: String, yaml: String)] = [],
                products: StoreProducts = StoreProducts()) {
        self.app = app; self.locales = locales; self.extras = extras; self.products = products
    }

    public static func == (a: StoreManifest, b: StoreManifest) -> Bool {
        a.app == b.app && a.locales == b.locales && a.extras.map(\.key) == b.extras.map(\.key) && a.extras.map(\.yaml) == b.extras.map(\.yaml)
            && a.products == b.products
    }

    /// A file `app.yml` names (e.g. `eula.file`), inside the manifest directory `dir`; nil when the name leads outside it
    /// (an absolute path, `..`, or a symbolic link out of it).
    public static func resolve(_ relative: String, in dir: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let url = dir.appendingPathComponent(relative).standardizedFileURL
        let base = dir.resolvingSymlinksInPath().standardizedFileURL.path
        // A missing file's own path cannot be resolved: resolve its directory's.
        let resolved = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        let target = resolved.standardizedFileURL.path
        return target.hasPrefix(base + "/") ? url : nil
    }

    /// Locales in a stable order: the primary locale first, then by name.
    public var orderedLocales: [String] {
        locales.keys.sorted { a, b in
            if a == app.primaryLocale { return b != app.primaryLocale }
            if b == app.primaryLocale { return false }
            return a < b
        }
    }
}

/// A scalar of a generic `app.yml` map (`ageRating`, `encryption`): Apple's attribute values as they are.
public enum StoreScalar: Codable, Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): "\(b)"
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .string(let s): s
        }
    }
}

/// `all`, or a list of territory codes (USA, CAN, …).
public enum StoreTerritories: Codable, Sendable, Equatable {
    case all
    case only([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([String].self) { self = .only(list); return }
        let text = try c.decode(String.self)
        guard text == "all" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "use `all` or a list of territory codes, e.g. [USA, CAN]")
        }
        self = .all
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all: try c.encode("all")
        case .only(let list): try c.encode(list)
        }
    }
}

/// `app.yml`. Every key is optional when read; `validate` says which ones a submission needs.
public struct AppYAML: Codable, Sendable, Equatable {
    public struct Categories: Codable, Sendable, Equatable {
        public var primary: String?
        public var primarySubcategories: [String]?
        public var secondary: String?
        public var secondarySubcategories: [String]?
        public init(primary: String? = nil, primarySubcategories: [String]? = nil, secondary: String? = nil, secondarySubcategories: [String]? = nil) {
            self.primary = primary; self.primarySubcategories = primarySubcategories
            self.secondary = secondary; self.secondarySubcategories = secondarySubcategories
        }
    }

    public struct Release: Codable, Sendable, Equatable {
        /// MANUAL, AFTER_APPROVAL or SCHEDULED.
        public var type: String?
        /// ISO 8601, for SCHEDULED.
        public var earliestDate: String?
        public var phased: Bool?
        public init(type: String? = nil, earliestDate: String? = nil, phased: Bool? = nil) {
            self.type = type; self.earliestDate = earliestDate; self.phased = phased
        }
    }

    public struct Contact: Codable, Sendable, Equatable {
        public var firstName: String?
        public var lastName: String?
        public var phone: String?
        public var email: String?
        public init(firstName: String? = nil, lastName: String? = nil, phone: String? = nil, email: String? = nil) {
            self.firstName = firstName; self.lastName = lastName; self.phone = phone; self.email = email
        }
    }

    /// The sign-in App Review uses. The password is never in the manifest: `passwordSecret` names the secret-store entry
    /// (or environment variable) that holds it, which `store push` resolves.
    public struct DemoAccount: Codable, Sendable, Equatable {
        public var required: Bool?
        public var name: String?
        public var passwordSecret: String?
        public init(required: Bool? = nil, name: String? = nil, passwordSecret: String? = nil) {
            self.required = required; self.name = name; self.passwordSecret = passwordSecret
        }
    }

    public struct Review: Codable, Sendable, Equatable {
        public var contact: Contact?
        public var demoAccount: DemoAccount?
        public var notes: String?
        /// Files for App Review (a walkthrough video, a document), relative to the manifest directory (`review/…`).
        public var attachments: [String]?
        public init(contact: Contact? = nil, demoAccount: DemoAccount? = nil, notes: String? = nil, attachments: [String]? = nil) {
            self.contact = contact; self.demoAccount = demoAccount; self.notes = notes; self.attachments = attachments
        }
    }

    /// `standard` (Apple's licence agreement), or a custom one: its text file and the territories it applies to.
    public enum EULA: Codable, Sendable, Equatable {
        case standard
        case custom(file: String, territories: StoreTerritories?)

        enum Keys: String, CodingKey { case file, territories }

        public init(from decoder: Decoder) throws {
            if let c = try? decoder.singleValueContainer(), let text = try? c.decode(String.self) {
                guard text == "standard" else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "use `standard` or { file: eula.txt, territories: … }")
                }
                self = .standard
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            self = .custom(file: try c.decode(String.self, forKey: .file), territories: try c.decodeIfPresent(StoreTerritories.self, forKey: .territories))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .standard:
                var c = encoder.singleValueContainer()
                try c.encode("standard")
            case .custom(let file, let territories):
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(file, forKey: .file)
                try c.encodeIfPresent(territories, forKey: .territories)
            }
        }
    }

    /// The price schedule. Absent keys are not managed: `store push` keeps what App Store Connect has for them.
    public struct Pricing: Codable, Sendable, Equatable {
        /// A scheduled price change: from `date` (YYYY-MM-DD) on, `territory` (default: the base territory) costs `price`.
        public struct Change: Codable, Sendable, Equatable {
            public var date: String
            public var territory: String?
            public var price: String
            public init(date: String, territory: String? = nil, price: String) { self.date = date; self.territory = territory; self.price = price }
        }

        public var baseTerritory: String?
        /// `free`, or the customer price in the base territory's currency ("0.99").
        public var price: String?
        /// Manual prices outside the base territory (territory → customer price in its currency); the others follow
        /// the base price.
        public var territories: SortedMap<String>?
        /// Scheduled changes, by date.
        public var changes: [Change]?

        public init(baseTerritory: String? = nil, price: String? = nil, territories: SortedMap<String>? = nil, changes: [Change]? = nil) {
            self.baseTerritory = baseTerritory; self.price = price; self.territories = territories; self.changes = changes
        }
    }

    /// The App Privacy answers (what data the app collects, what for, linked to the user or not, used to track or not).
    /// App Store Connect keeps them per app, outside its API: `xless store privacy pull|push` and `store push` read and
    /// send them through the Apple ID web session.
    public struct Privacy: Codable, Sendable, Equatable {
        /// One kind of data the app collects.
        public struct DataUsage: Codable, Sendable, Equatable {
            /// Apple's category ID: EMAIL_ADDRESS, PRECISE_LOCATION, CRASH_DATA…
            public var category: String
            /// Apple's purpose IDs: APP_FUNCTIONALITY, ANALYTICS…
            public var purposes: [String]?
            /// The data is linked to the user's identity.
            public var linkedToYou: Bool?
            /// The data is used to track the user.
            public var tracking: Bool?

            public init(category: String, purposes: [String]? = nil, linkedToYou: Bool? = nil, tracking: Bool? = nil) {
                self.category = category; self.purposes = purposes; self.linkedToYou = linkedToYou; self.tracking = tracking
            }
        }

        /// false: "Data Not Collected".
        public var collectsData: Bool?
        public var data: [DataUsage]?

        public init(collectsData: Bool? = nil, data: [DataUsage]? = nil) { self.collectsData = collectsData; self.data = data }
    }

    public struct Availability: Codable, Sendable, Equatable {
        public var territories: StoreTerritories?
        public var newTerritories: Bool?
        public init(territories: StoreTerritories? = nil, newTerritories: Bool? = nil) {
            self.territories = territories; self.newTerritories = newTerritories
        }
    }

    public var bundleID: String?
    /// Informational: App Store Connect never changes a SKU.
    public var sku: String?
    /// IOS, MAC_OS, TV_OS or VISION_OS: the platform whose App Store version this manifest describes.
    public var platform: String?
    public var primaryLocale: String?
    public var version: String?
    public var copyright: String?
    public var contentRights: String?
    public var categories: Categories?
    public var ageRating: SortedMap<StoreScalar>?
    public var release: Release?
    public var review: Review?
    public var encryption: SortedMap<StoreScalar>?
    /// The export compliance document App Store Connect may ask for (`compliance/…`), sent with the encryption declaration.
    public var encryptionDocument: String?
    public var accessibility: SortedMap<SortedMap<Bool>>?
    public var eula: EULA?
    public var pricing: Pricing?
    public var availability: Availability?
    public var privacy: Privacy?
    /// App preview (path relative to the manifest directory) → the frame shown as its poster, `HH:MM:SS:FF`.
    public var previewFrames: SortedMap<String>?

    public init() {}

    /// The keys `AppYAML` models, in the order `pull` writes them.
    public static let keys = ["bundleID", "sku", "platform", "primaryLocale", "version", "copyright", "contentRights", "categories",
                              "ageRating", "release", "review", "encryption", "encryptionDocument", "accessibility", "eula", "pricing",
                              "availability", "privacy", "previewFrames"]
}

/// A string-keyed map written with its keys sorted, so a pulled `app.yml` is stable from one pull to the next.
public struct SortedMap<V: Codable & Sendable & Equatable>: Codable, Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public var values: [String: V]

    public init(_ values: [String: V]) { self.values = values }
    public init(dictionaryLiteral elements: (String, V)...) { values = Dictionary(elements, uniquingKeysWith: { $1 }) }

    struct Name: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws { values = try decoder.singleValueContainer().decode([String: V].self) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Name.self)
        for key in values.keys.sorted() { try c.encode(values[key]!, forKey: Name(stringValue: key)) }
    }

    public subscript(key: String) -> V? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }
}

/// One locale's text (one file per field) and media.
public struct LocaleListing: Sendable, Equatable {
    public var name: String?
    public var subtitle: String?
    public var privacyURL: String?
    public var privacyChoicesURL: String?
    /// The privacy policy as text (tvOS apps, which cannot open a URL).
    public var privacyPolicyText: String?
    public var description: String?
    public var keywords: String?
    public var promotionalText: String?
    public var whatsNew: String?
    public var supportURL: String?
    public var marketingURL: String?
    public var screenshots: [MediaSet]
    public var previews: [MediaSet]

    public init(name: String? = nil, subtitle: String? = nil, privacyURL: String? = nil, privacyChoicesURL: String? = nil,
                privacyPolicyText: String? = nil, description: String? = nil, keywords: String? = nil, promotionalText: String? = nil, whatsNew: String? = nil,
                supportURL: String? = nil, marketingURL: String? = nil, screenshots: [MediaSet] = [], previews: [MediaSet] = []) {
        self.name = name; self.subtitle = subtitle; self.privacyURL = privacyURL; self.privacyChoicesURL = privacyChoicesURL
        self.privacyPolicyText = privacyPolicyText
        self.description = description; self.keywords = keywords; self.promotionalText = promotionalText; self.whatsNew = whatsNew
        self.supportURL = supportURL; self.marketingURL = marketingURL; self.screenshots = screenshots; self.previews = previews
    }

    /// The text fields: file name → key path. App info fields first, then the version's.
    public static var textFields: [(file: String, field: WritableKeyPath<LocaleListing, String?>)] { [
        ("name.txt", \.name), ("subtitle.txt", \.subtitle), ("privacy_url.txt", \.privacyURL), ("privacy_choices_url.txt", \.privacyChoicesURL),
        ("privacy_policy_text.txt", \.privacyPolicyText),
        ("description.txt", \.description), ("keywords.txt", \.keywords), ("promotional_text.txt", \.promotionalText),
        ("whats_new.txt", \.whatsNew), ("support_url.txt", \.supportURL), ("marketing_url.txt", \.marketingURL),
    ] }

    /// Files holding a URL (surrounding whitespace is not part of the value).
    public static let urlFiles: Set<String> = ["privacy_url.txt", "privacy_choices_url.txt", "support_url.txt", "marketing_url.txt"]

    public var hasText: Bool { Self.textFields.contains { self[keyPath: $0.field] != nil } }
}

/// A screenshot set or a preview set: its type (the directory name) and its files in display order, as paths relative
/// to the manifest directory.
public struct MediaSet: Sendable, Equatable {
    public var type: String
    public var files: [String]
    public init(type: String, files: [String]) { self.type = type; self.files = files }
}

/// Display order of a set's files: by name, a leading number compared as a number (`2-a.png` before `10-b.png`).
public enum MediaOrder {
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let (na, nb) = (leadingNumber(a), leadingNumber(b))
            if let na, let nb, na != nb { return na < nb }
            return a < b
        }
    }

    static func leadingNumber(_ name: String) -> Int? { Int(name.prefix { $0.isASCII && $0.isNumber }) }
}

/// Something `validate` (or `pull`) found, attached to a file of the manifest.
public struct StoreIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    /// Relative to the manifest's parent directory, starting with the manifest directory's name (`appstore/en-US/name.txt`).
    public var path: String
    public var message: String
    public var fix: String
    public var severity: Severity

    public init(_ path: String, _ message: String, fix: String, severity: Severity = .error) {
        self.path = path; self.message = message; self.fix = fix; self.severity = severity
    }

    /// `[account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten …` (a warning reads `warning: …`).
    public var description: String {
        let text = "\(path): \(message) — \(fix)"
        return severity == .error ? "[\(Stage.account.rawValue)] \(text)" : "warning: \(text)"
    }
}
