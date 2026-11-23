import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault

// `xless auth api-key`: what the commands sequence, kept apart from the terminal and the network so the order (create,
// download once, store, verify) and every failure message are tested with fakes (docs/apple-account.md#xless-auth-api-key).

/// What `create` needs from App Store Connect's web interface (`ASCAPIKeys`; a fake in tests).
protocol APIKeyWeb: Sendable {
    func create(nickname: String, roles: [String], appIDs: [String]) async throws -> ASCAPIKeyInfo
    func downloadPrivateKey(id: String) async throws -> SecretBytes
}

extension ASCAPIKeys: APIKeyWeb {}

/// One documented-API call with a key: proof it works.
typealias APIKeyVerifier = @Sendable (ASCCredentials) async throws -> Void

/// The roles an API key can have, and the default.
enum APIKeyRoles {
    static let known = ["ADMIN", "APP_MANAGER", "DEVELOPER", "FINANCE", "SALES", "MARKETING", "CUSTOMER_SUPPORT", "ACCESS_TO_REPORTS"]
    static let defaultRole = "APP_MANAGER"

    /// `app-manager`, `App Manager`, `APP_MANAGER` → `APP_MANAGER`; unknown names are refused. Empty → the default.
    static func parse(_ texts: [String]) throws -> [String] {
        var roles: [String] = []
        for text in texts {
            let role = text.trimmingCharacters(in: .whitespaces).uppercased()
                .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            guard known.contains(role) else {
                throw XlessError(.account, "--role \(text) is not an API key role", fix: "use one of \(known.joined(separator: ", "))")
            }
            if !roles.contains(role) { roles.append(role) }
        }
        return roles.isEmpty ? [defaultRole] : roles
    }

    /// The text recorded in the store and shown by `auth status`: `APP_MANAGER`, `ADMIN,FINANCE`.
    static func recorded(_ roles: [String]) -> String? { roles.isEmpty ? nil : roles.joined(separator: ",") }
}

/// The store side: which entry an API key goes to, and keeping it there.
struct APIKeyStore {
    static let base = "ASC_KEY_P8"

    /// `ASC_KEY_P8@<TEAM_ID>`, or `ASC_KEY_P8` without a team.
    static func entryName(team: String?) -> String { team.map { "\(base)@\($0)" } ?? base }

    /// Refuses, before anything is created, when the store already holds the entry or resolves an `ASC_KEY_P8` for the
    /// team: a second one would make the pipeline's choice ambiguous.
    static func precheck(_ file: some SecretEntries, name: String, team: String?) throws {
        let existing: VaultEntry?
        do { existing = try file.entry(named: name) ?? VaultResolver.candidate(for: base, in: file, team: team) } catch {
            throw XlessError(.account, "the secret store already has several \(base) entries\(team.map { " for team \($0)" } ?? "")",
                             fix: "remove the ones you no longer use (`xless secrets list`, `xless secrets rm <name>`), then re-run")
        }
        guard let existing else { return }
        let id = existing.metadata.keyID
        throw XlessError(.account, "the secret store already has an API key for \(team.map { "team \($0)" } ?? "xless") (\(existing.name)\(id.map { ", key \($0)" } ?? ""))",
                         fix: "replace it: \(id.map { "`xless auth api-key revoke \($0)` revokes it and removes the entry, or " } ?? "")`xless secrets rm \(existing.name)` removes the entry; then re-run")
    }

    /// The store, unlocked by this command (`SecretStore.unlock`) before anything was asked of Apple.
    let store: any SecretStore
    /// The store this command read and unlocked.
    let catalogID: String

    /// Puts the key into the store; returns the entry name used: `name`, or `name.<KEY_ID>` when `name` was taken
    /// since the precheck (the key is never dropped for a name).
    func save(name: String, secret: SecretBytes, metadata: VaultEntry.Metadata) throws -> String {
        var used = name
        try store.update(reason: "storing the new API key") { file in
            guard file.id == catalogID else {
                throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command")
            }
            used = name
            if file.entry(named: used) != nil { used = "\(name).\(metadata.keyID ?? "new")" }
            var n = 2
            while file.entry(named: used) != nil { used = "\(name).\(metadata.keyID ?? "new").\(n)"; n += 1 }
            return [.add(name: used, kind: .ascAPIKey, metadata: metadata, secret: secret)]
        }
        return used
    }

    /// Removes the store's API-key entries of `keyID` (any team); returns their names. Needs no passphrase.
    static func removeKeys(id keyID: String, from store: any SecretStore) throws -> [String] {
        guard let file = try store.catalog(), file.entries.contains(where: { matches($0, keyID) }) else { return [] }
        var removed: [String] = []
        try store.update(reason: "removing API key \(keyID)") { current in
            removed = current.entries.filter { matches($0, keyID) }.map(\.name)
            return removed.map { .remove(name: $0) }
        }
        return removed
    }

