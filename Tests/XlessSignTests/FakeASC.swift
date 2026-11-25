import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC

/// A stateful stand-in for the App Store Connect endpoints signing uses: certificates, bundle IDs, capabilities and
/// profiles. A profile's entitlements are a snapshot of the identifier's state when the profile is created, as in App
/// Store Connect: something enabled later reaches only a regenerated profile.
final class FakeASC: HTTPTransport, @unchecked Sendable {
    let team: String
    let certificate: String
    /// identifier → resource ID.
    var bundleIDs: [String: String] = [:]
    /// resource ID → enabled capability types.
    var capabilities: [String: [String]] = [:]
    /// App groups assigned to an identifier by hand in the developer portal.
    var assignedGroups: [String: [String]] = [:]
    /// iCloud containers assigned to an identifier by hand in the developer portal.
    var assignedContainers: [String: [String]] = [:]
    /// Groups assigned to every identifier without an `assignedGroups` entry.
    var groupsForAll: [String] = []
    /// Entitlements of capabilities enabled by hand in the portal (no API type), per identifier.
    var portal: [String: [String: Any]] = [:]
    struct Profile {
        var id: String, name: String, bundleResource: String, content: Data
        var certificates = ["C1"], state = "ACTIVE", expires = future
    }
    var profiles: [Profile] = []
    /// Capability types App Store Connect refuses to enable (409).
    var refuse: Set<String> = []
    /// Capability types every new identifier has.
    var enabledByApple: [String] = []
    /// Deleted profiles stay listed (a listing that lags behind).
    var keepsDeleted = false
    /// "METHOD /path" → the next requests to it that fail, and whether what they ask for happens all the same.
    var failures: [String: [(status: Int, happens: Bool)]] = [:]
    private var lost = false
    /// "METHOD /path" of every request, in order.
    var log: [String] = []
    /// Capability types created, as (identifier, type).
    var created: [(String, String)] = []
    /// The settings each created capability was sent with, as "TYPE KEY=OPTION".
    var createdSettings: [String] = []
    private var serial = 0

    init(team: String = "ABCDE12345", certificateJSON: String) { self.team = team; self.certificate = certificateJSON }

    func entitlements(of identifier: String) -> [String: Any] {
        var e: [String: Any] = ["application-identifier": "\(team).\(identifier)", "com.apple.developer.team-identifier": team,
                                "beta-reports-active": true, "get-task-allow": false, "keychain-access-groups": ["\(team).*"]]
        let caps = bundleIDs[identifier].flatMap { capabilities[$0] } ?? []
        if caps.contains("PUSH_NOTIFICATIONS") { e["aps-environment"] = "production" }
        if caps.contains("ASSOCIATED_DOMAINS") { e["com.apple.developer.associated-domains"] = "*" }
        if caps.contains("AUTOFILL_CREDENTIAL_PROVIDER") { e["com.apple.developer.authentication-services.autofill-credential-provider"] = true }
        if caps.contains("ICLOUD") {
            e["com.apple.developer.icloud-container-identifiers"] = assignedContainers[identifier] ?? []
            e["com.apple.developer.icloud-services"] = "*"
            e["com.apple.developer.ubiquity-kvstore-identifier"] = "\(team).*"
        }
        if caps.contains("APPLE_ID_AUTH") { e["com.apple.developer.applesignin"] = ["Default"] }
        if caps.contains("APP_GROUPS") { e["com.apple.security.application-groups"] = assignedGroups[identifier] ?? groupsForAll }
        for (k, v) in portal[identifier] ?? [:] { e[k] = v }
        return e
    }

