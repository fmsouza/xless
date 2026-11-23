import Foundation
import XlessASC
import XlessCore
import Yams

// In-app purchases and auto-renewable subscriptions in the manifest (docs/appstore-manifest.md#in-app-purchases-and-subscriptions):
//
//   appstore/
//     iap/<productId>.yml                     one in-app purchase (IAPYAML)
//     iap/<productId>.png                     its App Review screenshot, when the file says so
//     subscriptions/<group>/group.yml         a subscription group (SubscriptionGroupYAML)
//     subscriptions/<group>/<productId>.yml   one subscription of the group (SubscriptionYAML)
//
// Values are App Store Connect's spellings; an absent key is not managed (`store push` keeps what App Store Connect has).

/// A product's text in one locale: the name and description customers see.
public struct ProductText: Codable, Sendable, Equatable {
    public var name: String?
    public var description: String?
    public init(name: String? = nil, description: String? = nil) { self.name = name; self.description = description }
}

/// A subscription group's text in one locale: its name and the app name shown with it.
public struct GroupText: Codable, Sendable, Equatable {
    public var name: String?
    public var customAppName: String?
    public init(name: String? = nil, customAppName: String? = nil) { self.name = name; self.customAppName = customAppName }
}

/// `iap/<productId>.yml`: a consumable, non-consumable or non-renewing subscription.
public struct IAPYAML: Codable, Sendable, Equatable {
    /// CONSUMABLE, NON_CONSUMABLE or NON_RENEWING_SUBSCRIPTION; fixed once the product exists.
    public var type: String?
    /// The name only App Store Connect shows (API `name`).
    public var referenceName: String?
    public var familySharable: Bool?
    public var reviewNote: String?
    /// The App Review screenshot, relative to the manifest directory (`iap/<productId>.png`).
    public var reviewScreenshot: String?
    /// The price schedule, as app.yml's `pricing` (base territory, price, manual prices, scheduled changes).
    public var pricing: AppYAML.Pricing?
    public var availability: AppYAML.Availability?
    public var localizations: SortedMap<ProductText>?

    public init(type: String? = nil, referenceName: String? = nil, familySharable: Bool? = nil, reviewNote: String? = nil, reviewScreenshot: String? = nil,
                pricing: AppYAML.Pricing? = nil, availability: AppYAML.Availability? = nil, localizations: SortedMap<ProductText>? = nil) {
        self.type = type; self.referenceName = referenceName; self.familySharable = familySharable; self.reviewNote = reviewNote
        self.reviewScreenshot = reviewScreenshot; self.pricing = pricing; self.availability = availability; self.localizations = localizations
    }

    public static let keys = ["type", "referenceName", "familySharable", "reviewNote", "reviewScreenshot", "pricing", "availability", "localizations"]
}

/// `subscriptions/<group>/group.yml`.
public struct SubscriptionGroupYAML: Codable, Sendable, Equatable {
    /// The group's name in App Store Connect: what ties the directory to the group.
    public var referenceName: String?
    public var localizations: SortedMap<GroupText>?

    public init(referenceName: String? = nil, localizations: SortedMap<GroupText>? = nil) { self.referenceName = referenceName; self.localizations = localizations }

    public static let keys = ["referenceName", "localizations"]
}

/// `subscriptions/<group>/<productId>.yml`: an auto-renewable subscription.
public struct SubscriptionYAML: Codable, Sendable, Equatable {
    /// Prices per territory: the base territory's price, and what it becomes elsewhere unless `territories` says.
    public struct Pricing: Codable, Sendable, Equatable {
        public var baseTerritory: String?
        public var price: String?
        /// Prices outside the base territory (territory → customer price in its currency); the others are Apple's
        /// equivalent of the base price.
        public var territories: SortedMap<String>?
        /// Existing subscribers keep the price they pay when it changes (default true).
        public var preserveCurrentPrice: Bool?

        public init(baseTerritory: String? = nil, price: String? = nil, territories: SortedMap<String>? = nil, preserveCurrentPrice: Bool? = nil) {
            self.baseTerritory = baseTerritory; self.price = price; self.territories = territories; self.preserveCurrentPrice = preserveCurrentPrice
        }
    }

