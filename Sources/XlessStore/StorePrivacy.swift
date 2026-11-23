import Foundation
import XlessAppleID
import XlessCore

// App Privacy (app.yml's `privacy:`): what data the app collects, what for, whether it is linked to the user and used
// to track them. App Store Connect keeps the answers as `appDataUsages` (category, purpose, data protection), outside
// its documented API: they are read and sent through the Apple ID web session (`PrivacyRemote`, `ASCWebPrivacy`).
//
//   collectsData: false                 → (–, –, DATA_NOT_COLLECTED)
//   category C, purpose P, linkedToYou  → (C, P, DATA_LINKED_TO_YOU), else (C, P, DATA_NOT_LINKED_TO_YOU), per purpose
//   category C, tracking: true          → (C, –, DATA_USED_TO_TRACK_YOU): category-wide, as App Store Connect answers it
//                                         (a tracking answer with a purpose, as fastlane writes them, counts as well)

/// A data protection (App Store Connect's IDs).
public enum PrivacyProtection {
    public static let notCollected = "DATA_NOT_COLLECTED"
    public static let linked = "DATA_LINKED_TO_YOU"
    public static let notLinked = "DATA_NOT_LINKED_TO_YOU"
    public static let tracking = "DATA_USED_TO_TRACK_YOU"
    public static let all: Set<String> = [notCollected, linked, notLinked, tracking]
}

/// One answer, as App Store Connect stores it.
public struct PrivacyTuple: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var category: String?
    public var purpose: String?
    public var protection: String

    public init(category: String? = nil, purpose: String? = nil, protection: String) {
        self.category = category; self.purpose = purpose; self.protection = protection
    }

    /// The answer of a usage App Store Connect has; nil when it is not one xless can read (no or an unknown protection,
    /// a collected-data answer without a category or purpose, "not collected" with one).
    public init?(_ usage: WebDataUsage) {
        guard let protection = usage.protection, PrivacyProtection.all.contains(protection) else { return nil }
        switch protection {
        case PrivacyProtection.notCollected: guard usage.category == nil, usage.purpose == nil else { return nil }
        case PrivacyProtection.tracking: guard usage.category != nil else { return nil }
        default: guard usage.category != nil, usage.purpose != nil else { return nil }
        }
        self.init(category: usage.category, purpose: usage.purpose, protection: protection)
    }

    /// What two answers must share to be the same: tracking is category-wide, so its purpose does not count.
    var key: String {
        protection == PrivacyProtection.tracking ? "\(category ?? "")|*|\(protection)" : "\(category ?? "")|\(purpose ?? "")|\(protection)"
    }

    public static func < (a: PrivacyTuple, b: PrivacyTuple) -> Bool { a.description < b.description }

    /// `EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU`.
    public var description: String {
        [category, purpose].compactMap { $0 }.joined(separator: " / ") + (category == nil ? "" : ": ") + protection
    }
}

/// One App Privacy request of a `store push` change.
public enum PrivacyStep: Sendable, Equatable {
    case create(PrivacyTuple)
    /// The usage's ID (and its answer, when xless can read it).
    case delete(String, PrivacyTuple?)
    /// Publish the answers (they are read again first, for the publish state's ID).
    case publish
}

/// App Privacy, read and sent through the Apple ID web session (`ASCWebPrivacy` is the real one).
public protocol PrivacyRemote: Sendable {
    func usages(app: String) async throws -> [WebDataUsage]
    func catalog() async throws -> WebPrivacyCatalog
    func publishState(app: String) async throws -> WebPrivacyPublishState?
    @discardableResult func create(app: String, category: String?, purpose: String?, protection: String) async throws -> String?
    func delete(id: String) async throws
    func publish(stateID: String) async throws
}

extension ASCWebPrivacy: PrivacyRemote {}

