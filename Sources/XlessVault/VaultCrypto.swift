import Crypto
import Foundation
import XlessCore

/// The store's cryptography: a random 256-bit data key seals each entry (AES-256-GCM); the data key is wrapped
/// (AES-256-GCM) under a key derived from the passphrase (scrypt). A failed tag is always an error, never a partial value.
public enum VaultCrypto {
    /// A new, empty store and its data key.
    public static func newVault(passphrase: SecretBytes, kdf: VaultKDF = .standard()) throws -> (VaultFile, SymmetricKey) {
        let dataKey = SymmetricKey(size: .bits256)
        var file = VaultFile(format: VaultFile.formatName, version: VaultFile.currentVersion,
                             minimumReaderVersion: VaultFile.currentVersion, id: UUID().uuidString.lowercased(),
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

    /// A new entry in the current format: every field of its metadata is authenticated with the secret.
    public static func seal(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes,
                            dataKey: SymmetricKey) throws -> VaultEntry {
        var known = metadata
        known.unknown = [:]
        let unsealed = VaultEntry(name: name, kind: kind, metadata: known, sealed: Data())
        guard let aad = unsealed.associatedData else { throw VaultError(.io, "cannot seal a secret", fix: "re-run") }
        let sealed = try secret.withUnsafeBytes { try seal($0, key: dataKey, aad: aad) }
        return VaultEntry(name: name, kind: kind, metadata: known, sealed: sealed)
    }

    /// The entry's secret, or an integrity error (never part of it). An entry of a newer format than this xless knows
    /// is an error that says to upgrade.
    public static func open(_ entry: VaultEntry, dataKey: SymmetricKey) throws -> SecretBytes {
        if entry.format > VaultEntry.currentFormat {
            throw VaultError(.newerFormat, "the entry \(entry.name) was written by a newer xless (entry format \(entry.format); this xless knows format \(VaultEntry.currentFormat) and older)",
                             fix: "upgrade xless (run the install line again: README.md#install) to use it")
        }
        // A current entry authenticates every field: one this xless does not know was added after it was sealed.
        guard entry.format < 2 || entry.metadata.unknown.isEmpty, let aad = entry.associatedData,
              let box = try? AES.GCM.SealedBox(combined: entry.sealed),
              var plain = try? AES.GCM.open(box, using: dataKey, authenticating: aad)
        else { throw VaultError.tampered("entry \(entry.name)") }
        return SecretBytes(wiping: &plain)
    }

    /// The file with every entry of the first format sealed again in the current one (its fields as they are, now all
    /// authenticated) and its version raised; what the file holds otherwise is unchanged. An entry that fails its seal
    /// is left as it is (it never opens; `xless secrets rm` removes it). Needs only the data key.
    public static func upgrade(_ file: VaultFile, dataKey: SymmetricKey) throws -> VaultFile {
        guard file.needsUpgrade else { return file }
        try verify(file, dataKey: dataKey)
        var out = file
        for (i, entry) in file.entries.enumerated() where entry.format == 1 {
            guard let secret = try? open(entry, dataKey: dataKey) else { continue }
            defer { secret.wipe() }
            var resealed = try seal(name: entry.name, kind: entry.kind, metadata: entry.metadata, secret: secret, dataKey: dataKey)
            resealed.unknown = entry.unknown
            out.entries[i] = resealed
        }
        out.version = max(file.version, VaultFile.currentVersion)
        out.minimumReaderVersion = max(file.minimumReaderVersion, VaultFile.currentVersion)
        return out
    }

    public static func keyBytes(_ key: SymmetricKey) -> SecretBytes { key.withUnsafeBytes { SecretBytes(copying: $0) } }

    private static func seal<D: DataProtocol>(_ plain: D, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else {
            throw VaultError(.io, "cannot seal a secret", fix: "re-run")
        }
        return combined
    }
}
