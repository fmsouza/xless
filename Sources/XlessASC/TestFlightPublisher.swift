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
        /// True for an external group (`testflight.external.groups`); absent for an internal one.
        public var external: Bool?
        /// The testers this run added to the group (`testflight.testers`, `testflight.external.testers`).
        public var added: [String]?
        public init(name: String, id: String, created: Bool, testerCount: Int, external: Bool? = nil, added: [String]? = nil) {
            self.name = name; self.id = id; self.created = created; self.testerCount = testerCount; self.external = external; self.added = added
        }
    }
    public var buildID: String
    public var buildNumber: String
    public var locale: String
    public var groups: [Group]
    public var whatToTestSet: Bool
    /// Delivery caveats that do not fail the run (e.g. membership of an automatic-distribution group could not be confirmed).
    public var notes: [String] = []
    /// The beta app review submission: `submitted (WAITING_FOR_REVIEW)`, `already submitted (APPROVED)`; nil without one.
    public var betaReview: String? = nil
    /// The bundle identifier of the app, for the hints.
    public var bundleID: String? = nil

    public init(buildID: String, buildNumber: String, locale: String, groups: [Group], whatToTestSet: Bool, notes: [String] = [],
                betaReview: String? = nil, bundleID: String? = nil) {
        self.buildID = buildID; self.buildNumber = buildNumber; self.locale = locale; self.groups = groups
        self.whatToTestSet = whatToTestSet; self.notes = notes; self.betaReview = betaReview; self.bundleID = bundleID
    }

    /// Lines for the terminal: build, one line per group, what to test, the beta app review.
    public var summary: [String] {
        var lines = ["TestFlight: build \(buildNumber) (\(buildID))"]
        for g in groups {
            let kind = g.external == true ? " (external)" : ""
            lines.append("  group \(g.name)\(kind)\(g.created ? " (created)" : "") — available to \(g.testerCount) tester\(g.testerCount == 1 ? "" : "s")")
            if let added = g.added, !added.isEmpty { lines.append("    added: \(added.joined(separator: ", "))") }
        }
        if whatToTestSet { lines.append("  what to test (\(locale)): set") }
        if let betaReview { lines.append("  beta app review: \(betaReview)") }
        return lines
    }

    public var warnings: [String] {
        let app = bundleID ?? "<bundle id>"
        return notes + groups.filter { $0.testerCount == 0 }.map {
            $0.external == true
                ? "warning: group \($0.name) has 0 testers: add them with `xless testflight testers add <email> --group \"\($0.name)\" --app \(app)`, testflight.external.testers in xless.yml, or a public link (`xless testflight public-link enable \"\($0.name)\" --app \(app)`)"
                : "warning: group \($0.name) has 0 testers, so nobody can install this build yet. Internal testers must be App Store Connect users (invite them with `xless users invite`); add them with `xless testflight testers add <email> --group \"\($0.name)\" --app \(app)` or testflight.testers in xless.yml"
        }
    }
}

/// Delivers an uploaded, processed build to TestFlight groups, with the operations of `ASCTestFlight` that `xless testflight`
/// has too: internal groups, their testers and, with `testflight.external`, external groups, their testers, the beta information and the beta app review submission.
///
/// Never deletes anything and never modifies an existing group: groups are reused by exact name, or created when missing
/// (internal groups with automatic distribution). Testers are added, never removed.
public struct TestFlightPublisher: Sendable {
    let client: ASCClient

    public init(client: ASCClient) { self.client = client }

    private func step<T>(_ what: String, done: String, _ op: () async throws -> T) async throws -> T {
        try await uploadStep(what, fix: "see the App Store Connect error above", suffix: done) {
            // A listing that does not end is an error, never a truncated list (a missing group would be created a second time).
            do { return try await op() } catch ASCPagingError.didNotTerminate {
                throw XlessError(.upload, "\(what): App Store Connect returned more than \(ASCPaging.maxPages) pages; pagination did not terminate",
                                 fix: "report this as an xless bug; \(done)")
            }
        }
    }

    /// The app's groups and those that have the build, read when they are first needed.
    private struct Delivery {
        var appID: String
        var buildID: String
        var done: String
        var groups: [ASCBetaGroup]?
        var current: Set<String>?
    }

