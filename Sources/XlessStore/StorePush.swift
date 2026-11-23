import Foundation
import XlessASC
import XlessCore

/// `xless store push`: makes App Store Connect's listing match the manifest, sending only what differs. It reads the
/// listing (documented API, API key), plans the changes part by part (`StorePushPart`), and applies the plan.
public struct StorePush: Sendable {
    public struct Options: Sendable {
        public var parts: [StorePushPart]
        /// Delete the localizations App Store Connect has and the manifest does not.
        public var prune: Bool
        /// Send the demo account's name and password even when they look unchanged (after a new password).
        public var resendDemoAccount: Bool
        /// The day prices are compared on: a scheduled price change from this day or earlier is in effect.
        public var today: Date
        /// Plan nothing that deletes (a change of action delete, or media that replaces or drops files): those changes
        /// go to `StorePlan.held` instead (`xless provision` never deletes; it reports them).
        public var holdDeletes: Bool

        public init(parts: [StorePushPart] = StorePushPart.allCases, prune: Bool = false, resendDemoAccount: Bool = false, today: Date = Date(),
                    holdDeletes: Bool = false) {
            self.parts = parts; self.prune = prune; self.resendDemoAccount = resendDemoAccount; self.today = today
            self.holdDeletes = holdDeletes
        }

        /// What `xless provision` pushes: every part but App Privacy (planned on its own, through the web session),
        /// products included, and nothing that deletes (held back and reported as drift).
        public static func provision(today: Date = Date()) -> Options {
            Options(parts: StorePushPart.allCases.filter { $0 != .privacy }, today: today, holdDeletes: true)
        }
    }

    /// What `push` prints (`--json`: this document).
    public struct Report: Encodable, Sendable, Equatable {
        public struct Change: Encodable, Sendable, Equatable {
            public var action: StoreChange.Action
            public var part: StorePushPart
            public var subject: String
            public var fields: [StoreFieldChange]

            init(_ c: StoreChange) { action = c.action; part = c.part; subject = c.subject; fields = c.fields }
        }

        public var appID: String
        public var bundleID: String
        public var platform: String
        public var version: String
        /// The version's state at App Store Connect, or `new` when push creates it.
        public var versionState: String
        public var dryRun: Bool
        /// Changes sent (all of them, unless one failed or a question was answered no); 0 on a dry run.
        public var applied: Int
        /// The plan; once sent, the changes sent (after a new version, those planned again against it).
        public var changes: [Change]
        public var notes: [String]
        let plan: StorePlan

        enum CodingKeys: String, CodingKey { case appID, bundleID, platform, version, versionState, dryRun, applied, changes, notes }

        init(target: Target, plan: StorePlan) {
            appID = target.app.id; bundleID = target.app.bundleID; platform = target.platform; version = target.versionString
            versionState = target.versionState; dryRun = true; applied = 0
            changes = plan.changes.map(Change.init)
            notes = plan.notes
            self.plan = plan
        }

        /// The plan, one change per line (`+` create, `~` update, `-` delete), and its summary.
        public var planText: String { "\(bundleID) (\(platform) \(version), \(versionState)):\n" + plan.text }

        /// After sending: what was sent, and the notes of every plan.
        public mutating func record(_ result: StorePush.Applied) {
            dryRun = false
            applied = result.sent.count
            changes = result.sent.map(Change.init)
            for note in result.notes where !notes.contains(note) { notes.append(note) }
        }
    }

    /// What `apply` sent, and what planning again (after a new version) noted.
    public struct Applied: Sendable {
        public var sent: [StoreChange] = []
        public var notes: [String] = []
        /// The plan made once the new version existed, when there was one.
        public var replanned: StorePlan?
    }