/// Reads, plans and sends App Privacy answers.
public struct StorePrivacy: Sendable {
    /// Apple's category IDs as of 2026 (fastlane's AppDataUsageCategory::ID); another one is a warning offline, checked
    /// against App Store Connect's own list before anything is sent.
    public static let knownCategories: Set<String> = [
        "PAYMENT_INFORMATION", "CREDIT_AND_FRAUD", "OTHER_FINANCIAL_INFO", "PRECISE_LOCATION", "COARSE_LOCATION", "SENSITIVE_INFO",
        "PHYSICAL_ADDRESS", "EMAIL_ADDRESS", "NAME", "PHONE_NUMBER", "OTHER_CONTACT_INFO", "CONTACTS", "EMAILS_OR_TEXT_MESSAGES",
        "PHOTOS_OR_VIDEOS", "AUDIO", "GAMEPLAY_CONTENT", "CUSTOMER_SUPPORT", "OTHER_USER_CONTENT", "BROWSING_HISTORY", "SEARCH_HISTORY",
        "USER_ID", "DEVICE_ID", "PURCHASE_HISTORY", "PRODUCT_INTERACTION", "ADVERTISING_DATA", "OTHER_USAGE_DATA", "CRASH_DATA",
        "PERFORMANCE_DATA", "OTHER_DIAGNOSTIC_DATA", "OTHER_DATA", "HEALTH", "FITNESS",
    ]
    /// Apple's purpose IDs (fastlane's AppDataUsagePurpose::ID).
    public static let knownPurposes: Set<String> = [
        "THIRD_PARTY_ADVERTISING", "DEVELOPERS_ADVERTISING", "ANALYTICS", "PRODUCT_PERSONALIZATION", "APP_FUNCTIONALITY", "OTHER_PURPOSES",
    ]

    public let remote: any PrivacyRemote

    public init(remote: any PrivacyRemote) { self.remote = remote }

    // MARK: - Manifest → answers

    /// The answers app.yml's `privacy` stands for. Call on a privacy section `ManifestValidator.privacyIssues` accepts.
    public static func tuples(_ privacy: AppYAML.Privacy) -> Set<PrivacyTuple> {
        guard privacy.collectsData == true else { return [PrivacyTuple(protection: PrivacyProtection.notCollected)] }
        var out: Set<PrivacyTuple> = []
        for usage in privacy.data ?? [] {
            let protection = usage.linkedToYou == true ? PrivacyProtection.linked : PrivacyProtection.notLinked
            for purpose in usage.purposes ?? [] { out.insert(PrivacyTuple(category: usage.category, purpose: purpose, protection: protection)) }
            if usage.tracking == true { out.insert(PrivacyTuple(category: usage.category, protection: PrivacyProtection.tracking)) }
        }
        return out
    }

    // MARK: - Answers → manifest

    /// The `privacy` section App Store Connect's answers make (nil: none, the questions were never answered), with
    /// what pull should say about them.
    public static func declaration(from usages: [WebDataUsage]) -> (privacy: AppYAML.Privacy?, notes: [String]) {
        guard !usages.isEmpty else { return (nil, []) }
        var notes: [String] = []
        let tuples = usages.compactMap(PrivacyTuple.init)
        if tuples.count < usages.count {
            let n = usages.count - tuples.count
            notes.append("\(n) App Privacy answer\(n == 1 ? "" : "s") App Store Connect has \(n == 1 ? "is" : "are") not one xless can read; left out (`xless store privacy push` deletes \(n == 1 ? "it" : "them"))")
        }
        let collected = tuples.filter { $0.protection != PrivacyProtection.notCollected }
        if collected.isEmpty {
            return tuples.isEmpty ? (nil, notes) : (AppYAML.Privacy(collectsData: false), notes)
        }
        if collected.count < tuples.count {
            notes.append("App Store Connect has both \"Data Not Collected\" and collected data; app.yml takes the collected data")
        }
        var data: [AppYAML.Privacy.DataUsage] = []
        for category in Set(collected.compactMap(\.category)).sorted() {
            let mine = collected.filter { $0.category == category }
            let identity = mine.filter { $0.protection == PrivacyProtection.linked || $0.protection == PrivacyProtection.notLinked }
            let linked = identity.contains { $0.protection == PrivacyProtection.linked }
            if linked, identity.contains(where: { $0.protection == PrivacyProtection.notLinked }) {
                notes.append("App Store Connect has \(category) both linked and not linked to the user; app.yml says linked (linkedToYou: true)")
            }
            let purposes = Set(identity.compactMap(\.purpose)).sorted()
            if purposes.isEmpty {
                notes.append("App Store Connect has \(category) with no purpose; add its purposes to app.yml before pushing")
            }
            data.append(AppYAML.Privacy.DataUsage(category: category, purposes: purposes, linkedToYou: linked,
                                                  tracking: mine.contains { $0.protection == PrivacyProtection.tracking }))
        }
        return (AppYAML.Privacy(collectsData: true, data: data), notes)
    }

