import Crypto
import Foundation
import XlessCore

/// The store's cryptography: a random 256-bit data key seals each entry (AES-256-GCM); the data key is wrapped
/// (AES-256-GCM) under a key derived from the passphrase (scrypt). A failed tag is always an error, never a partial value.
public enum VaultCrypto {
    /// A new, empty store and its data key.
    public static func newVault(passphrase: SecretBytes, kdf: VaultKDF = .standard()) throws -> (VaultFile, SymmetricKey) {
        let dataKey = SymmetricKey(size: .bits256)
        var file = VaultFile(format: VaultFile.formatName, version: VaultFile.currentVersion, id: UUID().uuidString.lowercased(),
                             kdf: kdf, wrappedKey: Data(), keyCheck: Data(), entries: [])
        file = try rewrap(file, dataKey: dataKey, passphrase: passphrase, kdf: kdf)
        file.keyCheck = try seal(Data(), key: dataKey, aad: file.keyCheckAssociatedData)
        return (file, dataKey)
    }

    /// The data key, unwrapped with the passphrase.
    public static func unwrap(_ file: VaultFile, passphrase: SecretBytes) throws -> SymmetricKey {
        let kek = try file.kdf.deriveKey(from: passphrase)
        guard let box = try? AES.GCM.SealedBox(combined: file.wrappedKey) else { throw VaultError.tampered("wrapped key") }
        guard var raw = try? AES.GCM.open(box, using: kek, authenticating: file.headerAssociatedData) else {
            // A wrong passphrase and an altered header look the same to GCM.
            throw VaultError.wrongPassphrase
        }
        defer { raw.withUnsafeMutableBytes { SecretBytes.zero($0) } }
        guard raw.count == 32 else { throw VaultError.tampered("wrapped key") }
        let key = SymmetricKey(data: raw)
        try verify(file, dataKey: key)
        return key
    }

    /// Checks that `dataKey` is this store's (a key from the unlock cache).
    public static func verify(_ file: VaultFile, dataKey: SymmetricKey) throws {
        guard let box = try? AES.GCM.SealedBox(combined: file.keyCheck),
              (try? AES.GCM.open(box, using: dataKey, authenticating: file.keyCheckAssociatedData)) != nil
        else { throw VaultError.tampered("key check") }
    }

    /// The file with the data key wrapped under a new passphrase (and fresh KDF salt); entries untouched.
    public static func rewrap(_ file: VaultFile, dataKey: SymmetricKey, passphrase: SecretBytes, kdf: VaultKDF = .standard()) throws -> VaultFile {
        var out = file
        out.kdf = kdf
        let kek = try kdf.deriveKey(from: passphrase)
        out.wrappedKey = try dataKey.withUnsafeBytes { try seal($0, key: kek, aad: out.headerAssociatedData) }
        return out
    }

    public static func seal(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes,
                            dataKey: SymmetricKey) throws -> VaultEntry {
        let unsealed = VaultEntry(name: name, kind: kind, metadata: metadata, sealed: Data())
        let sealed = try secret.withUnsafeBytes { try seal($0, key: dataKey, aad: unsealed.associatedData) }
        return VaultEntry(name: name, kind: kind, metadata: metadata, sealed: sealed)
    }

    /// The entry's secret, or an integrity error (never part of it).
    public static func open(_ entry: VaultEntry, dataKey: SymmetricKey) throws -> SecretBytes {
        guard let box = try? AES.GCM.SealedBox(combined: entry.sealed),
              var plain = try? AES.GCM.open(box, using: dataKey, authenticating: entry.associatedData)
        else { throw VaultError.tampered("entry \(entry.name)") }
        return SecretBytes(wiping: &plain)
    }

    public static func keyBytes(_ key: SymmetricKey) -> SecretBytes { key.withUnsafeBytes { SecretBytes(copying: $0) } }

    private static func seal<D: DataProtocol>(_ plain: D, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else {
            throw VaultError(.io, "cannot seal a secret", fix: "re-run")
        }
        return combined
    }
}
