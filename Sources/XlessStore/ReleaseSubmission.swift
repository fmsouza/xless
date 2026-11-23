import Foundation
import XlessASC
import XlessCore

/// `xless release submit`: the pre-flight, then the build, the release settings and the review submission, each sent
/// only when App Store Connect does not have it yet. A submission that stopped half-way (a draft submission with or
/// without the version, a build attached but not submitted) is resumed by running it again; a version already in
/// review is reported, never submitted twice.
public struct ReleaseSubmission: Sendable {
    public struct Request: Sendable {
        public var app: ASCApp
        public var platform: String
        public var version: ASCAppStoreVersion
        /// `--build`; nil: the build the version carries.
        public var build: BuildReference?
        /// `--release`; nil: the version's release type is left as it is.
        public var release: ReleaseChoice?
        /// `--phased` (true) / `--no-phased` (false); nil: left as it is.
        public var phased: Bool?
        public var manifestDir: URL?
        public var inheritedBundleID: String?
        /// Run the pre-flight and list the steps; send nothing.
        public var dryRun: Bool
        public var today: Date
        /// Send the manifest's in-app purchases and subscriptions with the version (`--no-products`: false).
        public var products: Bool

        public init(app: ASCApp, platform: String, version: ASCAppStoreVersion, build: BuildReference? = nil, release: ReleaseChoice? = nil,
                    phased: Bool? = nil, manifestDir: URL? = nil, inheritedBundleID: String? = nil, dryRun: Bool = false, today: Date = Date(),
                    products: Bool = true) {
            self.app = app; self.platform = platform; self.version = version; self.build = build; self.release = release; self.phased = phased
            self.manifestDir = manifestDir; self.inheritedBundleID = inheritedBundleID; self.dryRun = dryRun; self.today = today
            self.products = products
        }
    }

    /// How `submit` ended; the CLI's exit code follows it (0, 22, 21, 0).
    public enum Kind: String, Encodable, Sendable {
        case submitted, alreadyInReview, preflightFailed, dryRun
    }

    /// What `submit` prints (`--json`: this document).
    public struct Outcome: Encodable, Sendable {
        public var outcome: Kind
        public var appID: String
        public var bundleID: String
        public var platform: String
        public var version: String
        public var versionID: String
        public var versionState: String
        public var build: String?
        public var buildID: String?
        public var submissionID: String?
        public var submissionState: String?
        /// What was sent (a dry run: what would be).
        public var steps: [String]
        public var notes: [String]
        public var preflight: PreflightReport?
    }