    static func matches(_ entry: VaultEntry, _ keyID: String) -> Bool { entry.kind == .ascAPIKey && entry.metadata.keyID == keyID }
}

/// What `create` reports (`--json` prints it as is).
struct APIKeyCreated: Encodable, Equatable {
    let keyID: String
    let nickname: String
    let roles: [String]
    let allApps: Bool
    let appIDs: [String]
    let issuerID: String
    let team: String
    let entry: String
    let verified: Bool

    var text: String {
        """
        created API key \(keyID) "\(nickname)" for team \(team): role \(roles.joined(separator: ", ")), \(allApps ? "all apps" : "apps \(appIDs.joined(separator: ", "))")
        issuer ID \(issuerID)
        stored its private key in the secret store as \(entry) (Apple offers it once; it was never written to disk in clear)
        checked it with the documented API (GET /v1/apps): App Store Connect accepts it

        """
    }
}

/// `xless auth api-key create` once the store is unlocked and the team and issuer are known: create, download the
/// private key once, store it, verify it with one documented call.
struct APIKeyCreation {
    let web: any APIKeyWeb
    let vault: APIKeyStore
    let verify: APIKeyVerifier
    /// Progress lines (standard error).
    var say: (String) -> Void = { _ in }
    /// Where the private key goes when the store cannot keep it (a file to import), so it is not lost.
    var rescue: KeyRescue = .standard

    func run(nickname: String, roles: [String], appIDs: [String], team: String, issuerID: String, entry: String,
             now: Date = Date()) async throws -> APIKeyCreated {
        let key: ASCAPIKeyInfo
        do {
            key = try await web.create(nickname: nickname, roles: roles, appIDs: appIDs)
        } catch let e as XlessError {
            throw e
        } catch {
            throw XlessError(.account, "the request to create the API key got no answer (\(XlessError.wrapping(error, stage: .account).cause))",
                             fix: "a key may have been created anyway: check `xless auth api-key list` and revoke any key you did not get (`xless auth api-key revoke <KEY_ID>`), then re-run")
        }
        say("Created API key \(key.id); downloading its private key (Apple offers it once).")
        guard key.canDownload else {
            throw Self.lost(key.id, because: "App Store Connect does not offer its private key for download")
        }
        let secret: SecretBytes
        do { secret = try await web.downloadPrivateKey(id: key.id) } catch let e as APIKeyDownloadError {
            throw Self.lost(key.id, because: Self.reason(e))
        } catch {
            throw Self.lost(key.id, because: "its download failed (\(XlessError.wrapping(error, stage: .account).cause)); Apple may have served it, and it is lost")
        }
        defer { secret.wipe() }
        let metadata = VaultEntry.Metadata(teamID: team, keyID: key.id, issuerID: issuerID, created: now, role: APIKeyRoles.recorded(roles))
        let stored: String
        do { stored = try vault.save(name: entry, secret: secret, metadata: metadata) } catch {
            throw rescue.failure(secret, noun: "API key", keyID: key.id,
                                 because: "the secret store could not keep it (\(XlessError.wrapping(error, stage: .account).cause))",
                                 entry: entry,
                                 importOptions: ["--kind", VaultEntry.Kind.ascAPIKey.rawValue, "--team-id", team, "--key-id", key.id, "--issuer-id", issuerID]
                                     + (APIKeyRoles.recorded(roles).map { ["--role", $0] } ?? []),
                                 revoke: "xless auth api-key revoke \(key.id)", lost: { Self.lost(key.id, because: $0) })
        }
        say("Stored it in the secret store as \(stored); checking it with the documented API.")
        do {
            try await verify(ASCCredentials(keyID: key.id, issuerID: issuerID, privateKeyPEM: secret.utf8String()))
        } catch {
            throw XlessError(.account, "API key \(key.id) is stored as \(stored), but App Store Connect refused it for GET /v1/apps (\(XlessError.wrapping(error, stage: .account).cause))",
                             fix: "a new key can take a few minutes to work: retry `xless api GET /v1/apps --team \(team)` later; if it keeps failing, revoke it (`xless auth api-key revoke \(key.id)`) and create another")
        }
        return APIKeyCreated(keyID: key.id, nickname: nickname, roles: roles, allApps: appIDs.isEmpty, appIDs: appIDs,
                             issuerID: issuerID, team: team, entry: stored, verified: true)
    }

    static func reason(_ e: APIKeyDownloadError) -> String {
        switch e {
        case .noAnswer(let detail): "its download got no answer (\(detail)); Apple may have served it, and it is lost with the connection"
        case .refused(let status, let message): "App Store Connect answered HTTP \(status) to its download\(message.map { " (\($0))" } ?? "")"
        case .unreadable(let what): "App Store Connect's download answer held \(what)"
        }
    }

