import Crypto
import Foundation
import XlessCore

/// The encrypted vault as a `SecretStore`. Its data key, once unlocked, is kept in this object for the rest of the
/// process (one passphrase per command, shared by every lookup and write).
public final class VaultSecretStore: SecretStore, @unchecked Sendable {
    public let vault: VaultStore
    public let cache: (any VaultKeyCache)?
    let prompter: () -> (any PassphrasePrompter)?
    private let lock = NSLock()
    private var dataKey: (id: String, key: SymmetricKey)?

    /// - Parameter prompter: the terminal, or nil when there is none (called only when the passphrase is needed).
    public init(store: VaultStore, cache: (any VaultKeyCache)? = KernelKeyringCache(), prompter: @escaping () -> (any PassphrasePrompter)?) {
        vault = store
        self.cache = cache
        self.prompter = prompter
    }

    public var place: String { "the secret store at \(vault.location.file.path)" }

    public func catalog() throws -> SecretCatalog? { try vault.read().map(SecretCatalog.init) }

    public func existingCatalog() throws -> SecretCatalog {
        guard let catalog = try catalog() else { throw VaultStore.notInitialized(vault.location) }
        return catalog
    }

    public func unlock(_ catalog: SecretCatalog, remember: SecretHold?, reason: String) throws {
        _ = try key(for: try file(of: catalog), remember: remember, reason: reason)
    }

    public func secret(_ entry: VaultEntry, in catalog: SecretCatalog, reason: String) throws -> SecretBytes {
        try VaultCrypto.open(entry, dataKey: try key(for: try file(of: catalog), remember: nil, reason: reason))
    }

    public func authenticate(_ entry: VaultEntry, in catalog: SecretCatalog, reason: String) throws {
        try secret(entry, in: catalog, reason: reason).wipe()
    }

    /// Nothing to probe: `unlock` has the key and `update` checks the file under the writers' lock.
    public func probeWrites(reason: String) throws {}

    public func update(reason: String, _ body: (SecretCatalog) throws -> [SecretChange]) throws {
        try vault.update { file in
            var next = file
            for change in try body(SecretCatalog(file)) {
                switch change {
                case .add(let name, let kind, let metadata, let secret):
                    try VaultEntry.requireAllowed(name: name, kind: kind)
                    guard next.entry(named: name) == nil else { throw Self.exists(name) }
                    next.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: metadata, secret: secret,
                                                             dataKey: try key(for: file, remember: nil, reason: reason)))
                case .replace(let name, let kind, let metadata, let secret):
                    try VaultEntry.requireAllowed(name: name, kind: kind)
                    guard let index = next.entries.firstIndex(where: { $0.name == name }) else { throw Self.missing(name) }
                    var sealed = try VaultCrypto.seal(name: name, kind: kind, metadata: metadata, secret: secret,
                                                      dataKey: try key(for: file, remember: nil, reason: reason))
                    sealed.unknown = next.entries[index].unknown // the entry's fields a newer xless added stay
                    next.entries[index] = sealed
                case .remove(let name):
                    next.entries.removeAll { $0.name == name }
                }
            }
            // The first write with the data key at hand (this process's, or the unlock cache's: never asked for this)
            // moves a store of the first format to the current one.
            if next.needsUpgrade, let key = heldKey(for: file) { next = try VaultCrypto.upgrade(next, dataKey: key) }
            return next
        }
    }

    /// Drops the data key this process holds (its memory is zeroed as it is released); the next value asks again (or
    /// takes the unlock cache's). `main` calls it before the process ends, so the key does not outlive the command.
    public func forget() {
        lock.withLock { dataKey = nil }
    }

    /// The data key of `file` without asking: the one this process unlocked, else a valid one in the unlock cache.
    /// - Parameter using: false to look only (an unlock's idle time goes on).
    public func heldKey(for file: VaultFile, using: Bool = true) -> SymmetricKey? {
        SecretScope.enter()
        return lock.withLock {
            if let dataKey, dataKey.id == file.id { return dataKey.key }
            guard let cached = try? cache?.load(id: file.id, using: using, accept: { VaultUnlocker.opens(file, $0) }) else { return nil }
            let key = SymmetricKey(data: cached)
            dataKey = (file.id, key)
            return key
        }
    }

    /// The data key for `file`: this process's, else the unlock cache's, else asked (`VaultUnlocker`). With
    /// `remember`, it is (also) kept in the cache.
    public func key(for file: VaultFile, remember: SecretHold?, reason: String) throws -> SymmetricKey {
        SecretScope.enter() // before the passphrase and the data key are in memory
        return try lock.withLock {
            if remember == nil, let dataKey, dataKey.id == file.id { return dataKey.key }
            let key = try VaultUnlocker.dataKey(for: file, cache: cache, place: vault.location.file.path, prompter: prompter, remember: remember, reason: reason)
            dataKey = (file.id, key)
            return key
        }
    }

    private func file(of catalog: SecretCatalog) throws -> VaultFile {
        if let file = catalog.file { return file }
        guard let file = try vault.read(), file.id == catalog.id else {
            throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command")
        }
        return file
    }

    static func exists(_ name: String) -> VaultError {
        VaultError(.entryExists, "the secret store already has an entry \(name)", fix: "remove it first (`xless secrets rm \(name)`) or choose another name")
    }

    static func missing(_ name: String) -> VaultError {
        VaultError(.noEntry, "the entry \(name) is no longer in the secret store", fix: "see the names with `xless secrets list`")
    }
}