    public var referenceName: String?
    /// ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS or ONE_YEAR.
    public var period: String?
    /// Its rank in the group (1: the highest level of service).
    public var groupLevel: Int?
    public var familySharable: Bool?
    public var reviewNote: String?
    public var reviewScreenshot: String?
    public var pricing: Pricing?
    public var availability: AppYAML.Availability?
    public var localizations: SortedMap<ProductText>?

    public init(referenceName: String? = nil, period: String? = nil, groupLevel: Int? = nil, familySharable: Bool? = nil, reviewNote: String? = nil,
                reviewScreenshot: String? = nil, pricing: Pricing? = nil, availability: AppYAML.Availability? = nil, localizations: SortedMap<ProductText>? = nil) {
        self.referenceName = referenceName; self.period = period; self.groupLevel = groupLevel; self.familySharable = familySharable
        self.reviewNote = reviewNote; self.reviewScreenshot = reviewScreenshot; self.pricing = pricing; self.availability = availability
        self.localizations = localizations
    }

    public static let keys = ["referenceName", "period", "groupLevel", "familySharable", "reviewNote", "reviewScreenshot", "pricing", "availability", "localizations"]
}

/// One `subscriptions/<group>/` directory.
public struct SubscriptionGroupDir: Sendable, Equatable {
    public var group: SubscriptionGroupYAML
    /// Product ID → its file.
    public var subscriptions: [String: SubscriptionYAML]

    public init(group: SubscriptionGroupYAML = SubscriptionGroupYAML(), subscriptions: [String: SubscriptionYAML] = [:]) {
        self.group = group; self.subscriptions = subscriptions
    }
}

/// Every product file of the manifest.
public struct StoreProducts: Sendable, Equatable {
    /// Product ID → `iap/<productId>.yml`.
    public var iaps: [String: IAPYAML]
    /// Directory name → the group.
    public var groups: [String: SubscriptionGroupDir]

    public init(iaps: [String: IAPYAML] = [:], groups: [String: SubscriptionGroupDir] = [:]) { self.iaps = iaps; self.groups = groups }

    public var isEmpty: Bool { iaps.isEmpty && groups.isEmpty }

    /// Every product ID the manifest lists (in-app purchases and subscriptions).
    public var productIDs: [String] { (Array(iaps.keys) + groups.values.flatMap(\.subscriptions.keys)).sorted() }

    public static let iapDirectory = "iap"
    public static let subscriptionsDirectory = "subscriptions"
    public static let groupFile = "group.yml"

    /// The manifest path of each product file, by path.
    public var files: [String: String] {
        var out: [String: String] = [:]
        for (id, iap) in iaps { out["\(Self.iapDirectory)/\(id).yml"] = (try? ProductRender.yaml(iap)) ?? "" }
        for (dir, g) in groups {
            out["\(Self.subscriptionsDirectory)/\(dir)/\(Self.groupFile)"] = (try? ProductRender.yaml(g.group)) ?? ""
            for (id, s) in g.subscriptions { out["\(Self.subscriptionsDirectory)/\(dir)/\(id).yml"] = (try? ProductRender.yaml(s)) ?? "" }
        }
        return out
    }

    /// A directory name for a group App Store Connect names `referenceName`: lower case letters, digits and dashes.
    public static func directoryName(for referenceName: String, taken: Set<String>) -> String {
        var slug = String(referenceName.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "group" }
        var name = slug, n = 2
        while taken.contains(name) { name = "\(slug)-\(n)"; n += 1 }
        return name
    }
}

/// Product files as `pull` writes them.
public enum ProductRender {
    static let header = "# Written by `xless store pull` (docs/appstore-manifest.md#in-app-purchases-and-subscriptions); values are App Store Connect's.\n"

