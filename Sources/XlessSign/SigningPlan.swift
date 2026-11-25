import Foundation
import XlessASC
import XlessCore

/// One bundle signed for one lane: the app of a platform, or an app extension.
public struct SigningTarget: @unchecked Sendable {
    public var platform: Platform
    public var distribution: Distribution
    public var bundleID: String
    /// With the signing prefixes expanded (and a React Native overlay's rewrites applied), as `sign` sees them.
    public var entitlements: [String: Any]
    /// An app extension's path in the app (`PlugIns/Widget.appex`); nil for the app.
    public var extensionPath: String?
    /// false when the entitlements could not be read (a React Native app before its first build): nothing is checked
    /// against them.
    public var entitlementsKnown: Bool

    public init(platform: Platform, distribution: Distribution, bundleID: String, entitlements: [String: Any],
                extensionPath: String? = nil, entitlementsKnown: Bool = true) {
        self.platform = platform; self.distribution = distribution; self.bundleID = bundleID; self.entitlements = entitlements
        self.extensionPath = extensionPath; self.entitlementsKnown = entitlementsKnown
    }

    public var isApp: Bool { extensionPath == nil }
    /// `the iOS app`, `PlugIns/Widget.appex`.
    public var label: String { extensionPath ?? "the \(platform.display) app" }

    /// The certificate this target is signed with.
    public var signingKind: CertificateKind { distribution == .appStore ? .distribution : .developerID }
    public var profileType: ProfileType { ProfileType.for(platform: platform, distribution: distribution) }
    public var profileName: String { SigningProfile.name(bundleID: bundleID, type: profileType) }

    /// Why `profile` is not one to sign this target with; empty when it is. `certificate` nil: the certificate is yet to
    /// be made.
    public func problems(of profile: SigningProfile, bundle: String, certificate: String?, now: Date) -> [String] {
        var out: [String] = []
        if profile.state != "ACTIVE" { out.append("it is \(profile.state ?? "not active")") }
        if let e = profile.expires { if e < now.addingTimeInterval(7 * 86_400) { out.append("it expires on \(ASCDate.day(e))") } }
        else { out.append("App Store Connect gives no expiry date for it") }
        if let b = profile.bundleID { if b != bundle { out.append("it is for another bundle ID") } }
        else { out.append("App Store Connect gives no bundle ID for it") }
        if let certificate, !profile.certificateIDs.contains(certificate) {
            out.append("it does not hold the \(signingKind.certificateType.displayName) certificate \(certificate)")
        } else if certificate == nil {
            out.append("it does not hold the certificate this plan creates")
        }
        if entitlementsKnown, let content = profile.content, let granted = try? Entitlements.extract(fromProfile: content) {
            let lacking = Entitlements.profileLacks(user: entitlements, profile: granted, platform: platform)
            if !lacking.isEmpty { out.append("it lacks \(lacking.joined(separator: ", "))") }
        }
        return out
    }
}

/// What `sign` needs of the account and does not have: the plan it prints, then applies. `xless provision` plans the same
/// things (with more around them) from the same checks.
public struct SigningPlan: Sendable {
    public enum Profile: Sendable, Equatable {
        case usable(SigningProfile)
        case create
        /// xless's own profiles (by name) that cannot be signed with, and why.
        case replace([SigningProfile], reasons: [String])
    }

    public struct Item: Sendable {
        public var target: SigningTarget
        /// nil: the bundle ID is not registered.
        public var bundle: String?
        public var enable: [CapabilityRequest]
        public var profile: Profile
    }

    public var items: [Item]
    /// The certificate the profiles hold.
    public var certificate: String

    /// One line per change, in the order they are made. The names in it are the project's, the built app's and Apple's:
    /// whatever would drive the terminal or start a line of its own is written out (`TerminalText`).
    public var changes: [String] {
        items.flatMap { item in
            let id = item.target.bundleID
            var out: [String] = []
            if item.bundle == nil { out.append("register bundle ID \(id) as universal (iOS and macOS), named \"\(PortalName.bundleID(for: id))\"") }
            out += item.enable.map { "enable \($0.type.rawValue) (\($0.type.displayName)) on \(id)" }
            let kind = "\(item.target.profileType.displayName) for \(item.target.label), with certificate \(certificate)"
            switch item.profile {
            case .usable: break
            case .create: out.append("create profile \(item.target.profileName) (\(kind))")
            case .replace(let old, let reasons):
                out.append("replace profile \(item.target.profileName) (\(old.map(\.id).joined(separator: ", ")), which xless made): \(reasons.joined(separator: "; "))")
            }
            return out.map { TerminalText.escaped($0) }
        }
    }

