import Foundation
import XlessASC
import XlessCore

public enum Entitlements {
    /// Provisioning profiles are CMS-signed XML plists; read the embedded plist without CMS parsing.
    public static func extract(fromProfile data: Data) throws -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw XlessError(.sign, "provisioning profile has no embedded plist", fix: "delete the profile in App Store Connect and re-run")
        }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ents = dict["Entitlements"] as? [String: Any] else {
            throw XlessError(.sign, "provisioning profile plist lacks Entitlements", fix: "delete the profile in App Store Connect and re-run")
        }
        return ents
    }

    /// The team that issued a profile: its team-identifier entitlement, else the application-identifier prefix.
    static func team(ofProfile p: [String: Any]) -> String? {
        if let t = p["com.apple.developer.team-identifier"] as? String, !t.isEmpty { return t }
        let appID = (p["application-identifier"] as? String) ?? (p["com.apple.application-identifier"] as? String)
        return appID?.split(separator: ".", maxSplits: 1).first.map(String.init)
    }

    /// The API key is scoped to one team, so a wrong `teamID` in xless.yml would otherwise sign and upload fine and
    /// only fail in App Store Connect processing (invalid code-signing entitlements).
    public static func checkTeam(profile: [String: Any], teamID: String) throws {
        guard let team = team(ofProfile: profile) else {
            throw XlessError(.sign, "the provisioning profile names no team (no team-identifier or application-identifier)",
                             fix: "delete the profile in App Store Connect and re-run")
        }
        if team != teamID {
            throw XlessError(.sign, "xless.yml teamID \(teamID) ≠ team \(team) of the App Store Connect key", fix: "set teamID: \(team) in xless.yml")
        }
    }

    /// Keys xless sets itself; everything else in `user` must be granted by the profile.
    static let managedKeys: Set<String> = ["application-identifier", "com.apple.application-identifier",
                                           "com.apple.developer.team-identifier", "get-task-allow", "beta-reports-active"]

    /// macOS sandbox / hardened-runtime keys that are not gated by a provisioning profile.
    static let ungatedKeys: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.inherit",
                                           "com.apple.security.print", "com.apple.security.automation.apple-events"]
    static let ungatedPrefixes = ["com.apple.security.cs.", "com.apple.security.network.", "com.apple.security.files.",
                                  "com.apple.security.device.", "com.apple.security.personal-information."]

    static func isUngated(_ key: String) -> Bool {
        ungatedKeys.contains(key) || ungatedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The App Store profile's `aps-environment` wins over the entitlements file's, as when Xcode signs: a project
    /// says `development`, the distribution profile `production`.
    static let apsEnvironmentValues: Set<String> = ["development", "production"]
    /// macOS spells it with the `com.apple.developer.` prefix; the profile's wins there too.
    static let macAPSEnvironmentKey = "com.apple.developer.aps-environment"

    public static func merge(user: [String: Any], profile: [String: Any], platform: Platform,
                             teamID: String, bundleID: String) throws -> [String: Any] {
        if let problem = problems(user: user, profile: profile, platform: platform).first {
            throw refusal(problem, platform: platform, teamID: teamID, bundleID: bundleID)
        }
        var out = user.filter { !managedKeys.contains($0.key) }
        let appID = "\(teamID).\(bundleID)"
        out["com.apple.developer.team-identifier"] = teamID
        switch platform {
        case .ios:
            out["application-identifier"] = appID
            out["get-task-allow"] = false
            if profile["beta-reports-active"] as? Bool == true { out["beta-reports-active"] = true }
            if let mine = out["aps-environment"] as? String, apsEnvironmentValues.contains(mine),
               let theirs = profile["aps-environment"] as? String { out["aps-environment"] = theirs }
        case .macos:
            out["com.apple.application-identifier"] = appID
            if let mine = out[macAPSEnvironmentKey] as? String, apsEnvironmentValues.contains(mine),
               let theirs = profile[macAPSEnvironmentKey] as? String { out[macAPSEnvironmentKey] = theirs }
        }
        return out
    }

    // MARK: Signing-time build settings

    /// Build settings Xcode defines only while it signs, both `<team ID>.`. The build stage leaves them in the
    /// entitlements it records (`entitlements.json`), as written in the project's entitlements file.
    static let signingPrefixes = ["AppIdentifierPrefix", "TeamIdentifierPrefix"]

    /// Every string value with `$(AppIdentifierPrefix)` / `$(TeamIdentifierPrefix)` (or the `${…}` form) set to `<teamID>.`.
    public static func expandSigningPrefixes(_ ents: [String: Any], teamID: String) -> [String: Any] {
        mapStrings(ents) { s in
            guard s.contains("$") else { return s }
            var s = s
            for name in signingPrefixes { for ref in ["$(\(name))", "${\(name)}"] { s = s.replacingOccurrences(of: ref, with: teamID + ".") } }
            return s
        }
    }

    /// The overlay's `entitlements:` edits: `remove` drops top-level keys, `replace` rewrites every string value.
    public static func rewrite(_ ents: [String: Any], with rewrites: EntitlementRewrites) -> [String: Any] {
        if rewrites.isEmpty { return ents }
        let kept = ents.filter { !rewrites.remove.contains($0.key) }
        return mapStrings(kept) { rewrites.apply(to: $0) }
    }

    static func mapStrings(_ dict: [String: Any], _ f: (String) -> String) -> [String: Any] {
        func map(_ v: Any) -> Any {
            if let s = v as? String { return f(s) }
            if let d = v as? [String: Any] { return d.mapValues(map) }
            if let a = v as? [Any] { return a.map(map) }
            return v
        }
        return dict.mapValues(map)
    }

    // MARK: What a profile grants

    /// A gated entitlement the profile does not grant: the key is absent, or (iOS, `valueCheckedKeys`) some of its
    /// values are not among those the profile lists.
    enum Problem: Equatable {
        case missing(key: String)
        case notAllowed(key: String, values: [String], allowed: [String])
        var key: String { switch self { case .missing(let k), .notAllowed(let k, _, _): k } }
    }

    /// The gated entitlement keys a profile does not grant as `user` asks for them (absent, or values it does not list),
    /// a keychain group outside the team's pattern aside: what regenerating the profile would fix (`xless provision`).
    public static func profileLacks(user: [String: Any], profile: [String: Any], platform: Platform) -> [String] {
        problems(user: user, profile: profile, platform: platform).map(\.key).filter { $0 != keychainGroupsKey }
    }

    static let keychainGroupsKey = "keychain-access-groups"
    static let appGroupsKey = "com.apple.security.application-groups"
    static let associatedDomainsKey = "com.apple.developer.associated-domains"
    /// Keys whose values an iOS profile lists: keychain groups as team patterns (`TEAM.*`), app groups as the groups
    /// assigned to the identifier, associated domains as `*`.
    static let valueCheckedKeys: Set<String> = [keychainGroupsKey, appGroupsKey, associatedDomainsKey]
    static let iCloudContainersKey = "com.apple.developer.icloud-container-identifiers"
    static let ubiquityContainersKey = "com.apple.developer.ubiquity-container-identifiers"
    static let merchantIDsKey = "com.apple.developer.in-app-payments"
    /// Keys whose values are identifiers assigned to the bundle ID (iCloud containers, merchant IDs), on both platforms:
    /// xless enables their capability, but the API cannot assign the identifiers (`xless icloud-containers assign` does,
    /// through the Apple ID web session), and a profile lists only those assigned.
    static let linkedIdentifierKeys: Set<String> = [iCloudContainersKey, ubiquityContainersKey, merchantIDsKey]

    static func problems(user: [String: Any], profile: [String: Any], platform: Platform) -> [Problem] {
        var out: [Problem] = []
        for key in user.keys.sorted() where !managedKeys.contains(key) && !isUngated(key) {
            guard let granted = profile[key] else { out.append(.missing(key: key)); continue }
            guard (platform == .ios && valueCheckedKeys.contains(key)) || linkedIdentifierKeys.contains(key), let value = user[key] else { continue }
            let allowed = strings(granted)
            let refused = strings(value).filter { v in !allowed.contains { matches(v, pattern: $0) } }
            if !refused.isEmpty { out.append(.notAllowed(key: key, values: refused, allowed: allowed)) }
        }
        return out
    }

    /// A string, or the strings of an array; anything else lists nothing.
    static func strings(_ v: Any) -> [String] {
        if let s = v as? String { return [s] }
        return (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Profile patterns: `*` allows anything, a trailing `*` a prefix (`ABCDE12345.*`), anything else itself.
    static func matches(_ value: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") { return value.hasPrefix(pattern.dropLast()) }
        return value == pattern
    }

    static func refusal(_ problem: Problem, platform: Platform, teamID: String, bundleID: String) -> XlessError {
        let portal = "developer.apple.com/account/resources/identifiers"
        switch problem {
        case .missing(let key):
            let cause = "entitlement '\(key)' is not granted by the provisioning profile for \(bundleID)"
            // A key xless enables a capability for: the capability is enabled, so what is left is the identifier it needs
            // (an iCloud container, a merchant ID…) or a capability disabled since; `xless bundle-ids` shows and fixes it.
            if let type = Capabilities.map(for: platform)[key] {
                let command = "xless bundle-ids capabilities \(bundleID)"
                let linked = type.linkedIdentifier.map { " \(type.displayName) also needs \($0) assigned to \(bundleID)\(assignHow(type, bundleID: bundleID))." } ?? ""
                return XlessError(.sign, cause, fix: "check that \(type.displayName) is enabled with `\(command) list` (enable it with `\(command) enable \(type.rawValue)`).\(linked) Then re-run. \(finishFirst)")
            }
            let name = Capabilities.portalNames[key].map { " (\($0))" } ?? ""
            return XlessError(.sign, cause + "; xless cannot enable this capability automatically",
                              fix: "enable the matching capability\(name) for \(bundleID) at \(portal), then re-run. \(finishFirst)")
        // `SignStage` refuses missing app groups for all bundles at once (`checkAppGroups`) before merging; this is the
        // backstop for a direct `merge` caller.
        case .notAllowed(let key, let values, _) where key == appGroupsKey:
            return appGroupRefusal(values.map { ($0, [bundleID]) })
        case .notAllowed(let key, let values, let allowed):
            let cause = "entitlement '\(key)' value\(values.count == 1 ? "" : "s") \(values.map { "'\($0)'" }.joined(separator: ", ")) "
                + "\(values.count == 1 ? "is" : "are") not allowed by the provisioning profile for \(bundleID) (it allows: \(allowed.isEmpty ? "nothing" : allowed.joined(separator: ", ")))"
            if key == iCloudContainersKey || key == ubiquityContainersKey {
                let create = values.map { "`xless icloud-containers create \($0)`" }.joined(separator: ", ")
                return XlessError(.sign, cause, fix: "with the Apple ID web session (`sign` does not sign in): (1) \(create) (it reports a container that exists); (2) `xless icloud-containers assign \(bundleID) \(values.joined(separator: " "))`; (3) re-run (xless regenerates the profile). \(finishFirst)")
            }
            if key == merchantIDsKey {
                let ids = values.joined(separator: ", ")
                return XlessError(.sign, cause, fix: "(1) register the merchant ID with `xless merchant-ids create <identifier> --name <name>` (\(ids); skip one that exists); (2) at \(portal): \(bundleID) → Apple Pay Payment Processing → Edit → select \(ids) → Save; (3) re-run (xless regenerates the profile). \(finishFirst)")
            }
            if key == keychainGroupsKey {
                return XlessError(.sign, cause, fix: "a keychain group must start with the signing team's prefix \(teamID).: write it as $(AppIdentifierPrefix)<group> in the entitlements file, or map it with the overlay's identifiers.replace")
            }
            return XlessError(.sign, cause, fix: "configure the capability for \(bundleID) at \(portal) so its profile allows these values, or change them with the overlay's identifiers.replace, then re-run")
        }
    }

    /// Every run that still finds something missing deletes and recreates the affected profiles.
    static let finishFirst = "Finish every step before re-running: each run regenerates the profiles that still lack something"

    // MARK: App groups

    /// iOS: every app group a bundle's entitlements name must be assigned to its identifier, so that its profile lists
    /// it. App Store Connect's API can neither create an app group nor assign one (Apple's OpenAPI spec has no app-group
    /// resource and no group setting), so a missing group is one refusal with the `xless app-groups` commands for all
    /// bundles (they use the Apple ID web session, which `sign` never opens by itself).
    static func checkAppGroups(_ bundles: [(bundleID: String, user: [String: Any], profile: [String: Any])]) throws {
        var missing: [(group: String, bundleIDs: [String])] = []
        for b in bundles {
            guard let value = b.user[appGroupsKey] else { continue }
            let allowed = b.profile[appGroupsKey].map(strings) ?? []
            for group in strings(value) where !allowed.contains(where: { matches(group, pattern: $0) }) {
                if let i = missing.firstIndex(where: { $0.group == group }) { missing[i].bundleIDs.append(b.bundleID) }
                else { missing.append((group, [b.bundleID])) }
            }
        }
        if !missing.isEmpty { throw appGroupRefusal(missing) }
    }

    static func appGroupRefusal(_ missing: [(group: String, bundleIDs: [String])]) -> XlessError {
        let groups = missing.map(\.group)
        let ids = missing.flatMap(\.bundleIDs).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let cause = (missing.count == 1
            ? "app group \(groups[0]) is not in the provisioning profile\(ids.count == 1 ? "" : "s") of \(ids.joined(separator: ", "))"
            : "app groups are missing from provisioning profiles: " + missing.map { "\($0.group) (\($0.bundleIDs.joined(separator: ", ")))" }.joined(separator: "; "))
            + "; assigning app groups needs the Apple ID web session, which `sign` does not use"
        let create = groups.map { "`xless app-groups create \($0)`" }.joined(separator: ", ")
        let assign = ids.map { id in
            "`xless app-groups assign \(id) \(missing.filter { $0.bundleIDs.contains(id) }.map(\.group).joined(separator: " "))`"
        }.joined(separator: ", ")
        let fix = "(1) \(create) (it reports a group that exists); (2) \(assign); (3) re-run (xless regenerates the profiles). "
            + "A test build under another team: map the group to one this team owns with the overlay's identifiers.replace. "
            + finishFirst
        return XlessError(.sign, cause, fix: fix)
    }

    /// How a linked identifier gets assigned: the xless command for app groups and iCloud containers, else the portal.
    static func assignHow(_ type: CapabilityType, bundleID: String) -> String {
        switch type {
        case .appGroups: ": `xless app-groups assign \(bundleID) <group>`"
        case .icloud: ": `xless icloud-containers assign \(bundleID) <container>`"
        default: " at developer.apple.com/account/resources/identifiers (\(type.displayName) → Configure)"
        }
    }
}