    public let asc: StoreASC
    /// App Privacy through the Apple ID web session; nil when this push has none (the part is then only noted).
    public let privacy: StorePrivacy?
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, privacy: (any PrivacyRemote)? = nil, say: @escaping @Sendable (String) -> Void = { _ in }) {
        asc = StoreASC(resources: resources, say: say)
        self.privacy = privacy.map(StorePrivacy.init)
        self.say = say
    }

    // MARK: - The target

    /// The App Store version the manifest describes and the app information that goes with it.
    struct Target: Sendable {
        enum Version: Sendable {
            /// The manifest's version exists.
            case existing(ASCKeptResource<StoreVersionAttributes>)
            /// Another version of the platform is being prepared: it becomes the manifest's (versionString).
            case rename(ASCKeptResource<StoreVersionAttributes>)
            /// No version can take it: push creates it.
            case create
        }

        var app: ASCApp
        var platform: String
        var versionString: String
        var version: Version
        /// The app information to change: the one being edited, else (to compare with) the live one.
        var info: ASCKeptResource<StoreAppInfoAttributes>?
        var infoEditable: Bool

        var versionID: String? {
            switch version {
            case .existing(let v), .rename(let v): v.id
            case .create: nil
            }
        }

        var creating: Bool { if case .create = version { return true }; return false }

        /// The manifest describes the version on the App Store.
        var live: Bool { if case .existing(let v) = version { return StorePull.isLive(v.attributes) }; return false }

        var editable: Bool {
            switch version {
            case .existing(let v): StorePull.isEditable(v.attributes)
            case .rename, .create: true
            }
        }

        var versionState: String {
            switch version {
            case .existing(let v), .rename(let v): v.attributes.appVersionState ?? v.attributes.appStoreState ?? ""
            case .create: "new"
            }
        }
    }

    func target(app: ASCApp, manifest: StoreManifest) async throws -> Target {
        let platform = manifest.app.platform ?? "IOS"
        guard let wanted = manifest.app.version else {
            throw XlessError(.account, "app.yml has no version: push needs to know which App Store version the listing is for",
                             fix: "add `version: \"1.0\"` to app.yml")
        }
        let versions = try await asc.versions(of: app.id).filter { $0.attributes.platform == platform }
        let version: Target.Version
        if let found = versions.first(where: { $0.attributes.versionString == wanted }) {
            version = .existing(found)
        } else if let editable = versions.first(where: { StorePull.isEditable($0.attributes) }) {
            version = .rename(editable)
        } else {
            version = .create
        }
        let infos = try await asc.appInfos(of: app.id)
        let editableInfo = infos.first { Self.isEditableInfo($0.attributes) }
        let liveInfo = infos.first { StorePull.isLiveInfo($0.attributes) }
        // A manifest of the live version (`pull --live`) is compared with the live app information, as pull read it.
        if case .existing(let v) = version, StorePull.isLive(v.attributes) {
            return Target(app: app, platform: platform, versionString: wanted, version: version, info: liveInfo ?? infos.first, infoEditable: false)
        }
        let info = editableInfo ?? liveInfo ?? infos.first
        return Target(app: app, platform: platform, versionString: wanted, version: version, info: info, infoEditable: editableInfo != nil)
    }

    static func isEditableInfo(_ i: StoreAppInfoAttributes) -> Bool {
        [i.state, i.appStoreState].contains { $0.map(StorePull.editableStates.contains) ?? false }
    }

    // MARK: - Plan

    /// The changes the manifest at `dir` needs, part by part, with notes. Reads only.
    public func plan(app: ASCApp, manifest: StoreManifest, dir: URL, options: Options = Options()) async throws -> (StorePlan, Report) {
        let target = try await target(app: app, manifest: manifest)
        var context = PushContext(push: self, manifest: manifest, dir: dir, target: target, options: options)
        // Pricing, App Privacy and the products are the app's, not the version's: they need no version.
        if target.creating, !options.parts.contains(.text), options.parts.contains(where: { ![.text, .pricing, .privacy, .iap, .subscriptions].contains($0) }) {
            throw XlessError(.account, "App Store Connect has no \(target.platform) version \(target.versionString) yet, and only the text part creates it",
                             fix: "push the text part too (drop --only, or add text to it)")
        }
        for part in options.parts {
            switch part {
            case .text: try await context.planText()
            case .review: try await context.planReview()
            case .declarations: try await context.planDeclarations()
            case .pricing: try await context.planPricing()
            case .privacy: try await context.planPrivacy()
            case .iap: try await context.planInAppPurchases()
            case .subscriptions: try await context.planSubscriptions()
            case .media: try await context.planMedia()
            }
        }
        var plan = context.plan
        // The new version comes first: the rest is planned again once it exists.
        plan.changes = plan.changes.filter(\.replans) + plan.changes.filter { !$0.replans }
        if options.holdDeletes {
            plan.held = plan.changes.filter(\.deletes)
            plan.changes.removeAll(where: \.deletes)
        }
        return (plan, Report(target: target, plan: plan))
    }

    // MARK: - Apply

    /// Sends the plan's changes in order. After a change that `replans` (a new version), the rest is planned again
    /// against what App Store Connect now has: that plan is shown (`show`), its deletions confirmed (`confirm`; no
    /// sends nothing more), then sent.
    public func apply(_ plan: StorePlan, app: ASCApp, manifest: StoreManifest, dir: URL, options: Options = Options(), sender: StoreSender,
                      show: (StorePlan) -> Void = { _ in }, confirm: (StorePlan) throws -> Bool = { _ in true }) async throws -> Applied {
        // A secret is read before the first write: a missing one stops the push with nothing sent.
        for name in Set(plan.changes.flatMap(\.requests).compactMap(\.secret)).sorted() { _ = try sender.value(of: name) }
        var result = Applied()
        // What was uploaded stays recorded in media.lock, even when a later change fails.
        defer { recordLock([plan] + (result.replanned.map { [$0] } ?? []), sender: sender, dir: dir) }
        func send(_ changes: [StoreChange], of total: Int) async throws {
            for change in changes {
                defer {
                    for note in sender.record.takeNotes() {
                        say("note: \(note)")
                        result.notes.append(note)
                    }
                }
                do {
                    if change.privacy != nil {
                        guard let privacy else { throw XlessError(.account, "App Privacy needs the Apple ID web session", fix: "this is a bug in xless; please report it") }
                        try await privacy.apply(change, app: app.id)
                    } else {
                        try await sender.apply(change)
                    }
                } catch {
                    let n = result.sent.count
                    say("note: \(n) of \(total) change\(total == 1 ? "" : "s") \(n == 1 ? "was" : "were") sent before this failure; re-run `xless store push` to send the rest (it sends only what still differs)")
                    throw error
                }
                result.sent.append(change)
            }
        }
        // Changes that create what the rest depends on (a new version, a new in-app purchase, a subscription group)
        // come first: they are sent, then the rest is planned again against what App Store Connect now has, which
        // may create again (a subscription in a group just created), up to `maxReplans` rounds.
        var current = plan
        var total = plan.changes.count
        var created: [String] = []
        var rounds = 0
        while true {
            let leading = Array(current.changes.prefix { $0.replans })
            guard !leading.isEmpty else {
                try await send(current.changes, of: total)
                return result
            }
            try await send(leading, of: total)
            created += leading.map(Self.createdName)
            let what = Self.list(created)
            rounds += 1
            let next: StorePlan
            do {
                next = try await self.plan(app: app, manifest: manifest, dir: dir, options: options).0
            } catch {
                say("note: the \(what) \(created.count == 1 ? "was" : "were") created; re-run `xless store push` to send the rest")
                throw error
            }
            if let again = next.changes.first(where: { $0.replans && created.contains(Self.createdName($0)) }) {
                throw XlessError(.account, "App Store Connect does not show the \(Self.createdName(again)) push just created",
                                 fix: "wait a minute and re-run `xless store push`")
            }
            if rounds >= Self.maxReplans, next.changes.contains(where: \.replans) {
                throw XlessError(.account, "the \(what) \(created.count == 1 ? "was" : "were") created, but more remains to create than one push plans",
                                 fix: "re-run `xless store push` to send the rest")
            }
            result.replanned = next
            for note in next.notes where !result.notes.contains(note) { result.notes.append(note) }
            show(next)
            guard try confirm(next) else {
                say("cancelled; the \(what) \(created.count == 1 ? "was" : "were") created, nothing else was sent")
                return result
            }
            current = next
            total = result.sent.count + next.changes.count
        }
    }

    /// How many times `apply` plans again after creating.
    static let maxReplans = 3

    /// What a replanning change creates, as messages name it: `IOS version 1.1`, `in-app purchase com.example.coins`.
    static func createdName(_ change: StoreChange) -> String {
        // `version 1.1 (IOS)` → `IOS version 1.1`
        let s = change.subject
        if s.hasPrefix("version "), s.hasSuffix(")"), let open = s.lastIndex(of: "(") {
            let version = s[s.index(s.startIndex, offsetBy: "version ".count)..<open].trimmingCharacters(in: .whitespaces)
            return "\(s[s.index(after: open)..<s.index(before: s.endIndex)]) version \(version)"
        }
        return s
    }

    /// `a`, `a and b`, `a, b and c`.
    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

