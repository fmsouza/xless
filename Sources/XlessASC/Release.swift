import Foundation
import XlessCore

// The App Store side of `xless release` (docs/apple-account.md#xless-release): App Store versions, the build a version
// carries, its release type and phased release, review submissions and their items, and release requests. All of it
// is the documented API (App Store Connect API key). The pre-flight and the submission sequence are XlessStore's.

/// An App Store version, as the release commands read it.
public typealias ASCVersion = ASCAppStoreVersion

extension ASCKeptResource where A == ASCAppStoreVersionAttributes {
    public var versionString: String { attributes.versionString ?? "" }
    public var platform: String { attributes.platform ?? "" }
    /// The version's state: `appVersionState`, else the older `appStoreState`.
    public var state: String { attributes.appVersionState ?? attributes.appStoreState ?? "" }
    /// `1.2 (ios)`.
    public var display: String { "\(versionString) (\(BuildPlatform.display(platform)))" }
}

/// What a version's state means to the release commands.
public enum VersionState {
    /// States in which the version (its listing and its build) can still be changed and submitted.
    public static let editable: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]
    /// Added to a review submission that has not been sent yet.
    public static let readyForReview = "READY_FOR_REVIEW"
    /// Sent to App Review and not answered yet.
    public static let inReview: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "WAITING_FOR_EXPORT_COMPLIANCE"]
    /// Approved, waiting for `xless release publish`.
    public static let pendingDeveloperRelease = "PENDING_DEVELOPER_RELEASE"
    /// On the App Store (or on its way there).
    public static let released: Set<String> = ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION",
                                               "PENDING_APPLE_RELEASE", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"]

    /// Lower case with spaces: `waiting for review`.
    public static func display(_ state: String) -> String { state.lowercased().replacingOccurrences(of: "_", with: " ") }
}

/// When an approved version goes on sale: `--release manual|auto|<date>`.
public enum ReleaseChoice: Sendable, Equatable {
    /// MANUAL: `xless release publish` releases it.
    case manual
    /// AFTER_APPROVAL: released as soon as App Review approves it.
    case afterApproval
    /// SCHEDULED: released after approval, not before this time (ISO 8601, UTC).
    case scheduled(String)

    /// `manual`, `auto` (or `after-approval`), or a date: `2026-12-01` (midnight UTC) or an ISO 8601 time on the hour
    /// (`2026-12-01T09:00:00Z`, `2026-12-01T10:00+01:00`). A date must be in the future.
    public static func parse(_ text: String, now: Date = Date()) throws -> ReleaseChoice {
        switch text.lowercased() {
        case "manual": return .manual
        case "auto", "after-approval", "after_approval", "automatic": return .afterApproval
        default: break
        }
        guard let date = parseDate(text) else {
            throw IdentifierInputError("--release \(text): use manual, auto, or a date (2026-12-01, or 2026-12-01T09:00:00Z)")
        }
        guard Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).minute == 0,
              Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).second == 0 else {
            throw IdentifierInputError("--release \(text): App Store Connect schedules releases on the hour (e.g. 2026-12-01T09:00:00Z)")
        }
        guard date > now else { throw IdentifierInputError("--release \(text) is not in the future") }
        return .scheduled(utc(date))
    }

    static func parseDate(_ text: String) -> Date? {
        if text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: text), f.string(from: d) == text else { return nil }
            return d
        }
        var t = text
        // ISO8601DateFormatter wants seconds: `2026-12-01T10:00+01:00` → `…T10:00:00+01:00`.
        if let r = t.range(of: "T[0-9]{2}:[0-9]{2}(?=Z|[+-]|$)", options: .regularExpression) { t.insert(contentsOf: ":00", at: r.upperBound) }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: t)
    }

    static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// App Store Connect's `releaseType`.
    public var releaseType: String {
        switch self { case .manual: "MANUAL"; case .afterApproval: "AFTER_APPROVAL"; case .scheduled: "SCHEDULED" }
    }

    public var earliestDate: String? { if case .scheduled(let d) = self { return d }; return nil }

    /// How the release commands say it: `manual`, `after approval`, `scheduled 2026-12-01T00:00:00Z`.
    public static func display(type: String?, date: String?) -> String {
        switch type {
        case "MANUAL": "manual"
        case "AFTER_APPROVAL": "after approval"
        case "SCHEDULED": "scheduled \(date ?? "")"
        case nil: "not set"
        case let other?: other.lowercased()
        }
    }

    /// Whether the version already releases this way.
    public func matches(_ v: ASCAppStoreVersionAttributes) -> Bool {
        guard v.releaseType == releaseType else { return false }
        guard let date = earliestDate else { return true }
        guard let have = v.earliestReleaseDate, let a = Self.parseDate(have), let b = Self.parseDate(date) else { return false }
        return a == b
    }
}

