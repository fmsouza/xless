import Foundation
import XlessASC
import XlessCore
import XlessStore

/// `xless release submit`'s exit codes besides 0 (submitted) and 20 (any other `[account]` error).
enum ReleaseExit {
    static let preflightFailed: Int32 = 21
    static let alreadyInReview: Int32 = 22
}

/// Which app, platform and version a release command is about, as the command line and app.yml give them.
struct ReleaseWanted: Sendable, Equatable {
    /// An app ID or bundle identifier.
    var app: String
    /// IOS, MAC_OS, TV_OS or VISION_OS; nil: the app's only platform.
    var platform: String?
    /// The version string; nil: the command's default version.
    var version: String?
}

/// What the `xless release` commands do once their arguments are valid; returns what goes to standard output and says the
/// rest (notes, cancellations) on standard error.
struct ReleaseCLI {
    let resources: ASCResources
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    var release: ASCRelease { ASCRelease(resources: resources) }

    struct Target {
        var app: ASCApp
        var platform: String
        var version: ASCAppStoreVersion
        var name: String { "\(app.bundleID) \(version.display)" }
    }

    /// The app's platform: the one asked, else the only one its versions have.
    static func platform(_ wanted: String?, among versions: [ASCAppStoreVersion], app: ASCApp) throws -> String {
        if let wanted { return wanted }
        let platforms = Set(versions.map(\.platform)).sorted()
        guard platforms.count <= 1 else {
            throw XlessError(.account, "\(app.bundleID) has versions for \(platforms.map(BuildPlatform.display).joined(separator: " and "))",
                             fix: "pass --platform \(platforms.map(BuildPlatform.display).joined(separator: " or "))")
        }
        return platforms.first ?? "IOS"
    }

    /// The version a command acts on: `wanted.version` exactly, else the newest version `prefer` accepts, else the newest.
    func target(_ wanted: ReleaseWanted, prefer: (ASCAppStoreVersion) -> Bool = { _ in false }) async throws -> Target {
        let app = try await ASCApps(resources: resources).resolve(wanted.app)
        let all = try await release.versions(app: app.id)
        let platform = try Self.platform(wanted.platform, among: all, app: app)
        let versions = all.filter { $0.platform == platform }
        let display = BuildPlatform.display(platform)
        if let v = wanted.version {
            guard let found = versions.first(where: { $0.versionString == v }) else {
                throw XlessError(.account, "\(app.bundleID) has no \(display) version \(v)",
                                 fix: "create it with `xless release create \(v) --app \(app.bundleID) --platform \(display)`\(versions.isEmpty ? "" : " (it has \(versions.map(\.versionString).joined(separator: ", ")))")")
            }
            return Target(app: app, platform: platform, version: found)
        }
        guard let found = versions.first(where: prefer) ?? versions.first else {
            throw XlessError(.account, "\(app.bundleID) has no \(display) App Store version",
                             fix: "create one with `xless release create <version> --app \(app.bundleID) --platform \(display)`")
        }
        return Target(app: app, platform: platform, version: found)
    }

    struct Shown<D: Encodable>: Encodable { var result: String; var data: D }

    // MARK: create

    /// - Parameter platform: nil: the app's only platform (iOS for an app with no version yet).
    func create(app argument: String, platform wanted: String?, versionString: String) async throws -> String {
        let app = try await ASCApps(resources: resources).resolve(argument)
        let all = try await release.versions(app: app.id)
        let platform = try Self.platform(wanted, among: all, app: app)
        let versions = all.filter { $0.platform == platform }
        let display = BuildPlatform.display(platform)
        if let same = versions.first(where: { $0.versionString == versionString }) {
            guard VersionState.editable.contains(same.state) || same.state == VersionState.readyForReview else {
                throw XlessError(.account, "\(app.bundleID) \(same.display) is \(VersionState.display(same.state)); nothing was sent",
                                 fix: "a new version needs a higher version string than \(versionString)")
            }
            if json { return try ASCOutput.json(Shown(result: "existing", data: same)) }
            return "\(app.bundleID) already has \(display) version \(versionString) (\(same.id), \(VersionState.display(same.state))); nothing was sent\n"
        }
        // App Store Connect keeps one version in preparation per platform: that one takes the new version string.
        if let editable = versions.first(where: { VersionState.editable.contains($0.state) }) {
            let renamed = try await release.rename(editable.id, to: versionString)
            if json { return try ASCOutput.json(Shown(result: "renamed", data: renamed)) }
            return "renamed \(display) version \(editable.versionString) (\(editable.id)), the one being prepared, to \(versionString)\n"
        }
        if let pending = versions.first(where: { $0.state == VersionState.readyForReview || VersionState.inReview.contains($0.state) }) {
            throw XlessError(.account, "\(app.bundleID) \(pending.display) is \(VersionState.display(pending.state)): App Store Connect takes a new version once it is answered; nothing was sent",
                             fix: "wait for App Review, or withdraw it with `xless release cancel --app-version \(pending.versionString)`")
        }
        let created = try await release.createVersion(app: app.id, platform: platform, versionString: versionString)
        if json { return try ASCOutput.json(Shown(result: "created", data: created)) }
        return "created \(display) version \(versionString) of \(app.bundleID) (\(created.id)); `xless store push` fills its listing\n"
    }