    /// Refuses a plan that changes something: `off` is what turned provisioning updates off.
    public func requireNothing(off: String) throws {
        let changes = self.changes
        guard !changes.isEmpty else { return }
        let renewed = items.flatMap { item in if case .replace(let old, _) = item.profile { old.map { TerminalText.escaped("`xless profiles renew \($0.id)`") } } else { [String]() } }
        throw XlessError(.sign, "signing needs \(changes.count) change\(changes.count == 1 ? "" : "s") on the account, and provisioning updates are off (\(off)): \(changes.joined(separator: "; "))",
                         fix: "make them with `xless provision apply`\(renewed.isEmpty ? "" : " (and \(renewed.joined(separator: ", ")))"), or run `xless sign` once where xless may change the account, then re-run",
                         code: XlessError.provisioningNeeded)
    }

    /// What `sign` prints before it changes anything.
    public var text: String {
        let changes = self.changes
        if changes.isEmpty { return "xless: sign: the account has what signing needs; nothing is changed there" }
        return "xless: sign: \(changes.count) change\(changes.count == 1 ? "" : "s") on the account:\n" + changes.map { "  \($0)" }.joined(separator: "\n")
    }
}

/// Reads what signing needs of the account. Only GETs.
public struct SigningPlanner {
    let account: any SigningAccount
    let now: Date

    public init(account: any SigningAccount, now: Date = Date()) { self.account = account; self.now = now }

    public func plan(_ targets: [SigningTarget], certificate: String) async throws -> SigningPlan {
        var items: [SigningPlan.Item] = []
        for target in targets {
            let needed = Capabilities.required(entitlements: target.entitlements, platform: target.platform).requests
            let bundle = try await account.bundleID(target.bundleID)
            var missing = needed
            if let bundle, !needed.isEmpty { missing = Capabilities.missing(needed, in: try await account.capabilities(of: bundle)) }
            items.append(SigningPlan.Item(target: target, bundle: bundle, enable: missing,
                                          profile: try await profile(for: target, bundle: bundle, certificate: certificate, enabling: missing)))
        }
        return SigningPlan(items: items, certificate: certificate)
    }

    private func profile(for target: SigningTarget, bundle: String?, certificate: String, enabling: [CapabilityRequest]) async throws -> SigningPlan.Profile {
        let existing = try await account.profiles(named: target.profileName, type: target.profileType)
        guard let first = existing.first else { return .create }
        // A profile carries what its bundle ID had when it was made.
        if !enabling.isEmpty { return .replace(existing, reasons: ["it does not carry \(enabling.map(\.type.rawValue).joined(separator: ", ")), enabled above"]) }
        guard let bundle else { return .replace(existing, reasons: ["it is for another bundle ID"]) }
        // A capability enabled (or an app group assigned) by hand in the portal only reaches an existing profile once it
        // is made again. A keychain group outside the team's pattern is not something a new profile changes.
        func problems(_ p: SigningProfile) -> [String] {
            target.problems(of: p, bundle: bundle, certificate: certificate, now: now) + (p.content?.isEmpty ?? true ? ["App Store Connect gives no content for it"] : [])
        }
        if let usable = existing.first(where: { problems($0).isEmpty }) { return .usable(usable) }
        return .replace(existing, reasons: problems(first))
    }
}

/// Applies a signing plan: registers, enables what is missing (never changing the settings of what is enabled), creates
/// profiles, and deletes the ones the plan replaces, all of them named as xless names its own.
public struct SigningApplier {
    let account: APISigningAccount

    public init(account: APISigningAccount) { self.account = account }

    /// The profile of each item, in order.
    public func apply(_ plan: SigningPlan) async throws -> [Data] {
        var out: [Data] = []
        for item in plan.items { out.append(try await apply(item, certificate: plan.certificate)) }
        return out
    }

    func apply(_ item: SigningPlan.Item, certificate: String) async throws -> Data {
        let target = item.target
        var bundle = item.bundle
        if bundle == nil { bundle = try await account.register(bundleID: target.bundleID) }
        guard let bundle else { throw XlessError(.sign, "bundle ID \(target.bundleID) is not registered", fix: "re-run") }
        _ = try await account.enableMissing(item.enable, on: bundle, identifier: target.bundleID)
        var replaced: Set<String> = []
        switch item.profile {
        case .usable(let p): return try content(p)
        case .replace(let old, _):
            for p in old where p.name == target.profileName {
                try await account.deleteProfile(id: p.id)
                replaced.insert(p.id)
            }
        case .create: break
        }
        return try content(try await account.createProfile(name: target.profileName, type: target.profileType, bundleResourceID: bundle,
                                                           bundleID: target.bundleID, certificateID: certificate, replacing: replaced))
    }

    private func content(_ p: SigningProfile) throws -> Data {
        guard let content = p.content, !content.isEmpty else {
            throw XlessError(.sign, "App Store Connect returned a profile without content", fix: "re-run; if it persists, delete the profile in the portal")
        }
        return content
    }
}
