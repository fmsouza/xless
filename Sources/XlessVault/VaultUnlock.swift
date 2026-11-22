import Crypto
import Foundation
import XlessCore

/// The passphrase's source: the controlling terminal (`/dev/tty`) in the CLI, a script in tests. Never stdin, argv or
/// the environment.
public protocol PassphrasePrompter: AnyObject, Sendable {
    /// Read with echo off.
    func askSecret(_ prompt: String) throws -> SecretBytes
    func ask(_ prompt: String) throws -> String
    func say(_ line: String)
}

/// The opt-in unlock cache: the unwrapped data key, kept for a bounded time (`--remember`), keyed by the store's ID.
public protocol VaultKeyCache: Sendable {
    var isAvailable: Bool { get }
    func load(id: String) throws -> SecretBytes?
    func store(id: String, key: SecretBytes, seconds: Int) throws
    /// Drops the cached key; whether there was one.
    @discardableResult func forget(id: String) throws -> Bool
}

/// The cache in the Linux kernel keyring (session keyring, possessor-only, expired by the kernel; see `KernelKeyring`).
public struct KernelKeyringCache: VaultKeyCache {
    public init() {}

    static func keyName(_ id: String) -> String { "xless-vault:\(id)" }

    public var isAvailable: Bool { KernelKeyring.isAvailable }

    public func load(id: String) throws -> SecretBytes? {
        guard isAvailable, let key = try KernelKeyring.find(name: Self.keyName(id)) else { return nil }
        return try? KernelKeyring.read(key)
    }

    public func store(id: String, key: SecretBytes, seconds: Int) throws {
        guard isAvailable else {
            throw VaultError(.cacheUnavailable, "the kernel keyring is not available here (macOS, or a container that blocks it)",
                             fix: "run without --remember; the passphrase is asked by each command that needs the store")
        }
        do { try KernelKeyring.store(name: Self.keyName(id), secret: key, timeout: seconds) } catch {
            throw VaultError(.cacheUnavailable, "cannot keep the store unlocked: \(error)", fix: "run without --remember")
        }
    }

    public func forget(id: String) throws -> Bool {
        guard isAvailable else { return false }
        var any = false
        // Revoke every key of that name (a replace leaves one, but be thorough).
        while let key = try KernelKeyring.find(name: Self.keyName(id)) {
            try KernelKeyring.revoke(key)
            any = true
        }
        return any
    }
}

/// Gets the data key of an existing store: from the unlock cache, else by asking the passphrase.
public enum VaultUnlocker {
    public static let passphrasePrompt = "Secret store passphrase: "
    static let attempts = 3

    /// - Parameters:
    ///   - prompter: the terminal, or nil when there is none; called only when the cache cannot unlock.
    ///   - remember: seconds to keep the unlocked key in `cache` (nil: not cached).
    ///   - reason: what needs the store ("the secret ASC_KEY_P8", "exporting NOTE"), for the error when it is locked and there is no terminal.
    public static func dataKey(for file: VaultFile, cache: (any VaultKeyCache)?, prompter: () -> (any PassphrasePrompter)?,
                               remember: Int? = nil, reason: String) throws -> SymmetricKey {
        if let cached = try? cache?.load(id: file.id) {
            let key = SymmetricKey(data: cached)
            if (try? VaultCrypto.verify(file, dataKey: key)) != nil {
                if let remember, let cache { try cache.store(id: file.id, key: cached, seconds: remember) }
                return key
            }
            // A stale key (the store was re-created): drop it and ask.
            try? cache?.forget(id: file.id)
        }
        guard let prompter = prompter() else {
            throw VaultError(.locked, "the secret store is locked and there is no terminal to ask its passphrase on (needed for \(reason))",
                             fix: "run `xless secrets unlock --remember 30m` in this terminal session first, or provide it through the environment")
        }
        var lastError: VaultError = .wrongPassphrase
        for attempt in 1...attempts {
            let passphrase = try prompter.askSecret(passphrasePrompt)
            do {
                let key = try VaultCrypto.unwrap(file, passphrase: passphrase)
                if let remember, let cache { try cache.store(id: file.id, key: VaultCrypto.keyBytes(key), seconds: remember) }
                return key
            } catch let e as VaultError where e.kind == .wrongPassphrase {
                lastError = e
                if attempt < attempts { prompter.say("Wrong passphrase, try again.") }
            }
        }
        throw lastError
    }

    /// A new passphrase, typed twice; at least 8 bytes.
    public static func newPassphrase(_ prompter: any PassphrasePrompter, prompt: String = "New secret store passphrase: ") throws -> SecretBytes {
        let first = try prompter.askSecret(prompt)
        guard first.count >= 8 else {
            throw VaultError(.invalidInput, "the passphrase is shorter than 8 characters", fix: "re-run and choose a longer one (a few words is best)")
        }
        let second = try prompter.askSecret("Type it again: ")
        guard first == second else { throw VaultError(.invalidInput, "the two passphrases differ", fix: "re-run and type the same passphrase twice") }
        return first
    }
}

/// `--remember` durations: `90s`, `30m`, `1h` or bare seconds; 1 s … 1 h.
public enum RememberDuration {
    public static func seconds(_ text: String) throws -> Int {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        var digits = Substring(t)
        var unit = 1
        if let last = t.last, let u = units[last] { digits = t.dropLast(); unit = u }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let n = Int(digits), n > 0, n <= KernelKeyring.maximumTimeout / unit
        else {
            throw VaultError(.invalidInput, "--remember \(text) is not a duration between 1s and 1h", fix: "e.g. --remember 30m (at most 1h)")
        }
        return n * unit
    }
}
