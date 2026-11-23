import Crypto
import Foundation
import XlessCore

/// `Secrets`' last resort: a secret from the store. Opens the store (and asks the passphrase) only when it holds an entry
/// for the name asked; otherwise answers nil without a prompt, so the usual "missing secret" error follows.
///
/// Names: an entry named `NAME`, or `NAME@<anything>` (one per team: `XLESS_DIST_KEY@ABCDE12345`), filtered by the
/// selected team when there is one. `ASC_KEY_ID` and `ASC_ISSUER_ID` come from the `ASC_KEY_P8` entry's metadata. The
/// data key, once unlocked, is kept in this process only (for the rest of the command).
public final class VaultResolver: SecretFallback, @unchecked Sendable {
    let store: VaultStore
    let team: String?
    let cache: (any VaultKeyCache)?
    let prompter: () -> (any PassphrasePrompter)?
    private let lock = NSLock()
    private var dataKey: (id: String, key: SymmetricKey)?

    /// - Parameter prompter: the terminal, or nil when there is none (called only when the passphrase is needed).
    public init(store: VaultStore, team: String? = nil, cache: (any VaultKeyCache)? = KernelKeyringCache(),
                prompter: @escaping () -> (any PassphrasePrompter)?) {
        self.store = store
        self.team = team
        self.cache = cache
        self.prompter = prompter
    }

    /// Variables whose value is metadata of the `ASC_KEY_P8` entry.
    static func metadataField(_ name: String) -> ((VaultEntry.Metadata) -> String?)? {
        switch name {
        case "ASC_KEY_ID": { $0.keyID }
        case "ASC_ISSUER_ID": { $0.issuerID }
        default: nil
        }
    }

    public func lookup(_ name: String, stage: Stage) throws -> String? {
        try lookup(name, stage: stage) { try Self.candidate(for: $0, in: $1, team: team) }
    }

    /// This resolver preferring `team` (`preferredCandidate`), sharing its unlock: one passphrase for both.
    public func preferring(team: String) -> any SecretFallback { TeamPreferring(base: self, team: team) }

    /// The value of `name` (or the ID it stands for) from the entry `pick` chooses; nil when there is none.
    func lookup(_ name: String, stage: Stage, pick: (String, VaultFile) throws -> VaultEntry?) throws -> String? {
        do {
            guard let file = try store.read() else { return nil }
            if let field = Self.metadataField(name) {
                guard let entry = try pick("ASC_KEY_P8", file) else { return nil }
                // Open it first: the metadata is only authenticated with the secret.
                _ = try VaultCrypto.open(entry, dataKey: try key(for: file, reason: "the secret \(name)"))
                return field(entry.metadata)
            }
            guard let entry = try pick(name, file) else { return nil }
            let secret = try VaultCrypto.open(entry, dataKey: try key(for: file, reason: "the secret \(name)"))
            return secret.utf8String()
        } catch let e as VaultError {
            throw e.stageError(stage)
        }
    }

    /// The entry standing for `name` for a run of `team`'s project: `team`'s own (`NAME@team`, or recorded with that
    /// team ID), else one recorded for no team (no `@`, no team ID). Another team's entries are never chosen; several
    /// left is an error.
    public static func preferredCandidate(for name: String, in file: VaultFile, team: String) throws -> VaultEntry? {
        let all = file.entries.filter { $0.name == name || $0.name.hasPrefix(name + "@") }
        let own = all.filter { $0.metadata.teamID == team || $0.name == "\(name)@\(team)" }
        let found = own.isEmpty ? all.filter { $0.metadata.teamID == nil && !$0.name.contains("@") } : own
        guard found.count <= 1 else {
            throw VaultError(.ambiguous, "the secret store has several entries for \(name) of team \(team): \(found.map(\.name).joined(separator: ", "))",
                             fix: "keep one (`xless secrets rm <name>`)")
        }
        return found.first
    }

    /// The entry standing for `name`: `name` itself or `name@…`, of `team` when one is selected; nil when none; an error
    /// when several remain.
    public static func candidate(for name: String, in file: VaultFile, team: String?) throws -> VaultEntry? {
        var found = file.entries.filter { $0.name == name || $0.name.hasPrefix(name + "@") }
        if let team { found = found.filter { $0.metadata.teamID == team || $0.name == "\(name)@\(team)" } }
        guard found.count <= 1 else {
            throw VaultError(.ambiguous, "the secret store has several entries for \(name): \(found.map(\.name).joined(separator: ", "))",
                             fix: "keep one (`xless secrets rm <name>`), or record each one's team (--team-id at import) and select the team")
        }
        return found.first
    }

    private func key(for file: VaultFile, reason: String) throws -> SymmetricKey {
        SecretScope.enter() // before the passphrase and the data key are in memory
        return try lock.withLock {
            if let dataKey, dataKey.id == file.id { return dataKey.key }
            let key = try VaultUnlocker.dataKey(for: file, cache: cache, prompter: prompter, reason: reason)
            dataKey = (file.id, key)
            return key
        }
    }
}

/// `VaultResolver.preferring(team:)`: lookups through the same resolver (and its unlocked key), by `preferredCandidate`.
struct TeamPreferring: SecretFallback {
    let base: VaultResolver
    let team: String

    func lookup(_ name: String, stage: Stage) throws -> String? {
        try base.lookup(name, stage: stage) { try VaultResolver.preferredCandidate(for: $0, in: $1, team: team) }
    }

    func preferring(team: String) -> any SecretFallback { base.preferring(team: team) }
}
