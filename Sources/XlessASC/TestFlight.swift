import Foundation
import XlessCore

// TestFlight on the App Store Connect API key, for `xless testflight` (docs/apple-account.md#xless-testflight) and the
// `testflight:` block of xless.yml: beta groups, beta testers and their invitations, the builds each group gets, a build's
// "What to Test", the app's beta information (betaAppLocalizations, betaAppReviewDetail, betaLicenseAgreement), the
// beta app review submission and public links. Creates are sent once (postOnce); a 409 is settled by reading again.

public struct ASCBetaGroupAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var createdDate: String?
    public var isInternalGroup: Bool?
    public var hasAccessToAllBuilds: Bool?
    public var publicLinkEnabled: Bool?
    public var publicLinkId: String?
    public var publicLinkLimitEnabled: Bool?
    public var publicLinkLimit: Int?
    public var publicLink: String?
    public var feedbackEnabled: Bool?
    public init() {}
}

/// A TestFlight group of one app.
public typealias ASCBetaGroup = ASCKeptResource<ASCBetaGroupAttributes>

extension ASCKeptResource where A == ASCBetaGroupAttributes {
    public var name: String { attributes.name ?? "" }
    public var isInternal: Bool { attributes.isInternalGroup == true }
    /// `internal` or `external`.
    public var kind: String { isInternal ? "internal" : "external" }
    /// The public link when it is enabled.
    public var publicLink: String? { attributes.publicLinkEnabled == true ? attributes.publicLink : nil }
    /// The public link's tester limit when one is set.
    public var publicLinkLimit: Int? { attributes.publicLinkLimitEnabled == true ? attributes.publicLinkLimit : nil }
}

public struct ASCBetaTesterAttributes: ASCAttributes, Equatable {
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var inviteType: String?
    public var state: String?
    public init() {}
}

/// A beta tester of the team (one per email address, across apps).
public typealias ASCBetaTester = ASCKeptResource<ASCBetaTesterAttributes>

