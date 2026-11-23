import Foundation
import Testing
import XlessAppleID
import XlessCore
@testable import XlessStore

// App Privacy: app.yml ↔ App Store Connect's answers, the diff, its order, and the publish at the end.

typealias Usage = AppYAML.Privacy.DataUsage

let fullCatalog = WebPrivacyCatalog(
    categories: Dictionary(uniqueKeysWithValues: StorePrivacy.knownCategories.map { ($0, false) }).merging(["OLD_THING": true]) { $1 },
    purposes: Dictionary(uniqueKeysWithValues: StorePrivacy.knownPurposes.map { ($0, false) }),
    protections: Dictionary(uniqueKeysWithValues: PrivacyProtection.all.map { ($0, false) }))

func usage(_ id: String, _ category: String?, _ purpose: String?, _ protection: String?) -> WebDataUsage {
    WebDataUsage(id: id, category: category, purpose: purpose, protection: protection)
}

let emailLinked = AppYAML.Privacy(collectsData: true, data: [Usage(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false)])

/// The steps of a plan, in order, as text.
func steps(_ changes: [StoreChange]) -> [String] {
    changes.flatMap { $0.privacy ?? [] }.map {
        switch $0 {
        case .create(let t): "+ \(t)"
        case .delete(let id, let t): "- \(id)" + (t.map { " \($0)" } ?? "")
        case .publish: "publish"
        }
    }
}

func plan(_ want: AppYAML.Privacy, _ usages: [WebDataUsage], published: Bool? = true, catalog: WebPrivacyCatalog = fullCatalog) throws -> [StoreChange] {
    try StorePrivacy.plan(want, usages: usages, published: published, catalog: catalog, appName: "com.example.app")
}

@Test func theManifestStandsForOneAnswerPerPurposeAndACategoryWideTrackingAnswer() {
    let privacy = AppYAML.Privacy(collectsData: true, data: [
        Usage(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY", "ANALYTICS"], linkedToYou: true, tracking: false),
        Usage(category: "DEVICE_ID", purposes: ["THIRD_PARTY_ADVERTISING"], linkedToYou: false, tracking: true),
    ])
    #expect(StorePrivacy.tuples(privacy).sorted().map(\.description) == [
        "DEVICE_ID / THIRD_PARTY_ADVERTISING: DATA_NOT_LINKED_TO_YOU",
        "DEVICE_ID: DATA_USED_TO_TRACK_YOU",
        "EMAIL_ADDRESS / ANALYTICS: DATA_LINKED_TO_YOU",
        "EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU",
    ])
    #expect(StorePrivacy.tuples(AppYAML.Privacy(collectsData: false)).map(\.description) == ["DATA_NOT_COLLECTED"])
}

@Test func publishedAnswersThatMatchSendNothing() throws {
    #expect(try plan(emailLinked, [usage("u1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked)]).isEmpty)
    #expect(try plan(AppYAML.Privacy(collectsData: false), [usage("u1", nil, nil, PrivacyProtection.notCollected)]).isEmpty)
}

