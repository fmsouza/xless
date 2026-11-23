import Crypto
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault

// `xless keys`: what the commands sequence, kept apart from the terminal and the network so the order (check the limit,
// create, download once, store, report) and every failure message are tested with fakes (docs/apple-account.md#xless-keys).

/// What the commands need from the developer portal (`PortalAuthKeys`; a fake in tests).
protocol AuthKeyWeb: Sendable {
    func list() async throws -> [PortalAuthKey]
    func get(id: String) async throws -> PortalAuthKey
    func create(name: String, services: [AuthKeyService], bundleIDs: [String], musicIDs: [String]) async throws -> PortalAuthKey
    func downloadPrivateKey(id: String) async throws -> SecretBytes
    func revoke(id: String) async throws
}

extension PortalAuthKeys: AuthKeyWeb {}

/// The store side: which entry an auth key goes to, and keeping it there.
struct AuthKeyStore {
    /// `XLESS_APNS_KEY`, `XLESS_DEVICECHECK_KEY`, `XLESS_MUSICKIT_KEY`, `XLESS_SIWA_KEY` for a key of one service;
    /// `XLESS_AUTH_KEY` for one of several.
    static func base(for services: [AuthKeyService]) -> String {
        guard services.count == 1, let only = services.first else { return "XLESS_AUTH_KEY" }
        return "XLESS_\(only.argument.uppercased())_KEY"
    }

    /// What the entry records: `apns`, `apns,siwa`.
    static func recorded(_ services: [AuthKeyService]) -> String { services.map(\.argument).joined(separator: ",") }

    /// The services an entry records (unknown words dropped).
    static func services(of entry: VaultEntry) -> [AuthKeyService] {
        (entry.metadata.services ?? "").split(separator: ",").compactMap { AuthKeyService(argument: String($0)) }
    }

    /// `<base>@<TEAM_ID>` when nothing in the store stands for `<base>` in that team yet; else `<base>.<KEY_ID>@<TEAM_ID>`,
    /// which a lookup of `<base>` does not match, so the store never becomes ambiguous (Apple allows two APNs keys).
    static func entryName(base: String, keyID: String, team: String, in file: some SecretEntries) -> String {
        let first = "\(base)@\(team)"
        let resolved: Bool
        do { resolved = try VaultResolver.candidate(for: base, in: file, team: team) != nil } catch { resolved = true } // several: taken
        guard file.entry(named: first) != nil || resolved else { return first }
        var name = "\(base).\(keyID)@\(team)"
        var n = 2
        while file.entry(named: name) != nil { name = "\(base).\(keyID).\(n)@\(team)"; n += 1 }
        return name
    }

    /// The store, unlocked by this command (`SecretStore.unlock`) before anything was asked of Apple.
    let store: any SecretStore
    /// The store this command read and unlocked.
    let catalogID: String

    /// Puts the key into the store under the name `entryName` picks at that moment; returns it.
    func save(base: String, keyID: String, team: String, secret: SecretBytes, metadata: VaultEntry.Metadata) throws -> String {
        var used = ""
        try store.update(reason: "storing the new auth key") { file in
            guard file.id == catalogID else { throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command") }
            used = Self.entryName(base: base, keyID: keyID, team: team, in: file)
            return [.add(name: used, kind: .authKey, metadata: metadata, secret: secret)]
        }
        return used
    }

    /// Removes the store's auth-key entries of `keyID`; returns their names. Needs no passphrase.
    static func removeKeys(id keyID: String, from store: any SecretStore) throws -> [String] {
        guard let file = try store.catalog(), file.entries.contains(where: { matches($0, keyID) }) else { return [] }
        var removed: [String] = []
        try store.update(reason: "removing auth key \(keyID)") { current in
            removed = current.entries.filter { matches($0, keyID) }.map(\.name)
            return removed.map { .remove(name: $0) }
        }
        return removed
    }

    /// The names of the auth-key entries holding key `keyID`.
    static func entries(holding keyID: String, in file: (any SecretEntries)?) -> [String] {
        (file?.entries ?? []).filter { matches($0, keyID) }.map(\.name).sorted()
    }

    static func matches(_ entry: VaultEntry, _ keyID: String) -> Bool { entry.kind == .authKey && entry.metadata.keyID == keyID }
}

/// What `create` reports (`--json` prints it as is).
struct AuthKeyCreated: Encodable, Equatable {
    let keyID: String
    let name: String
    let services: [String]
    let bundleIDs: [String]
    let musicIDs: [String]
    let team: String
    let entry: String