    /// The key exists at Apple and xless does not have its private key.
    static func lost(_ keyID: String, because reason: String) -> XlessError {
        XlessError(.account, "API key \(keyID) was created, but xless does not have its private key: \(reason)",
                   fix: "Apple offers a key's private key once, so it cannot be downloaded again: revoke it with `xless auth api-key revoke \(keyID)` (or at \(ASCAPIKeys.page)) and create another")
    }
}

/// `xless auth api-key import`, once the file is read: validate, one documented call, then store (a key that does not
/// work is never stored).
enum APIKeyImport {
    static func run(secret: SecretBytes, keyID: String, issuerID: String, role: String?, team: String?, entry: String,
                    verify: APIKeyVerifier, unlock: () throws -> APIKeyStore, now: Date = Date()) async throws -> String {
        do { try VaultImport.validate(secret, kind: .ascAPIKey) } catch let e as VaultError {
            throw XlessError(.account, e.cause, fix: "import the AuthKey_<KEY_ID>.p8 file App Store Connect gave you")
        }
        do {
            try await verify(ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: secret.utf8String()))
        } catch {
            throw XlessError(.account, "App Store Connect refused the key for GET /v1/apps (\(XlessError.wrapping(error, stage: .account).cause)); nothing was stored",
                             fix: "check that --key-id and --issuer-id belong to this .p8 (App Store Connect > Users and Access > Integrations) and that the key is active")
        }
        let metadata = VaultEntry.Metadata(teamID: team, keyID: keyID, issuerID: issuerID, created: now, role: role)
        return try unlock().save(name: entry, secret: secret, metadata: metadata)
    }
}

enum APIKeyVerification {
    /// `GET /v1/apps?limit=1` with the key. A key App Store Connect has just created can be refused (401) for a moment:
    /// `unauthorizedRetries` more tries, `wait` apart.
    static func verifier(transport: HTTPTransport, unauthorizedRetries: Int = 0, wait: Duration = .seconds(5),
                         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> APIKeyVerifier {
        { credentials in
            let client = ASCClient(credentials: credentials, transport: transport, sleep: sleep)
            var left = unauthorizedRetries
            while true {
                do {
                    _ = try await client.request("GET", "/v1/apps", query: [("limit", "1")])
                    return
                } catch let e as ASCError where e.status == 401 && left > 0 {
                    left -= 1
                    try await sleep(wait)
                }
            }
        }
    }
}

/// `xless auth api-key list`: the team's keys, the one xless uses marked.
enum APIKeyListing {
    struct Row: Encodable, Equatable {
        let id: String
        let nickname: String?
        let roles: [String]
        let isActive: Bool
        let allAppsVisible: Bool
        let lastUsed: String?
        let createdBy: String?
        let revokedBy: String?
        let revokingDate: String?
        let usedByXless: Bool
    }

    static func rows(_ keys: [ASCAPIKeyInfo], used: String?) -> [Row] {
        keys.map { k in
            Row(id: k.id, nickname: k.nickname, roles: k.roles, isActive: k.isActive, allAppsVisible: k.allAppsVisible,
                lastUsed: k.lastUsed, createdBy: k.createdBy, revokedBy: k.revokedBy, revokingDate: k.revokingDate, usedByXless: k.id == used)
        }
    }

    static func table(_ rows: [Row]) -> String {
        guard !rows.isEmpty else { return "This team has no App Store Connect API keys (create one with `xless auth api-key create`).\n" }
        let table = TextTable(["", "KEY ID", "NAME", "ROLES", "APPS", "STATUS", "LAST USED", "CREATED BY"], rows.map { r in
            [r.usedByXless ? "*" : "", r.id, r.nickname ?? "-", r.roles.isEmpty ? "-" : r.roles.joined(separator: ","),
             r.allAppsVisible ? "all" : "some", r.isActive ? "active" : "revoked", r.lastUsed ?? "-", r.createdBy ?? "-"]
        }).rendered
        return table + (rows.contains(where: \.usedByXless) ? "* the key xless uses (`xless auth status`)\n" : "")
    }

    /// The key ID xless would use: `ASC_KEY_ID` (or `ASC_KEY_ID_FILE`), else the store's `ASC_KEY_P8` entry for the
    /// team. Reads no secret.
    static func usedKeyID(env: [String: String], store: () throws -> (any SecretEntries)?, team: String?) -> String? {
        if let id = try? Secrets(env: env, fallback: nil).optional("ASC_KEY_ID", stage: .account) { return id }
        guard let file = try? store(), let entry = try? VaultResolver.candidate(for: APIKeyStore.base, in: file, team: team) else { return nil }
        return entry.metadata.keyID
    }
}
