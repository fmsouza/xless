import Foundation
import XlessASC
import XlessCore

// What `store push` will send, as plain values: the plan is printed (and is all `--dry-run` does), compared in tests,
// and applied by `StoreSender`. No plan ever holds a secret: a request that needs one names it, and the sender reads it
// at the last moment.

/// One HTTP request of a change: a JSON:API document for App Store Connect's documented API.
public struct StoreRequest: Sendable, Equatable {
    public var method: String
    /// The path; `{id}` stands for the ID of the resource the change's first creating request created.
    public var path: String
    public var body: JSONValue?
    /// The secret whose value goes into `data.attributes.demoAccountPassword` when the request is sent.
    public var secret: String?

    public init(method: String, path: String, body: JSONValue? = nil, secret: String? = nil) {
        self.method = method; self.path = path; self.body = body; self.secret = secret
    }

    /// POST `{ data: { type, attributes, relationships } }` to `/v1/<type>`.
    public static func create(_ type: String, attributes: [String: JSONValue], relationships: [String: JSONValue] = [:], secret: String? = nil) -> StoreRequest {
        StoreRequest(method: "POST", path: "/v1/\(type)", body: document(type: type, id: nil, attributes: attributes, relationships: relationships), secret: secret)
    }

    /// PATCH `{ data: { type, id, attributes, relationships } }` to `/v1/<type>/<id>`.
    public static func update(_ type: String, id: String, attributes: [String: JSONValue] = [:], relationships: [String: JSONValue] = [:],
                              secret: String? = nil) -> StoreRequest {
        StoreRequest(method: "PATCH", path: "/v1/\(type)/\(id)", body: document(type: type, id: id, attributes: attributes, relationships: relationships), secret: secret)
    }

    public static func delete(_ type: String, id: String) -> StoreRequest { StoreRequest(method: "DELETE", path: "/v1/\(type)/\(id)") }

    /// A to-one relationship's linkage (`null` clears it).
    public static func link(_ type: String, _ id: String?) -> JSONValue {
        .object(["data": id.map { .object(["type": .string(type), "id": .string($0)]) } ?? .null])
    }

    /// A to-many relationship's linkage.
    public static func links(_ type: String, _ ids: [String]) -> JSONValue {
        .object(["data": .array(ids.map { .object(["type": .string(type), "id": .string($0)]) })])
    }

    static func document(type: String, id: String?, attributes: [String: JSONValue], relationships: [String: JSONValue]) -> JSONValue {
        var data: [String: JSONValue] = ["type": .string(type)]
        if let id { data["id"] = .string(id) }
        if !attributes.isEmpty { data["attributes"] = .object(attributes) }
        if !relationships.isEmpty { data["relationships"] = .object(relationships) }
        return .object(["data": .object(data)])
    }
}

/// A field a change sets: its old and new value as shown in the plan (nil: not set). A secret field shows neither,
/// only the name of the secret its value comes from.
public struct StoreFieldChange: Sendable, Equatable, Encodable {
    public var name: String
    public var from: String?
    public var to: String?
    public var secret: String?

    public init(_ name: String, from: String?, to: String?, secret: String? = nil) {
        self.name = name; self.from = from; self.to = to; self.secret = secret
    }

    /// `subtitle: "Does things" → "Does more"`; a long or multi-line value as its length; the password as its source.
    public var text: String {
        if let secret { return "\(name) (from \(secret))" }
        func short(_ v: String?) -> Bool { v.map { $0.count <= 60 && !$0.contains("\n") } ?? true }
        if !short(from) || !short(to) {
            func length(_ v: String?) -> String { v.map { "\($0.count)" } ?? "0" }
            return "\(name) (\(length(from)) → \(length(to)) characters)"
        }
        func shown(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "(none)" }
        return from == nil && to != nil ? "\(name): \(shown(to))" : "\(name): \(shown(from)) → \(shown(to))"
    }
}

/// One resource to create, update or delete, in one part of the listing.
public struct StoreChange: Sendable, Equatable {
    public enum Action: String, Sendable, Encodable { case create, update, delete }