    /// - Parameter secret: the value of a secret by name: the demo account's password for `testflight.external.review`,
    ///   read only when it must be sent.
    public func publish(bundleID: String, buildID: String, buildNumber: String, config: TestFlightConfig,
                        secret: (String) throws -> String = { name in throw XlessError(.upload, "missing secret \(name)", fix: "set \(name) or \(name)_FILE") }) async throws -> TestFlightResult {
        let done = "the build is already uploaded and processed (build \(buildNumber)); deliver it by hand in App Store Connect → TestFlight, or fix the cause and ship again with a higher build number"

        let app = try await uploadApp(bundleID: bundleID, resources: ASCResources(client: client), fix: "see the App Store Connect error above", suffix: done)

        let tf = testFlight
        var whatToTestSet = false
        if let text = config.whatToTest {
            _ = try await step("setting What to Test (\(config.locale))", done: done) { try await tf.setWhatsNew(build: buildID, locale: config.locale, text: text) }
            whatToTestSet = true
        }

        var groups: [TestFlightResult.Group] = []
        var notes: [String] = []
        var delivery = Delivery(appID: app.id, buildID: buildID, done: done)
        let users: Set<String>? = config.testers.isEmpty ? nil : try await step("reading the team's users", done: done) { try await tf.userEmails() }
        for name in config.groups {
            groups.append(try await deliver(&delivery, to: name, external: false, testers: config.testers, users: users, notes: &notes))
        }
        var betaReview: String?
        if let external = config.external {
            betaReview = try await publishExternal(external, locale: config.locale, delivery: &delivery, groups: &groups, notes: &notes, secret: secret)
        }
        return TestFlightResult(buildID: buildID, buildNumber: buildNumber, locale: config.locale, groups: groups, whatToTestSet: whatToTestSet,
                                notes: notes, betaReview: betaReview, bundleID: bundleID)
    }

    var testFlight: ASCTestFlight { ASCTestFlight(resources: ASCResources(client: client)) }

    /// Puts the build and the testers into the group of that name, which is created when the app has none.
    private func deliver(_ delivery: inout Delivery, to name: String, external: Bool, testers: [TestFlightTester], users: Set<String>?,
                         notes: inout [String]) async throws -> TestFlightResult.Group {
        let tf = testFlight, appID = delivery.appID, buildID = delivery.buildID, done = delivery.done
        let existing: [ASCBetaGroup]
        if let groups = delivery.groups { existing = groups } else {
            existing = try await step("looking up the TestFlight groups", done: done) { try await tf.groups(app: appID) }
        }
        if let found = existing.first(where: { $0.name == name }), found.isInternal == external {
            throw external
                ? XlessError(.upload, "TestFlight group \(name) already exists and is an internal group; testflight.external.groups lists external groups",
                             fix: "move it to testflight.groups, or rename it in testflight.external.groups; \(done)")
                : XlessError(.upload, "TestFlight group \(name) already exists and is an external group; xless only delivers to internal groups",
                             fix: "rename the group in testflight.groups (a missing one is created as internal), or point testflight.groups at an existing internal group; \(done)")
        }
        let outcome = try await step(external ? "creating external group \(name)" : "creating group \(name)", done: done) {
            try await tf.createGroup(name: name, app: appID, external: external, allBuilds: !external, existing: existing)
        }
        let group = outcome.value
        var created = false
        if case .created = outcome { created = true }
        delivery.groups = existing.contains { $0.id == group.id } ? existing : existing + [group]

        let current: Set<String>
        if let read = delivery.current { current = read } else {
            // Only saves a request: without it the build is added, as to a group that does not have it.
            current = try await step("reading the build's groups", done: done) {
                do { return try await tf.groupIDs(with: buildID, app: appID) } catch is ASCError { return [] }
            }
            delivery.current = current
        }
        let addition = try await step("adding the build to group \(name)", done: done) { try await tf.addBuild(buildID, to: group, app: appID, current: current) }
        if let note = addition.note(build: buildID, group: name) { notes.append(note) }

        let added = try await add(testers, to: group, appID: appID, users: users, notes: &notes, done: done)
        let count = try await step("counting testers in group \(name)", done: done) { try await tf.testerCount(group: group.id) }
        return .init(name: name, id: group.id, created: created, testerCount: count, external: external ? true : nil, added: added.isEmpty ? nil : added)
    }

