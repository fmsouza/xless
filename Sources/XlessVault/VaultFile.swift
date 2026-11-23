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
///
/// Versions: 1, the first releases' (entries of format 1); 2, every entry's fields authenticated (entry format 2).
/// `minimumReaderVersion` is the oldest store format an xless must know to rewrite the file without losing anything:
/// an xless that knows less still reads the entries whose format it knows, but refuses to change the file. Fields
/// this xless does not know are written back as they were read.
public struct VaultFile: Codable, Sendable, Equatable {
    public static let formatName = "xless-vault"
    /// The store format this xless writes and the newest it can rewrite.
    public static let currentVersion = 2
    /// The layout the wrapped key and the key check authenticate (it stays 1, so a store moves to a newer version with
    /// its data key alone, without the passphrase).
    static let keyLayout = 1

    public var format: String
    public var version: Int
    /// The oldest store format that may rewrite this file (`version` when the file does not say; 1 for version 1).
    public var minimumReaderVersion: Int
    /// Random; names the unlock cache's keyring key, so two stores never share one.
    public var id: String
    public var kdf: VaultKDF
    var wrappedKey: Data
    var keyCheck: Data
    public var entries: [VaultEntry]
    /// Top-level fields this xless does not know, as read.
    var unknown: [String: VaultJSON] = [:]

    init(format: String, version: Int, minimumReaderVersion: Int, id: String, kdf: VaultKDF, wrappedKey: Data, keyCheck: Data,
         entries: [VaultEntry]) {
        self.format = format
        self.version = version
        self.minimumReaderVersion = minimumReaderVersion
        self.id = id
        self.kdf = kdf
        self.wrappedKey = wrappedKey
        self.keyCheck = keyCheck
        self.entries = entries
    }

    public func entry(named name: String) -> VaultEntry? { entries.first { $0.name == name } }

    /// Whether this xless may rewrite the file (it knows every field a newer xless may have put in it).
    public var isWritable: Bool { minimumReaderVersion <= Self.currentVersion }

    /// Refuses a file this xless may not rewrite (`isWritable`), before anything is changed or asked.
    public func requireWritable() throws {
        guard isWritable else {
            throw VaultError(.newerFormat,
                             "the secret store was written by a newer xless (store format \(minimumReaderVersion); this xless knows format \(Self.currentVersion) and older): it can read the entries it knows but must not change the file, or it would drop what it does not know",
                             fix: "upgrade xless (run the install line again: README.md#install); the store is unchanged")
        }
    }

    /// Whether some entries still have the first format (a store of version 1): the next write with the data key at
    /// hand seals them again with every field (`VaultCrypto.upgrade`).
    public var needsUpgrade: Bool { version < Self.currentVersion }

    var headerAssociatedData: Data {
        var out = Data("xless-vault-header/\(Self.keyLayout)\u{0}\(format)\u{0}\(id)\u{0}\(kdf.algorithm)\u{0}".utf8)
        out.append(kdf.salt)
        out.append(Data("\u{0}\(kdf.rounds)\u{0}\(kdf.blockSize)\u{0}\(kdf.parallelism)".utf8))
        return out
    }

    var keyCheckAssociatedData: Data { Data("xless-vault-key-check/\(Self.keyLayout)\u{0}\(id)".utf8) }

    // MARK: Encoding

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, version, minimumReaderVersion, id, kdf, wrappedKey, keyCheck, entries
    }

    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        minimumReaderVersion = version >= 2 ? try c.decodeIfPresent(Int.self, forKey: .minimumReaderVersion) ?? version : 1
        id = try c.decode(String.self, forKey: .id)
        kdf = try c.decode(VaultKDF.self, forKey: .kdf)
        wrappedKey = try c.decode(Data.self, forKey: .wrappedKey)
        keyCheck = try c.decode(Data.self, forKey: .keyCheck)
        entries = try c.decode([VaultEntry].self, forKey: .entries)
        unknown = try VaultJSON.unknownMembers(of: decoder, known: Self.knownKeys)
        // What an entry's format really is follows from the store's version: every entry of a version-1 store has
        // format 1; in a later store an entry must say 2 or more, and one that does not (an older entry pasted in, its
        // optional fields stripped) never opens.
        for i in entries.indices {
            if version < 2 {
                if entries[i].format != 1 { entries[i].format = 0 }
            } else if entries[i].format < 2 {
                entries[i].format = 0
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        if version >= 2 { try c.encode(minimumReaderVersion, forKey: .minimumReaderVersion) }
        try c.encode(id, forKey: .id)
        try c.encode(kdf, forKey: .kdf)
        try c.encode(wrappedKey, forKey: .wrappedKey)
        try c.encode(keyCheck, forKey: .keyCheck)
        try c.encode(entries, forKey: .entries)
        try VaultJSON.encode(unknown, to: encoder, known: Self.knownKeys)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// The file; any version from 1 (a newer one is read as far as this xless knows it: `requireWritable`).
    public static func decode(_ data: Data) throws -> VaultFile {
        struct Probe: Decodable { var format: String?; var version: Int? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.format == formatName, let version = probe.version else {
            throw VaultError.tampered("not an xless secret store file")
        }
        guard version >= 1 else { throw VaultError.tampered("store version \(version)") }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        do { return try d.decode(VaultFile.self, from: data) } catch {
            // A newer xless may have changed what this one expects (a kind it added): never call that store corrupt.
            guard version > currentVersion else { throw VaultError.tampered("malformed file") }
            throw VaultError(.newerFormat,
                             "the secret store was written by a newer xless (store format \(version)) in a way this xless (format \(currentVersion) and older) cannot read",
                             fix: "upgrade xless (run the install line again: README.md#install); the store is unchanged, do not re-create it")
        }
    }
}