    public var action: Action
    public var part: StorePushPart
    /// What changes, for people: `version text en-US`, `App Review details`.
    public var subject: String
    public var fields: [StoreFieldChange]
    public var requests: [StoreRequest]
    /// The rest of the plan depends on IDs this change makes (a new version): it is planned again once it is applied.
    public var replans: Bool
    /// Files to upload (and the set's order and deletions), done after `requests`.
    public var media: StoreMediaWork?

    public init(_ action: Action, _ part: StorePushPart, _ subject: String, fields: [StoreFieldChange] = [], requests: [StoreRequest], replans: Bool = false,
                media: StoreMediaWork? = nil) {
        self.action = action; self.part = part; self.subject = subject; self.fields = fields; self.requests = requests; self.replans = replans
        self.media = media
    }

    public var text: String {
        let sign = switch action { case .create: "+"; case .update: "~"; case .delete: "-" }
        guard !fields.isEmpty else { return "\(sign) \(subject)" }
        if fields.count == 1 { return "\(sign) \(subject): \(fields[0].text)" }
        return "\(sign) \(subject)\n" + fields.map { "    \($0.text)" }.joined(separator: "\n")
    }
}

/// The parts of the listing `store push` sends, in the order it sends them (#97 adds privacy).
public enum StorePushPart: String, Sendable, CaseIterable, Encodable {
    /// Text and the version: primary locale, categories, the app information and version localizations, the version.
    case text
    /// App Review details, with the demo account.
    case review
    /// Age rating, content rights, licence agreement, export compliance (and its document), accessibility.
    case declarations
    /// The price schedule and the territories the app is available in (app-level: no version needed).
    case pricing
    /// Screenshots and app previews, per locale and display type.
    case media

    /// `text,review` (also repeated) → parts, in push order.
    public static func parse(_ arguments: [String]) throws -> [StorePushPart] {
        var parts: Set<StorePushPart> = []
        for name in arguments.flatMap({ $0.split(separator: ",") }).map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            guard let part = StorePushPart(rawValue: name) else {
                throw XlessError(.account, "--only \(name) is not a part of the listing store push sends",
                                 fix: "use \(allCases.map(\.rawValue).joined(separator: ", ")) (comma-separated)")
            }
            parts.insert(part)
        }
        return allCases.filter(parts.contains)
    }
}

/// Everything a push would do, and what it found worth saying.
public struct StorePlan: Sendable, Equatable {
    public var changes: [StoreChange] = []
    public var notes: [String] = []
    /// media.lock entries planning found (a local file that is an upload App Store Connect has), recorded once the
    /// plan is applied.
    public var lock: [String: MediaLock.Entry] = [:]

    public init(changes: [StoreChange] = [], notes: [String] = []) { self.changes = changes; self.notes = notes }

    public var deletes: [StoreChange] { changes.filter { $0.action == .delete } }

    /// The changes, one per line (indented by two spaces), then the summary.
    public var text: String {
        changes.map { $0.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n") + "\n" }.joined()
            + summary + "\n"
    }

    /// `3 changes: 1 to create, 2 to update`.
    public var summary: String {
        guard !changes.isEmpty else { return "nothing to push: App Store Connect already matches the manifest" }
        let counts = StoreChange.Action.allCases.compactMap { action -> String? in
            let n = changes.filter { $0.action == action }.count
            return n == 0 ? nil : "\(n) to \(action.rawValue)"
        }
        return "\(changes.count) change\(changes.count == 1 ? "" : "s"): \(counts.joined(separator: ", "))"
    }
}

extension StoreChange.Action: CaseIterable {}

// MARK: - Media

/// What kind of file a media change uploads, and where App Store Connect keeps it.
public enum StoreMediaKind: String, Sendable, Equatable {
    case screenshots, previews, reviewAttachments, encryptionDocument