    /// Apple turning one tester down (a conflict, an address it refuses): every 4xx but those about the key or the rate.
    static func refusesTester(_ e: ASCError) -> Bool { (400..<500).contains(e.status) && ![401, 403, 429].contains(e.status) }

    /// Adds `testers` to the group (those already in it are left alone). A tester Apple or xless refuses (an internal
    /// group's tester who is not a user of the team, an address Apple turns down) is a note, not a failure: the build is
    /// delivered either way.
    private func add(_ testers: [TestFlightTester], to group: ASCBetaGroup, appID: String, users: Set<String>?,
                     notes: inout [String], done: String) async throws -> [String] {
        guard !testers.isEmpty else { return [] }
        let tf = testFlight, name = group.name
        let members = try await step("reading the testers of group \(name)", done: done) { try await tf.members(of: group) }
        var added: [String] = []
        for t in testers {
            let request = BetaTesterRequest(email: t.email, firstName: t.firstName, lastName: t.lastName)
            let what = "adding \(t.email) to group \(name)"
            let result = try await step(what, done: done) { () async throws -> ASCTestFlight.TesterAddition? in
                do { return try await tf.add(request, to: group, app: appID, members: members, users: users) } catch let e as XlessError where e.stage == .account {
                    notes.append("warning: \(e.cause); \(e.fix)")
                } catch let e as ASCError where Self.refusesTester(e) {
                    notes.append("warning: \(what): \(e.description); add them by hand (`xless testflight testers add \(t.email) --group \"\(name)\" --app \(appID)`) once the cause is fixed")
                }
                return nil
            }
            guard let result else { continue }
            if case .alreadyInGroup = result { continue }
            added.append(t.email)
        }
        return added
    }

    /// `testflight.external`: the beta information, the external groups (with the build and their testers), then the
    /// submission. Returns the beta app review line.
    private func publishExternal(_ external: ExternalTestFlight, locale: String, delivery: inout Delivery, groups: inout [TestFlightResult.Group],
                                 notes: inout [String], secret: (String) throws -> String) async throws -> String? {
        let tf = testFlight, appID = delivery.appID, buildID = delivery.buildID, done = delivery.done
        if let info = external.info {
            let text = BetaInfoText(description: info.description, feedbackEmail: info.feedbackEmail, marketingURL: info.marketingUrl,
                                    privacyPolicyURL: info.privacyPolicyUrl)
            _ = try await step("setting the beta app information (\(locale))", done: done) { try await tf.setLocalization(app: appID, locale: locale, text) }
        }
        if let review = external.review {
            let change = BetaReviewChange(contactFirstName: review.contact?.firstName, contactLastName: review.contact?.lastName,
                                          contactPhone: review.contact?.phone, contactEmail: review.contact?.email, notes: review.notes,
                                          demoAccountName: review.demoAccount?.name, demoAccountRequired: review.demoAccount?.required,
                                          passwordSecret: review.demoAccount?.passwordSecret ?? BetaReviewChange.defaultPasswordSecret)
            let detail = try await step("reading the beta App Review details", done: done) { try await tf.reviewDetail(app: appID) }
            // The password is read before the step: a missing secret is its own error, never an App Store Connect one.
            var value: String?
            if change.diff(from: detail.attributes).password {
                do { value = try secret(change.passwordSecret) } catch let e as XlessError {
                    throw XlessError(.upload, e.cause.replacingOccurrences(of: "; nothing was sent", with: ""), fix: "\(e.fix); \(done)")
                }
            }
            let password = value
            _ = try await step("setting the beta App Review details", done: done) {
                do { return try await tf.updateReviewDetail(detail, change) { _ in password ?? "" } } catch let e as XlessError where e.stage == .account {
                    throw XlessError(.upload, e.cause, fix: done)
                }
            }
        }
        for name in external.groups {
            groups.append(try await deliver(&delivery, to: name, external: true, testers: external.testers, users: nil, notes: &notes))
        }
        guard external.submit else { return nil }
        let submission = try await step("submitting the build for beta app review", done: done) { try await tf.submit(build: buildID) }
        let state = submission.value.attributes.betaReviewState ?? "WAITING_FOR_REVIEW"
        if case .unchanged = submission { return "already submitted (\(state))" }
        return "submitted (\(state)); external testers get the build once Apple approves it (`xless testflight beta-review status \(buildID)`)"
    }
}