    var text: String {
        let names = services.compactMap { AuthKeyService(argument: $0)?.shortName }.joined(separator: ", ")
        return """
        created auth key \(keyID) "\(name)" for team \(team): \(names)\(bundleIDs.isEmpty ? "" : " (bundle IDs \(bundleIDs.joined(separator: ", ")))")
        stored its private key in the secret store as \(entry) (Apple offers it once; it was never written to disk in clear)
        a server signs with key ID \(keyID) and team ID \(team); `xless secrets export \(entry) --out AuthKey_\(keyID).p8` writes the .p8 for one

        """
    }
}

/// `xless keys create` once the store is unlocked and the team is selected: check the name and Apple's limit, create,
/// download the private key once, store it.
struct AuthKeyCreation {
    let web: any AuthKeyWeb
    let vault: AuthKeyStore
    /// Progress lines (standard error).
    var say: (String) -> Void = { _ in }
    /// Where the private key goes when the store cannot keep it (a file to import), so it is not lost.
    var rescue: KeyRescue = .standard

    /// - Parameter name: the name given with `--name` (a name the team uses is refused), else nil: `defaultName(...)`,
    /// with ` 2`, ` 3`… when the team already has a key of that name.
    func run(name given: String?, services: [AuthKeyService], bundleIDs: [String], musicIDs: [String] = [], team: String,
             now: Date = Date()) async throws -> AuthKeyCreated {
        let existing = try await web.list()
        let name = given ?? Self.freeName(Self.defaultName(services, now: now), existing: existing)
        try Self.precheck(name: name, services: services, existing: existing)
        let key = try await web.create(name: name, services: services, bundleIDs: bundleIDs, musicIDs: musicIDs)
        say("Created auth key \(key.id); downloading its private key (Apple offers it once).")
        let secret: SecretBytes
        do { secret = try await web.downloadPrivateKey(id: key.id) } catch let e as APIKeyDownloadError {
            throw Self.lost(key.id, because: Self.reason(e))
        } catch {
            throw Self.lost(key.id, because: "its download failed (\(XlessError.wrapping(error, stage: .account).cause)); Apple may have served it, and it is lost")
        }
        defer { secret.wipe() }
        let metadata = VaultEntry.Metadata(teamID: team, keyID: key.id, created: now, services: AuthKeyStore.recorded(services))
        let stored: String
        do {
            stored = try vault.save(base: AuthKeyStore.base(for: services), keyID: key.id, team: team, secret: secret, metadata: metadata)
        } catch {
            let base = AuthKeyStore.base(for: services)
            let entry = ((try? vault.store.catalog()) ?? nil).map { AuthKeyStore.entryName(base: base, keyID: key.id, team: team, in: $0) } ?? "\(base)@\(team)"
            throw rescue.failure(secret, noun: "auth key", keyID: key.id,
                                 because: "the secret store could not keep it (\(XlessError.wrapping(error, stage: .account).cause))",
                                 entry: entry,
                                 importOptions: ["--kind", VaultEntry.Kind.authKey.rawValue, "--team-id", team, "--key-id", key.id,
                                                 "--services", AuthKeyStore.recorded(services)],
                                 revoke: "xless keys revoke \(key.id)", lost: { Self.lost(key.id, because: $0) })
        }
        return AuthKeyCreated(keyID: key.id, name: name, services: services.map(\.argument), bundleIDs: bundleIDs, musicIDs: musicIDs,
                              team: team, entry: stored)
    }

    /// `xless APNs 20261123`, `xless APNs SIWA 20261123`: letters, digits and spaces, as the portal takes them.
    static func defaultName(_ services: [AuthKeyService], now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        let words = services.map { s in
            switch s { case .apns: "APNs"; case .deviceCheck: "DeviceCheck"; case .musicKit: "MusicKit"; case .signInWithApple: "SIWA" }
        }
        return (["xless"] + words + [f.string(from: now)]).joined(separator: " ")
    }

    /// `name`, or `name 2`, `name 3`… when the team has a key of that name.
    static func freeName(_ name: String, existing: [PortalAuthKey]) -> String {
        var candidate = name
        var n = 2
        while existing.contains(where: { $0.name == candidate }) { candidate = "\(name) \(n)"; n += 1 }
        return candidate
    }

    /// Refuses before anything is created: a name the team already uses, or a service at Apple's limit.
    static func precheck(name: String, services: [AuthKeyService], existing: [PortalAuthKey]) throws {
        if let same = existing.first(where: { $0.name == name }) {
            throw XlessError(.account, "the team already has an auth key named \"\(name)\" (\(same.id))",
                             fix: "pass another --name, or use that key (`xless keys show \(same.id)`)")
        }
        for service in services {
            guard let limit = service.limit else { continue }
            let using = existing.filter { $0.serviceKinds.contains(service) }
            guard using.count >= limit else { continue }
            let list = using.map { "\($0.id) \"\($0.name)\"" }.joined(separator: ", ")
            throw XlessError(.account, "the team already has \(using.count) \(service.shortName) keys (Apple allows \(limit)): \(list)",
                             fix: "use one of them (`xless keys show <KEY_ID>`; one \(service.shortName) key serves every app of the team), or revoke one you no longer use (`xless keys revoke <KEY_ID>`), then re-run")
        }
    }