public struct ASCPhasedReleaseAttributes: ASCAttributes, Equatable {
    /// INACTIVE (not started), ACTIVE, PAUSED or COMPLETE.
    public var phasedReleaseState: String?
    public var startDate: String?
    public var totalPauseDuration: Int?
    public var currentDayNumber: Int?
    public init() {}
}

public typealias ASCPhasedRelease = ASCKeptResource<ASCPhasedReleaseAttributes>

extension ASCKeptResource where A == ASCPhasedReleaseAttributes {
    public var state: String { attributes.phasedReleaseState ?? "INACTIVE" }
}

public struct ASCReviewSubmissionAttributes: ASCAttributes, Equatable {
    public var platform: String?
    public var submittedDate: String?
    /// READY_FOR_REVIEW (a draft, not sent), WAITING_FOR_REVIEW, IN_REVIEW, UNRESOLVED_ISSUES, CANCELING, COMPLETING, COMPLETE.
    public var state: String?
    public init() {}
}

public typealias ASCReviewSubmission = ASCKeptResource<ASCReviewSubmissionAttributes>

extension ASCKeptResource where A == ASCReviewSubmissionAttributes {
    public var state: String { attributes.state ?? "" }
    /// The version the submission is for, when App Store Connect said it (`appStoreVersionForReview`).
    public var versionID: String? { resource.relatedID("appStoreVersionForReview") }
}

public struct ASCReviewSubmissionItemAttributes: ASCAttributes, Equatable {
    /// READY_FOR_REVIEW, ACCEPTED, APPROVED, REJECTED or REMOVED.
    public var state: String?
    public init() {}
}

public typealias ASCReviewSubmissionItem = ASCKeptResource<ASCReviewSubmissionItemAttributes>

extension ASCKeptResource where A == ASCReviewSubmissionItemAttributes {
    public var state: String { attributes.state ?? "" }
    /// The App Store version the item submits; nil for another kind of item (in-app event, custom product page…).
    public var versionID: String? { resource.relatedID("appStoreVersion") }
}

/// Review submission states.
public enum SubmissionState {
    /// Created, items being added: not sent to App Review yet.
    public static let draft = "READY_FOR_REVIEW"
    /// Sent, waiting for or in review.
    public static let inReview: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW"]
    /// App Review rejected an item: fix it and submit the same submission again.
    public static let unresolved = "UNRESOLVED_ISSUES"
    /// Not finished yet: a submission in any of these holds its version.
    public static let open: Set<String> = ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "CANCELING", "COMPLETING"]
}

/// The release operations, on the App Store Connect API key.
public struct ASCRelease: Sendable {
    public let resources: ASCResources

    /// A to-one relationship's linkage.
    static func link(_ type: String, _ id: String) -> JSONValue { .object(["data": .object(["type": .string(type), "id": .string(id)])]) }

    public init(resources: ASCResources) { self.resources = resources }

    /// The app's App Store versions (of `platform` when given), newest first.
    public func versions(app appID: String, platform: String? = nil) async throws -> [ASCVersion] {
        let query = ASCQuery(filters: platform.map { [("platform", $0)] } ?? [])
        let items = try await resources.list("/v1/apps/\(appID)/appStoreVersions", query: query, as: ASCVersion.self).items
        return items.filter { platform == nil || $0.platform == platform }
            .sorted { ($0.attributes.createdDate ?? "", $0.id) > ($1.attributes.createdDate ?? "", $1.id) }
    }