extension StorePush {
    /// Updates `dir`'s media.lock with what the plans matched and the sender uploaded and deleted; a lock that cannot
    /// be written is only a note (it is a cache: the next push compares with App Store Connect anyway).
    func recordLock(_ plans: [StorePlan], sender: StoreSender, dir: URL) {
        var lock = MediaLock.read(dir)
        let before = lock
        let deleted = sender.record.deleted
        for (path, entry) in lock.files.values where entry.id.map(deleted.contains) == true { lock.files[path] = nil }
        for plan in plans { for (path, entry) in plan.lock { lock.files[path] = entry } }
        for (path, entry) in sender.record.uploads { lock.files[path] = entry }
        guard lock != before else { return }
        do { try lock.write(to: dir) } catch {
            say("note: \(dir.lastPathComponent)/\(MediaLock.fileName) could not be written (\(error.localizedDescription)); the next push still uploads nothing App Store Connect has")
        }
    }
}

/// The planners' shared state: what is being pushed, against what, and the plan so far.
struct PushContext {
    let push: StorePush
    let manifest: StoreManifest
    let dir: URL
    let target: StorePush.Target
    let options: StorePush.Options
    var plan = StorePlan()

    var asc: StoreASC { push.asc }
    var app: AppYAML { manifest.app }
    var name: String { dir.lastPathComponent }