    static func reason(_ e: APIKeyDownloadError) -> String {
        switch e {
        case .noAnswer(let detail): "its download got no answer (\(detail)); Apple may have served it, and it is lost with the connection"
        case .refused(let status, let message): "the developer portal answered HTTP \(status) to its download\(message.map { " (\($0))" } ?? "")"
        case .unreadable(let what): "the developer portal's download answer held \(what)"
        }
    }

    /// The key exists at Apple and xless does not have its private key.
    static func lost(_ keyID: String, because reason: String) -> XlessError {
        XlessError(.account, "auth key \(keyID) was created, but xless does not have its private key: \(reason)",
                   fix: "Apple offers a key's private key once, so it cannot be downloaded again: revoke it with `xless keys revoke \(keyID)` (or at \(PortalAuthKeys.page)) and create another")
    }
}

/// `list`, `show` and `revoke` once signed in: each returns what goes to standard output.
struct AuthKeyCLI {
    let web: any AuthKeyWeb
    var json = false
    /// The secret store, read without a passphrase (nil: none).
    var storeFile: () -> (any SecretEntries)? = { nil }
    /// Removes the store's entries of a revoked key.
    var removeEntries: (String) throws -> [String] = { _ in [] }

    struct Row: Encodable, Equatable {
        let id: String
        let name: String
        let services: [String]
        let bundleIDs: [String]
        let canDownload: Bool
        let canRevoke: Bool
        let storeEntries: [String]
    }

    func row(_ k: PortalAuthKey, _ file: (any SecretEntries)?) -> Row {
        Row(id: k.id, name: k.name, services: (k.services ?? []).map { AuthKeyService(id: $0.id)?.argument ?? $0.id },
            bundleIDs: (k.services ?? []).flatMap(\.bundleIDs), canDownload: k.canDownload, canRevoke: k.canRevoke,
            storeEntries: AuthKeyStore.entries(holding: k.id, in: file))
    }

    func list() async throws -> String {
        let keys = try await web.list()
        let file = storeFile()
        let rows = keys.map { row($0, file) }
        if json { return try ASCOutput.json(["data": rows]) }
        guard !keys.isEmpty else { return "This team has no auth keys (create one with `xless keys create --service apns`).\n" }
        return TextTable(["KEY ID", "NAME", "SERVICES", "DOWNLOADABLE", "STORE ENTRY"], zip(keys, rows).map { k, r in
            [k.id, k.name.isEmpty ? "-" : k.name, k.serviceNames, k.canDownload ? "yes" : "no",
             r.storeEntries.isEmpty ? "-" : r.storeEntries.joined(separator: ", ")]
        }).rendered
    }

    func show(_ id: String) async throws -> String {
        let key = try await web.get(id: id)
        let r = row(key, storeFile())
        if json { return try ASCOutput.json(r) }
        var lines = ["Key ID:       \(key.id)", "Name:         \(key.name.isEmpty ? "-" : key.name)", "Services:     \(key.serviceNames)"]
        if !r.bundleIDs.isEmpty { lines.append("Bundle IDs:   \(r.bundleIDs.joined(separator: ", ")) (Sign in with Apple)") }
        lines.append("Downloadable: " + (key.canDownload ? "yes (once; only `xless keys create` downloads, straight into the store)" : "no (Apple served its private key already)"))
        lines.append("Store entry:  " + (r.storeEntries.isEmpty ? "none (xless does not have its private key)" : r.storeEntries.joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Asks (`confirm`), revokes, then removes the store's entries for the key.
    func revoke(_ id: String, confirm: (String) throws -> Bool) async throws -> String {
        let key = try await web.get(id: id)
        guard key.canRevoke else {
            throw XlessError(.account, "the developer portal does not let this Apple ID revoke auth key \(id)",
                             fix: "the Account Holder or an Admin of the team revokes keys (\(PortalAuthKeys.page))")
        }
        let entries = AuthKeyStore.entries(holding: id, in: storeFile())
        let question = "Revoke auth key \(id) \"\(key.name)\" (\(key.serviceNames))? Every server signing with it stops working at once, and Apple cannot undo it."
            + (entries.isEmpty ? "" : " Its private key is in the secret store as \(entries.joined(separator: ", ")) and will be removed.")
        guard try confirm(question) else { return "cancelled; nothing was sent\n" }
        try await web.revoke(id: id)
        var out = "revoked auth key \(id)\n"
        let removed: [String]
        do { removed = try removeEntries(id) } catch {
            throw XlessError(.account, "revoked auth key \(id), but could not remove \(entries.isEmpty ? "its entries" : entries.joined(separator: ", ")) from the secret store (\(XlessError.wrapping(error, stage: .account).cause))",
                             fix: StoreCleanup.fix(after: error, names: entries, fallback: "the entries of key \(id) (`xless secrets list`)", done: "the key itself is revoked at Apple"))
        }
        out += removed.isEmpty ? "the secret store held no entry for it\n" : "removed \(removed.joined(separator: ", ")) from the secret store\n"
        return out
    }
}
