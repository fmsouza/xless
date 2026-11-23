import Foundation
import XlessCore

/// Entries without their values: names, kinds and metadata. The vault's file and a store's catalog are both one.
public protocol SecretEntries {
    var entries: [VaultEntry] { get }
}

extension SecretEntries {
    public func entry(named name: String) -> VaultEntry? { entries.first { $0.name == name } }
}

extension VaultFile: SecretEntries {}

/// What a secret store holds, read without asking anything: every entry's name, kind and metadata, never a value.
public struct SecretCatalog: SecretEntries, Sendable {
    /// Which store this is (the vault's random ID; `helper:<name>`): a key unlocked for one store is never used on
    /// another, and a command notices when the store it read was replaced.
    public let id: String
    public var entries: [VaultEntry]
    /// The vault's file this catalog was read from (nil for a helper).
    let file: VaultFile?

    init(_ file: VaultFile) {
        id = file.id
        entries = file.entries
        self.file = file
    }

    init(id: String, entries: [VaultEntry]) {
        self.id = id
        self.entries = entries
        file = nil
    }
}

/// A change `SecretStore.update` makes, in the order given.
public enum SecretChange {
    /// A new entry; refused when the name is taken.
    case add(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes)
    /// The entry `name` with new metadata (and its value); refused when there is no such entry.
    case replace(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes)
    /// Removes `name` (nothing when there is none).
    case remove(name: String)
}

/// Where the secrets live (`secrets.backend` in config.yml): the encrypted vault (`VaultSecretStore`) or an external
/// credential helper (`HelperSecretStore`). Everything that reads or writes secrets goes through this, so either
/// backend works the same.
public protocol SecretStore: AnyObject, Sendable {
    /// For messages: "the secret store at /…/secrets.vault", "the credential helper xless-credential-pass".
    var place: String { get }
    /// The entries, without asking anything (no passphrase); nil when there is no store yet (`xless secrets init`).
    func catalog() throws -> SecretCatalog?
    /// The catalog; an error saying how to create the store when there is none.
    func existingCatalog() throws -> SecretCatalog
    /// Gets ready to read and write values without asking again later: the vault asks its passphrase now (once per
    /// process; `remember` seconds also keeps it in the kernel keyring). Call before anything that cannot be undone
    /// (creating a key at Apple), so a key is never made that the store then cannot take. A helper needs nothing.
    func unlock(_ catalog: SecretCatalog, remember: Int?, reason: String) throws
    /// The value of `entry` (one of `catalog`'s), unlocking first when needed.
    func secret(_ entry: VaultEntry, in catalog: SecretCatalog, reason: String) throws -> SecretBytes
    /// Read–modify–write: `body` gets the store as it is now and returns the changes to make. The vault does it under
    /// its writers' lock and replaces its file atomically; a helper lists, then stores and erases one by one.
    func update(reason: String, _ body: (SecretCatalog) throws -> [SecretChange]) throws
}
