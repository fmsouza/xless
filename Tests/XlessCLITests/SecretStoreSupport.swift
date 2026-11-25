import Foundation
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

/// Makes a directory that is the user's alone.
func makePrivateDirectory(_ url: URL) throws {
    #if os(Windows)
    try PrivateFile.makeDirectory(url.path)
    #else
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #endif
}

/// What is said of a file that is the user's alone.
#if os(Windows)
let privateFileWords = "yours alone"
#else
let privateFileWords = "mode 0600"
#endif

/// Whether a file is the user's alone, as a secret's is.
func isPrivateFile(_ path: String) throws -> Bool {
    #if os(Windows)
    return try PrivateFile.read(path, .anyDrive, limit: 1 << 20) != nil
    #else
    return try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600
    #endif
}