    public static func yaml<T: Encodable>(_ value: T) throws -> String {
        var options = YAMLEncoder.Options()
        options.allowUnicode = true
        options.width = -1
        options.newLineScalarStyle = .literal
        let encoder = YAMLEncoder()
        encoder.options = options
        let body = try encoder.encode(value)
        return header + (body.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" ? "" : body)
    }
}

// MARK: - Reading

extension ManifestReader {
    /// `iap/` and `subscriptions/`: the product files, and what is wrong with them.
    static func readProducts(_ dir: URL) -> (StoreProducts, [StoreIssue]) {
        let name = dir.lastPathComponent
        var products = StoreProducts()
        var issues: [StoreIssue] = []
        let iapDir = dir.appendingPathComponent(StoreProducts.iapDirectory)
        for entry in children(iapDir) where !isDirectory(entry) && entry.pathExtension == "yml" {
            let id = entry.deletingPathExtension().lastPathComponent
            let display = "\(name)/\(StoreProducts.iapDirectory)/\(entry.lastPathComponent)"
            guard ProductID.isProductID(id) else {
                issues.append(StoreIssue(display, "\(id) is not a product ID", fix: "name the file after the product ID: letters, digits, dots, dashes, underscores (com.example.coins100.yml)"))
                continue
            }
            let (value, found) = readYAML(entry, display: display, as: IAPYAML.self, keys: IAPYAML.keys)
            issues += found
            if let value { products.iaps[id] = value }
        }
        let subscriptionsDir = dir.appendingPathComponent(StoreProducts.subscriptionsDirectory)
        for entry in children(subscriptionsDir) {
            let groupName = entry.lastPathComponent
            let base = "\(name)/\(StoreProducts.subscriptionsDirectory)/\(groupName)"
            guard isDirectory(entry) else {
                if entry.pathExtension == "yml" {
                    issues.append(StoreIssue(base, "is not inside a group directory", fix: "move it to \(name)/\(StoreProducts.subscriptionsDirectory)/<group>/ next to that group's group.yml"))
                }
                continue
            }
            var g = SubscriptionGroupDir()
            let groupURL = entry.appendingPathComponent(StoreProducts.groupFile)
            if FileManager.default.fileExists(atPath: groupURL.path) {
                let (value, found) = readYAML(groupURL, display: "\(base)/\(StoreProducts.groupFile)", as: SubscriptionGroupYAML.self, keys: SubscriptionGroupYAML.keys)
                issues += found
                if let value { g.group = value }
            } else {
                issues.append(StoreIssue("\(base)/\(StoreProducts.groupFile)", "missing", fix: "write it with the group's `referenceName` (docs/appstore-manifest.md#in-app-purchases-and-subscriptions)"))
            }
            for file in children(entry) where !isDirectory(file) && file.pathExtension == "yml" && file.lastPathComponent != StoreProducts.groupFile {
                let id = file.deletingPathExtension().lastPathComponent
                let display = "\(base)/\(file.lastPathComponent)"
                guard ProductID.isProductID(id) else {
                    issues.append(StoreIssue(display, "\(id) is not a product ID", fix: "name the file after the product ID: letters, digits, dots, dashes, underscores (com.example.monthly.yml)"))
                    continue
                }
                let (value, found) = readYAML(file, display: display, as: SubscriptionYAML.self, keys: SubscriptionYAML.keys)
                issues += found
                if let value { g.subscriptions[id] = value }
            }
            products.groups[groupName] = g
        }
        return (products, issues)
    }

