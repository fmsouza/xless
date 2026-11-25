import Crypto
import Foundation
@testable import XlessCore
@testable import XlessVault

/// Fast scrypt for tests (the real default is N = 2^17).
func testKDF() -> VaultKDF { .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1) }

/// A fresh store directory under a 0700 temporary parent; removed by `cleanup()`.
struct TempStore {
    let root: URL
    let location: VaultLocation
    var store: VaultStore { VaultStore(location: location) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        location = VaultLocation(directory: root.appendingPathComponent("xless/vault"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A new store with `entries` (name → (kind, metadata, secret)), and its data key.
    @discardableResult
    func make(passphrase: String = "correct horse battery",
              entries: [(String, VaultEntry.Kind, VaultEntry.Metadata, String)] = []) throws -> (VaultFile, SymmetricKey) {
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: passphrase), kdf: testKDF())
        for (name, kind, meta, secret) in entries {
            file.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: meta, secret: SecretBytes(utf8: secret), dataKey: key))
        }
        try store.create(file)
        return (file, key)
    }
}

/// Answers passphrase prompts from a script; counts them.
final class ScriptedPrompter: PassphrasePrompter, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private(set) var asked = 0
    private(set) var said: [String] = []

    init(_ answers: [String]) { self.answers = answers }

    func askSecret(_ prompt: String) throws -> SecretBytes {
        try lock.withLock {
            asked += 1
            guard !answers.isEmpty else { throw VaultError(.invalidInput, "no more scripted answers", fix: "-") }
            return SecretBytes(utf8: answers.removeFirst())
        }
    }

    func ask(_ prompt: String) throws -> String { try askSecret(prompt).utf8String() }
    func say(_ line: String) { lock.withLock { said.append(line) } }
}

/// An in-memory unlock cache.
final class MemoryCache: VaultKeyCache, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: [UInt8]] = [:]
    private(set) var stored: [(String, Int)] = []
    private(set) var typed: [Bool] = []
    private(set) var places: [String] = []
    var isAvailable: Bool { true }

    func load(id: String, using: Bool = true, accept: (SecretBytes) -> Bool = { _ in true }) throws -> SecretBytes? {
        lock.withLock {
            guard let key = keys[id].map({ SecretBytes(copying: $0) }) else { return nil }
            if accept(key) { return key }
            keys[id] = nil
            return nil
        }
    }
    func store(id: String, key: SecretBytes, seconds: Int) throws {
        try store(key, id: id, place: "", hold: SecretHold(seconds: seconds, idle: seconds, maximum: seconds), typed: true)
    }
    func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typed: Bool) throws {
        lock.withLock {
            keys[id] = key.withUnsafeBytes { Array($0) }
            stored.append((id, hold.seconds))
            self.typed.append(typed)
            places.append(place)
        }
    }
    func forget(place: String) throws { lock.withLock { keys = [:] } }
    func held(id: String) -> HeldUnlock? { lock.withLock { keys[id] == nil ? nil : HeldUnlock(backend: .agent, expires: nil) } }
    func forget(id: String) throws -> Bool { lock.withLock { keys.removeValue(forKey: id) != nil } }
}

func mode(_ path: String) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
