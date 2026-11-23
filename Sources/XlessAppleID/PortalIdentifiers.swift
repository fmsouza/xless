import Foundation
import XlessCore

// App groups and iCloud containers (`xless app-groups`, `xless icloud-containers`): the App Store Connect API can neither
// create nor assign them, so they go through the developer portal's web interface on the Apple ID session. iCloud
// containers use the portal's `v1/cloudContainers` (App Store Connect CLI: internal/web/developer_icloud_containers*.go);
// app groups have no known v1 resource and use the `QH65B2/….action` posts the portal's pages and fastlane use
// (spaceship/portal/portal_client.rb). Where a v1 call is refused as if it did not exist (`PortalFallback`), the
// matching `.action` post is tried instead.

/// Which of the two identifiers a command handles.
public enum PortalLinkedKind: String, Sendable, CaseIterable {
    case appGroup
    case cloudContainer

    /// `app group`, `iCloud container`.
    public var noun: String {
        switch self { case .appGroup: "app group"; case .cloudContainer: "iCloud container" }
    }

    /// The xless command: `app-groups`, `icloud-containers`.
    public var command: String {
        switch self { case .appGroup: "app-groups"; case .cloudContainer: "icloud-containers" }
    }

    /// The literal prefix Apple requires.
    public var prefix: String {
        switch self { case .appGroup: "group."; case .cloudContainer: "iCloud." }
    }

    public var example: String { prefix + "com.example.app" }

    /// The bundle-ID capability the identifiers are assigned through.
    public var capability: String {
        switch self { case .appGroup: "APP_GROUPS"; case .cloudContainer: "ICLOUD" }
    }

    /// The capability's display name, as the portal shows it.
    public var capabilityName: String {
        switch self { case .appGroup: "App Groups"; case .cloudContainer: "iCloud" }
    }

    /// The relationship of that capability that lists them, and their JSON:API type (the same word).
    public var relationship: String {
        switch self { case .appGroup: "appGroups"; case .cloudContainer: "cloudContainers" }
    }

    /// Where a person does the same in a browser.
    public var page: String {
        switch self {
        case .appGroup: "https://developer.apple.com/account/resources/identifiers/list/applicationGroup"
        case .cloudContainer: "https://developer.apple.com/account/resources/identifiers/list/cloudContainer"
        }
    }

    /// The identifier, trimmed, if it is one Apple accepts: the exact prefix, then letters, digits, `-` and `.` without
    /// empty parts. Checked before anything is sent.
    public func validate(_ text: String) throws -> String {
        let id = text.trimmingCharacters(in: .whitespaces)
        guard id.hasPrefix(prefix) else {
            if id.lowercased().hasPrefix(prefix.lowercased()) {
                throw PortalInputError("\(id): an \(noun) identifier starts with \(prefix) exactly (\(prefix + id.dropFirst(prefix.count)))")
            }
            throw PortalInputError("\(id) is not an \(noun) identifier: it starts with \(prefix), e.g. \(example)")
        }
        let rest = id.dropFirst(prefix.count)
        guard !rest.isEmpty else { throw PortalInputError("\(id): an \(noun) identifier needs a reverse-DNS name after \(prefix), e.g. \(example)") }
        guard rest.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }) else {
            throw PortalInputError("\(id): an \(noun) identifier has only letters, digits, - and . after \(prefix)")
        }
        guard !rest.hasPrefix("."), !rest.hasSuffix("."), !rest.contains("..") else {
            throw PortalInputError("\(id): an \(noun) identifier has no empty part between dots")
        }
        guard id.count <= 255 else { throw PortalInputError("\(id): an \(noun) identifier has at most 255 characters") }
        return id
    }
}

/// An identifier or name that is wrong before anything is sent.
public struct PortalInputError: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One app group or iCloud container of the team. `id` is the portal's resource ID (what a bundle ID's capability links).
public struct PortalIdentifier: Codable, Sendable, Equatable {
    public var id: String
    public var identifier: String
    public var name: String
    public var prefix: String?
    /// App groups: the portal's status (`current`).
    public var status: String?
    /// iCloud containers: hidden in the portal's list.
    public var hidden: Bool?

    public init(id: String, identifier: String, name: String, prefix: String? = nil, status: String? = nil, hidden: Bool? = nil) {
        self.id = id; self.identifier = identifier; self.name = name; self.prefix = prefix; self.status = status; self.hidden = hidden
    }
}

/// What `create` did: registered it, or found it registered (and sent nothing).
public enum PortalCreation: Sendable, Equatable {
    case created(PortalIdentifier)
    case existing(PortalIdentifier)

    public var item: PortalIdentifier {
        switch self { case .created(let i), .existing(let i): i }
    }
}