    /// One YAML file decoded as `T`; unknown top-level keys are warnings.
    static func readYAML<T: Decodable>(_ url: URL, display: String, as: T.Type, keys: [String]) -> (T?, [StoreIssue]) {
        guard let data = try? Data(contentsOf: url) else { return (nil, [StoreIssue(display, "cannot be read", fix: "check its permissions")]) }
        guard let text = String(data: data, encoding: .utf8) else { return (nil, [StoreIssue(display, "is not UTF-8 text", fix: "save it as UTF-8")]) }
        let node: Node?
        do { node = try Yams.compose(yaml: text) } catch {
            return (nil, [StoreIssue(display, "is not valid YAML (\(yamlProblem(error)))", fix: "fix the YAML syntax")])
        }
        guard let node else { return (try? YAMLDecoder().decode(T.self, from: "{}"), []) }
        guard let mapping = node.mapping else {
            return (nil, [StoreIssue(display, "is not a YAML mapping", fix: "write `key: value` lines (docs/appstore-manifest.md#in-app-purchases-and-subscriptions)")])
        }
        var issues: [StoreIssue] = []
        for (key, _) in mapping {
            let k = key.string ?? "\(key)"
            guard !keys.contains(k) else { continue }
            let near = keys.first { $0.lowercased() == k.lowercased() }
            issues.append(StoreIssue(display, "unknown key `\(k)`", fix: near.map { "did you mean `\($0)`?" } ?? "remove it; the keys are listed in docs/appstore-manifest.md",
                                     severity: .warning))
        }
        do {
            return (try YAMLDecoder().decode(T.self, from: node), issues)
        } catch let error as DecodingError {
            issues.append(decodingIssue(error, display: display))
        } catch {
            issues.append(StoreIssue(display, "cannot be read: \(error)", fix: "compare it with docs/appstore-manifest.md"))
        }
        return (nil, issues)
    }
}

// MARK: - Validation

extension ManifestValidator {
    /// Apple's limits on product text (characters).
    public static let productLimits: [String: Int] = ["iap.name": 35, "iap.description": 55, "subscription.name": 35, "subscription.description": 55,
                                                      "group.name": 75, "group.customAppName": 30, "reviewNote": 4000, "referenceName": 64]
}

extension ManifestValidator.Run {
    mutating func products() {
        let products = manifest.products
        let iapBase = "\(name)/\(StoreProducts.iapDirectory)"
        var seenIDs: [String: String] = [:]
        func claim(_ id: String, _ path: String) {
            if let other = seenIDs[id] { error(path, "product ID \(id) is also \(other)", "a product ID belongs to one product: rename or remove one file") }
            seenIDs[id] = path
        }
        for id in products.iaps.keys.sorted() {
            let iap = products.iaps[id]!
            let path = "\(iapBase)/\(id).yml"
            claim(id, path)
            if let type = iap.type {
                if !InAppPurchaseType.all.contains(type) { error(path, "type \(type) is not an in-app purchase type", "use one of \(oneOf(InAppPurchaseType.all)) (auto-renewable subscriptions go in \(name)/\(StoreProducts.subscriptionsDirectory)/)") }
            } else {
                missing(path, "no type", "add `type:` (\(oneOf(InAppPurchaseType.all))); App Store Connect needs it to create the product")
            }
            if iap.referenceName == nil { missing(path, "no referenceName", "add `referenceName:`, the name App Store Connect shows") }
            productCommon(path, referenceName: iap.referenceName, reviewNote: iap.reviewNote, screenshot: iap.reviewScreenshot, folder: StoreProducts.iapDirectory, id: id)
            if let p = iap.pricing { pricingIssues(p, path: path) }
            territoryList(iap.availability?.territories, key: "availability.territories", path: path)
            productTexts(path, iap.localizations, kind: "iap")
        }
        for dir in products.groups.keys.sorted() {
            let g = products.groups[dir]!
            let base = "\(name)/\(StoreProducts.subscriptionsDirectory)/\(dir)"
            let groupPath = "\(base)/\(StoreProducts.groupFile)"
            if let ref = g.group.referenceName {
                if ref.trimmingCharacters(in: .whitespaces).isEmpty { error(groupPath, "referenceName is empty", "name the group") }
                if let other = products.groups.first(where: { $0.key != dir && $0.value.group.referenceName == ref })?.key, other < dir {
                    error(groupPath, "referenceName \(ref) is also \(name)/\(StoreProducts.subscriptionsDirectory)/\(other)'s", "a group is one directory: merge them")
                }
            } else if FileManager.default.fileExists(atPath: self.dir.appendingPathComponent("\(StoreProducts.subscriptionsDirectory)/\(dir)/\(StoreProducts.groupFile)").path) {
                error(groupPath, "no referenceName", "add `referenceName:`: it is how push finds the group in App Store Connect")
            }
            for (locale, text) in (g.group.localizations?.values ?? [:]).sorted(by: { $0.key < $1.key }) {
                localeKey(locale, path: groupPath)
                if text.name == nil { missing(groupPath, "localizations.\(locale) has no name", "give the group's name in \(locale)") }
                limit(text.name, "group.name", "localizations.\(locale).name", groupPath)
                limit(text.customAppName, "group.customAppName", "localizations.\(locale).customAppName", groupPath)
            }
            var levels: [Int: String] = [:]
            for id in g.subscriptions.keys.sorted() {
                let s = g.subscriptions[id]!
                let path = "\(base)/\(id).yml"
                claim(id, path)
                if let period = s.period {
                    if !SubscriptionPeriod.all.contains(period) { error(path, "period \(period) is not a subscription period", "use one of \(oneOf(SubscriptionPeriod.all))") }
                } else {
                    missing(path, "no period", "add `period:` (\(oneOf(SubscriptionPeriod.all)))")
                }
                if s.referenceName == nil { missing(path, "no referenceName", "add `referenceName:`, the name App Store Connect shows") }
                if let level = s.groupLevel {
                    if level < 1 { error(path, "groupLevel \(level) is not a level", "use 1 (the highest level of service), 2, …") }
                    if let other = levels[level] { error(path, "groupLevel \(level) is also \(other)'s", "give each subscription of the group its own level") }
                    levels[level] = id
                }
                productCommon(path, referenceName: s.referenceName, reviewNote: s.reviewNote, screenshot: s.reviewScreenshot,
                              folder: "\(StoreProducts.subscriptionsDirectory)/\(dir)", id: id)
                if let p = s.pricing {
                    pricingIssues(AppYAML.Pricing(baseTerritory: p.baseTerritory, price: p.price, territories: p.territories), path: path)
                    if p.price != nil, p.baseTerritory == nil { warn(path, "pricing has no baseTerritory: USA is assumed", "add `baseTerritory: USA` (or the territory the price is in)") }
                }
                territoryList(s.availability?.territories, key: "availability.territories", path: path)
                productTexts(path, s.localizations, kind: "subscription")
            }
        }
    }

