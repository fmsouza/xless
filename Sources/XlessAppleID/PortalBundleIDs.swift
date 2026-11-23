import Foundation
import XlessCore

/// A bundle ID (App ID) as the developer portal's `v1/bundleIds` serves it. Its `id` is the same resource ID the App
/// Store Connect API uses.
public struct PortalBundleID: Codable, Sendable, Equatable {
    public var id: String
    public var identifier: String
    public var name: String
    public var platform: String?

    public init(id: String, identifier: String, name: String, platform: String? = nil) {
        self.id = id; self.identifier = identifier; self.name = name; self.platform = platform
    }
}

/// What a bundle ID's App Groups or iCloud capability links: whether the capability is there, enabled, and the resource
/// IDs of the groups or containers it lists.
public struct LinkedState: Sendable, Equatable {
    public var present: Bool
    public var enabled: Bool
    public var ids: [String]

    public init(present: Bool, enabled: Bool, ids: [String]) {
        self.present = present; self.enabled = enabled; self.ids = ids
    }
}

/// Assigning app groups and iCloud containers to a bundle ID: `PATCH services-account/v1/bundleIds/{id}` with the bundle
/// ID's whole capability graph, in which only the App Groups (or iCloud) capability's `appGroups` (`cloudContainers`)
/// relationship changes; every other capability goes back as Apple sent it (App Store Connect CLI:
/// internal/web/developer_app_groups.go, developer_bundle_ids.go). When v1 refuses as if absent (`PortalFallback`), the
/// `assignApplicationGroupToAppId.action` / `assignCloudContainerToAppId.action` posts fastlane uses set the list
/// instead. Every write is checked by reading the bundle ID again.
public struct PortalBundleIDs: Sendable {
    static let includes = ["bundleIdCapabilities", "bundleIdCapabilities.capability", "bundleIdCapabilities.associatedBundleIds",
                           "bundleIdCapabilities.appGroups", "bundleIdCapabilities.merchantIds", "bundleIdCapabilities.cloudContainers",
                           "bundleIdCapabilities.certificates", "bundleIdCapabilities.appConsentBundleId", "bundleIdCapabilities.macBundleId",
                           "bundleIdCapabilities.relatedAppConsentBundleIds", "bundleIdCapabilities.parentBundleId",
                           "bundleIdCapabilities.mediaSharingProtocolIds"]
    /// The most capabilities one read includes; a bundle ID with this many or more is refused unless Apple says how many.
    static let capabilityLimit = 50
    /// The `limit` Apple reports with a `total` of 0 on a nested relationship that is complete (captured by App Store
    /// Connect CLI, 2026-10-03).
    static let unboundedLimit = 2_147_483_647
    static let page = "https://developer.apple.com/account/resources/identifiers/list"
    static let legacyAssign: [PortalLinkedKind: (path: String, field: String)] = [
        .appGroup: ("QH65B2/account/ios/identifiers/assignApplicationGroupToAppId.action", "applicationGroups"),
        .cloudContainer: ("QH65B2/account/ios/identifiers/assignCloudContainerToAppId.action", "cloudContainers"),
    ]

    public let portal: PortalWebClient

    public init(portal: PortalWebClient) { self.portal = portal }