@Test func matchingAnswersThatAreNotPublishedAreOnlyPublished() throws {
    let changes = try plan(emailLinked, [usage("u1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked)], published: false)
    #expect(steps(changes) == ["publish"])
    #expect(changes.map(\.text) == ["~ publish the App Privacy answers of com.example.app"])
}

@Test func onlyTheAnswersThatChangedAreDeletedAndCreatedThenPublished() throws {
    let want = AppYAML.Privacy(collectsData: true, data: [
        Usage(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY", "ANALYTICS"], linkedToYou: true, tracking: false),
        Usage(category: "NAME", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false),
    ])
    let have = [
        usage("u1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked),
        usage("u2", "EMAIL_ADDRESS", "PRODUCT_PERSONALIZATION", PrivacyProtection.linked),
        usage("u3", "NAME", "APP_FUNCTIONALITY", PrivacyProtection.notLinked),
        usage("u4", "CRASH_DATA", "ANALYTICS", PrivacyProtection.notLinked),
    ]
    let changes = try plan(want, have)
    #expect(steps(changes) == [
        "- u4 CRASH_DATA / ANALYTICS: DATA_NOT_LINKED_TO_YOU",
        "+ EMAIL_ADDRESS / ANALYTICS: DATA_LINKED_TO_YOU",
        "- u2 EMAIL_ADDRESS / PRODUCT_PERSONALIZATION: DATA_LINKED_TO_YOU",
        "+ NAME / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU",
        "- u3 NAME / APP_FUNCTIONALITY: DATA_NOT_LINKED_TO_YOU",
        "publish",
    ], "u1 is kept; each category creates before it deletes, so an interruption leaves more answers, never fewer")
    #expect(changes.map(\.text) == [
        "- App Privacy CRASH_DATA\n    purposes: \"ANALYTICS\" → (none)\n    linkedToYou: \"false\" → (none)\n    tracking: \"false\" → (none)",
        "~ App Privacy EMAIL_ADDRESS: purposes: \"APP_FUNCTIONALITY, PRODUCT_PERSONALIZATION\" → \"ANALYTICS, APP_FUNCTIONALITY\"",
        "~ App Privacy NAME: linkedToYou: \"false\" → \"true\"",
        "~ publish the App Privacy answers of com.example.app",
    ])
    #expect(StorePlan(changes: changes).deletes.isEmpty, "changing App Privacy answers is not a deletion to confirm")
}

@Test func goingToDataNotCollectedDeletesTheCollectedAnswersFirst() throws {
    let have = [usage("u1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked), usage("u2", "EMAIL_ADDRESS", nil, PrivacyProtection.tracking)]
    #expect(steps(try plan(AppYAML.Privacy(collectsData: false), have)) == [
        "- u1 EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "- u2 EMAIL_ADDRESS: DATA_USED_TO_TRACK_YOU", "+ DATA_NOT_COLLECTED", "publish",
    ])
}

@Test func goingFromDataNotCollectedDeletesItFirst() throws {
    let changes = try plan(emailLinked, [usage("u0", nil, nil, PrivacyProtection.notCollected)])
    #expect(steps(changes) == ["- u0 DATA_NOT_COLLECTED", "+ EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "publish"])
    #expect(changes.first?.text == "- App Privacy: data not collected")
    #expect(changes[1].action == .create)
}

@Test func firstAnswersAreCreated() throws {
    #expect(steps(try plan(emailLinked, [], published: nil)) == ["+ EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "publish"])
}

@Test func trackingAnswersFastlaneWritesPerPurposeAreKept() throws {
    // fastlane's upload_app_privacy_details_to_app_store writes the tracking answer once per purpose.
    let want = AppYAML.Privacy(collectsData: true, data: [Usage(category: "DEVICE_ID", purposes: ["ANALYTICS", "THIRD_PARTY_ADVERTISING"], linkedToYou: false, tracking: true)])
    let have = [
        usage("a", "DEVICE_ID", "ANALYTICS", PrivacyProtection.notLinked), usage("b", "DEVICE_ID", "THIRD_PARTY_ADVERTISING", PrivacyProtection.notLinked),
        usage("c", "DEVICE_ID", "ANALYTICS", PrivacyProtection.tracking), usage("d", "DEVICE_ID", "THIRD_PARTY_ADVERTISING", PrivacyProtection.tracking),
    ]
    #expect(try plan(want, have).isEmpty)
    #expect(StorePrivacy.declaration(from: have).privacy == want)
}

@Test func duplicatesAndAnswersXlessCannotReadAreDeleted() throws {
    let have = [
        usage("u1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked),
        usage("u2", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", PrivacyProtection.linked),
        usage("x1", "EMAIL_ADDRESS", "APP_FUNCTIONALITY", nil),
        usage("x2", nil, nil, "SOMETHING_NEW"),
    ]
    let changes = try plan(emailLinked, have)
    #expect(steps(changes) == ["- x1", "- x2", "- u2 EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "publish"])
    #expect(changes.first?.text == "- App Privacy answers xless cannot read (2)")
}

@Test func idsAppStoreConnectDoesNotTakeStopThePlan() throws {
    let want = AppYAML.Privacy(collectsData: true, data: [
        Usage(category: "OLD_THING", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false),
        Usage(category: "MADE_UP", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false),
    ])
    #expect {
        try plan(want, [])
    } throws: { error in
        let e = error as? XlessError
        return e?.cause == "app.yml's privacy: category MADE_UP is not one App Store Connect knows; category OLD_THING is retired by App Store Connect; nothing was sent"
    }
    // A list App Store Connect gives empty proves nothing.
    #expect(steps(try plan(want, [], catalog: WebPrivacyCatalog(purposes: fullCatalog.purposes, protections: fullCatalog.protections))).count == 3)
}

@Test func anInvalidSectionStopsThePlan() throws {
    #expect {
        try plan(AppYAML.Privacy(collectsData: true), [])
    } throws: { ($0 as? XlessError)?.cause == "app.yml: privacy says collectsData: true but lists no data; nothing was sent" }
}

@Test func pullGroupsAnswersByCategory() {
    let (privacy, notes) = StorePrivacy.declaration(from: [
        usage("1", "NAME", "APP_FUNCTIONALITY", PrivacyProtection.linked),
        usage("2", "NAME", "ANALYTICS", PrivacyProtection.notLinked),
        usage("3", "CRASH_DATA", "ANALYTICS", PrivacyProtection.notLinked),
        usage("4", "CRASH_DATA", nil, PrivacyProtection.tracking),
        usage("5", nil, nil, "SOMETHING_NEW"),
    ])
    #expect(privacy == AppYAML.Privacy(collectsData: true, data: [
        Usage(category: "CRASH_DATA", purposes: ["ANALYTICS"], linkedToYou: false, tracking: true),
        Usage(category: "NAME", purposes: ["ANALYTICS", "APP_FUNCTIONALITY"], linkedToYou: true, tracking: false),
    ]))
    #expect(notes == [
        "1 App Privacy answer App Store Connect has is not one xless can read; left out (`xless store privacy push` deletes it)",
        "App Store Connect has NAME both linked and not linked to the user; app.yml says linked (linkedToYou: true)",
    ])
    #expect(StorePrivacy.declaration(from: [usage("1", nil, nil, PrivacyProtection.notCollected)]).privacy == AppYAML.Privacy(collectsData: false))
    #expect(StorePrivacy.declaration(from: []).privacy == nil, "never answered")
}