    mutating func productCommon(_ path: String, referenceName: String?, reviewNote: String?, screenshot: String?, folder: String, id: String) {
        if let r = referenceName, r.trimmingCharacters(in: .whitespaces).isEmpty { error(path, "referenceName is empty", "give the product a name") }
        limit(referenceName, "referenceName", "referenceName", path)
        limit(reviewNote, "reviewNote", "reviewNote", path)
        guard let file = screenshot else { return }
        guard let url = StoreManifest.resolve(file, in: dir) else {
            error(path, "reviewScreenshot: \(file) is outside \(name)/", "keep the screenshot inside the manifest, e.g. \(folder)/\(id).png")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error("\(name)/\(file)", "is missing (reviewScreenshot of \(id))", "put the screenshot there, or remove reviewScreenshot")
            return
        }
        if ImageInfo.read(data) == nil { error("\(name)/\(file)", "is not a PNG or JPEG image", "App Review screenshots are PNG or JPEG") }
    }

    mutating func productTexts(_ path: String, _ localizations: SortedMap<ProductText>?, kind: String) {
        guard let localizations, !localizations.isEmpty else {
            missing(path, "no localizations", "add `localizations:` with at least the primary locale's name (customers see it)")
            return
        }
        for (locale, text) in localizations.values.sorted(by: { $0.key < $1.key }) {
            localeKey(locale, path: path)
            if text.name == nil { missing(path, "localizations.\(locale) has no name", "give the name customers see in \(locale)") }
            limit(text.name, "\(kind).name", "localizations.\(locale).name", path)
            limit(text.description, "\(kind).description", "localizations.\(locale).description", path)
        }
    }

    mutating func localeKey(_ locale: String, path: String) {
        do { _ = try AppLocale.normalize(locale) } catch let e as IdentifierInputError {
            error(path, "localizations: \(e.description)", "use an App Store Connect locale such as en-US or de-DE")
        } catch {}
    }

    mutating func limit(_ value: String?, _ key: String, _ field: String, _ path: String) {
        guard let value, let max = ManifestValidator.productLimits[key], value.count > max else { return }
        error(path, "\(field) is \(value.count) characters, Apple allows \(max)", "shorten it")
    }
}
