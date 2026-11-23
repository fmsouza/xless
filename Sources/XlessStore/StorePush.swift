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

        public init(parts: [StorePushPart] = StorePushPart.allCases, prune: Bool = false, resendDemoAccount: Bool = false) {
            self.parts = parts; self.prune = prune; self.resendDemoAccount = resendDemoAccount
        }
    }

    /// What `push` prints (`--json`: this document).
    public struct Report: Encodable, Sendable, Equatable {
        public struct Change: Encodable, Sendable, Equatable {
            public var action: StoreChange.Action
            public var part: StorePushPart
            public var subject: String
            public var fields: [StoreFieldChange]
        }

        public var appID: String
        public var bundleID: String
        public var platform: String
        public var version: String
        /// The version's state at App Store Connect, or `new` when push creates it.
        public var versionState: String
        public var dryRun: Bool
        /// Changes sent (all of them, unless one failed); 0 on a dry run.
        public var applied: Int
        public var changes: [Change]
        public var notes: [String]
        let plan: StorePlan

        enum CodingKeys: String, CodingKey { case appID, bundleID, platform, version, versionState, dryRun, applied, changes, notes }

        init(target: Target, plan: StorePlan) {
            appID = target.app.id; bundleID = target.app.bundleID; platform = target.platform; version = target.versionString
            versionState = target.versionState; dryRun = true; applied = 0
            changes = plan.changes.map { Change(action: $0.action, part: $0.part, subject: $0.subject, fields: $0.fields) }
            notes = plan.notes
            self.plan = plan
        }

        /// The plan, one change per line (`+` create, `~` update, `-` delete), and its summary.
        public var planText: String {
            var out = "\(bundleID) (\(platform) \(version), \(versionState)):\n"
            for change in plan.changes {
                out += change.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n") + "\n"
            }
            return out + plan.summary + "\n"
        }
    }

    public let asc: StoreASC
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, say: @escaping @Sendable (String) -> Void = { _ in }) {
        asc = StoreASC(resources: resources, say: say)
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
        let info = editableInfo ?? infos.first { StorePull.isLiveInfo($0.attributes) } ?? infos.first
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
        if target.creating, !options.parts.contains(.text), options.parts.contains(where: { $0 != .text }) {
            throw XlessError(.account, "App Store Connect has no \(target.platform) version \(target.versionString) yet, and only the text part creates it",
                             fix: "push the text part too (drop --only, or add text to it)")
        }
        for part in options.parts {
            switch part {
            case .text: try await context.planText()
            case .review: try await context.planReview()
            case .declarations: try await context.planDeclarations()
            }
        }
        var plan = context.plan
        // The new version comes first: the rest is planned again once it exists.
        plan.changes = plan.changes.filter(\.replans) + plan.changes.filter { !$0.replans }
        return (plan, Report(target: target, plan: plan))
    }

    // MARK: - Apply

    /// Sends the plan's changes in order. After a change that `replans` (a new version), the rest is planned again
    /// against what App Store Connect now has, and that plan is applied. Returns how many changes were sent.
    public func apply(_ plan: StorePlan, app: ASCApp, manifest: StoreManifest, dir: URL, options: Options = Options(),
                      sender: StoreSender) async throws -> Int {
        // A secret is read before the first write: a missing one stops the push with nothing sent.
        for name in Set(plan.changes.flatMap(\.requests).compactMap(\.secret)).sorted() { _ = try sender.value(of: name) }
        var applied = 0
        func send(_ changes: [StoreChange], of total: Int) async throws {
            for change in changes {
                do { try await sender.apply(change) } catch {
                    say("note: \(applied) of \(total) change\(total == 1 ? " was" : "s were") sent before this failure; re-run `xless store push` to send the rest (it sends only what still differs)")
                    throw error
                }
                applied += 1
            }
        }
        if let index = plan.changes.firstIndex(where: \.replans) {
            try await send(Array(plan.changes[...index]), of: plan.changes.count)
            let (next, _) = try await self.plan(app: app, manifest: manifest, dir: dir, options: options)
            if next.changes.contains(where: \.replans) {
                throw XlessError(.account, "App Store Connect does not show the \(manifest.app.platform ?? "IOS") version \(manifest.app.version ?? "") push just created",
                                 fix: "wait a minute and re-run `xless store push`")
            }
            try await send(next.changes, of: applied + next.changes.count)
        } else {
            try await send(plan.changes, of: plan.changes.count)
        }
        return applied
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
    /// difference sets the attribute, or clears it (`null`) unless `clears` is false.
    mutating func text(_ name: String, want: String?, have: String?, isURL: Bool = false, clears: Bool = true) {
        let current = have.flatMap { ManifestText.normalize($0, isURL: isURL) }
        guard want != current, want != nil || clears else { return }
        attributes[name] = want.map { .string($0) } ?? .null
        fields.append(StoreFieldChange(name, from: current, to: want))
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