    /// The resource type of one file (also its path: /v1/<itemType>).
    public var itemType: String {
        switch self {
        case .screenshots: "appScreenshots"
        case .previews: "appPreviews"
        case .reviewAttachments: "appStoreReviewAttachments"
        case .encryptionDocument: "appEncryptionDeclarationDocuments"
        }
    }

    /// The set the files belong to (ordered), for screenshots and previews.
    public var setType: String? {
        switch self {
        case .screenshots: "appScreenshotSets"
        case .previews: "appPreviewSets"
        case .reviewAttachments, .encryptionDocument: nil
        }
    }

    /// The set's type attribute (`screenshotDisplayType`, `previewType`).
    public var setAttribute: String? {
        switch self {
        case .screenshots: "screenshotDisplayType"
        case .previews: "previewType"
        case .reviewAttachments, .encryptionDocument: nil
        }
    }

    /// A file's to-one relationship to what holds it, and that resource's type.
    public var parent: (relationship: String, type: String) {
        switch self {
        case .screenshots: ("appScreenshotSet", "appScreenshotSets")
        case .previews: ("appPreviewSet", "appPreviewSets")
        case .reviewAttachments: ("appStoreReviewDetail", "appStoreReviewDetails")
        case .encryptionDocument: ("appEncryptionDeclaration", "appEncryptionDeclarations")
        }
    }

    static let allItemTypes: Set<String> = Set([StoreMediaKind.screenshots, .previews, .reviewAttachments, .encryptionDocument].map(\.itemType))

    /// How many files Apple takes in one set.
    public var maxItems: Int? {
        switch self {
        case .screenshots: ScreenshotDisplayType.maxPerSet
        case .previews: PreviewType.maxPerSet
        case .reviewAttachments: nil
        case .encryptionDocument: 1
        }
    }
}

/// A local file to upload.
public struct StoreUpload: Sendable, Equatable {
    /// Relative to the manifest directory: how the plan names it, and its media.lock key.
    public var path: String
    public var file: URL
    public var fileName: String
    public var fileSize: Int
    public var md5: String
    /// Attributes sent with the commit (`previewFrameTimeCode`).
    public var commit: [String: JSONValue]

    public init(path: String, file: URL, fileName: String, fileSize: Int, md5: String, commit: [String: JSONValue] = [:]) {
        self.path = path; self.file = file; self.fileName = fileName; self.fileSize = fileSize; self.md5 = md5; self.commit = commit
    }
}

/// One set's files as App Store Connect should end up with them: `StoreSender` creates the set if needed, uploads,
/// deletes, then puts the set in order.
public struct StoreMediaWork: Sendable, Equatable {
    /// The version localization a new set belongs to: known, or (a locale this push creates) looked up when sent.
    public enum Localization: Sendable, Equatable {
        case id(String)
        case locale(String, versionID: String)
    }

    public enum Container: Sendable, Equatable {
        /// An existing set.
        case set(String)
        /// A set to create, of this display or preview type.
        case newSet(type: String, localization: Localization)
        /// The resource the files hang from (review details, encryption declaration); `{id}`: the one the change created.
        case parent(String)
    }

    /// A position of the set once sent: a file App Store Connect has, or one to upload.
    public enum Slot: Sendable, Equatable {
        case keep(String)
        case upload(StoreUpload)
    }

    public var kind: StoreMediaKind
    public var container: Container
    /// The files in display order.
    public var slots: [Slot]
    /// Files App Store Connect has that go (replaced, failed, or pruned).
    public var deletes: [String]
    /// Delete before uploading (the set would otherwise hold more than Apple allows).
    public var deleteFirst: Bool
    /// Send the order (PATCH of the set's files relationship) once uploads and deletions are done.
    public var reorder: Bool

    public init(kind: StoreMediaKind, container: Container, slots: [Slot], deletes: [String] = [], deleteFirst: Bool = false, reorder: Bool = false) {
        self.kind = kind; self.container = container; self.slots = slots; self.deletes = deletes; self.deleteFirst = deleteFirst; self.reorder = reorder
    }

    public var uploads: [StoreUpload] { slots.compactMap { if case .upload(let u) = $0 { return u }; return nil } }
}