    private func attributes(_ p: Profile) -> [String: Any] {
        ["name": p.name, "profileState": p.state, "profileType": String(p.name.split(separator: " ").last ?? ""),
         "profileContent": p.content.base64EncodedString(), "expirationDate": p.expires]
    }
    private func next(_ prefix: String) -> String { serial += 1; return "\(prefix)\(serial)" }
    private func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET", url = request.url!, path = url.path
        log.append("\(method) \(path)")
        if let failure = failures["\(method) \(path)"]?.first {
            failures["\(method) \(path)"]!.removeFirst()
            if failure.happens { lost = true } else { return answer(url, failure.status, #"{"errors":[{"status":"\#(failure.status)","code":"X"}]}"#) }
        }
        defer { lost = false }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["data"] as? [String: Any]
        let attrs = body?["attributes"] as? [String: Any] ?? [:]
        func relID(_ name: String) -> String? { ((body?["relationships"] as? [String: Any])?[name] as? [String: Any]).flatMap { ($0["data"] as? [String: Any])?["id"] as? String } }
        let parts = path.split(separator: "/").map(String.init)   // ["v1", "profiles", "P1", "relationships", "bundleId"]
        let (status, text): (Int, String)
        switch (method, parts.count, parts.dropFirst().first ?? "") {
        case ("GET", 2, "certificates"):
            (status, text) = (200, #"{"data":[\#(certificate)]}"#)
        case ("GET", 2, "bundleIds"):
            let id = query["filter[identifier]"] ?? ""
            let data = bundleIDs[id].map { [["type": "bundleIds", "id": $0, "attributes": ["identifier": id, "platform": "UNIVERSAL"]]] } ?? []
            (status, text) = (200, json(["data": data]))
        case ("POST", 2, "bundleIds"):
            let identifier = attrs["identifier"] as! String
            let id = next("B"); bundleIDs[identifier] = id
            if !enabledByApple.isEmpty { capabilities[id] = enabledByApple }
            (status, text) = (201, json(["data": ["type": "bundleIds", "id": id, "attributes": ["identifier": identifier]]]))
        case ("GET", 4, "bundleIds"):
            let data = (capabilities[parts[2]] ?? []).map { ["type": "bundleIdCapabilities", "id": "\(parts[2])_\($0)", "attributes": ["capabilityType": $0]] }
            (status, text) = (200, json(["data": data]))
        case ("POST", 2, "bundleIdCapabilities") where refuse.contains(attrs["capabilityType"] as? String ?? ""):
            (status, text) = (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"There is a problem with the request entity","detail":"This capability is not available for this platform."}]}"#)
        case ("POST", 2, "bundleIdCapabilities"):
            let type = attrs["capabilityType"] as! String, resource = relID("bundleId")!
            capabilities[resource, default: []].append(type)
            for setting in attrs["settings"] as? [[String: Any]] ?? [] {
                let option = ((setting["options"] as? [[String: Any]])?.first?["key"] as? String) ?? ""
                createdSettings.append("\(type) \(setting["key"] as? String ?? "")=\(option)")
            }
            created.append((bundleIDs.first { $0.value == resource }!.key, type))
            (status, text) = (201, json(["data": ["type": "bundleIdCapabilities", "id": next("K"), "attributes": ["capabilityType": type]]]))
        case ("GET", 2, "profiles"):
            let data = profiles.filter { $0.name == query["filter[name]"] }.map { p in
                ["type": "profiles", "id": p.id, "attributes": attributes(p).filter { $0.key != "profileContent" }]
            }
            (status, text) = (200, json(["data": data]))
        case ("GET", 5, "profiles") where parts[4] == "certificates":
            (status, text) = (200, json(["data": profiles.first { $0.id == parts[2] }!.certificates.map { ["type": "certificates", "id": $0] }]))
        case ("GET", 3, "profiles"):
            let p = profiles.first { $0.id == parts[2] }!
            (status, text) = (200, json(["data": ["type": "profiles", "id": p.id, "attributes": attributes(p),
                                                  "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": p.bundleResource]]]]]))
        case ("DELETE", 3, "profiles"):
            if !keepsDeleted { profiles.removeAll { $0.id == parts[2] } }
            (status, text) = (204, "")
        case ("POST", 2, "profiles"):
            let resource = relID("bundleId")!, identifier = bundleIDs.first { $0.value == resource }!.key
            let p = Profile(id: next("P"), name: attrs["name"] as! String, bundleResource: resource, content: try fakeProfile(entitlements(of: identifier)))
            profiles.append(p)
            (status, text) = (201, json(["data": ["type": "profiles", "id": p.id, "attributes": ["name": p.name, "profileContent": p.content.base64EncodedString()]]]))
        default:
            (status, text) = (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"fake","detail":"\#(method) \#(path)"}]}"#)
        }
        return lost ? answer(url, 500, #"{"errors":[{"status":"500","code":"X"}]}"#) : answer(url, status, text)
    }

    private func answer(_ url: URL, _ status: Int, _ text: String) -> (Data, HTTPURLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
