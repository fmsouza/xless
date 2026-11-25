import Foundation
import XlessCore

// Builds (`/v1/builds`) for `xless builds` (docs/apple-account.md#xless-builds): list, show, wait for processing,
// expire, export compliance. `ASCBuilds.find` / `resolve` are the "find a build by version and number" helper that
// TestFlight distribution and the release commands share; `BuildProcessing.poll` is the one processing loop
// (`BuildUploader` and `xless builds wait`).

public struct ASCBuildAttributes: ASCAttributes, Equatable {
    /// The build number (CFBundleVersion).
    public var version: String?
    public var uploadedDate: String?
    public var expirationDate: String?
    public var expired: Bool?
    public var minOsVersion: String?
    public var processingState: String?
    public var buildAudienceType: String?
    public var usesNonExemptEncryption: Bool?
    public init() {}
}

public typealias ASCBuild = ASCKeptResource<ASCBuildAttributes>

extension ASCKeptResource where A == ASCBuildAttributes {
    /// The build number (CFBundleVersion).
    public var number: String { attributes.version ?? "" }
    public var processingState: String { attributes.processingState ?? "" }
    public var isExpired: Bool { attributes.expired == true }
}

extension ASCAnyResource {
    /// The text of one attribute, nil when it is absent or null. Anything else is an error: the typed attributes of an
    /// `ASCKeptResource` would be left out then, all of them, as if App Store Connect had given none.
    func text(_ name: String) throws -> String? {
        switch attributes?[name] {
        case nil, .null: return nil
        case .string(let text): return text
        case .some: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(name) of the \(type) resource \(id) is not text"))
        }
    }

    /// The ID a to-one relationship's linkage points at, when the answer carried the linkage.
    public func relatedID(_ name: String) -> String? { relationships?[name]?["data"]?["id"]?.string }
}

/// A build's processing state, as `--state` names it.
public enum BuildState: String, Codable, Sendable, CaseIterable {
    case processing = "PROCESSING"
    case valid = "VALID"
    case invalid = "INVALID"
    case failed = "FAILED"

    public init?(argument: String) { self.init(rawValue: argument.uppercased()) }
    public var argument: String { rawValue.lowercased() }
}

/// The platform of a build's version (`preReleaseVersion.platform`).
public enum BuildPlatform: String, Codable, Sendable, CaseIterable {
    case ios = "IOS"
    case macOS = "MAC_OS"
    case tvOS = "TV_OS"
    case visionOS = "VISION_OS"

    /// `ios`, `macos` (`mac`), `tvos` or `visionos`, any case.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "ios": self = .ios
        case "macos", "mac": self = .macOS
        case "tvos": self = .tvOS
        case "visionos": self = .visionOS
        default: return nil
        }
    }

    public var argument: String {
        switch self { case .ios: "ios"; case .macOS: "macos"; case .tvOS: "tvos"; case .visionOS: "visionos" }
    }

    /// The command-line name of an API value; an unknown value as it is.
    public static func display(_ value: String?) -> String {
        guard let value else { return "" }
        return BuildPlatform(rawValue: value)?.argument ?? value
    }
}

/// How a command names a build: its ID, or its version and build number (`1.2.0+42`).
public enum BuildReference: Sendable, Equatable, CustomStringConvertible {
    case id(String)
    case version(String, number: String)

    static let dotted = "^[0-9]+(\\.[0-9]+)*$"

    public static func parse(_ text: String) throws -> BuildReference {
        if let plus = text.firstIndex(of: "+") {
            let version = String(text[..<plus]), number = String(text[text.index(after: plus)...])
            guard version.range(of: dotted, options: .regularExpression) != nil, number.range(of: dotted, options: .regularExpression) != nil else {
                throw IdentifierInputError("\(text) is not <version>+<build number>: both are numbers separated by dots, e.g. 1.2.0+42")
            }
            return .version(version, number: number)
        }
        guard isBuildID(text) else {
            throw IdentifierInputError("\(text) is not a build ID (see `xless builds list`) nor <version>+<build number> (e.g. 1.2.0+42)")
        }
        if text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }) {
            throw IdentifierInputError("\(text) looks like a build number: name the build as <version>+\(text) (e.g. 1.0+\(text)) or by its ID from `xless builds list`")
        }
        return .id(text)
    }

    /// App Store Connect's build IDs: letters, digits and dashes (a UUID).
    public static func isBuildID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
            && text.first != "-"
    }

    public var description: String {
        switch self {
        case .id(let id): id
        case .version(let v, let n): "\(v)+\(n)"
        }
    }
}

