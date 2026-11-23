import Foundation
import XlessASC
import XlessCore
import XlessVault

/// Where a webhook's signing secret is kept: the store entry `XLESS_WEBHOOK_SECRET.<webhook ID>`, with `@<TEAM_ID>`
/// when a team is in effect (kind generic). One entry per webhook; `xless secrets export` hands it to the receiver.
struct WebhookSecretStore {
    static let base = "XLESS_WEBHOOK_SECRET"

    static func entryName(webhookID: String, team: String?) -> String {
        "\(base).\(webhookID)" + (team.map { "@\($0)" } ?? "")
    }

    static func matches(_ entry: VaultEntry, _ webhookID: String) -> Bool {
        entry.name.split(separator: "@", maxSplits: 1).first.map(String.init) == "\(base).\(webhookID)"
    }

    /// The names of the entries holding webhook `id`'s secret.
    static func entries(holding id: String, in file: (any SecretEntries)?) -> [String] {
        (file?.entries ?? []).filter { matches($0, id) }.map(\.name).sorted()
    }

    /// Removes the entries of webhook `id`; returns their names. Needs no passphrase.
    static func remove(id: String, from store: any SecretStore) throws -> [String] {
        guard let file = try store.catalog(), file.entries.contains(where: { matches($0, id) }) else { return [] }
        var removed: [String] = []
        try store.update(reason: "removing the secret of webhook \(id)") { current in
            removed = current.entries.filter { matches($0, id) }.map(\.name)
            return removed.map { .remove(name: $0) }
        }
        return removed
    }

    /// The store, unlocked by this command before anything was sent to Apple.
    let store: any SecretStore
    let catalogID: String

    /// Puts the secret of webhook `webhookID` into the store; returns the entry's name.
    func save(webhookID: String, team: String?, secret: SecretBytes, now: Date) throws -> String {
        let name = Self.entryName(webhookID: webhookID, team: team)
        try store.update(reason: "storing the signing secret of webhook \(webhookID)") { file in
            guard file.id == catalogID else { throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command") }
            return [.add(name: name, kind: .generic, metadata: VaultEntry.Metadata(teamID: team, created: now), secret: secret)]
        }
        return name
    }
}

/// What the webhook commands do once their arguments are valid; returns what goes to standard output and says the rest
/// on standard error. The signing secret is never part of either.
struct WebhookCLI {
    let webhooks: ASCWebhooks
    let apps: ASCApps
    var json = false
    var team: String?
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// The secret store, read without a passphrase (nil: none).
    var storeFile: () -> (any SecretEntries)? = { nil }
    /// Checks the store and unlocks it; called before anything is sent, so a webhook is never made whose secret
    /// cannot be kept.
    var unlockStore: () throws -> WebhookSecretStore
    /// Removes the store's entries of a deleted webhook.
    var removeEntries: (String) throws -> [String] = { _ in [] }
    var newSecret: () -> SecretBytes = WebhookInput.newSecret
    var now: () -> Date = Date.init

    init(resources: ASCResources, json: Bool = false, team: String? = nil,
         terminal: @escaping () -> (any Confirming)? = { try? TerminalPrompter.forAccount() },
         say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
         storeFile: @escaping () -> (any SecretEntries)? = { nil }, unlockStore: @escaping () throws -> WebhookSecretStore,
         removeEntries: @escaping (String) throws -> [String] = { _ in [] }) {
        webhooks = ASCWebhooks(resources: resources); apps = ASCApps(resources: resources)
        self.json = json; self.team = team; self.terminal = terminal; self.say = say
        self.storeFile = storeFile; self.unlockStore = unlockStore; self.removeEntries = removeEntries
    }

    struct Row: Encodable {
        var data: ASCWebhook
        /// The store entries holding its secret.
        var secretEntries: [String]
    }

    func list(app argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let hooks = try await webhooks.list(app: app.id)
        let file = storeFile()
        let rows = hooks.map { Row(data: $0, secretEntries: WebhookSecretStore.entries(holding: $0.id, in: file)) }
        if json { return try ASCOutput.json(["data": rows]) }
        guard !hooks.isEmpty else { return "\(app.bundleID) has no webhooks (create one with `xless webhooks create`).\n" }
        return TextTable(["ID", "NAME", "URL", "ENABLED", "EVENTS", "SECRET IN STORE"], rows.map { r in
            [r.data.id, r.data.name, r.data.url, r.data.enabled ? "yes" : "no", r.data.events.joined(separator: ","),
             r.secretEntries.isEmpty ? "-" : r.secretEntries.joined(separator: ", ")]
        }).rendered
    }