    public func version(id: String) async throws -> ASCVersion {
        try await resources.get("/v1/appStoreVersions/\(id)", as: ASCVersion.self).data
    }

    /// Creates the version (POST once).
    public func createVersion(app appID: String, platform: String, versionString: String) async throws -> ASCVersion {
        let attributes: [String: JSONValue] = ["platform": .string(platform), "versionString": .string(versionString)]
        let relationships: [String: JSONValue] = ["app": Self.link("apps", appID)]
        return try await resources.create("/v1/appStoreVersions", type: "appStoreVersions", attributes: attributes, relationships: relationships).data
    }

    /// Changes the version string of a version being prepared.
    public func rename(_ versionID: String, to versionString: String) async throws -> ASCVersion {
        try await resources.update("/v1/appStoreVersions/\(versionID)", type: "appStoreVersions", id: versionID,
                                   attributes: ["versionString": JSONValue.string(versionString)]).data
    }

    /// The ID of the build the version carries; nil when none is attached.
    public func buildID(of versionID: String) async throws -> String? {
        try await resources.toOneRelationship("/v1/appStoreVersions/\(versionID)", "build")?.id
    }

    /// Attaches the build to the version (PATCH the `build` relationship).
    public func attach(build buildID: String, to versionID: String) async throws {
        try await resources.replaceToOneRelationship("/v1/appStoreVersions/\(versionID)", "build", ASCRef(type: "builds", id: buildID))
    }

    /// Sets how the approved version is released.
    public func setRelease(_ choice: ReleaseChoice, on versionID: String) async throws -> ASCVersion {
        var attributes: [String: JSONValue] = ["releaseType": .string(choice.releaseType)]
        if let date = choice.earliestDate { attributes["earliestReleaseDate"] = .string(date) }
        return try await resources.update("/v1/appStoreVersions/\(versionID)", type: "appStoreVersions", id: versionID, attributes: attributes).data
    }

    /// The version's phased release; nil when it has none.
    public func phasedRelease(of versionID: String) async throws -> ASCPhasedRelease? {
        do {
            return try await resources.get("/v1/appStoreVersions/\(versionID)/appStoreVersionPhasedRelease", as: ASCPhasedRelease?.self).data
        } catch let e as ASCError where e.status == 404 { return nil }
    }

    /// Gives the version a phased release (INACTIVE: it starts when the version is released).
    public func createPhasedRelease(on versionID: String) async throws -> ASCPhasedRelease {
        let relationships: [String: JSONValue] = ["appStoreVersion": Self.link("appStoreVersions", versionID)]
        return try await resources.create("/v1/appStoreVersionPhasedReleases", type: "appStoreVersionPhasedReleases",
                                          attributes: ["phasedReleaseState": JSONValue.string("INACTIVE")], relationships: relationships).data
    }

    public func deletePhasedRelease(_ id: String) async throws {
        do { try await resources.delete("/v1/appStoreVersionPhasedReleases/\(id)") } catch let e as ASCError where e.status == 404 {}
    }

    /// Pauses (PAUSED), resumes (ACTIVE) or completes (COMPLETE) a phased release.
    public func setPhased(_ id: String, state: String) async throws -> ASCPhasedRelease {
        try await resources.update("/v1/appStoreVersionPhasedReleases/\(id)", type: "appStoreVersionPhasedReleases", id: id,
                                   attributes: ["phasedReleaseState": JSONValue.string(state)]).data
    }

    /// The app's review submissions for `platform` (in `states` when given), most recently submitted first; drafts
    /// (never submitted) come first.
    public func submissions(app appID: String, platform: String, states: Set<String> = []) async throws -> [ASCReviewSubmission] {
        var filters = [("app", appID), ("platform", platform)]
        if !states.isEmpty { filters.append(("state", states.sorted().joined(separator: ","))) }
        let query = ASCQuery(filters: filters, include: ["appStoreVersionForReview"])
        let items = try await resources.list("/v1/reviewSubmissions", query: query, as: ASCReviewSubmission.self).items
        return items.filter { states.isEmpty || states.contains($0.state) }
            .sorted { ($0.attributes.submittedDate ?? "~", $0.id) > ($1.attributes.submittedDate ?? "~", $1.id) }
    }

