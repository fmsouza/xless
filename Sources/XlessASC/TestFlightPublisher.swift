import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

public struct TestFlightResult: Codable, Sendable, Equatable {
    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        public var id: String
        public var created: Bool
        public var testerCount: Int
        public init(name: String, id: String, created: Bool, testerCount: Int) {
            self.name = name; self.id = id; self.created = created; self.testerCount = testerCount
        }
    }
    public var buildID: String
    public var buildNumber: String
    public var locale: String
    public var groups: [Group]
    public var whatToTestSet: Bool
    /// Delivery caveats that do not fail the run (e.g. membership of an automatic-distribution group could not be confirmed).
    public var notes: [String] = []

    /// Lines for the terminal: build, one line per group, what to test.
    public var summary: [String] {
        var lines = ["TestFlight: build \(buildNumber) (\(buildID))"]
        for g in groups {
            lines.append("  group \(g.name)\(g.created ? " (created)" : "") — available to \(g.testerCount) tester\(g.testerCount == 1 ? "" : "s")")
        }
        if whatToTestSet { lines.append("  what to test (\(locale)): set") }
        return lines
    }

    public var warnings: [String] {
        notes + groups.filter { $0.testerCount == 0 }.map {
            "warning: group \($0.name) has 0 testers, so nobody can install this build yet. Internal testers must be App Store Connect users (invite them with `xless users invite`): add them to the group once in the web UI (TestFlight, \($0.name), Testers)"
        }
    }
}

/// Delivers an uploaded, processed build to internal TestFlight groups (App Store Connect API v1).
///
/// Never deletes anything and never modifies an existing group: groups are reused by exact name, or created as
/// internal groups with automatic distribution when missing.
public struct TestFlightPublisher: Sendable {
    let client: ASCClient

    public init(client: ASCClient) { self.client = client }

    struct Named: Codable, Sendable { var bundleId: String? }
    struct GroupAttributes: Codable, Sendable {
        var name: String?
        var isInternalGroup: Bool?
        var hasAccessToAllBuilds: Bool?
    }
    struct LocalizationAttributes: Codable, Sendable { var locale: String?; var whatsNew: String? }
    struct ListDocument<D: Codable & Sendable>: Codable, Sendable {
        struct Meta: Codable, Sendable { struct Paging: Codable, Sendable { var total: Int? }; var paging: Paging? }
        struct Links: Codable, Sendable { var next: String? }
        var data: [D]
        var meta: Meta?
        var links: Links?
    }
    struct NoAttributes: Codable, Sendable {}

    private func step<T>(_ what: String, done: String, _ op: () async throws -> T) async throws -> T {
        try await uploadStep(what, fix: "see the App Store Connect error above", suffix: done, op)
    }

    public func publish(bundleID: String, buildID: String, buildNumber: String, config: TestFlightConfig) async throws -> TestFlightResult {
        let done = "the build is already uploaded and processed (build \(buildNumber)); deliver it by hand in App Store Connect → TestFlight, or fix the cause and ship again with a higher build number"

        let apps: ASCDocument<[ASCResource<Named>]> = try await step("looking up the app record", done: done) {
            try await client.get("/v1/apps", query: [("filter[bundleId]", bundleID)])
        }
        guard let app = apps.data.first(where: { $0.attributes.bundleId == bundleID }) else {
            throw XlessError(.upload, "no app record for \(bundleID)", fix: "create it with `xless apps create --bundle-id \(bundleID) --name <name> --sku <sku> --locale <locale>` (Apple ID sign-in: the API cannot create app records), or in App Store Connect (Apps → +)")
        }

        var whatToTestSet = false
        if let text = config.whatToTest {
            try await setWhatToTest(text, locale: config.locale, buildID: buildID, done: done)
            whatToTestSet = true
        }

        var groups: [TestFlightResult.Group] = []
        var notes: [String] = []
        for name in config.groups {
            let found = try await findOrCreateGroup(name, appID: app.id, done: done)
            if let note = try await attach(buildID: buildID, toGroup: found.id, name: name, automatic: found.automatic, done: done) { notes.append(note) }
            let count = try await testerCount(groupID: found.id, name: name, done: done)
            groups.append(.init(name: name, id: found.id, created: found.created, testerCount: count))
        }
        return TestFlightResult(buildID: buildID, buildNumber: buildNumber, locale: config.locale, groups: groups, whatToTestSet: whatToTestSet, notes: notes)
    }

    /// Every item of a paged listing (`ASCResources.list`: `limit=200`, following `links.next`). A listing that does not
    /// end within `ASCPaging.maxPages` pages is an error, never a truncated list (a missing group would be created a second time).
    private func listAll<D: Decodable & Sendable>(_ what: String, path: String, query: [(String, String)], done: String, as: D.Type) async throws -> [D] {
        try await step(what, done: done) {
            do { return try await ASCResources(client: client).list(path, query: ASCQuery(extra: query), as: D.self).items } catch ASCPagingError.didNotTerminate {
                throw XlessError(.upload, "\(what): App Store Connect returned more than \(ASCPaging.maxPages) pages; pagination did not terminate",
                                 fix: "report this as an xless bug; \(done)")
            }
        }
    }