    /// The bundle ID an argument names: its identifier (`com.example.app`, exact) or its resource ID.
    public func resolve(_ argument: String) async throws -> PortalBundleID {
        let text = argument.trimmingCharacters(in: .whitespaces)
        let fields = [("fields[bundleIds]", "name,identifier,platform")]
        if PortalIdentifiers.isResourceID(text) {
            let response = try await portal.jsonAPIResponse("GET", "v1/bundleIds/\(text)", query: fields)
            if response.status == 404 {
                throw XlessError(.account, "the team has no bundle ID with ID \(text)", fix: "use its identifier (com.example.app) or an ID from `xless bundle-ids list`")
            }
            guard response.isSuccess else {
                throw AppleWebFailure.refused(.developerPortal, method: "GET", path: "/services-account/v1/bundleIds/\(text)", response: response, page: Self.page)
            }
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let data = object["data"] as? [String: Any],
                  let bundle = Self.bundleID(data), bundle.id == text else {
                throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: "/services-account/v1/bundleIds/\(text)", what: "no bundle ID", page: Self.page)
            }
            return bundle
        }
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.*".unicodeScalars.contains($0)) }) else {
            throw XlessError(.account, "\(text) is neither a bundle identifier nor a bundle ID's ID", fix: "use com.example.app or an ID from `xless bundle-ids list`")
        }
        let data = try await portal.jsonAPI("GET", "v1/bundleIds", query: fields + [("filter[identifier]", text), ("limit", "200")], page: Self.page)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["data"] as? [[String: Any]] else {
            throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: "/services-account/v1/bundleIds", what: "no list of bundle IDs", page: Self.page)
        }
        guard let bundle = list.compactMap(Self.bundleID).first(where: { $0.identifier == text }) else {
            throw XlessError(.account, "the team has no bundle ID \(text)", fix: "register it with `xless bundle-ids create \(text)`, or check `xless bundle-ids list`")
        }
        return bundle
    }

    static func bundleID(_ resource: [String: Any]) -> PortalBundleID? {
        let a = resource["attributes"] as? [String: Any] ?? [:]
        guard resource["type"] as? String == "bundleIds", let id = resource["id"] as? String, PortalIdentifiers.isResourceID(id),
              let identifier = a["identifier"] as? String else { return nil }
        return PortalBundleID(id: id, identifier: identifier, name: a["name"] as? String ?? "", platform: a["platform"] as? String)
    }

    /// The bundle ID with its capabilities and what they link (the document a PATCH is built from).
    func document(_ bundle: PortalBundleID) async throws -> [String: Any] {
        let path = "v1/bundleIds/\(bundle.id)"
        let data = try await portal.jsonAPI("GET", path, query: [
            ("fields[bundleIds]", "name,identifier,platform,seedId,wildcard,bundleIdCapabilities"),
            ("include", Self.includes.joined(separator: ",")),
            ("limit[bundleIdCapabilities]", String(Self.capabilityLimit)),
        ], page: Self.page)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let resource = object["data"] as? [String: Any],
              resource["id"] as? String == bundle.id, resource["type"] as? String == "bundleIds" else {
            throw AppleWebFailure.malformed(.developerPortal, method: "GET", path: "/services-account/\(path)", what: "another resource than bundle ID \(bundle.id)", page: Self.page)
        }
        return object
    }

    /// What the bundle ID's capability for `kind` links now.
    public func linked(_ kind: PortalLinkedKind, of bundle: PortalBundleID) async throws -> LinkedState {
        try Self.state(document: try await document(bundle), kind: kind, bundle: bundle.identifier)
    }

    /// Makes the capability for `kind` list exactly `ids` (enabled or not as asked) and returns what Apple then reports.
    /// An App Groups capability the bundle ID lacks is added; a missing iCloud capability is refused (it needs its
    /// setting: `xless bundle-ids capabilities … enable ICLOUD`). Sent once; checked by reading the bundle ID again.
    public func setLinked(_ kind: PortalLinkedKind, ids: [String], enabled: Bool, on bundle: PortalBundleID) async throws -> LinkedState {
        guard ids.allSatisfy(PortalIdentifiers.isResourceID) else {
            throw XlessError(.account, "refused to send an \(kind.noun) ID that is not letters and digits", fix: "this is a bug in xless; please report it")
        }
        let document = try await document(bundle)
        guard let team = await portal.teamID else {
            throw XlessError(.account, "no team is selected for the developer portal", fix: "pass --team <TEAM_ID>")
        }
        let body = try Self.patchBody(document: document, kind: kind, ids: ids, enabled: enabled, teamID: team, bundle: bundle.identifier)
        let path = "v1/bundleIds/\(bundle.id)"
        let response = try await portal.jsonAPIResponse("PATCH", path, body: body)
        if !response.isSuccess {
            if PortalFallback.applies(status: response.status), let legacy = Self.legacyAssign[kind] {
                var form = [("appIdId", bundle.id)]
                if kind == .appGroup { form.append(("displayId", bundle.id)) }
                form += ids.map { (legacy.field, $0) }
                _ = try await portal.legacy(legacy.path, form: form, page: kind.page)
            } else {
                let refusal = AppleWebFailure.refused(.developerPortal, method: "PATCH", path: "/services-account/\(path)", response: response, page: kind.page)
                // 5xx or a timeout: the change may have been made; the bundle ID says.
                guard response.status >= 500 || response.status == 408,
                      let after = try? Self.state(document: try await self.document(bundle), kind: kind, bundle: bundle.identifier),
                      Self.matches(after, ids: ids, enabled: enabled) else { throw refusal }
                return after
            }
        }
        let after = try Self.state(document: try await self.document(bundle), kind: kind, bundle: bundle.identifier)
        guard Self.matches(after, ids: ids, enabled: enabled) else {
            throw XlessError(.account, "the developer portal accepted the change to \(bundle.identifier), but its \(kind.capabilityName) capability now lists \(after.ids.isEmpty ? "nothing" : after.ids.joined(separator: ", ")) instead of \(ids.isEmpty ? "nothing" : ids.joined(separator: ", "))",
                             fix: "check it with `xless \(kind.command) assign` again or at \(kind.page) (\(AppleWebFailure.undocumented))")
        }
        return after
    }

    static func matches(_ state: LinkedState, ids: [String], enabled: Bool) -> Bool {
        Set(state.ids) == Set(ids) && (!enabled || state.enabled)
    }

    // MARK: The capability graph (pure)

    static func unsafe(_ bundle: String, _ why: String) -> XlessError {
        XlessError(.account, "xless cannot safely change \(bundle): the developer portal \(why); nothing was sent",
                   fix: "\(AppleWebFailure.undocumented); re-run with --verbose to see the exchange (redacted), and meanwhile do it at \(page)")
    }

    /// The bundle ID's capabilities, each as Apple included it, in the order the bundle ID lists them. Refused unless
    /// the list is complete: a PATCH replaces it whole, so a capability missing here would be removed.
    static func capabilities(document: [String: Any], bundle: String) throws -> [[String: Any]] {
        let resource = document["data"] as? [String: Any] ?? [:]
        guard let relationship = (resource["relationships"] as? [String: Any])?["bundleIdCapabilities"] as? [String: Any],
              let references = relationship["data"] as? [[String: Any]] else {
            throw unsafe(bundle, "did not list its capabilities")
        }
        if let why = incomplete(relationship, count: references.count, requestedLimit: capabilityLimit) { throw unsafe(bundle, "listed its capabilities \(why)") }
        let included = document["included"] as? [[String: Any]] ?? []
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for reference in references {
            guard reference["type"] as? String == "bundleIdCapabilities", let id = reference["id"] as? String, !id.isEmpty else {
                throw unsafe(bundle, "listed a capability that is not one")
            }
            guard seen.insert(id).inserted else { continue }
            guard let capability = included.first(where: { $0["type"] as? String == "bundleIdCapabilities" && $0["id"] as? String == id }),
                  capabilityType(capability) != nil else {
                throw unsafe(bundle, "left out the details of capability \(id)")
            }
            out.append(capability)
        }
        return out
    }

    /// Why a relationship's list may lack items (a next page, or a total that is not the count), or nil when complete.
    static func incomplete(_ relationship: [String: Any], count: Int, requestedLimit: Int) -> String? {
        if let next = (relationship["links"] as? [String: Any])?["next"] as? String, !next.isEmpty { return "over several pages" }
        let paging = (relationship["meta"] as? [String: Any])?["paging"] as? [String: Any]
        if let total = (paging?["total"] as? NSNumber)?.intValue {
            if total == count { return nil }
            // Apple's placeholder: total 0 next to the items, with the limit asked for (or the unbounded one).
            let limit = (paging?["limit"] as? NSNumber)?.intValue
            if total == 0, count > 0, limit == (requestedLimit > 0 ? requestedLimit : unboundedLimit), requestedLimit == 0 || count < requestedLimit { return nil }
            return "as \(count) of \(total)"
        }
        if requestedLimit > 0, count >= requestedLimit { return "up to its limit of \(requestedLimit), maybe not all" }
        return nil
    }

    /// The capability type of an included `bundleIdCapabilities` (`APP_GROUPS`), from its `capability` relationship.
    static func capabilityType(_ capability: [String: Any]) -> String? {
        let data = ((capability["relationships"] as? [String: Any])?["capability"] as? [String: Any])?["data"] as? [String: Any]
        guard data?["type"] as? String == "capabilities", let id = data?["id"] as? String, !id.isEmpty else { return nil }
        return id.uppercased()
    }

    /// What the capability for `kind` links in `document`.
    static func state(document: [String: Any], kind: PortalLinkedKind, bundle: String) throws -> LinkedState {
        let matching = try capabilities(document: document, bundle: bundle).filter { capabilityType($0) == kind.capability }
        guard let capability = matching.first else { return LinkedState(present: false, enabled: false, ids: []) }
        guard matching.count == 1 else { throw unsafe(bundle, "listed \(kind.capability) twice") }
        guard let enabled = ((capability["attributes"] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue else {
            throw unsafe(bundle, "did not say whether \(kind.capability) is enabled")
        }
        guard let relationship = (capability["relationships"] as? [String: Any])?[kind.relationship] as? [String: Any],
              let references = relationship["data"] as? [[String: Any]] else {
            throw unsafe(bundle, "did not list the \(kind.relationship) of its \(kind.capability) capability")
        }
        if let why = incomplete(relationship, count: references.count, requestedLimit: 0) {
            throw unsafe(bundle, "listed the \(kind.relationship) of its \(kind.capability) capability \(why)")
        }
        var ids: [String] = []
        for r in references {
            guard r["type"] as? String == kind.relationship, let id = r["id"] as? String, PortalIdentifiers.isResourceID(id) else {
                throw unsafe(bundle, "listed an \(kind.noun) that is not one")
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return LinkedState(present: true, enabled: enabled, ids: ids)
    }

    /// The PATCH body: the bundle ID as Apple sent it (attributes without the `~permissions…` ones, plus `teamId`), with
    /// every capability reduced to its writable attributes (`enabled`, `settings`) and the one for `kind` set to `ids`.
    static func patchBody(document: [String: Any], kind: PortalLinkedKind, ids: [String], enabled: Bool, teamID: String, bundle: String) throws -> Data {
        let resource = document["data"] as? [String: Any] ?? [:]
        var capabilities = try capabilities(document: document, bundle: bundle)
        let linked: [String: Any] = ["data": ids.map { ["type": kind.relationship, "id": $0] }]
        if let i = capabilities.firstIndex(where: { capabilityType($0) == kind.capability }) {
            var attributes = capabilities[i]["attributes"] as? [String: Any] ?? [:]
            attributes["enabled"] = enabled
            var relationships = capabilities[i]["relationships"] as? [String: Any] ?? [:]
            relationships[kind.relationship] = linked
            capabilities[i]["attributes"] = attributes
            capabilities[i]["relationships"] = relationships
        } else if kind == .appGroup {
            capabilities.append(["type": "bundleIdCapabilities",
                                 "attributes": ["enabled": enabled, "settings": [Any]()],
                                 "relationships": ["capability": ["data": ["type": "capabilities", "id": kind.capability]], kind.relationship: linked]])
        } else {
            throw XlessError(.account, "\(bundle) does not have the \(kind.capabilityName) capability, so no \(kind.noun) can be assigned to it; nothing was sent",
                             fix: "enable it first with `xless bundle-ids capabilities \(bundle) enable \(kind.capability)` (or let `xless sign` enable it), then re-run")
        }
        for i in capabilities.indices {
            let attributes = capabilities[i]["attributes"] as? [String: Any] ?? [:]
            var writable: [String: Any] = ["settings": attributes["settings"] ?? [Any]()]
            if let e = attributes["enabled"] { writable["enabled"] = e }
            capabilities[i]["attributes"] = writable
        }
        var attributes = (resource["attributes"] as? [String: Any] ?? [:]).filter { !$0.key.hasPrefix("~permissions") && $0.key != "permissions" }
        attributes["teamId"] = teamID
        var relationships = resource["relationships"] as? [String: Any] ?? [:]
        relationships["bundleIdCapabilities"] = ["data": capabilities]
        let data: [String: Any] = ["id": resource["id"] ?? "", "type": "bundleIds", "attributes": attributes, "relationships": relationships]
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}