    /// A submission's items, with the version each submits.
    public func items(of submissionID: String) async throws -> [ASCReviewSubmissionItem] {
        try await resources.list("/v1/reviewSubmissions/\(submissionID)/items", query: ASCQuery(include: ["appStoreVersion"]),
                                 as: ASCReviewSubmissionItem.self).items
    }

    /// Creates a review submission (a draft until `submit`), POST once.
    public func createSubmission(app appID: String, platform: String) async throws -> ASCReviewSubmission {
        let relationships: [String: JSONValue] = ["app": Self.link("apps", appID)]
        return try await resources.create("/v1/reviewSubmissions", type: "reviewSubmissions", attributes: ["platform": JSONValue.string(platform)],
                                          relationships: relationships).data
    }

    /// Adds the version to a draft submission, POST once.
    public func addItem(version versionID: String, to submissionID: String) async throws -> ASCReviewSubmissionItem {
        let relationships: [String: JSONValue] = [
            "reviewSubmission": Self.link("reviewSubmissions", submissionID),
            "appStoreVersion": Self.link("appStoreVersions", versionID),
        ]
        return try await resources.create("/v1/reviewSubmissionItems", type: "reviewSubmissionItems", attributes: [String: JSONValue](),
                                          relationships: relationships).data
    }

    /// Adds another kind of item to a draft submission (`relationship`: inAppPurchaseVersion, subscriptionVersion,
    /// subscriptionGroupVersion…, to the resource `type`/`id`), POST once.
    public func addItem(_ relationship: String, type: String, id: String, to submissionID: String) async throws -> ASCReviewSubmissionItem {
        let relationships: [String: JSONValue] = [
            "reviewSubmission": Self.link("reviewSubmissions", submissionID),
            relationship: Self.link(type, id),
        ]
        return try await resources.create("/v1/reviewSubmissionItems", type: "reviewSubmissionItems", attributes: [String: JSONValue](),
                                          relationships: relationships).data
    }

    /// Submits an in-app purchase or a subscription with the app's next version, the way App Store Connect did
    /// before review submission items took products (POST /v1/inAppPurchaseSubmissions, /v1/subscriptionSubmissions),
    /// POST once.
    public func submitProduct(_ path: String, relationship: String, type: String, id: String) async throws {
        let body: JSONValue = .object(["data": .object([
            "type": .string(String(path.split(separator: "/").last ?? "")),
            "relationships": .object([relationship: Self.link(type, id)]),
        ])])
        _ = try await resources.client.request("POST", path, body: try JSONEncoder().encode(body), maxAttempts: 1)
    }

    /// Sends the submission to App Review (`submitted: true`).
    public func submit(_ submissionID: String) async throws -> ASCReviewSubmission {
        try await resources.update("/v1/reviewSubmissions/\(submissionID)", type: "reviewSubmissions", id: submissionID,
                                   attributes: ["submitted": JSONValue.bool(true)]).data
    }

    /// Withdraws the submission from App Review (`canceled: true`).
    public func cancel(_ submissionID: String) async throws -> ASCReviewSubmission {
        try await resources.update("/v1/reviewSubmissions/\(submissionID)", type: "reviewSubmissions", id: submissionID,
                                   attributes: ["canceled": JSONValue.bool(true)]).data
    }

    /// Releases an approved version held for a manual release (POST /v1/appStoreVersionReleaseRequests, once).
    public func requestRelease(version versionID: String) async throws {
        let relationships: [String: JSONValue] = ["appStoreVersion": Self.link("appStoreVersions", versionID)]
        let _: ASCSingle<ASCAnyResource?> = try await resources.create("/v1/appStoreVersionReleaseRequests", type: "appStoreVersionReleaseRequests",
                                                                        attributes: [String: JSONValue](), relationships: relationships)
    }
}