    struct Created: Encodable {
        /// `created` or `existing`.
        var result: String
        var data: ASCWebhook
        /// The store entry holding its secret (nil for an existing webhook xless did not make here).
        var secretEntry: String?
    }

    func create(app argument: String, name: String?, url: String, events: [String], enabled: Bool) async throws -> String {
        let (events, unknown) = try Self.events(events)
        for event in unknown { say("warning: \(event) is not an event xless knows (\(WebhookEvents.known.count) are); it is sent as given") }
        let vault = try unlockStore()
        let app = try await apps.resolve(argument)
        if let same = try await webhooks.list(app: app.id).first(where: { $0.url == url }) {
            let entries = WebhookSecretStore.entries(holding: same.id, in: storeFile())
            if json { return try ASCOutput.json(Created(result: "existing", data: same, secretEntry: entries.first)) }
            return "\(app.bundleID) already has webhook \(same.id) \"\(same.name)\" for \(url); nothing was sent"
                + (entries.isEmpty ? " (its secret is not in this store: delete it and create it again to have one)" : " (secret in the store as \(entries.joined(separator: ", ")))") + "\n"
        }
        let request = WebhookRequest(appID: app.id, name: name ?? WebhookInput.defaultName(for: url), url: url, events: events, enabled: enabled)
        let secret = newSecret()
        defer { secret.wipe() }
        let created = try await webhooks.create(request, secret: secret)
        let entry: String
        do {
            entry = try vault.save(webhookID: created.id, team: team, secret: secret, now: now())
        } catch {
            // A webhook whose secret is lost cannot be verified: take it back.
            let cause = "the secret store did not take the signing secret of the new webhook \(created.id) (\(error))"
            do {
                try await webhooks.delete(id: created.id)
            } catch {
                throw XlessError(.account, cause + ", and deleting the webhook again failed", fix: "delete it with `xless webhooks delete \(created.id)`, fix the store (`xless secrets status`), then create it again")
            }
            throw XlessError(.account, cause + "; the webhook was deleted again", fix: "fix the store (`xless secrets status`), then re-run")
        }
        if json { return try ASCOutput.json(Created(result: "created", data: created, secretEntry: entry)) }
        return """
        created webhook \(created.id) "\(created.name)" for \(app.bundleID): \(created.url) (\(created.enabled ? "enabled" : "disabled")), events \(created.events.joined(separator: ", "))
        stored its signing secret in the secret store as \(entry) (never printed); `xless secrets export \(entry) --out <file>` writes it for the server that checks the signatures

        """
    }

    func delete(_ id: String, yes: Bool) async throws -> String {
        let hook = try await webhooks.get(id: id)
        let question = "Delete webhook \(hook.id) \"\(hook.name)\" (\(hook.url))? App Store Connect stops sending it events."
        guard try AccountConfirm.confirm(question, action: "deleting webhook \(hook.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await webhooks.delete(id: hook.id)
        let removed: [String]
        do { removed = try removeEntries(hook.id) } catch {
            let names = WebhookSecretStore.entries(holding: hook.id, in: storeFile())
            say("warning: the webhook is deleted, but its secret could not be removed from the store (\(error))"
                + (names.isEmpty ? "" : ": `xless secrets rm \(names.joined(separator: "` and `xless secrets rm "))`"))
            removed = []
        }
        struct Deleted: Encodable { var deleted: ASCWebhook; var removedEntries: [String] }
        if json { return try ASCOutput.json(Deleted(deleted: hook, removedEntries: removed)) }
        return "deleted webhook \(hook.id) \"\(hook.name)\"" + (removed.isEmpty ? "" : "; removed its secret from the store (\(removed.joined(separator: ", ")))") + "\n"
    }

    static func events(_ arguments: [String]) throws -> (events: [String], unknown: [String]) {
        do { return try WebhookEvents.parse(arguments) } catch let e as IdentifierInputError {
            throw XlessError(.account, e.description, fix: "pass --events with names from `xless webhooks create --help`")
        }
    }
}