    // MARK: attach

    func attach(_ wanted: ReleaseWanted, build reference: BuildReference) async throws -> String {
        let t = try await target(wanted, prefer: { VersionState.editable.contains($0.state) })
        guard VersionState.editable.contains(t.version.state) || t.version.state == VersionState.readyForReview else {
            throw XlessError(.account, "\(t.name) is \(VersionState.display(t.version.state)): its build can no longer change; nothing was sent",
                             fix: "attach builds to the version being prepared (`xless release create <version>`)")
        }
        let b = try await ASCBuilds(resources: resources).resolve(reference, appID: t.app.id, platform: BuildPlatform(rawValue: t.platform))
        if let owner = b.appID, owner != t.app.id {
            throw XlessError(.account, "build \(b.id) is a build of \(b.bundleID ?? owner), not of \(t.app.bundleID); nothing was sent", fix: "pick one of `xless builds list --app \(t.app.bundleID)`")
        }
        if let p = b.platform, p != t.platform {
            throw XlessError(.account, "build \(b.name) (\(b.id)) is a \(BuildPlatform.display(p)) build, not \(BuildPlatform.display(t.platform)); nothing was sent",
                             fix: "pick a \(BuildPlatform.display(t.platform)) build (`xless builds list --app \(t.app.bundleID) --platform \(BuildPlatform.display(t.platform))`)")
        }
        if let v = b.appVersion, v != t.version.versionString {
            throw XlessError(.account, "build \(b.name) is version \(v), not \(t.version.versionString); nothing was sent",
                             fix: "attach a build of \(t.version.versionString), or pick the version with --app-version \(v)")
        }
        if b.build.isExpired { throw XlessError(.account, "build \(b.name) (\(b.id)) has expired; nothing was sent", fix: "upload a new build") }
        struct Attached: Encodable { var result: String; var versionID: String; var buildID: String }
        if try await release.buildID(of: t.version.id) == b.id {
            if json { return try ASCOutput.json(Attached(result: "unchanged", versionID: t.version.id, buildID: b.id)) }
            return "\(t.name) already carries build \(b.name) (\(b.id)); nothing was sent\n"
        }
        if b.build.processingState != "VALID" {
            say("note: build \(b.name) is \(b.build.processingState.lowercased()); submitting needs it valid (`xless builds wait \(b.id)`)")
        }
        try await release.attach(build: b.id, to: t.version.id)
        if json { return try ASCOutput.json(Attached(result: "attached", versionID: t.version.id, buildID: b.id)) }
        return "attached build \(b.name) (\(b.id)) to \(t.name)\n"
    }

    // MARK: submit

    struct SubmitOptions {
        var build: BuildReference?
        var release: ReleaseChoice?
        var phased: Bool?
        var manifestDir: URL?
        var inheritedBundleID: String?
        var dryRun = false
        var today = Date()
        /// Send the manifest's in-app purchases and subscriptions with the version.
        var products = true
    }

    /// What to print and the exit code (0, 21 or 22).
    func submit(_ wanted: ReleaseWanted, options o: SubmitOptions, privacy: (any PrivacyRemote)? = nil) async throws -> (text: String, exit: Int32) {
        let t = try await target(wanted, prefer: { VersionState.editable.contains($0.state) || $0.state == VersionState.readyForReview })
        let outcome = try await ReleaseSubmission(resources: resources, privacy: privacy, say: say).run(.init(
            app: t.app, platform: t.platform, version: t.version, build: o.build, release: o.release, phased: o.phased,
            manifestDir: o.manifestDir, inheritedBundleID: o.inheritedBundleID, dryRun: o.dryRun, today: o.today, products: o.products))
        for note in outcome.notes { say("note: \(note)") }
        let exit: Int32 = switch outcome.outcome {
        case .submitted, .dryRun: 0
        case .preflightFailed: ReleaseExit.preflightFailed
        case .alreadyInReview: ReleaseExit.alreadyInReview
        }
        let n = outcome.preflight?.failures.count ?? 0
        if outcome.outcome == .preflightFailed {
            say("error: [account] the pre-flight of \(t.name) found \(n) problem\(n == 1 ? "" : "s"); nothing was sent — fix \(n == 1 ? "it" : "them") and re-run")
        }
        if json { return (try ASCOutput.json(outcome), exit) }
        let submission = outcome.submissionID.map { " (review submission \($0)\(outcome.submissionState.map { ", \(VersionState.display($0))" } ?? ""))" } ?? ""
        var text = outcome.preflight.map { "pre-flight of \(t.name)\(outcome.build.map { ", build \($0)" } ?? ""):\n" + $0.text } ?? ""
        switch outcome.outcome {
        case .alreadyInReview:
            text += "\(t.name) is already in review\(submission); nothing was sent\n"
        case .preflightFailed:
            break
        case .dryRun:
            text += "would send:\n" + outcome.steps.map { "  \($0)\n" }.joined() + "dry run: nothing was sent\n"
        case .submitted:
            text += "sent:\n" + outcome.steps.map { "  \($0)\n" }.joined() + "submitted \(t.name) for review\(submission)\n"
        }
        return (text, exit)
    }