/// A build with what xless shows next to it: its version and platform (`preReleaseVersion`), its app, and — when read
/// on its own — its TestFlight states and encryption declaration.
public struct ASCBuildDetail: Sendable {
    public var build: ASCBuild
    /// The resources App Store Connect included with the build (what `--json` prints next to it).
    public var included: [ASCAnyResource]

    public init(build: ASCBuild, included: [ASCAnyResource]) { self.build = build; self.included = included }

    public var id: String { build.id }
    public var number: String { build.number }

    func related(_ name: String, type: String) -> ASCAnyResource? {
        guard let id = build.resource.relatedID(name) else { return nil }
        return included.first { $0.type == type && $0.id == id }
    }

    /// The version (CFBundleShortVersionString) the build belongs to.
    public var appVersion: String? { related("preReleaseVersion", type: "preReleaseVersions")?.attributes?["version"]?.string }
    /// The platform's API value (IOS, MAC_OS…).
    public var platform: String? { related("preReleaseVersion", type: "preReleaseVersions")?.attributes?["platform"]?.string }
    public var appID: String? { build.resource.relatedID("app") }
    public var bundleID: String? { related("app", type: "apps")?.attributes?["bundleId"]?.string }
    public var appName: String? { related("app", type: "apps")?.attributes?["name"]?.string }
    public var internalBetaState: String? { related("buildBetaDetail", type: "buildBetaDetails")?.attributes?["internalBuildState"]?.string }
    public var externalBetaState: String? { related("buildBetaDetail", type: "buildBetaDetails")?.attributes?["externalBuildState"]?.string }
    public var encryptionDeclarationID: String? { build.resource.relatedID("appEncryptionDeclaration") }
    public var encryptionDeclaration: ASCAnyResource? { related("appEncryptionDeclaration", type: "appEncryptionDeclarations") }

    /// `1.2.0+42`, or the build number alone when the version was not included.
    public var name: String { appVersion.map { "\($0)+\(number)" } ?? number }
}

/// What `xless builds list` filters on.
public struct BuildFilter: Sendable {
    public var appID: String?
    public var appVersion: String?
    public var number: String?
    public var platform: BuildPlatform?
    public var states: [BuildState]
    /// false: builds that have not expired (the default); true: expired builds only; nil: both.
    public var expired: Bool?

    public init(appID: String? = nil, appVersion: String? = nil, number: String? = nil, platform: BuildPlatform? = nil,
                states: [BuildState] = [], expired: Bool? = false) {
        self.appID = appID; self.appVersion = appVersion; self.number = number; self.platform = platform; self.states = states; self.expired = expired
    }

    var query: ASCQuery {
        var filters: [(String, String)] = []
        if let appID { filters.append(("app", appID)) }
        if let appVersion { filters.append(("preReleaseVersion.version", appVersion)) }
        if let number { filters.append(("version", number)) }
        if let platform { filters.append(("preReleaseVersion.platform", platform.rawValue)) }
        if !states.isEmpty { filters.append(("processingState", states.map(\.rawValue).joined(separator: ","))) }
        if let expired { filters.append(("expired", expired ? "true" : "false")) }
        return ASCQuery(filters: filters, fields: [("apps", ["bundleId", "name"])], include: ["preReleaseVersion", "app"], sort: ["-uploadedDate"])
    }
}

public struct ASCBuildListing: Sendable {
    public var builds: [ASCBuildDetail]
    public var included: [ASCAnyResource]
}

public struct ASCEncryptionDeclarationAttributes: ASCAttributes, Equatable {
    public var appDescription: String?
    public var createdDate: String?
    public var exempt: Bool?
    public var containsProprietaryCryptography: Bool?
    public var containsThirdPartyCryptography: Bool?
    public var availableOnFrenchStore: Bool?
    public var appEncryptionDeclarationState: String?
    public var codeValue: String?
    public init() {}
}