extension ASCKeptResource where A == ASCBetaTesterAttributes {
    public var email: String { attributes.email ?? "" }
    public var fullName: String { [attributes.firstName, attributes.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    /// The groups the tester is in, when the answer carried the linkage.
    public var groupIDs: [String]? { resource.relatedIDs("betaGroups") }
}

public struct ASCBetaAppLocalizationAttributes: ASCAttributes, Equatable {
    public var feedbackEmail: String?
    public var marketingUrl: String?
    public var privacyPolicyUrl: String?
    public var tvOsPrivacyPolicy: String?
    public var description: String?
    public var locale: String?
    public init() {}
}

/// The app's beta description, feedback email and URLs, for one locale.
public typealias ASCBetaAppLocalization = ASCKeptResource<ASCBetaAppLocalizationAttributes>

/// The beta App Review details, read without the demo account's password (xless never asks for it).
public struct ASCBetaReviewDetailAttributes: ASCAttributes, Equatable {
    public var contactFirstName: String?
    public var contactLastName: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var demoAccountName: String?
    public var demoAccountRequired: Bool?
    public var notes: String?
    public init() {}
    /// Every attribute but `demoAccountPassword`: the sparse fieldset of every read.
    public static let fields = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName", "demoAccountRequired", "notes"]
}

public typealias ASCBetaReviewDetail = ASCKeptResource<ASCBetaReviewDetailAttributes>

extension ASCKeptResource where A == ASCBetaReviewDetailAttributes {
    /// The details without `demoAccountPassword`, whatever App Store Connect answered (a PATCH answer cannot be narrowed
    /// with a sparse fieldset): what xless keeps and prints.
    public var withoutPassword: ASCBetaReviewDetail {
        var r = resource
        r.attributes?["demoAccountPassword"] = nil
        return ASCBetaReviewDetail(resource: r)
    }
}

public struct ASCBetaLicenseAttributes: ASCAttributes, Equatable {
    public var agreementText: String?
    public init() {}
}

public typealias ASCBetaLicense = ASCKeptResource<ASCBetaLicenseAttributes>

public struct ASCBetaSubmissionAttributes: ASCAttributes, Equatable {
    public var betaReviewState: String?
    public var submittedDate: String?
    public init() {}
}

/// A build's beta app review submission.
public typealias ASCBetaSubmission = ASCKeptResource<ASCBetaSubmissionAttributes>

public struct ASCBetaBuildLocalizationAttributes: ASCAttributes, Equatable {
    public var locale: String?
    public var whatsNew: String?
    public init() {}
}

/// A build's "What to Test", for one locale.
public typealias ASCBetaBuildLocalization = ASCKeptResource<ASCBetaBuildLocalizationAttributes>

/// A tester to add: the email address, and the names a new tester gets.
public struct BetaTesterRequest: Sendable, Equatable {
    public var email: String
    public var firstName: String?
    public var lastName: String?
    public init(email: String, firstName: String? = nil, lastName: String? = nil) {
        self.email = email; self.firstName = firstName; self.lastName = lastName
    }
}

/// An email address as TestFlight takes it: `UserEmail`'s rules, and no comma (`filter[email]` splits on commas).
public enum BetaTesterEmail {
    public static func validate(_ raw: String) throws -> String {
        let email = try UserEmail.validate(raw)
        if email.contains(",") { throw IdentifierInputError("\(email) is not an email address (it has a comma)") }
        return email
    }
}

/// The beta information texts to set for one locale; nil leaves a field as it is, "" clears it.
public struct BetaInfoText: Sendable, Equatable {
    public var description: String?
    public var feedbackEmail: String?
    public var marketingURL: String?
    public var privacyPolicyURL: String?
    public init(description: String? = nil, feedbackEmail: String? = nil, marketingURL: String? = nil, privacyPolicyURL: String? = nil) {
        self.description = description; self.feedbackEmail = feedbackEmail; self.marketingURL = marketingURL; self.privacyPolicyURL = privacyPolicyURL
    }
    public var isEmpty: Bool { description == nil && feedbackEmail == nil && marketingURL == nil && privacyPolicyURL == nil }
}

/// The beta App Review details to set; nil leaves a field as it is.
public struct BetaReviewChange: Sendable, Equatable {
    public var contactFirstName: String?
    public var contactLastName: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var notes: String?
    public var demoAccountName: String?
    public var demoAccountRequired: Bool?
    /// The secret holding the demo account's password (`XLESS_DEMO_PASSWORD` by default).
    public var passwordSecret: String
    /// Send the password even when nothing about the demo account changed (it was changed at Apple's end).
    public var resendDemoAccount: Bool

    public static let defaultPasswordSecret = "XLESS_DEMO_PASSWORD"

    public init(contactFirstName: String? = nil, contactLastName: String? = nil, contactPhone: String? = nil, contactEmail: String? = nil,
                notes: String? = nil, demoAccountName: String? = nil, demoAccountRequired: Bool? = nil,
                passwordSecret: String = defaultPasswordSecret, resendDemoAccount: Bool = false) {
        self.contactFirstName = contactFirstName; self.contactLastName = contactLastName; self.contactPhone = contactPhone
        self.contactEmail = contactEmail; self.notes = notes; self.demoAccountName = demoAccountName
        self.demoAccountRequired = demoAccountRequired; self.passwordSecret = passwordSecret; self.resendDemoAccount = resendDemoAccount
    }

    /// Whether the change says anything about the demo account: only then may the password go along.
    public var touchesDemoAccount: Bool { demoAccountName != nil || demoAccountRequired != nil || resendDemoAccount }

    /// What differs from `have`: the attributes to send, the names of the fields that change, and whether the demo account's
    /// password goes along. Apple never gives the password back, so it cannot be compared: it is sent when the demo account
    /// is (or becomes) required and it had no name, its name changes, it becomes required, or on `resendDemoAccount`.
    public func diff(from have: ASCBetaReviewDetailAttributes) -> (attributes: [String: JSONValue], fields: [String], password: Bool) {
        var attributes: [String: JSONValue] = [:]
        var fields: [String] = []
        func text(_ name: String, _ want: String?, _ current: String?) {
            guard let want else { return }
            let w = want.trimmingCharacters(in: .whitespacesAndNewlines)
            if w != (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { attributes[name] = .string(w); fields.append(name) }
        }
        text("contactFirstName", contactFirstName, have.contactFirstName)
        text("contactLastName", contactLastName, have.contactLastName)
        text("contactPhone", contactPhone, have.contactPhone)
        text("contactEmail", contactEmail, have.contactEmail)
        text("notes", notes, have.notes)
        let before = fields.count
        text("demoAccountName", demoAccountName, have.demoAccountName)
        let nameChanged = fields.count > before
        var becameRequired = false
        if let required = demoAccountRequired, required != (have.demoAccountRequired ?? false) {
            attributes["demoAccountRequired"] = .bool(required); fields.append("demoAccountRequired")
            becameRequired = required
        }
        let required = demoAccountRequired ?? have.demoAccountRequired ?? false
        let hadName = !(have.demoAccountName ?? "").isEmpty
        let password = touchesDemoAccount && required && (nameChanged || becameRequired || !hadName || resendDemoAccount)
        if password {
            if attributes["demoAccountName"] == nil, let name = demoAccountName ?? have.demoAccountName { attributes["demoAccountName"] = .string(name) }
            fields.append("demoAccountPassword")
        }
        return (attributes, fields, password)
    }
}

extension ASCError {
    /// The error without `value`, wherever App Store Connect's answer repeated it (a password sent in the request).
    public func scrubbing(_ value: String) -> ASCError {
        guard !value.isEmpty else { return self }
        var e = self
        func clean(_ s: String?) -> String? { s?.replacingOccurrences(of: value, with: HTTPTrace.placeholder) }
        e.items = items.map { item in
            var i = item
            i.title = clean(i.title); i.detail = clean(i.detail); i.code = clean(i.code)
            if let source = i.source { i.source = .init(pointer: clean(source.pointer), parameter: clean(source.parameter)) }
            return i
        }
        return e
    }
}

/// The TestFlight operations, on the App Store Connect API key (App Manager is enough, but checking that an internal
/// tester is a user of the team reads /v1/users, which needs Admin: without it Apple decides).
public struct ASCTestFlight: Sendable {
    public let resources: ASCResources
    public init(resources: ASCResources) { self.resources = resources }

    public enum Outcome<R: Sendable>: Sendable {
        case created(R)
        case updated(R)
        /// Already as asked: nothing was sent.
        case unchanged(R)

        public var value: R {
            switch self { case .created(let r), .updated(let r), .unchanged(let r): r }
        }
    }

    // MARK: Groups

    /// Every group of the app, sorted by name, then ID. No `filter[name]`: ASC splits it on commas.
    public func groups(app appID: String) async throws -> [ASCBetaGroup] {
        let items = try await resources.list("/v1/betaGroups", query: ASCQuery(filters: [("app", appID)]), as: ASCBetaGroup.self).items
        return items.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The group a command names, among `groups`: its exact (case-sensitive) name, else its ID.
    public static func pick(_ text: String, from groups: [ASCBetaGroup]) -> ASCBetaGroup? {
        groups.first { $0.name == text } ?? groups.first { $0.id == text }
    }

    /// The app's group named `text` (exact name, else ID); an error listing the app's groups when there is none.
    public func group(_ text: String, app appID: String, display: String? = nil) async throws -> ASCBetaGroup {
        let all = try await groups(app: appID)
        if let g = Self.pick(text, from: all) { return g }
        throw Self.noGroup(text, app: display ?? appID, among: all)
    }

    /// The error for a group name (or ID) that is none of `all`.
    public static func noGroup(_ text: String, app: String, among all: [ASCBetaGroup]) -> XlessError {
        let names = all.map { "\($0.name) (\($0.kind))" }
        return XlessError(.account, "\(app) has no TestFlight group named \(text)",
                          fix: names.isEmpty ? "create one with `xless testflight groups create \"\(text)\" --app \(app)`"
                              : "use one of: \(names.joined(separator: ", ")) (names are case-sensitive), or create it with `xless testflight groups create`")
    }

    /// Creates the group, unless the app already has one with that exact name: then that one is returned and nothing is
    /// sent (an error when it is of the other kind). `allBuilds` (automatic distribution) is for internal groups only.
    public func createGroup(name: String, app appID: String, external: Bool, allBuilds: Bool = false, feedback: Bool? = nil,
                            existing: [ASCBetaGroup]? = nil) async throws -> Outcome<ASCBetaGroup> {
        var all = existing ?? []
        if existing == nil { all = try await groups(app: appID) }
        if let found = all.first(where: { $0.name == name }) {
            guard found.isInternal == !external else {
                throw XlessError(.account, "the TestFlight group \(name) already exists as an \(found.kind) group (\(found.id)); a group cannot change between internal and external",
                                 fix: "choose another name, or use the existing group as it is")
            }
            return .unchanged(found)
        }
        struct Attributes: Encodable, Sendable { var name: String; var isInternalGroup: Bool; var hasAccessToAllBuilds: Bool?; var feedbackEnabled: Bool? }
        struct Relationships: Encodable, Sendable { var app: ASCToOne }
        let attributes = Attributes(name: name, isInternalGroup: !external, hasAccessToAllBuilds: external ? nil : allBuilds, feedbackEnabled: feedback)
        do {
            let created: ASCSingle<ASCBetaGroup> = try await resources.create("/v1/betaGroups", type: "betaGroups", attributes: attributes,
                                                                             relationships: Relationships(app: ASCToOne(ASCRef(type: "apps", id: appID))))
            return .created(created.data)
        } catch let e as ASCError where e.status == 409 {
            if let found = try await groups(app: appID).first(where: { $0.name == name && $0.isInternal == !external }) { return .unchanged(found) }
            throw e
        }
    }

    /// The settings `updateGroup` changes; nil leaves one as it is.
    public struct GroupChange: Sendable, Equatable {
        public var name: String?
        public var feedback: Bool?
        public var publicLink: Bool?
        /// `.some(nil)`: no limit; `.some(n)`: at most n testers through the public link.
        public var publicLinkLimit: Int??
        public init(name: String? = nil, feedback: Bool? = nil, publicLink: Bool? = nil, publicLinkLimit: Int?? = nil) {
            self.name = name; self.feedback = feedback; self.publicLink = publicLink; self.publicLinkLimit = publicLinkLimit
        }
    }

    /// Sends what differs from the group in one PATCH; nil when nothing differs and nothing was sent.
    public func updateGroup(_ group: ASCBetaGroup, _ change: GroupChange) async throws -> ASCBetaGroup? {
        let a = group.attributes
        var attributes: [String: JSONValue] = [:]
        if let name = change.name, name != group.name { attributes["name"] = .string(name) }
        if let f = change.feedback, f != (a.feedbackEnabled ?? false) { attributes["feedbackEnabled"] = .bool(f) }
        if let p = change.publicLink, p != (a.publicLinkEnabled ?? false) { attributes["publicLinkEnabled"] = .bool(p) }
        if let limit = change.publicLinkLimit {
            if let n = limit {
                if a.publicLinkLimitEnabled != true { attributes["publicLinkLimitEnabled"] = .bool(true) }
                if a.publicLinkLimit != n { attributes["publicLinkLimit"] = .int(n) }
            } else if a.publicLinkLimitEnabled == true {
                attributes["publicLinkLimitEnabled"] = .bool(false)
            }
        }
        guard !attributes.isEmpty else { return nil }
        let updated: ASCSingle<ASCBetaGroup> = try await resources.update("/v1/betaGroups/\(group.id)", type: "betaGroups", id: group.id,
                                                                         attributes: attributes)
        return updated.data
    }

    /// Deletes the group: its testers lose access to the builds they got through it.
    public func deleteGroup(_ group: ASCBetaGroup) async throws {
        do { try await resources.delete("/v1/betaGroups/\(group.id)") } catch let e as ASCError where e.status == 404 {}
    }

    // MARK: Testers

    static func testerQuery(_ filters: [(String, String)]) -> ASCQuery {
        ASCQuery(filters: filters, fields: [("betaGroups", ["name"])], include: ["betaGroups"], extra: [("limit[betaGroups]", "50")])
    }

    /// The app's testers (or only one group's), with their groups (`included`), sorted by email, then ID.
    public func testers(app appID: String, group groupID: String? = nil) async throws -> ASCListing<ASCBetaTester> {
        var filters = [("apps", appID)]
        if let groupID { filters.append(("betaGroups", groupID)) }
        var listing = try await resources.list("/v1/betaTesters", query: Self.testerQuery(filters), as: ASCBetaTester.self)
        listing.items.sort { ($0.email.lowercased(), $0.id) < ($1.email.lowercased(), $1.id) }
        return listing
    }

    /// The group's testers.
    public func members(of group: ASCBetaGroup) async throws -> [ASCBetaTester] {
        try await resources.list("/v1/betaTesters", query: ASCQuery(filters: [("betaGroups", group.id)]), as: ASCBetaTester.self).items
    }

    /// The team's beta tester with this address (compared without regard to case), in any app.
    public func findTester(email: String) async throws -> ASCBetaTester? {
        let found = try await resources.list("/v1/betaTesters", query: ASCQuery(filters: [("email", email)]), as: ASCBetaTester.self).items
        return found.first { UserEmail.same($0.email, email) }
    }

    /// The email addresses of the team's App Store Connect users (internal testers must be one); nil when the key may
    /// not read them (only Admin may), and then Apple decides.
    public func userEmails() async throws -> Set<String>? {
        do { return Set(try await ASCUsers(resources: resources).list().items.map { $0.email.lowercased() }) } catch let e as ASCError where e.status == 403 {
            return nil
        }
    }

    public enum TesterAddition: Sendable {
        /// A new tester, created in the group.
        case created(ASCBetaTester)
        /// An existing tester, added to the group.
        case added(ASCBetaTester)
        /// Already in the group: nothing was sent.
        case alreadyInGroup(ASCBetaTester)

        public var tester: ASCBetaTester {
            switch self { case .created(let t), .added(let t), .alreadyInGroup(let t): t }
        }
    }

    /// Adds someone to the group: nothing when they are among `members` already; an existing tester is linked; a new
    /// one is created with the group (sent once; a 409 is settled by looking the address up and linking it).
    /// - Parameters:
    ///   - members: the group's testers (`members(of:)`), read once for several additions.
    ///   - users: for an internal group, the team's user addresses (`userEmails()`), lower-cased; nil skips the check.
    public func add(_ request: BetaTesterRequest, to group: ASCBetaGroup, members: [ASCBetaTester], users: Set<String>?) async throws -> TesterAddition {
        if let member = members.first(where: { UserEmail.same($0.email, request.email) }) { return .alreadyInGroup(member) }
        if group.isInternal, let users, !users.contains(request.email.lowercased()) {
            throw XlessError(.account, "\(request.email) is not an App Store Connect user of this team, and the testers of an internal group (\(group.name)) must be",
                             fix: "invite them with `xless users invite \(request.email) --first-name <name> --last-name <name> --role developer --all-apps`, and add them once they accept; or use an external group")
        }
        if let tester = try await findTester(email: request.email) {
            try await link(tester, to: group)
            return .added(tester)
        }
        struct Attributes: Encodable, Sendable { var email: String; var firstName: String?; var lastName: String? }
        struct Relationships: Encodable, Sendable { var betaGroups: ASCToMany }
        do {
            let created: ASCSingle<ASCBetaTester> = try await resources.create(
                "/v1/betaTesters", type: "betaTesters", attributes: Attributes(email: request.email, firstName: request.firstName, lastName: request.lastName),
                relationships: Relationships(betaGroups: ASCToMany([ASCRef(type: "betaGroups", id: group.id)])))
            return .created(created.data)
        } catch let e as ASCError where e.status == 409 {
            guard let tester = try await findTester(email: request.email) else { throw e }
            if try await self.members(of: group).contains(where: { $0.id == tester.id }) { return .alreadyInGroup(tester) }
            try await link(tester, to: group)
            return .added(tester)
        }
    }

    func link(_ tester: ASCBetaTester, to group: ASCBetaGroup) async throws {
        try await resources.addRelationship("/v1/betaGroups/\(group.id)", "betaTesters", [ASCRef(type: "betaTesters", id: tester.id)])
    }

    /// Takes the testers out of the group (they keep other groups' builds).
    public func remove(_ testers: [ASCBetaTester], from group: ASCBetaGroup) async throws {
        guard !testers.isEmpty else { return }
        try await resources.removeRelationship("/v1/betaGroups/\(group.id)", "betaTesters", testers.map { ASCRef(type: "betaTesters", id: $0.id) })
    }

    /// Takes the testers out of the app: every group and build of it.
    public func remove(_ testers: [ASCBetaTester], fromApp appID: String) async throws {
        guard !testers.isEmpty else { return }
        try await resources.removeRelationship("/v1/apps/\(appID)", "betaTesters", testers.map { ASCRef(type: "betaTesters", id: $0.id) })
    }

    /// Has Apple email the tester an invitation to the app (again). Sent once.
    public func invite(_ tester: ASCBetaTester, app appID: String) async throws -> String? {
        struct Relationships: Encodable, Sendable { var betaTester: ASCToOne; var app: ASCToOne }
        struct Inner: Encodable, Sendable { var type = "betaTesterInvitations"; var relationships: Relationships }
        struct Body: Encodable, Sendable { var data: Inner }
        let body = Body(data: Inner(relationships: Relationships(betaTester: ASCToOne(ASCRef(type: "betaTesters", id: tester.id)),
                                                                 app: ASCToOne(ASCRef(type: "apps", id: appID)))))
        let response = try await resources.client.request("POST", "/v1/betaTesterInvitations", body: try JSONEncoder().encode(body), maxAttempts: 1)
        return (try? JSONDecoder().decode(ASCSingle<ASCAnyResource>.self, from: response.data))?.data.id
    }

    // MARK: Builds

    /// The IDs of the app's groups that have the build.
    public func groupIDs(with buildID: String, app appID: String) async throws -> Set<String> {
        let items = try await resources.list("/v1/betaGroups", query: ASCQuery(filters: [("app", appID), ("builds", buildID)], fields: [("betaGroups", ["name"])]),
                                             as: ASCRef.self).items
        return Set(items.map(\.id))
    }

    public func addBuild(_ buildID: String, to groups: [ASCBetaGroup]) async throws {
        guard !groups.isEmpty else { return }
        try await resources.addRelationship("/v1/builds/\(buildID)", "betaGroups", groups.map { ASCRef(type: "betaGroups", id: $0.id) })
    }

    public func removeBuild(_ buildID: String, from groups: [ASCBetaGroup]) async throws {
        guard !groups.isEmpty else { return }
        try await resources.removeRelationship("/v1/builds/\(buildID)", "betaGroups", groups.map { ASCRef(type: "betaGroups", id: $0.id) })
    }

    /// The build's "What to Test", every locale.
    public func whatsNew(build buildID: String) async throws -> [ASCBetaBuildLocalization] {
        try await resources.list("/v1/builds/\(buildID)/betaBuildLocalizations", as: ASCBetaBuildLocalization.self).items
            .sorted { ($0.attributes.locale ?? "") < ($1.attributes.locale ?? "") }
    }

    /// Sets the build's "What to Test" for `locale`: updates the localization, creates it, or sends nothing when the text
    /// is already that. A create that loses a race (409) updates the one App Store Connect made meanwhile.
    public func setWhatsNew(build buildID: String, locale: String, text: String) async throws -> Outcome<ASCBetaBuildLocalization> {
        func existing() async throws -> ASCBetaBuildLocalization? { try await whatsNew(build: buildID).first { $0.attributes.locale == locale } }
        func update(_ loc: ASCBetaBuildLocalization) async throws -> Outcome<ASCBetaBuildLocalization> {
            if loc.attributes.whatsNew == text { return .unchanged(loc) }
            let updated: ASCSingle<ASCBetaBuildLocalization> = try await resources.update(
                "/v1/betaBuildLocalizations/\(loc.id)", type: "betaBuildLocalizations", id: loc.id, attributes: ["whatsNew": text])
            return .updated(updated.data)
        }
        if let loc = try await existing() { return try await update(loc) }
        struct Relationships: Encodable, Sendable { var build: ASCToOne }
        do {
            let created: ASCSingle<ASCBetaBuildLocalization> = try await resources.create(
                "/v1/betaBuildLocalizations", type: "betaBuildLocalizations", attributes: ["locale": locale, "whatsNew": text],
                relationships: Relationships(build: ASCToOne(ASCRef(type: "builds", id: buildID))))
            return .created(created.data)
        } catch let e as ASCError where e.status == 409 {
            guard let loc = try await existing() else { throw e }
            return try await update(loc)
        }
    }

    // MARK: Beta information

    /// The app's beta localizations, sorted by locale.
    public func localizations(app appID: String) async throws -> [ASCBetaAppLocalization] {
        try await resources.list("/v1/apps/\(appID)/betaAppLocalizations", as: ASCBetaAppLocalization.self).items
            .sorted { ($0.attributes.locale ?? "") < ($1.attributes.locale ?? "") }
    }

    static func infoDiff(_ text: BetaInfoText, have: ASCBetaAppLocalizationAttributes?) -> [String: String] {
        var out: [String: String] = [:]
        func field(_ name: String, _ want: String?, _ current: String?) {
            guard let want else { return }
            let w = want.trimmingCharacters(in: .whitespacesAndNewlines)
            if w != (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { out[name] = w }
        }
        field("description", text.description, have?.description)
        field("feedbackEmail", text.feedbackEmail, have?.feedbackEmail)
        field("marketingUrl", text.marketingURL, have?.marketingUrl)
        field("privacyPolicyUrl", text.privacyPolicyURL, have?.privacyPolicyUrl)
        return out
    }

    /// Sets the beta texts of `locale`: what differs is sent (a missing locale is created); nothing when all match.
    public func setLocalization(app appID: String, locale: String, _ text: BetaInfoText,
                                existing: [ASCBetaAppLocalization]? = nil) async throws -> Outcome<ASCBetaAppLocalization>? {
        var all = existing ?? []
        if existing == nil { all = try await localizations(app: appID) }
        let current = all.first { $0.attributes.locale == locale }
        let diff = Self.infoDiff(text, have: current?.attributes)
        if let current {
            guard !diff.isEmpty else { return .unchanged(current) }
            let updated: ASCSingle<ASCBetaAppLocalization> = try await resources.update(
                "/v1/betaAppLocalizations/\(current.id)", type: "betaAppLocalizations", id: current.id, attributes: diff)
            return .updated(updated.data)
        }
        guard !diff.isEmpty else { return nil }
        struct Relationships: Encodable, Sendable { var app: ASCToOne }
        var attributes = diff
        attributes["locale"] = locale
        do {
            let created: ASCSingle<ASCBetaAppLocalization> = try await resources.create(
                "/v1/betaAppLocalizations", type: "betaAppLocalizations", attributes: attributes,
                relationships: Relationships(app: ASCToOne(ASCRef(type: "apps", id: appID))))
            return .created(created.data)
        } catch let e as ASCError where e.status == 409 {
            // Lost a race with a localization made meanwhile: set that one.
            let again = try await localizations(app: appID)
            guard again.contains(where: { $0.attributes.locale == locale }) else { throw e }
            return try await setLocalization(app: appID, locale: locale, text, existing: again)
        }
    }

    /// The app's beta App Review details, without the demo account's password.
    public func reviewDetail(app appID: String) async throws -> ASCBetaReviewDetail {
        try await resources.get("/v1/apps/\(appID)/betaAppReviewDetail",
                                query: ASCQuery(fields: [("betaAppReviewDetails", ASCBetaReviewDetailAttributes.fields)]), as: ASCBetaReviewDetail.self).data.withoutPassword
    }

    /// Sends what differs (`BetaReviewChange.diff`) in one PATCH; nil when nothing differs and nothing was sent. The
    /// password is read from `password` only when it goes along, hidden from traces, sent once and scrubbed from errors.
    public func updateReviewDetail(_ detail: ASCBetaReviewDetail, _ change: BetaReviewChange,
                                   password: (String) throws -> String) async throws -> ASCBetaReviewDetail? {
        let diff = change.diff(from: detail.attributes)
        guard !diff.attributes.isEmpty || diff.password else { return nil }
        var attributes = diff.attributes
        var secret = ""
        if diff.password {
            secret = try password(change.passwordSecret)
            HTTPTrace.hide(secret)
            attributes["demoAccountPassword"] = .string(secret)
        }
        struct Inner: Encodable, Sendable { var type = "betaAppReviewDetails"; var id: String; var attributes: [String: JSONValue] }
        struct Body: Encodable, Sendable { var data: Inner }
        let body = try JSONEncoder().encode(Body(data: Inner(id: detail.id, attributes: attributes)))
        do {
            let response = try await resources.client.request("PATCH", "/v1/betaAppReviewDetails/\(detail.id)", body: body,
                                                               maxAttempts: diff.password ? 1 : ASCClient.maxAttempts)
            return (try? JSONDecoder().decode(ASCSingle<ASCBetaReviewDetail>.self, from: response.data))?.data.withoutPassword ?? detail
        } catch let e as ASCError {
            throw e.scrubbing(secret)
        } catch {
            if !secret.isEmpty, "\(error)".contains(secret) {
                throw XlessError(.account, "sending the beta App Review details failed", fix: "re-run the command")
            }
            throw error
        }
    }

    public func license(app appID: String) async throws -> ASCBetaLicense {
        try await resources.get("/v1/apps/\(appID)/betaLicenseAgreement", as: ASCBetaLicense.self).data
    }

    /// Replaces the beta license agreement's text; nil when it already is that text.
    public func updateLicense(_ license: ASCBetaLicense, text: String) async throws -> ASCBetaLicense? {
        guard (license.attributes.agreementText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let updated: ASCSingle<ASCBetaLicense> = try await resources.update("/v1/betaLicenseAgreements/\(license.id)", type: "betaLicenseAgreements",
                                                                           id: license.id, attributes: ["agreementText": text])
        return updated.data
    }

    // MARK: Beta app review

    /// The build's beta app review submission; nil when it was never submitted.
    public func submission(build buildID: String) async throws -> ASCBetaSubmission? {
        try await resources.list("/v1/betaAppReviewSubmissions", query: ASCQuery(filters: [("build", buildID)]), as: ASCBetaSubmission.self).items.first
    }

    /// Submits the build for beta app review, unless it already was (then that submission, and nothing is sent).
    public func submit(build buildID: String) async throws -> Outcome<ASCBetaSubmission> {
        if let existing = try await submission(build: buildID) { return .unchanged(existing) }
        struct Relationships: Encodable, Sendable { var build: ASCToOne }
        struct Inner: Encodable, Sendable { var type = "betaAppReviewSubmissions"; var relationships: Relationships }
        struct Body: Encodable, Sendable { var data: Inner }
        do {
            let created: ASCSingle<ASCBetaSubmission> = try await resources.client.postOnce(
                "/v1/betaAppReviewSubmissions", body: Body(data: Inner(relationships: Relationships(build: ASCToOne(ASCRef(type: "builds", id: buildID))))))
            return .created(created.data)
        } catch let e as ASCError where e.status == 409 {
            if let existing = try await submission(build: buildID) { return .unchanged(existing) }
            throw e
        }
    }
}