/// When a v1 call's refusal means "not here" (the endpoint, or the body shape, is not what Apple serves now) rather than
/// "no": then the older `.action` post is tried. 401/403, agreements, 409 and 5xx are real answers (or unknown
/// outcomes) and are never retried another way.
public enum PortalFallback {
    public static let statuses: Set<Int> = [400, 404, 405, 415, 422]
    public static func applies(status: Int) -> Bool { statuses.contains(status) }
}

public enum PortalIdentifiers {
    /// A resource ID: letters and digits only (anything else never reaches a URL or a form).
    public static func isResourceID(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// The item an argument names, by identifier (it has a dot) or by resource ID, among the team's.
    public static func resolve(_ argument: String, in items: [PortalIdentifier], kind: PortalLinkedKind) throws -> PortalIdentifier {
        let text = argument.trimmingCharacters(in: .whitespaces)
        if text.contains(".") {
            let id: String
            do { id = try kind.validate(text) } catch let e as PortalInputError { throw XlessError(.account, e.description, fix: "use an identifier like \(kind.example), or the ID from `xless \(kind.command) list`") }
            guard let found = items.first(where: { $0.identifier == id }) else {
                throw XlessError(.account, "the team has no \(kind.noun) \(id)", fix: "create it with `xless \(kind.command) create \(id)`, or check `xless \(kind.command) list`")
            }
            return found
        }
        guard let found = items.first(where: { $0.id == text }) else {
            throw XlessError(.account, "the team has no \(kind.noun) with ID \(text)", fix: "use an identifier (\(kind.example)) or an ID from `xless \(kind.command) list`")
        }
        return found
    }

    /// The `[(name, value)]` form of a legacy listing page.
    static func pageForm(_ page: Int, size: Int) -> [(String, String)] {
        [("pageNumber", String(page)), ("pageSize", String(size)), ("sort", "name=asc")]
    }

    /// Reads every page of a legacy listing (`listKey` holds the items, `totalRecords` their count).
    static func legacyList(_ portal: PortalWebClient, path: String, listKey: String, page: String,
                           item: ([String: Any]) -> PortalIdentifier?) async throws -> [PortalIdentifier] {
        var items: [PortalIdentifier] = []
        for number in 1...maxPages {
            let data = try await portal.legacy(path, form: pageForm(number, size: pageSize), page: page)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object[listKey] as? [[String: Any]] else {
                throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(path), what: "no \(listKey)", page: page)
            }
            for entry in list {
                guard let i = item(entry) else {
                    throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(path), what: "an entry without an ID or identifier", page: page)
                }
                if !items.contains(where: { $0.id == i.id }) { items.append(i) }
            }
            let total = (object["totalRecords"] as? NSNumber)?.intValue ?? 0
            if list.isEmpty || items.count >= total { return items }
        }
        throw AppleWebFailure.malformed(.developerPortal, method: "POST", path: PortalWebClient.display(path), what: "more than \(maxPages) pages", page: page)
    }

    static let pageSize = 500
    static let maxPages = 20

    /// An entry of a legacy listing: the ID under `idKey`, plus identifier, name, prefix, status.
    static func legacyItem(_ entry: [String: Any], idKey: String) -> PortalIdentifier? {
        guard let id = entry[idKey] as? String, !id.isEmpty, let identifier = entry["identifier"] as? String, !identifier.isEmpty else { return nil }
        return PortalIdentifier(id: id, identifier: identifier, name: entry["name"] as? String ?? "", prefix: entry["prefix"] as? String,
                                status: entry["status"] as? String)
    }
}

/// The team's app groups (`QH65B2/account/ios/identifiers/…ApplicationGroup….action`).
public struct PortalAppGroups: Sendable {
    static let listPath = "QH65B2/account/ios/identifiers/listApplicationGroups.action"
    static let createPath = "QH65B2/account/ios/identifiers/addApplicationGroup.action"
    public let portal: PortalWebClient

    public init(portal: PortalWebClient) { self.portal = portal }

    public func list() async throws -> [PortalIdentifier] {
        try await PortalIdentifiers.legacyList(portal, path: Self.listPath, listKey: "applicationGroupList", page: PortalLinkedKind.appGroup.page) {
            PortalIdentifiers.legacyItem($0, idKey: "applicationGroup")
        }
    }

    /// Registers the group unless the team has it (then nothing is sent). Sent once, never retried.
    public func create(identifier: String, name: String) async throws -> PortalCreation {
        let existing = try await list()
        if let found = existing.first(where: { $0.identifier == identifier }) { return .existing(found) }
        try await portal.primeCSRF()
        let data = try await portal.legacy(Self.createPath, form: [("name", name), ("identifier", identifier)], page: PortalLinkedKind.appGroup.page)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entry = object["applicationGroup"] as? [String: Any],
           let created = PortalIdentifiers.legacyItem(entry, idKey: "applicationGroup") {
            return .created(created)
        }
        if let created = try? await list().first(where: { $0.identifier == identifier }) { return .created(created) }
        throw XlessError(.account, "the developer portal accepted app group \(identifier) but its answer names no group",
                         fix: "check `xless app-groups list` before re-running (\(AppleWebFailure.undocumented))")
    }
}

