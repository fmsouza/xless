import Foundation
import XlessAppleID
import XlessCore
import XlessVault

/// An Apple ID session kept across reboots (`xless auth login --keep 3d --across-reboots`): an entry of the encrypted
/// store, sealed under its data key. Nothing that a program can read without the passphrase (a Keychain item or a Secret
/// Service one, which the user's every process can have) is enough to open it.
struct VaultSavedSession: SavedSession {
    private static let reason = "the saved Apple ID session"
    /// The encrypted store; throws where the secrets are elsewhere.
    let vault: @Sendable () throws -> VaultSecretStore

    init(_ vault: @escaping @Sendable () throws -> VaultSecretStore = { try VaultSavedSession.configured() }) { self.vault = vault }

    static func configured() throws -> VaultSecretStore {
        if HeldSecrets.isOff { throw unsupported("XLESS_NO_SECRET_STORE=1 is set") }
        guard case .vault(let vault) = try SecretStoreCLI.backend() else {
            throw unsupported("a credential helper holds the secrets, and whatever can run it could read the session (secrets.backend in config.yml)")
        }
        return vault
    }

    static func unsupported(_ why: String) -> XlessError {
        XlessError(.account, "the Apple ID session is saved across reboots in xless's encrypted store only: \(why)", fix: "run without --across-reboots")
    }

    func save(_ plain: SecretBytes, expires: Date) throws {
        let metadata = VaultEntry.Metadata(created: Date(), expires: expires)
        try vault().update(reason: Self.reason) { catalog in
            let name = SecretEnvironment.savedSession
            return [catalog.entry(named: name) == nil ? .add(name: name, kind: .generic, metadata: metadata, secret: plain)
                                                      : .replace(name: name, kind: .generic, metadata: metadata, secret: plain)]
        }
    }

    func load(asking: Bool) throws -> SecretBytes? {
        let vault = try vault()
        guard let file = try vault.vault.read(), let catalog = try vault.catalog(), catalog.id == file.id,
              let entry = catalog.entry(named: SecretEnvironment.savedSession), asking || vault.heldKey(for: file, using: false) != nil else { return nil }
        return try vault.secret(entry, in: catalog, reason: Self.reason)
    }

    var expires: Date? { ((try? vault().catalog()) ?? nil)?.entry(named: SecretEnvironment.savedSession)?.metadata.expires }

    @discardableResult func remove() throws -> Bool {
        let vault = try vault()
        guard try vault.catalog()?.entry(named: SecretEnvironment.savedSession) != nil else { return false }
        try vault.update(reason: Self.reason) { $0.entry(named: SecretEnvironment.savedSession) == nil ? [] : [.remove(name: SecretEnvironment.savedSession)] }
        return true
    }
}
