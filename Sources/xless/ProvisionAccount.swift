import Crypto
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessSign
import XlessStore
import XlessVault

// The sides `xless provision` reads and changes, as narrow protocols so the planner and the applier are tested over an
// in-memory account (Tests/XlessCLITests/ProvisionTests.swift): the documented API (API key), the Apple ID web session,
// the secret store and the `appstore/` listing.

struct ProvisionGroup: Sendable, Equatable {
    var id: String
    var name: String
    var isInternal: Bool
}

/// The documented App Store Connect API (the API key): bundle IDs, capabilities, certificates, profiles, the app and
/// its TestFlight groups. The signing part is `sign`'s; the certificate and app parts are the ones `xless certs create` and `xless apps create` use.
protocol ProvisionAccount: SigningAccount, CertificateAPI, AppCreationAPI {
    func betaGroups(app appID: String) async throws -> [ProvisionGroup]
    func createBetaGroup(name: String, app appID: String, external: Bool) async throws
}

/// App Privacy through the web session (`StorePrivacy`).
protocol ProvisionPrivacy: Sendable {
    func plan(_ want: AppYAML.Privacy, app: String, appName: String) async throws -> [StoreChange]
    func apply(_ change: StoreChange, app: String) async throws
}

extension StorePrivacy: ProvisionPrivacy {}

/// What the Apple ID web session does for `provision`: app groups and iCloud containers, the APNs key, the app record
/// and App Privacy (the interfaces of `xless app-groups`, `keys`, `apps create` and `store privacy`).
struct ProvisionWebSide: Sendable {
    var appGroups: any LinkedIdentifierPortal
    var cloudContainers: any LinkedIdentifierPortal
    var authKeys: any AuthKeyWeb
    var apps: any AppCreationWeb & Sendable
    var privacy: any ProvisionPrivacy

    func portal(_ kind: PortalLinkedKind) -> any LinkedIdentifierPortal { kind == .appGroup ? appGroups : cloudContainers }
}

/// What a push of the listing would send, for the plan.
struct ProvisionListingPlan: Sendable, Equatable {
    /// One line per change, as `xless store push` prints them.
    var changes: [String]
    /// The subjects of the changes held back because they delete something.
    var held: [String]
    var notes: [String]
    /// The names of the secrets it would send (the demo account's password).
    var secrets: [String] = []
}

/// What a push of the listing sent, and what it held back once planned again against what App Store Connect then had
/// (a new version Apple filled from the previous one): the subjects of the changes that would delete or replace.
struct ProvisionListingApplied: Sendable, Equatable {
    var sent: Int
    var held: [String] = []
    /// That plan's notes (a localization App Store Connect has and the manifest lacks, kept).
    var notes: [String] = []
}

/// The `appstore/` listing (`xless store push`, with nothing that deletes).
protocol ProvisionListing: Sendable {
    func plan(appID: String) async throws -> ProvisionListingPlan
    /// Pushes what differs (planning again after it creates a version or a product).
    func apply(appID: String) async throws -> ProvisionListingApplied
}

/// The secret store and the environment: which signing and auth keys exist (no passphrase), their values when needed
/// (the passphrase, asked once per process: `unlock` is the resolver the API key came from).
struct ProvisionVault: @unchecked Sendable {
    let store: any SecretStore
    let env: [String: String]

    /// The store as it is now (nil when `xless secrets init` was never run); needs no passphrase.
    func file() throws -> SecretCatalog? {
        do { return try store.catalog() } catch { throw XlessError.wrapping(error, stage: .account) }
    }

    /// The store as it is now; an error when there is none.
    func existing() throws -> SecretCatalog {
        do { return try store.existingCatalog() } catch { throw XlessError.wrapping(error, stage: .account) }
    }

    /// A key given in the environment, `NAME` or `NAME_FILE` (the secret store is not asked).
    func environmentKey(_ name: String) throws -> String? { try Secrets(env: env, fallback: nil).optional(name, stage: .account) }

    /// Unlocks the store for `file` to store something in it (asks the vault's passphrase, once per process; a credential
    /// helper must pass a test write, `SecretStore.probeWrites`); refuses a store a newer xless wrote first.
    func unlock(_ file: SecretCatalog, reason: String) throws {
        do {
            try file.requireWritable()
            try store.unlock(file, remember: nil, reason: reason)
            try store.probeWrites(reason: reason)
        } catch { throw XlessError.wrapping(error, stage: .account) }
    }

    /// Unlocks the store when it is what will give one of the secrets `names`.
    func unlock(toRead names: [String], team: String) throws {
        guard let file = try file() else { return }
        for name in names where try environmentKey(name) == nil {
            guard (try? VaultResolver.preferredCandidate(for: name, in: file, team: team)) ?? nil != nil else { continue }
            do { try store.unlock(file, remember: nil, reason: "reading \(name)") } catch { throw XlessError.wrapping(error, stage: .account) }
        }
    }