    public let release: ASCRelease
    public let builds: ASCBuilds
    public let preflight: ReleasePreflight
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, privacy: (any PrivacyRemote)? = nil, say: @escaping @Sendable (String) -> Void = { _ in }) {
        release = ASCRelease(resources: resources)
        builds = ASCBuilds(resources: resources)
        preflight = ReleasePreflight(resources: resources, privacy: privacy, say: say)
        self.say = say
    }

    /// The open review submissions of the app's platform, with the one holding `versionID` (if any) found.
    public struct Submissions: Sendable {
        public var open: [ASCReviewSubmission]
        public var holding: ASCReviewSubmission?
        public var draft: ASCReviewSubmission?
        /// The draft's items (read when there is a draft).
        public var draftItems: [ASCReviewSubmissionItem]
    }

    /// Finds the open submission that holds the version (by `appStoreVersionForReview`, else by its items).
    public func submissions(app appID: String, platform: String, versionID: String) async throws -> Submissions {
        let open = try await release.submissions(app: appID, platform: platform, states: SubmissionState.open)
        var holding = open.first { $0.versionID == versionID }
        let draft = open.first { $0.state == SubmissionState.draft }
        var draftItems: [ASCReviewSubmissionItem] = []
        if let draft { draftItems = try await release.items(of: draft.id) }
        if holding == nil {
            for s in open where s.versionID == nil {
                let items = s.id == draft?.id ? draftItems : try await release.items(of: s.id)
                if items.contains(where: { $0.versionID == versionID && $0.state != "REMOVED" }) { holding = s; break }
            }
        }
        return Submissions(open: open, holding: holding, draft: draft, draftItems: draftItems)
    }

    public func run(_ r: Request) async throws -> Outcome {
        let v = r.version
        var out = Outcome(outcome: .submitted, appID: r.app.id, bundleID: r.app.bundleID, platform: r.platform, version: v.versionString,
                          versionID: v.id, versionState: v.state, steps: [], notes: [])
        let found = try await submissions(app: r.app.id, platform: r.platform, versionID: v.id)
        if let s = found.holding {
            out.submissionID = s.id
            out.submissionState = s.state
        }
        if VersionState.inReview.contains(v.state) || found.holding.map({ SubmissionState.inReview.contains($0.state) }) == true {
            out.outcome = .alreadyInReview
            return out
        }
        if let s = found.holding, ["CANCELING", "COMPLETING"].contains(s.state) {
            throw XlessError(.account, "the review submission \(s.id) of version \(v.versionString) is \(VersionState.display(s.state)); nothing was sent",
                             fix: "wait a few minutes and re-run (`xless release status` shows it)")
        }
        guard VersionState.editable.contains(v.state) || v.state == VersionState.readyForReview else {
            throw Self.notSubmittable(v)
        }

        // The build: the one named, else the one attached.
        let attachedID = try await release.buildID(of: v.id)
        let platform = BuildPlatform(rawValue: r.platform)
        let build: ASCBuildDetail? = if let ref = r.build {
            try await builds.resolve(ref, appID: r.app.id, platform: platform)
        } else if let attachedID {
            try await builds.get(id: attachedID)
        } else {
            nil
        }
        out.build = build?.name
        out.buildID = build?.id

        let report = try await preflight.run(ReleasePreflight.Input(
            app: r.app, platform: r.platform, version: v, build: build, manifestDir: r.manifestDir, inheritedBundleID: r.inheritedBundleID,
            overridesReleaseType: r.release != nil, overridesPhased: r.phased != nil, today: r.today, products: r.products))
        out.preflight = report
        guard report.passed else {
            out.outcome = .preflightFailed
            return out
        }

        // The steps, each only when App Store Connect does not have it yet.
        var steps: [(String, () async throws -> Void)] = []
        if let build, build.id != attachedID {
            steps.append(("attach build \(build.name) (\(build.id))\(attachedID.map { " in place of \($0)" } ?? "")", { try await release.attach(build: build.id, to: v.id) }))
        }
        if let choice = r.release, !choice.matches(v.attributes) {
            let from = ReleaseChoice.display(type: v.attributes.releaseType, date: v.attributes.earliestReleaseDate)
            let to = ReleaseChoice.display(type: choice.releaseType, date: choice.earliestDate)
            steps.append(("release \(from) → \(to)", { _ = try await release.setRelease(choice, on: v.id) }))
        }
        if let phased = r.phased {
            let current = try await release.phasedRelease(of: v.id)
            if phased, current == nil {
                steps.append(("add a phased release (7 days, from the release)", { _ = try await release.createPhasedRelease(on: v.id) }))
            } else if !phased, let current {
                if current.state == "INACTIVE" {
                    steps.append(("remove the phased release", { try await release.deletePhasedRelease(current.id) }))
                } else {
                    out.notes.append("the phased release has started (\(current.state.lowercased())); --no-phased leaves it")
                }
            }
        }
        var submissionID = found.holding?.id
        var submittedState: String?
        // The manifest's products, as items of the submission (or submitted the older way).
        let manifestProducts = r.products ? try await ManifestProducts.read(r.manifestDir, app: r.app.id, resources: release.resources) : nil
        func productSteps(_ existing: [ASCReviewSubmissionItem], into id: @escaping () -> String?) -> [(String, () async throws -> Void)] {
            (manifestProducts?.toSubmit(existing: existing) ?? []).map { p in
                (p.step, {
                    switch p.how {
                    case .item(let relationship, let type, let itemID):
                        guard let submission = id() else { return }
                        _ = try await release.addItem(relationship, type: type, id: itemID, to: submission)
                    case .submission(let path, let relationship, let type, let productID):
                        try await release.submitProduct(path, relationship: relationship, type: type, id: productID)
                    }
                })
            }
        }
        if let holding = found.holding {
            // A draft, or a submission App Review sent back (UNRESOLVED_ISSUES), takes items until it is submitted again.
            if !(manifestProducts?.found.isEmpty ?? true) {
                let items = holding.id == found.draft?.id ? found.draftItems : try await release.items(of: holding.id)
                steps += productSteps(items) { holding.id }
            }
            steps.append((holding.state == SubmissionState.unresolved ? "submit review submission \(holding.id) again" : "submit review submission \(holding.id)",
                          { submittedState = try await release.submit(holding.id).state }))
        } else {
            if let draft = found.draft {
                // A draft of another version cannot take this one too.
                if let other = found.draftItems.first(where: { $0.versionID != nil && $0.versionID != v.id && $0.state != "REMOVED" }) {
                    throw XlessError(.account, "the draft review submission \(draft.id) holds another App Store version (item \(other.id)); nothing was sent",
                                     fix: "remove that item (`xless api DELETE /v1/reviewSubmissionItems/\(other.id)`), then re-run")
                }
                submissionID = draft.id
                steps.append(("add version \(v.versionString) to draft review submission \(draft.id)", { _ = try await release.addItem(version: v.id, to: draft.id) }))
                steps += productSteps(found.draftItems) { draft.id }
                steps.append(("submit review submission \(draft.id)", { submittedState = try await release.submit(draft.id).state }))
            } else {
                steps.append(("create a review submission", {
                    let created = try await release.createSubmission(app: r.app.id, platform: r.platform)
                    submissionID = created.id
                }))
                steps.append(("add version \(v.versionString) to it", {
                    guard let id = submissionID else { return }
                    _ = try await release.addItem(version: v.id, to: id)
                }))
                steps += productSteps([]) { submissionID }
                steps.append(("submit it", {
                    guard let id = submissionID else { return }
                    submittedState = try await release.submit(id).state
                }))
            }
        }
        out.steps = steps.map { $0.0 }
        if r.dryRun {
            out.outcome = .dryRun
            return out
        }
        var sent = 0
        for (what, send) in steps {
            do { try await send() } catch {
                say("note: \(sent) of \(steps.count) step\(steps.count == 1 ? "" : "s") \(sent == 1 ? "was" : "were") sent before \(what) failed; re-run `xless release submit` to resume (it sends only what is missing)")
                throw error
            }
            sent += 1
        }
        out.submissionID = submissionID
        out.submissionState = submittedState.flatMap { $0.isEmpty ? nil : $0 }
        return out
    }

    /// Why a version in `state` cannot be submitted.
    public static func notSubmittable(_ v: ASCAppStoreVersion) -> XlessError {
        let name = "version \(v.display) is \(VersionState.display(v.state))"
        if v.state == VersionState.pendingDeveloperRelease {
            return XlessError(.account, "\(name): App Review approved it; nothing was sent", fix: "`xless release publish` releases it")
        }
        if VersionState.released.contains(v.state) || v.state == "ACCEPTED" {
            return XlessError(.account, "\(name); nothing was sent", fix: "submit the next version: `xless release create <version>`")
        }
        return XlessError(.account, "\(name) and cannot be submitted; nothing was sent", fix: "`xless release status` shows where it is")
    }
}