    // MARK: - Plan

    /// The changes (part `privacy`) that make App Store Connect's answers `want`, then publish them. Only the answers
    /// that differ are deleted or created; the catalog is checked first, so an ID App Store Connect does not take stops
    /// the push before anything is sent.
    public static func plan(_ want: AppYAML.Privacy, usages: [WebDataUsage], published: Bool?, catalog: WebPrivacyCatalog,
                            appName: String) throws -> [StoreChange] {
        if let issue = ManifestValidator.privacyIssues(want, path: "app.yml").first(where: { $0.severity == .error }) {
            throw XlessError(.account, "\(issue.path): \(issue.message); nothing was sent", fix: issue.fix)
        }
        let desired = tuples(want)
        try check(desired, against: catalog)
        let wantedKeys = Set(desired.map(\.key))

        // What App Store Connect has: kept when wanted (one of each answer; every tracking answer of a tracked
        // category), else deleted.
        var present: Set<String> = []
        var deletes: [(id: String, tuple: PrivacyTuple?)] = []
        for usage in usages {
            guard let tuple = PrivacyTuple(usage), wantedKeys.contains(tuple.key) else { deletes.append((usage.id, PrivacyTuple(usage))); continue }
            if tuple.protection != PrivacyProtection.tracking, present.contains(tuple.key) { deletes.append((usage.id, tuple)); continue }
            present.insert(tuple.key)
        }
        let creates = desired.filter { !present.contains($0.key) }.sorted()

        let have = declaration(from: usages).privacy
        func entry(_ p: AppYAML.Privacy?, _ category: String) -> AppYAML.Privacy.DataUsage? {
            p?.collectsData == true ? p?.data?.first { $0.category == category } : nil
        }
        let subject = "App Privacy"
        var changes: [StoreChange] = []

        // Answers xless cannot read go first: they belong to no category.
        let unreadable = deletes.filter { $0.tuple == nil }
        if !unreadable.isEmpty {
            changes.append(StoreChange(.delete, .privacy, "\(subject) answers xless cannot read (\(unreadable.count))", requests: [],
                                       privacy: unreadable.map { .delete($0.id, nil) }))
        }
        // "Data Not Collected" and collected data cannot coexist (409 STATE_ERROR): the old kind goes first.
        let notCollectedCreates = creates.filter { $0.protection == PrivacyProtection.notCollected }
        let notCollectedDeletes = deletes.filter { $0.tuple?.protection == PrivacyProtection.notCollected }
        var categoryChanges: [StoreChange] = []
        let categories = Set(creates.compactMap(\.category) + deletes.compactMap { $0.tuple?.category }).sorted()
        for category in categories {
            let mine = creates.filter { $0.category == category }.map { PrivacyStep.create($0) }
                + deletes.filter { $0.tuple?.category == category }.map { PrivacyStep.delete($0.id, $0.tuple) }
            let before = entry(have, category), after = entry(want, category)
            let action: StoreChange.Action = before == nil ? .create : after == nil ? .delete : .update
            var fields: [StoreFieldChange] = []
            func list(_ v: [String]?) -> String? { v.map { $0.sorted().joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 } }
            func flag(_ v: Bool?) -> String? { v.map { "\($0)" } }
            for (name, from, to) in [("purposes", list(before?.purposes), list(after?.purposes)),
                                     ("linkedToYou", flag(before?.linkedToYou), flag(after.map { $0.linkedToYou ?? false })),
                                     ("tracking", flag(before?.tracking), flag(after.map { $0.tracking ?? false }))] where from != to {
                fields.append(StoreFieldChange(name, from: from, to: to))
            }
            categoryChanges.append(StoreChange(action, .privacy, "\(subject) \(category)", fields: fields, requests: [], privacy: mine))
        }
        if want.collectsData == true {
            if !notCollectedDeletes.isEmpty {
                changes.append(StoreChange(.delete, .privacy, "\(subject): data not collected", requests: [],
                                           privacy: notCollectedDeletes.map { .delete($0.id, $0.tuple) }))
            }
            changes += categoryChanges
        } else {
            changes += categoryChanges
            if !notCollectedCreates.isEmpty || !notCollectedDeletes.isEmpty {
                let steps = notCollectedCreates.map { PrivacyStep.create($0) } + notCollectedDeletes.map { PrivacyStep.delete($0.id, $0.tuple) }
                changes.append(StoreChange(notCollectedCreates.isEmpty ? .update : .create, .privacy, "\(subject): data not collected", requests: [], privacy: steps))
            }
        }
        if !changes.isEmpty || published == false {
            changes.append(StoreChange(.update, .privacy, "publish the \(subject) answers of \(appName)", requests: [], privacy: [.publish]))
        }
        return changes
    }