    func open(_ entry: VaultEntry, in file: SecretCatalog, reason: String) throws -> SecretBytes {
        do { return try store.secret(entry, in: file, reason: reason) } catch { throw XlessError.wrapping(error, stage: .account) }
    }
}

// MARK: - The real sides

struct APIProvisionAccount: ProvisionAccount {
    let resources: ASCResources

    var issuerID: String { resources.issuerID }
    var signing: APISigningAccount { APISigningAccount(resources: resources, stage: .account) }
    var certificates: ASCCertificates { ASCCertificates(resources: resources) }

    func bundleID(_ identifier: String) async throws -> String? { try await signing.bundleID(identifier) }
    func register(bundleID identifier: String) async throws -> String { try await signing.register(bundleID: identifier) }
    func capabilities(of bundleResourceID: String) async throws -> [SigningCapability] { try await signing.capabilities(of: bundleResourceID) }
    func enable(_ request: CapabilityRequest, on bundleResourceID: String, identifier: String) async throws {
        try await signing.enable(request, on: bundleResourceID, identifier: identifier)
    }
    func profiles(named name: String, type: ProfileType) async throws -> [SigningProfile] { try await signing.profiles(named: name, type: type) }
    func createProfile(name: String, type: ProfileType, bundleResourceID: String, bundleID identifier: String, certificateID: String) async throws -> SigningProfile {
        try await signing.createProfile(name: name, type: type, bundleResourceID: bundleResourceID, bundleID: identifier, certificateID: certificateID)
    }

    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate] {
        try await certificates.list(types: types, withContent: withContent)
    }

    func create(type: CertificateType, csrPEM: String, relatedID: String?) async throws -> ASCCertificate {
        try await certificates.create(type: type, csrPEM: csrPEM, relatedID: relatedID)
    }

    func findApp(bundleID: String) async throws -> AppSummary? { try await ASCApps(resources: resources).find(bundleID: bundleID).map(AppSummary.init) }
    func showsApp(id: String) async throws -> Bool { try await ASCApps(resources: resources).shows(id: id) }
    func hasBundleID(_ identifier: String) async throws -> Bool { try await bundleID(identifier) != nil }
    func registerBundleID(_ identifier: String) async throws { _ = try await register(bundleID: identifier) }

    func betaGroups(app appID: String) async throws -> [ProvisionGroup] {
        try await ASCTestFlight(resources: resources).groups(app: appID).map { ProvisionGroup(id: $0.id, name: $0.name, isInternal: $0.isInternal) }
    }

    func createBetaGroup(name: String, app appID: String, external: Bool) async throws {
        _ = try await ASCTestFlight(resources: resources).createGroup(name: name, app: appID, external: external, allBuilds: !external)
    }
}

/// `xless store push` of the manifest, every part but App Privacy (planned on its own), holding back what deletes.
struct StorePushListing: ProvisionListing {
    let client: ASCClient
    let manifest: StoreManifest
    let dir: URL
    let secrets: Secrets
    let say: @Sendable (String) -> Void

    var options: StorePush.Options { .provision() }

    func plan(appID: String) async throws -> ProvisionListingPlan {
        let resources = ASCResources(client: client)
        let app = try await ASCApps(resources: resources).get(id: appID)
        let (plan, _) = try await StorePush(resources: resources, say: say).plan(app: app, manifest: manifest, dir: dir, options: options)
        return ProvisionListingPlan(changes: plan.changes.map(\.text), held: plan.held.map(\.subject), notes: plan.notes,
                                    secrets: Set(plan.changes.flatMap(\.requests).compactMap(\.secret)).sorted())
    }

    func apply(appID: String) async throws -> ProvisionListingApplied {
        let resources = ASCResources(client: client)
        let app = try await ASCApps(resources: resources).get(id: appID)
        let push = StorePush(resources: resources, say: say)
        let (plan, _) = try await push.plan(app: app, manifest: manifest, dir: dir, options: options)
        let secrets = self.secrets
        let sender = StoreSender(client: client, secret: { try StorePushCLI.demoPassword($0, secrets: secrets) })
        let applied = try await push.apply(plan, app: app, manifest: manifest, dir: dir, options: options, sender: sender)
        // Planned again after a new version (or product) was made: what that plan held back is drift the plan did not show.
        let last = applied.replanned ?? plan
        return ProvisionListingApplied(sent: applied.sent.count, held: last.held.map(\.subject), notes: last.notes)
    }
}

extension ProvisionWebSide {
    /// The web side over a signed-in session whose team is selected.
    init(session: AppleWebSession) {
        self.init(appGroups: WebLinkedIdentifiers(kind: .appGroup, portal: session.portal),
                  cloudContainers: WebLinkedIdentifiers(kind: .cloudContainer, portal: session.portal),
                  authKeys: PortalAuthKeys(portal: session.portal),
                  apps: WebAppCreation(apps: ASCWebApps(asc: session.asc), portal: PortalBundleIDs(portal: session.portal)),
                  privacy: StorePrivacy(remote: ASCWebPrivacy(asc: session.asc)))
    }
}