    // MARK: status

    struct Status: Encodable {
        struct Submission: Encodable {
            var id: String
            var state: String
            var submittedDate: String?
            var items: [ASCReviewSubmissionItem]
        }
        var appID: String
        var bundleID: String
        var version: ASCAppStoreVersion
        var build: ASCBuild?
        var phasedRelease: ASCPhasedRelease?
        var submissions: [Submission]
    }

    func status(_ wanted: ReleaseWanted) async throws -> String {
        let t = try await target(wanted)
        let v = t.version
        let builds = ASCBuilds(resources: resources)
        var build: ASCBuildDetail?
        if let id = try await release.buildID(of: v.id) { build = try await builds.get(id: id) }
        let phased = try await release.phasedRelease(of: v.id)
        var submissions: [Status.Submission] = []
        for s in try await release.submissions(app: t.app.id, platform: t.platform) where submissions.count < 3 {
            if let id = s.versionID, id != v.id { continue }
            let items = try await release.items(of: s.id)
            guard s.versionID == v.id || items.contains(where: { $0.versionID == v.id }) else { continue }
            submissions.append(.init(id: s.id, state: s.state, submittedDate: s.attributes.submittedDate, items: items))
        }
        if json {
            return try ASCOutput.json(Status(appID: t.app.id, bundleID: t.app.bundleID, version: v, build: build?.build, phasedRelease: phased, submissions: submissions))
        }
        var rows = [["STATE", VersionState.display(v.state)],
                    ["RELEASE", ReleaseChoice.display(type: v.attributes.releaseType, date: v.attributes.earliestReleaseDate)],
                    ["BUILD", build.map { "\($0.name) (\($0.id)), \(BuildCLI.state($0.build))" } ?? "none"],
                    ["PHASED RELEASE", phased.map(Self.phasedText) ?? "none"]]
        for s in submissions {
            let items = s.items.filter { $0.versionID == v.id || $0.versionID == nil }.map { "item \($0.id) \(VersionState.display($0.state))" }
            rows.append(["REVIEW SUBMISSION", "\(s.id): \(VersionState.display(s.state))\(s.submittedDate.map { ", submitted \($0)" } ?? "")"
                         + (items.isEmpty ? "" : " (\(items.joined(separator: ", ")))")])
        }
        if submissions.isEmpty { rows.append(["REVIEW SUBMISSION", "none"]) }
        var out = TextTable([t.app.bundleID, v.display], rows).rendered
        // App Review's rejection (not the developer's own withdrawal), or an open submission it sent back.
        let rejected = ["REJECTED", "METADATA_REJECTED", "INVALID_BINARY"].contains(v.state)
            || submissions.contains { $0.state == SubmissionState.unresolved }
        if rejected {
            out += "\nApp Review rejected it. The App Store Connect API does not give App Review's reasons: Apple emails them to the account holder "
                + "and the admins. Fix what they name, then `xless release submit` again.\n"
        }
        return out
    }

    static func phasedText(_ p: ASCPhasedRelease) -> String {
        var text = VersionState.display(p.state)
        if let day = p.attributes.currentDayNumber, p.state == "ACTIVE" || p.state == "PAUSED" { text += ", day \(day) of 7" }
        if let start = p.attributes.startDate { text += ", started \(start)" }
        return text
    }

    // MARK: cancel