public typealias ASCEncryptionDeclaration = ASCKeptResource<ASCEncryptionDeclarationAttributes>

/// The build operations, on the App Store Connect API key.
public struct ASCBuilds: Sendable {
    public static let path = "/v1/builds"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    /// The builds that match `filter`, most recently uploaded first; at most `limit` (nil: every page).
    public func list(_ filter: BuildFilter, limit: Int? = nil) async throws -> ASCBuildListing {
        let listing = try await resources.list(Self.path, query: filter.query, as: ASCBuild.self, maxItems: limit)
        return ASCBuildListing(builds: listing.items.map { ASCBuildDetail(build: $0, included: Self.relevant(to: $0, in: listing.included)) },
                               included: listing.included)
    }

    /// The included resources `build` points at.
    static func relevant(to build: ASCBuild, in included: [ASCAnyResource]) -> [ASCAnyResource] {
        let ids = Set((build.resource.relationships ?? [:]).compactMap { _, v in v["data"]?["id"]?.string })
        return included.filter { ids.contains($0.id) }
    }

    /// One build with its version, app, TestFlight states and encryption declaration.
    public func get(id: String) async throws -> ASCBuildDetail {
        guard BuildReference.isBuildID(id) else {
            throw XlessError(.account, "\(id) is not a build ID", fix: "use a build ID from `xless builds list`, or <version>+<build number>")
        }
        let single: ASCSingle<ASCBuild> = try await resources.get(
            "\(Self.path)/\(id)",
            query: ASCQuery(fields: [("apps", ["bundleId", "name"])], include: ["preReleaseVersion", "app", "buildBetaDetail", "appEncryptionDeclaration"]),
            as: ASCBuild.self)
        return ASCBuildDetail(build: single.data, included: single.included)
    }

    /// The build's processing state (nil: not given), nothing included: what the wait after an upload reads every round.
    public func processing(id: String) async throws -> (id: String, state: String?) {
        let build = try await resources.get("\(Self.path)/\(id)", as: ASCBuild.self).data
        return (build.id, try build.resource.text("processingState"))
    }