    mutating func add(_ change: StoreChange) { plan.changes.append(change) }

    /// The `privacy` part: app.yml's App Privacy answers against App Store Connect's (web session), then published.
    mutating func planPrivacy() async throws {
        guard let wanted = app.privacy else { return }
        guard let privacy = push.privacy else {
            note("privacy is not pushed: App Privacy needs the Apple ID web session (`xless store privacy push`, or keep a session first with `xless auth login --keep 30m`)")
            return
        }
        for change in try await privacy.plan(wanted, app: target.app.id, appName: target.app.bundleID) { add(change) }
    }
    mutating func note(_ text: String) { plan.notes.append(text) }

    /// Refuses a change to a version App Store Connect no longer lets anyone edit.
    func requireEditableVersion(_ what: String) throws {
        guard target.editable else {
            throw XlessError(.account, "\(what) differs, but \(target.platform) version \(target.versionString) is \(target.versionState) and cannot be edited",
                             fix: "set app.yml's version to the next version (push creates it), or `xless store pull` to take App Store Connect's values")
        }
    }

    /// Refuses a change to app information that only changes with a new version.
    func requireEditableInfo(_ what: String) throws {
        guard target.infoEditable || target.creating else {
            throw XlessError(.account, "\(what) differs, but the app information is live and changes only with a new version",
                             fix: "set app.yml's version to the next version (push creates it with new app information), or `xless store pull`")
        }
    }
}

/// The fields of one resource that differ, as plan lines and as the attributes to send.
struct FieldDiff {
    var fields: [StoreFieldChange] = []
    var attributes: [String: JSONValue] = [:]

    var isEmpty: Bool { fields.isEmpty }

    /// A text attribute: `want` is the manifest's (nil: not set), `have` Apple's (normalised as `pull` writes it). A
    /// difference sets the attribute, or clears it (`null`) when `clears`, or when the manifest says so with "".
    mutating func text(_ name: String, want: String?, have: String?, isURL: Bool = false, clears: Bool = true) {
        let current = have.flatMap { ManifestText.normalize($0, isURL: isURL) }
        let wanted = want.flatMap { ManifestText.normalize($0, isURL: isURL) }
        guard wanted != current, wanted != nil || clears || want != nil else { return }
        attributes[name] = wanted.map { .string($0) } ?? .null
        fields.append(StoreFieldChange(name, from: current, to: wanted))
    }

    /// A value managed only when the manifest gives one.
    mutating func value(_ name: String, want: StoreScalar?, have: StoreScalar?) {
        guard let want, !want.same(have) else { return }
        attributes[name] = want.json
        fields.append(StoreFieldChange(name, from: have?.description, to: want.description))
    }
}

extension StoreScalar {
    var json: JSONValue {
        switch self {
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        }
    }

    init?(_ json: JSONValue?) {
        switch json {
        case .bool(let b)?: self = .bool(b)
        case .int(let i)?: self = .int(i)
        case .double(let d)?: self = .double(d)
        case .string(let s)?: self = .string(s)
        default: return nil
        }
    }

    /// Equal as App Store Connect means it: 1 and 1.0 are the same number.
    func same(_ other: StoreScalar?) -> Bool {
        switch (self, other) {
        case (.int(let a), .double(let b)?): Double(a) == b
        case (.double(let a), .int(let b)?): a == Double(b)
        default: self == other
        }
    }
}
