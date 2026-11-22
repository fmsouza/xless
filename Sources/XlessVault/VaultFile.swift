import Crypto
import _CryptoExtras
import Foundation
import XlessCore

/// The passphrase's key derivation: scrypt, its parameters recorded in the file (and authenticated with the data key).
public struct VaultKDF: Codable, Sendable, Equatable {
    public var algorithm: String
    public var salt: Data
    /// N (a power of two), r, p.
    public var rounds: Int
    public var blockSize: Int
    public var parallelism: Int

    /// N = 2^17, r = 8, p = 1: 128 MiB and a fraction of a second per unlock.
    public static func standard() -> VaultKDF { fresh(rounds: 1 << 17, blockSize: 8, parallelism: 1) }

    /// New parameters with a fresh 16-byte salt (tests use small `rounds`).
    public static func fresh(rounds: Int, blockSize: Int, parallelism: Int) -> VaultKDF {
        VaultKDF(algorithm: "scrypt", salt: Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }),
                 rounds: rounds, blockSize: blockSize, parallelism: parallelism)
    }

    /// Refuses parameters no xless writes, before deriving anything: an altered header must not make an unlock take
    /// gigabytes of memory or hours.
    func validate() throws {
        let powerOfTwo = rounds > 0 && rounds & (rounds - 1) == 0
        guard algorithm == "scrypt", powerOfTwo, (1 << 10...1 << 22).contains(rounds), (1...32).contains(blockSize),
              (1...16).contains(parallelism), 128 * rounds * blockSize * parallelism <= 1 << 30, (16...64).contains(salt.count)
        else { throw VaultError.tampered("key derivation parameters out of range") }
    }

    func deriveKey(from passphrase: SecretBytes) throws -> SymmetricKey {
        try validate()
        return try passphrase.withUnsafeBytes { bytes in
            try KDF.Scrypt.deriveKey(from: bytes, salt: salt, outputByteCount: 32, rounds: rounds, blockSize: blockSize,
                                     parallelism: parallelism)
        }
    }
}

/// The store's file: a versioned header (format, version, random ID, KDF), the data key wrapped by the passphrase's key,
/// a key check (to verify a data key taken from the unlock cache) and the entries.
public struct VaultFile: Codable, Sendable, Equatable {
    public static let formatName = "xless-vault"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    /// Random; names the unlock cache's keyring key, so two stores never share one.
    public var id: String
    public var kdf: VaultKDF
    var wrappedKey: Data
    var keyCheck: Data
    public var entries: [VaultEntry]

    public func entry(named name: String) -> VaultEntry? { entries.first { $0.name == name } }

    var headerAssociatedData: Data {
        var out = Data("xless-vault-header/\(version)\u{0}\(format)\u{0}\(id)\u{0}\(kdf.algorithm)\u{0}".utf8)
        out.append(kdf.salt)
        out.append(Data("\u{0}\(kdf.rounds)\u{0}\(kdf.blockSize)\u{0}\(kdf.parallelism)".utf8))
        return out
    }

    var keyCheckAssociatedData: Data { Data("xless-vault-key-check/\(version)\u{0}\(id)".utf8) }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> VaultFile {
        struct Probe: Decodable { var format: String?; var version: Int? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.format == formatName, let version = probe.version else {
            throw VaultError.tampered("not an xless secret store file")
        }
        guard version == currentVersion else {
            throw VaultError(.unsupported, "the secret store is format version \(version); this xless reads version \(currentVersion)",
                             fix: "use the xless release that wrote it, or a newer one")
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        do { return try d.decode(VaultFile.self, from: data) } catch { throw VaultError.tampered("malformed file") }
    }
}