@Test func theValidatorChecksThePrivacySection() {
    let bad = AppYAML.Privacy(collectsData: true, data: [
        Usage(category: "email", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false),
        Usage(category: "NAME", purposes: [], linkedToYou: nil, tracking: nil),
        Usage(category: "NAME", purposes: ["SPYING", "SPYING"], linkedToYou: true, tracking: false),
    ])
    #expect(ManifestValidator.privacyIssues(bad, path: "appstore/app.yml").map(\.description) == [
        "[account] appstore/app.yml: privacy.data[0].category email is not an App Privacy category ID — use Apple's IDs, e.g. EMAIL_ADDRESS, PRECISE_LOCATION, CRASH_DATA (docs/appstore-manifest.md)",
        "[account] appstore/app.yml: privacy.data NAME has no purposes — add `purposes: [APP_FUNCTIONALITY]` (what the data is used for)",
        "[account] appstore/app.yml: privacy.data NAME has no linkedToYou — say whether the data is linked to the user's identity: `linkedToYou: true` or `false`",
        "[account] appstore/app.yml: privacy.data NAME has no tracking — say whether the data is used to track the user: `tracking: true` or `false`",
        "[account] appstore/app.yml: privacy.data NAME is listed twice — list each category once, with all its purposes",
        "warning: appstore/app.yml: privacy.data NAME: purpose SPYING is not one xless knows — check the ID: ANALYTICS, APP_FUNCTIONALITY, DEVELOPERS_ADVERTISING, OTHER_PURPOSES, PRODUCT_PERSONALIZATION, THIRD_PARTY_ADVERTISING",
        "warning: appstore/app.yml: privacy.data NAME: purpose SPYING is not one xless knows — check the ID: ANALYTICS, APP_FUNCTIONALITY, DEVELOPERS_ADVERTISING, OTHER_PURPOSES, PRODUCT_PERSONALIZATION, THIRD_PARTY_ADVERTISING",
        "[account] appstore/app.yml: privacy.data NAME lists a purpose twice — list each purpose once",
    ])
    #expect(ManifestValidator.privacyIssues(AppYAML.Privacy(collectsData: false, data: [Usage(category: "NAME")]), path: "a").map(\.message) == ["privacy says collectsData: false but lists data"])
    #expect(ManifestValidator.privacyIssues(AppYAML.Privacy(), path: "a").map(\.message) == ["privacy has no collectsData"])
    #expect(ManifestValidator.privacyIssues(emailLinked, path: "a").isEmpty)
}