    private func testerCount(groupID id: String, name: String, done: String) async throws -> Int {
        let probe: ListDocument<ASCRef> = try await step("counting testers in group \(name)", done: done) {
            try await client.get("/v1/betaGroups/\(id)/betaTesters", query: [("limit", "1")])
        }
        if let total = probe.meta?.paging?.total { return total }
        return try await listAll("counting testers in group \(name)", path: "/v1/betaGroups/\(id)/betaTesters", query: [], done: done, as: ASCRef.self).count
    }

    /// "What to Test" lives in a per-locale betaBuildLocalization of the build: update it when present, create it otherwise.
    private func setWhatToTest(_ text: String, locale: String, buildID: String, done: String) async throws {
        struct Update: Codable, Sendable { var whatsNew: String }
        func existing() async throws -> ASCResource<LocalizationAttributes>? {
            try await listAll("reading the build's What to Test", path: "/v1/builds/\(buildID)/betaBuildLocalizations", query: [], done: done,
                              as: ASCResource<LocalizationAttributes>.self).first { $0.attributes.locale == locale }
        }
        func update(_ id: String) async throws {
            let _: ASCDocument<ASCResource<LocalizationAttributes>> = try await step("updating What to Test (\(locale))", done: done) {
                try await client.patch("/v1/betaBuildLocalizations/\(id)", body: ASCUpdate(type: "betaBuildLocalizations", id: id, attributes: Update(whatsNew: text)))
            }
        }
        if let loc = try await existing() { return try await update(loc.id) }
        struct Rels: Codable, Sendable { var build: ASCToOne }
        do {
            let _: ASCDocument<ASCResource<LocalizationAttributes>> = try await step("setting What to Test (\(locale))", done: done) {
                try await client.post("/v1/betaBuildLocalizations", body: ASCCreate<LocalizationAttributes, Rels>(
                    type: "betaBuildLocalizations", attributes: .init(locale: locale, whatsNew: text),
                    relationships: .init(build: .init(.init(type: "builds", id: buildID)))))
            }
        } catch let original as XlessError where original.cause.contains("HTTP 409") {
            // Lost a race with a localization ASC created meanwhile: update that one.
            guard let loc = try await existing() else { throw original }
            try await update(loc.id)
        }
    }

    private func findOrCreateGroup(_ name: String, appID: String, done: String) async throws -> (id: String, created: Bool, automatic: Bool) {
        // No filter[name]: it is an array filter that ASC splits on commas, so names containing a comma would never match.
        let all = try await listAll("looking up group \(name)", path: "/v1/betaGroups", query: [("filter[app]", appID)], done: done,
                                    as: ASCResource<GroupAttributes>.self)
        if let group = all.first(where: { $0.attributes.name == name }) {
            guard group.attributes.isInternalGroup == true else {
                throw XlessError(.upload, "TestFlight group \(name) already exists and is an external group; xless only delivers to internal groups",
                                 fix: "rename the group in testflight.groups (a missing one is created as internal), or point testflight.groups at an existing internal group; \(done)")
            }
            return (group.id, false, group.attributes.hasAccessToAllBuilds == true)
        }
        struct Rels: Codable, Sendable { var app: ASCToOne }
        // postOnce: a retried create could hit a half-applied first attempt and leave a duplicate or a 409.
        let created: ASCDocument<ASCResource<GroupAttributes>> = try await step("creating group \(name)", done: done) {
            try await client.postOnce("/v1/betaGroups", body: ASCCreate<GroupAttributes, Rels>(
                type: "betaGroups", attributes: .init(name: name, isInternalGroup: true, hasAccessToAllBuilds: true),
                relationships: .init(app: .init(.init(type: "apps", id: appID)))))
        }
        return (created.data.id, true, true)
    }

    /// Explicitly adds the build to the group. An automatic-distribution group may already carry the build (or reject the add):
    /// on 409/422 the membership is checked with a bounded query, and if it still cannot be confirmed the build is expected to
    /// arrive through automatic distribution, which is reported as a note. Other groups keep the error.
    private func attach(buildID: String, toGroup id: String, name: String, automatic: Bool, done: String) async throws -> String? {
        do {
            let _: ASCEmpty = try await step("adding the build to group \(name)", done: done) {
                try await client.post("/v1/betaGroups/\(id)/relationships/builds", body: ASCToMany([.init(type: "builds", id: buildID)]))
            }
            return nil
        } catch let original as XlessError where automatic && (original.cause.contains("HTTP 409") || original.cause.contains("HTTP 422")) {
            let member: ListDocument<ASCRef>? = try? await client.get("/v1/betaGroups", query: [("filter[id]", id), ("filter[builds]", buildID), ("limit", "1")])
            if member?.data.isEmpty == false { return nil }
            return "warning: could not confirm that build \(buildID) is in group \(name) (\(original.cause)); the group has automatic distribution, so the build will appear via automatic distribution — check App Store Connect → TestFlight"
        }
    }
}