/// The team's iCloud containers: `v1/cloudContainers` (visible and hidden), else the `QH65B2/account/cloudContainer/…`
/// posts. They cannot be deleted.
public struct PortalCloudContainers: Sendable {
    static let path = "v1/cloudContainers"
    static let listQuery = [("limit", "1000"), ("offset", "0"), ("sort", "name")]
    static let legacyListPath = "QH65B2/account/cloudContainer/listCloudContainers.action"
    static let legacyCreatePath = "QH65B2/account/cloudContainer/addCloudContainer.action"
    public let portal: PortalWebClient

    public init(portal: PortalWebClient) { self.portal = portal }

    var page: String { PortalLinkedKind.cloudContainer.page }

    public func list() async throws -> [PortalIdentifier] {
        var items: [PortalIdentifier] = []
        for hidden in [false, true] {
            let response = try await portal.jsonAPIResponse("GET", Self.path, query: Self.listQuery, urlQuery: [("filter[AND][hidden]", String(hidden))])
            guard response.isSuccess else {
                if PortalFallback.applies(status: response.status) { return try await legacyList() }
                throw AppleWebFailure.refused(.developerPortal, method: "GET", path: PortalWebClient.display(Self.path), response: response, page: page)
            }
            for i in try parseList(response.data) where !items.contains(where: { $0.id == i.id }) { items.append(i) }
        }
        return items
    }

    func parseList(_ data: Data) throws -> [PortalIdentifier] {
        let display = PortalWebClient.display(Self.path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["data"] as? [[String: Any]] else {
            throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: display, what: "no list of containers", page: page)
        }
        let next = (object["links"] as? [String: Any])?["next"] as? String
        let total = (((object["meta"] as? [String: Any])?["paging"] as? [String: Any])?["total"] as? NSNumber)?.intValue
        if !(next ?? "").isEmpty || (total ?? 0) > list.count {
            throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: display, what: "more containers than one page holds (xless reads 1000)", page: page)
        }
        return try list.map { r in
            guard let item = Self.item(r) else {
                throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: display, what: "a container without an ID or identifier", page: page)
            }
            return item
        }
    }

    static func item(_ resource: [String: Any]) -> PortalIdentifier? {
        let a = resource["attributes"] as? [String: Any] ?? [:]
        guard let id = resource["id"] as? String, !id.isEmpty, let identifier = a["identifier"] as? String, !identifier.isEmpty else { return nil }
        return PortalIdentifier(id: id, identifier: identifier, name: a["name"] as? String ?? "", prefix: a["prefix"] as? String,
                                hidden: (a["hidden"] as? NSNumber)?.boolValue ?? false)
    }

    func legacyList() async throws -> [PortalIdentifier] {
        try await PortalIdentifiers.legacyList(portal, path: Self.legacyListPath, listKey: "cloudContainerList", page: page) {
            PortalIdentifiers.legacyItem($0, idKey: "cloudContainer")
        }
    }

    /// Registers the container unless the team has it (then nothing is sent). Sent once, never retried; a container
    /// cannot be deleted afterwards.
    public func create(identifier: String, name: String) async throws -> PortalCreation {
        if let found = try await list().first(where: { $0.identifier == identifier }) { return .existing(found) }
        guard let team = await portal.teamID else {
            throw XlessError(.account, "no team is selected for the developer portal", fix: "pass --team <TEAM_ID>")
        }
        let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "cloudContainers",
                                                                        "attributes": ["identifier": identifier, "name": name, "teamId": team]]],
                                              options: [.sortedKeys])
        let response = try await portal.jsonAPIResponse("POST", Self.path, body: body)
        if response.isSuccess {
            if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let data = object["data"] as? [String: Any],
               let created = Self.item(data), created.identifier == identifier {
                return .created(created)
            }
            return .created(try await readBack(identifier))
        }
        guard PortalFallback.applies(status: response.status) else {
            throw AppleWebFailure.refused(.developerPortal, method: "POST", path: PortalWebClient.display(Self.path), response: response, page: page)
        }
        let data = try await portal.legacy(Self.legacyCreatePath, form: [("name", name), ("identifier", identifier)], page: page)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entry = object["cloudContainer"] as? [String: Any],
           let created = PortalIdentifiers.legacyItem(entry, idKey: "cloudContainer") {
            return .created(created)
        }
        return .created(try await readBack(identifier))
    }

    /// The container just created, from the listing (the answer did not name it).
    func readBack(_ identifier: String) async throws -> PortalIdentifier {
        if let found = try? await list().first(where: { $0.identifier == identifier }) { return found }
        throw XlessError(.account, "the developer portal accepted iCloud container \(identifier) but neither its answer nor the listing shows it",
                         fix: "check `xless icloud-containers list` before re-running: a container cannot be deleted (\(AppleWebFailure.undocumented))")
    }
}