// MARK: - Sending

/// App Store Connect's App Privacy, in memory.
final class FakePrivacy: PrivacyRemote, @unchecked Sendable {
    let lock = NSLock()
    var stored: [WebDataUsage]
    var published: Bool?
    var calls: [String] = []
    var next = 0
    var failOn: String?

    init(_ usages: [WebDataUsage] = [], published: Bool? = true) { stored = usages; self.published = published }

    func record(_ call: String) throws {
        try lock.withLock {
            calls.append(call)
            if let failOn, call.hasPrefix(failOn) { throw XlessError(.account, "App Store Connect refused \(call)", fix: "-") }
        }
    }

    func usages(app: String) async throws -> [WebDataUsage] { try record("GET usages \(app)"); return lock.withLock { stored } }
    func catalog() async throws -> WebPrivacyCatalog { fullCatalog }
    func publishState(app: String) async throws -> WebPrivacyPublishState? {
        lock.withLock { published.map { WebPrivacyPublishState(id: "PS-\(app)", published: $0) } }
    }
    func create(app: String, category: String?, purpose: String?, protection: String) async throws -> String? {
        try record("POST \(app) \(PrivacyTuple(category: category, purpose: purpose, protection: protection))")
        return lock.withLock {
            next += 1
            stored.append(WebDataUsage(id: "n\(next)", category: category, purpose: purpose, protection: protection))
            if published != nil { published = false }
            return "n\(next)"
        }
    }
    func delete(id: String) async throws {
        try record("DELETE \(id)")
        lock.withLock { stored.removeAll { $0.id == id }; if published != nil { published = false } }
    }
    func publish(stateID: String) async throws {
        try record("PATCH \(stateID)")
        lock.withLock { published = true }
    }

    var sent: [String] { lock.withLock { calls.filter { !$0.hasPrefix("GET") } } }
}

@Test func applyingThePlanSendsItsStepsThenARerunSendsNothing() async throws {
    let fake = FakePrivacy([usage("u0", nil, nil, PrivacyProtection.notCollected)])
    let privacy = StorePrivacy(remote: fake)
    let changes = try await privacy.plan(emailLinked, app: "123", appName: "com.example.app")
    for change in changes { try await privacy.apply(change, app: "123") }
    #expect(fake.sent == ["DELETE u0", "POST 123 EMAIL_ADDRESS / APP_FUNCTIONALITY: DATA_LINKED_TO_YOU", "PATCH PS-123"])
    #expect(try await privacy.plan(emailLinked, app: "123", appName: "com.example.app").isEmpty, "pushed, then compared again: no diff")
    #expect(StorePrivacy.declaration(from: fake.stored).privacy == emailLinked, "pulled back: the same answers")
}

@Test func publishingWithoutAPublishStateSaysWhereToDoIt() async throws {
    let fake = FakePrivacy([], published: nil)
    let privacy = StorePrivacy(remote: fake)
    let changes = try await privacy.plan(emailLinked, app: "123", appName: "x")
    try await privacy.apply(changes[0], app: "123")
    await #expect {
        try await privacy.apply(changes[1], app: "123")
    } throws: { ($0 as? XlessError)?.fix.contains("https://appstoreconnect.apple.com/apps/123/distribution/privacy") == true }
}