    /// Every ID the answers send must be one App Store Connect lists and has not retired. A list it gives empty proves
    /// nothing and is not checked.
    static func check(_ tuples: Set<PrivacyTuple>, against catalog: WebPrivacyCatalog) throws {
        var problems: [String] = []
        func look(_ id: String?, in list: [String: Bool], _ what: String) {
            guard let id, !list.isEmpty else { return }
            switch list[id] {
            case nil: problems.append("\(what) \(id) is not one App Store Connect knows")
            case true?: problems.append("\(what) \(id) is retired by App Store Connect")
            case false?: break
            }
        }
        for t in tuples.sorted() {
            look(t.category, in: catalog.categories, "category")
            look(t.purpose, in: catalog.purposes, "purpose")
            look(t.protection, in: catalog.protections, "data protection")
        }
        let unique = problems.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let first = unique.first else { return }
        let known = catalog.categories.filter { !$0.value }.keys.sorted().joined(separator: ", ")
        throw XlessError(.account, "app.yml's privacy: \(unique.count == 1 ? first : unique.joined(separator: "; ")); nothing was sent",
                         fix: "use App Store Connect's IDs (categories: \(known.isEmpty ? "see docs/appstore-manifest.md" : known)); `xless store privacy pull` writes an existing app's answers")
    }

    // MARK: - Remote

    /// What App Store Connect has for the app.
    public struct Remote: Sendable {
        public var usages: [WebDataUsage]
        public var published: Bool?
    }

    public func read(app: String) async throws -> Remote {
        let usages = try await remote.usages(app: app)
        let state = try await remote.publishState(app: app)
        return Remote(usages: usages, published: state?.published)
    }

    /// The plan for `want` against what App Store Connect has now.
    public func plan(_ want: AppYAML.Privacy, app: String, appName: String) async throws -> [StoreChange] {
        let have = try await read(app: app)
        let catalog = try await remote.catalog()
        return try Self.plan(want, usages: have.usages, published: have.published, catalog: catalog, appName: appName)
    }

    /// Sends one change's steps, in order.
    public func apply(_ change: StoreChange, app: String) async throws {
        for step in change.privacy ?? [] {
            switch step {
            case .create(let t): try await remote.create(app: app, category: t.category, purpose: t.purpose, protection: t.protection)
            case .delete(let id, _): try await remote.delete(id: id)
            case .publish:
                guard let state = try await remote.publishState(app: app) else {
                    throw XlessError(.account, "App Store Connect has no publish state for the app's App Privacy answers, so they cannot be published",
                                     fix: "publish them at \(ASCWebPrivacy.page)/\(app)/distribution/privacy; the answers themselves were sent")
                }
                try await remote.publish(stateID: state.id)
            }
        }
    }
}
