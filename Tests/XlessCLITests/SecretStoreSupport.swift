import XlessCore
import XlessVault

/// Answers the vault's passphrase prompt with the tests' passphrase.
final class TestPassphrase: PassphrasePrompter, @unchecked Sendable {
    func askSecret(_ prompt: String) throws -> SecretBytes { SecretBytes(utf8: "correct horse battery") }
    func ask(_ prompt: String) throws -> String { "correct horse battery" }
    func say(_ line: String) {}
}

extension VaultStore {
    /// This vault as a `SecretStore` that unlocks with the tests' passphrase (no keyring cache).
    var secretStore: VaultSecretStore { VaultSecretStore(store: self, cache: nil, prompter: { TestPassphrase() }) }
}