    func cancel(_ wanted: ReleaseWanted, yes: Bool) async throws -> String {
        let t = try await target(wanted, prefer: { VersionState.inReview.contains($0.state) || $0.state == VersionState.readyForReview })
        let found = try await ReleaseSubmission(resources: resources, say: say).submissions(app: t.app.id, platform: t.platform, versionID: t.version.id)
        struct Canceled: Encodable { var result: String; var submissionID: String?; var state: String? }
        guard let s = found.holding else {
            if json { return try ASCOutput.json(Canceled(result: "none", submissionID: nil, state: nil)) }
            return "\(t.name) is in no open review submission; nothing was sent\n"
        }
        if s.state == "CANCELING" {
            if json { return try ASCOutput.json(Canceled(result: "unchanged", submissionID: s.id, state: s.state)) }
            return "review submission \(s.id) of \(t.name) is already being canceled; nothing was sent\n"
        }
        guard s.state != "COMPLETING" else {
            throw XlessError(.account, "review submission \(s.id) of \(t.name) is completing: App Review has answered; nothing was sent", fix: "`xless release status` shows the answer")
        }
        let question = "Withdraw \(t.name) from App Review (review submission \(s.id), \(VersionState.display(s.state)))? [y/N] "
        guard try AccountConfirm.confirm(question, action: "canceling review submission \(s.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        let canceled = try await release.cancel(s.id)
        if json { return try ASCOutput.json(Canceled(result: "canceled", submissionID: s.id, state: canceled.state)) }
        return "canceled review submission \(s.id) of \(t.name)\(canceled.state.isEmpty ? "" : " (\(VersionState.display(canceled.state)))"); `xless release submit` submits it again\n"
    }

    // MARK: publish

    func publish(_ wanted: ReleaseWanted) async throws -> String {
        let t = try await target(wanted, prefer: { $0.state == VersionState.pendingDeveloperRelease })
        let v = t.version
        struct Published: Encodable { var result: String; var versionID: String; var state: String }
        if v.state == "PENDING_APPLE_RELEASE" {
            if json { return try ASCOutput.json(Published(result: "unchanged", versionID: v.id, state: v.state)) }
            return "\(t.name) is approved and scheduled: Apple releases it on \(v.attributes.earliestReleaseDate ?? "its date"); nothing was sent\n"
        }
        if VersionState.released.contains(v.state) {
            if json { return try ASCOutput.json(Published(result: "unchanged", versionID: v.id, state: v.state)) }
            return "\(t.name) is already released (\(VersionState.display(v.state))); nothing was sent\n"
        }
        guard v.state == VersionState.pendingDeveloperRelease else {
            let fix = VersionState.inReview.contains(v.state) || v.state == VersionState.readyForReview
                ? "wait for App Review's approval (`xless release status`)"
                : "submit it first: `xless release submit --release manual` (or --release auto to release it on approval)"
            throw XlessError(.account, "\(t.name) is \(VersionState.display(v.state)), not approved and waiting for its release; nothing was sent", fix: fix)
        }
        try await release.requestRelease(version: v.id)
        let phased = try? await release.phasedRelease(of: v.id)
        if json {
            let now = (try? await release.version(id: v.id))?.state ?? v.state
            return try ASCOutput.json(Published(result: "released", versionID: v.id, state: now))
        }
        return "released \(t.name)\(phased != nil ? ": its phased release starts (`xless release phased pause` holds it)" : ""); it reaches the App Store within a few hours\n"
    }

    // MARK: phased

    enum PhasedAction: String, CaseIterable {
        case pause, resume, complete

        var state: String { switch self { case .pause: "PAUSED"; case .resume: "ACTIVE"; case .complete: "COMPLETE" } }
        var from: Set<String> { switch self { case .pause: ["ACTIVE"]; case .resume: ["PAUSED"]; case .complete: ["ACTIVE", "PAUSED"] } }
        var done: String { switch self { case .pause: "paused"; case .resume: "resumed"; case .complete: "completed" } }
    }

    func phased(_ action: PhasedAction, _ wanted: ReleaseWanted) async throws -> String {
        let t = try await target(wanted, prefer: { VersionState.released.contains($0.state) || $0.state == VersionState.pendingDeveloperRelease })
        guard let p = try await release.phasedRelease(of: t.version.id) else {
            throw XlessError(.account, "\(t.name) has no phased release; nothing was sent",
                             fix: "a phased release is chosen before the release: `xless release submit --phased` (or release.phased in app.yml)")
        }
        if p.state == action.state {
            if json { return try ASCOutput.json(Shown(result: "unchanged", data: p)) }
            return "the phased release of \(t.name) is already \(VersionState.display(p.state)); nothing was sent\n"
        }
        guard action.from.contains(p.state) else {
            let why = p.state == "INACTIVE" ? "has not started (it starts when the version is released)" : "is \(VersionState.display(p.state))"
            throw XlessError(.account, "the phased release of \(t.name) \(why): it cannot be \(action.done); nothing was sent", fix: "`xless release status` shows it")
        }
        let updated = try await release.setPhased(p.id, state: action.state)
        if json { return try ASCOutput.json(Shown(result: action.done, data: updated)) }
        let after = action == .complete ? ": every user gets the update now" : action == .pause ? " (for up to 30 days in all)" : ""
        return "\(action.done) the phased release of \(t.name)\(after)\n"
    }
}