    /// The build numbers App Store Connect holds for the app's version: every state and platform, expired ones too. A
    /// build whose number cannot be read is an error: the list is what the next number is compared with.
    public func numbers(appID: String, version: String) async throws -> [String] {
        let query = ASCQuery(filters: [("app", appID), ("preReleaseVersion.version", version)], fields: [("builds", ["version"])])
        return try await resources.list(Self.path, query: query, as: ASCBuild.self).items.map { build in
            guard let number = try build.resource.text("version") else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "the build \(build.id) has no version"))
            }
            return number
        }
    }

    /// The build with exactly this version and build number (expired or not); nil when there is none. Several matches
    /// (the same numbers in two apps, or on two platforms of one app) are an error naming each.
    public func find(version: String, number: String, appID: String? = nil, platform: BuildPlatform? = nil) async throws -> ASCBuildDetail? {
        let filter = BuildFilter(appID: appID, appVersion: version, number: number, platform: platform, expired: nil)
        let matches = try await list(filter).builds.filter { $0.number == number && ($0.appVersion == nil || $0.appVersion == version) }
        guard matches.count <= 1 else {
            let each = matches.map { "\($0.id) (\($0.bundleID ?? $0.appID ?? "app ?"), \(BuildPlatform.display($0.platform)))" }
            throw XlessError(.account, "\(matches.count) builds are \(version)+\(number): \(each.joined(separator: ", "))",
                             fix: "narrow it with --app and --platform, or name the build by its ID")
        }
        return matches.first
    }

    /// The build a command names, read on its own (`get`).
    public func resolve(_ reference: BuildReference, appID: String? = nil, platform: BuildPlatform? = nil) async throws -> ASCBuildDetail {
        switch reference {
        case .id(let id): return try await get(id: id)
        case .version(let version, let number):
            guard let found = try await find(version: version, number: number, appID: appID, platform: platform) else {
                throw XlessError(.account, "no build \(version)+\(number) is visible to this API key\(appID.map { " in app \($0)" } ?? "")",
                                 fix: "check `xless builds list\(appID.map { " --app \($0)" } ?? "")` (and --team); a build that was just uploaded appears a few minutes later: `xless builds wait \(version)+\(number)` waits for it")
            }
            return try await get(id: found.id)
        }
    }

    /// Expires the build (PATCH `expired: true`): testers can no longer install it. Cannot be undone.
    public func expire(_ id: String) async throws -> ASCBuild {
        struct Attributes: Encodable, Sendable { var expired: Bool }
        let single: ASCSingle<ASCBuild> = try await resources.update("\(Self.path)/\(id)", type: "builds", id: id, attributes: Attributes(expired: true))
        return single.data
    }

    /// Answers export compliance for a build whose Info.plist has no `ITSAppUsesNonExemptEncryption`.
    public func setUsesNonExemptEncryption(_ id: String, _ value: Bool) async throws -> ASCBuild {
        struct Attributes: Encodable, Sendable { var usesNonExemptEncryption: Bool }
        let single: ASCSingle<ASCBuild> = try await resources.update("\(Self.path)/\(id)", type: "builds", id: id,
                                                                     attributes: Attributes(usesNonExemptEncryption: value))
        return single.data
    }

    /// The app's encryption declarations, newest first.
    public func declarations(appID: String) async throws -> [ASCEncryptionDeclaration] {
        let listing = try await resources.list("/v1/appEncryptionDeclarations", query: ASCQuery(filters: [("app", appID)]), as: ASCEncryptionDeclaration.self)
        return listing.items.sorted { ($0.attributes.createdDate ?? "") > ($1.attributes.createdDate ?? "") }
    }

    /// Points the build's encryption declaration at `declarationID` (PATCH the relationship).
    public func attach(declaration declarationID: String, to buildID: String) async throws {
        try await resources.replaceToOneRelationship("\(Self.path)/\(buildID)", "appEncryptionDeclaration",
                                                     ASCRef(type: "appEncryptionDeclarations", id: declarationID))
    }

    /// How `wait` ended: the build it last read (nil when a `version+number` never appeared) and the end of the poll.
    public struct Waited: Sendable {
        public var end: BuildProcessing.End
        public var build: ASCBuildDetail?
    }

    /// Reads the build every `interval` until processing ends or `timeout` passes. A `version+number` that is not
    /// visible yet (a build that was just uploaded) is looked up again each round. Only reads: cancelling the task
    /// (Ctrl-C) stops it with `CancellationError` and leaves nothing behind. `onRead` sees every read.
    public func wait(_ reference: BuildReference, appID: String? = nil, platform: BuildPlatform? = nil, interval: Duration = .seconds(30),
                     timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     onRead: (ASCBuildDetail?) throws -> Void = { _ in }) async throws -> Waited {
        var id: String?
        if case .id(let given) = reference { id = given }
        var last: ASCBuildDetail?
        let end = try await BuildProcessing.poll(deadline: .now + timeout, interval: interval, sleep: sleep) {
            if id == nil, case .version(let version, let number) = reference {
                id = try await find(version: version, number: number, appID: appID, platform: platform)?.id
            }
            last = nil
            if let id { last = try await get(id: id) }
            try onRead(last)
            return try last?.build.resource.text("processingState")
        }
        return Waited(end: end, build: last)
    }
}

/// The processing loop of a build: `BuildUploader` after an upload, `xless builds wait` on its own.
public enum BuildProcessing {
    /// The states processing ends in.
    public static let terminal: Set<String> = ["VALID", "INVALID", "FAILED"]

    public enum End: Sendable, Equatable {
        /// Processing ended in this state (VALID, INVALID or FAILED).
        case finished(String)
        /// The deadline passed; the last state read (nil when none was).
        case timedOut(String?)
    }

    /// Calls `fetch` (which returns the current processing state, nil when unknown) until it returns a terminal state or
    /// `deadline` passes, sleeping `interval` between reads. Checks for cancellation around every read.
    public static func poll(deadline: ContinuousClock.Instant, interval: Duration,
                            sleep: @Sendable (Duration) async throws -> Void, fetch: () async throws -> String?) async throws -> End {
        while true {
            try Task.checkCancellation()
            let state = try await fetch()
            try Task.checkCancellation()
            if let state, terminal.contains(state) { return .finished(state) }
            if ContinuousClock.now > deadline { return .timedOut(state) }
            try await sleep(interval)
        }
    }
}
