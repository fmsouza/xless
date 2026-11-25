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

/// An unlock held for later commands, as `xless secrets status` and `xless auth status` show it.
public struct HeldUnlock: Sendable, Equatable {
    public enum Backend: String, Sendable, Equatable { case agent, keyring }

    public let backend: Backend
    /// When it ends whatever happens (nil: the backend does not say).
    public let expires: Date?
    /// The agent drops it after this many seconds without use.
    public let idle: Int?
    public let idleExpires: Date?
    /// The seconds since the passphrase (or the password) was typed; nil: not known.
    public let typedAgo: Int?

    public init(backend: Backend, expires: Date?, idle: Int? = nil, idleExpires: Date? = nil, typedAgo: Int? = nil) {
        self.backend = backend; self.expires = expires; self.idle = idle; self.idleExpires = idleExpires; self.typedAgo = typedAgo
    }
}

/// The opt-in unlock cache: the unwrapped data key, kept for a bounded time (`xless unlock`, `--remember`), keyed by the
/// store's ID.
public protocol VaultKeyCache: Sendable {
    var isAvailable: Bool { get }
    /// The key held for the store `id`, when `accept` says it is the store's. One that is not is dropped.
    /// - Parameter using: false to look only (its idle time goes on).
    func load(id: String, using: Bool, accept: (SecretBytes) -> Bool) throws -> SecretBytes?
    /// - Parameters:
    ///   - place: where the store is: a key held for another store at the same place is dropped.
    ///   - typedAgo: the seconds since the passphrase was typed, which the longest hold counts from; 0: for this.
    func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typedAgo: Int) throws
    /// Drops the cached key; whether there was one.
    @discardableResult func forget(id: String) throws -> Bool
    /// The store at `place` was replaced: drops the keys held for what was there.
    func forget(place: String) throws
    /// What is held for the store `id`.
    func held(id: String) -> HeldUnlock?
}

/// The cache in the Linux kernel keyring (session keyring, possessor-only, expired by the kernel after at most an hour;
/// see `KernelKeyring`).
public struct KernelKeyringCache: VaultKeyCache {
    public init() {}

    static let prefix = "xless-vault:"
    /// Beside each key, when the kernel drops it (it does not tell itself) and when the passphrase was typed, by the wall
    /// clock and by the one that counts while the system sleeps.
    static let untilPrefix = "xless-vault-until:"

    static func keyName(_ id: String) -> String { prefix + id }

    public var isAvailable: Bool { KernelKeyring.isAvailable }

    public func load(id: String, using: Bool, accept: (SecretBytes) -> Bool) throws -> SecretBytes? {
        guard isAvailable, let key = try KernelKeyring.find(name: Self.keyName(id)), let bytes = try? KernelKeyring.read(key) else { return nil }
        if accept(bytes) { return bytes }
        _ = try forget(id: id)
        return nil
    }

    public func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typedAgo: Int) throws {
        guard isAvailable else {
            throw VaultError(.cacheUnavailable, "the kernel keyring is not available here (macOS, or a container that blocks it)",
                             fix: "run without --remember; the passphrase is asked by each command that needs the store")
        }
        let seconds = min(hold.seconds, KernelKeyring.maximumTimeout, hold.maximum - typedAgo)
        guard seconds > 0 else {
            throw VaultError(.cacheUnavailable, "the store was unlocked longer ago than it may be kept unlocked", fix: "run `xless lock`, then `xless unlock`")
        }
        do {
            let now = Int(Date().timeIntervalSince1970), awake = SystemClock.seconds
            // First what is known of the key, so the key is never there without it.
            try KernelKeyring.store(name: Self.untilPrefix + id, secret: SecretBytes(utf8: "\(now + seconds) \(now - typedAgo) \(awake - typedAgo)"), timeout: seconds)
            try KernelKeyring.store(name: Self.keyName(id), secret: key, timeout: seconds)
        } catch {
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
        while let key = try KernelKeyring.find(name: Self.untilPrefix + id) { try KernelKeyring.revoke(key) }
        return any
    }

    /// The keyring does not know the places: every store's key goes.
    public func forget(place: String) throws { try forgetAll() }

    /// Drops every store's key; how many there were.
    @discardableResult public func forgetAll() throws -> Int {
        let count = try KernelKeyring.revokeAll(prefix: Self.prefix)
        try KernelKeyring.revokeAll(prefix: Self.untilPrefix)
        return count
    }

    public func held(id: String) -> HeldUnlock? {
        guard isAvailable, (try? KernelKeyring.find(name: Self.keyName(id))) ?? nil != nil else { return nil }
        let text = ((try? KernelKeyring.find(name: Self.untilPrefix + id)) ?? nil).flatMap { try? KernelKeyring.read($0) }?.utf8String() ?? ""
        let known = text.split(separator: " ").compactMap { Int($0) }
        guard known.count == 3 else { return HeldUnlock(backend: .keyring, expires: nil) }
        let age = max(0, Int(Date().timeIntervalSince1970.rounded(.up)) - known[1], SystemClock.seconds - known[2])
        return HeldUnlock(backend: .keyring, expires: Date(timeIntervalSince1970: TimeInterval(known[0])), typedAgo: age)
    }
}

/// What the command line adds around the passphrase's question.
public protocol UnlockManner: Sendable {
    /// The line before it: what is asked, for what, and for how long it is kept (`remember`, nil: for this command).
    func announcement(reason: String, remember: SecretHold?) -> String?
    /// A passphrase was typed, for this command only: offers on the same terminal to keep the store unlocked; the hold
    /// the person agreed to. It is asked under the store's lock, so it must not ask the store for anything.
    func offer(_ prompter: any PassphrasePrompter) -> SecretHold?
    /// Whether what it agreed to is held now.
    func kept(_ held: Bool, _ prompter: any PassphrasePrompter)
}

/// Gets the data key of an existing store: from the unlock cache, else by asking the passphrase.
public enum VaultUnlocker {
    public static let passphrasePrompt = "Secret store passphrase: "
    static let attempts = 3

    /// - Parameters:
    ///   - prompter: the terminal, or nil when there is none; called only when the cache cannot unlock.
    ///   - remember: how long to keep the unlocked key in `cache` (nil: not cached).
    ///   - place: where the store is.
    ///   - reason: what needs the store ("the secret ASC_KEY_P8", "exporting NOTE"), for the line before the question and the error when it is locked and there is no terminal.
    public static func dataKey(for file: VaultFile, cache: (any VaultKeyCache)?, place: String = "", manner: (any UnlockManner)? = nil,
                               prompter: () -> (any PassphrasePrompter)?, remember: SecretHold? = nil, reason: String) throws -> SymmetricKey {
        // A stale key (the store was re-created) is dropped, and the passphrase asked.
        if let cached = try? cache?.load(id: file.id, using: true, accept: { opens(file, $0) }) {
            guard let remember, let cache else { return SymmetricKey(data: cached) }
            if let age = cache.held(id: file.id)?.typedAgo, age < remember.maximum {
                try cache.store(cached, id: file.id, place: place, hold: remember, typedAgo: max(age, 1))
                return SymmetricKey(data: cached)
            }
            // Held since nobody knows when, or for the longest time already: kept on only by typing it again.
        }
        if InputGate.isOff {
            throw VaultError.inputNeeded("the secret store's passphrase (\(reason))",
                                         fix: "run `xless unlock` in this terminal session first, or provide the secret through the environment")
        }
        guard let prompter = prompter() else {
            throw VaultError(.locked, "the secret store is locked and there is no terminal to ask its passphrase on (needed for \(reason))",
                             fix: "run `xless unlock` in this terminal session first, or provide it through the environment")
        }
        if let line = manner?.announcement(reason: reason, remember: remember) { prompter.say(line) }
        var lastError: VaultError = .wrongPassphrase
        for attempt in 1...attempts {
            let passphrase = try prompter.askSecret(passphrasePrompt)
            do {
                let key = try VaultCrypto.unwrap(file, passphrase: passphrase)
                if let remember, let cache {
                    try cache.store(VaultCrypto.keyBytes(key), id: file.id, place: place, hold: remember, typedAgo: 0)
                } else if let cache, let hold = manner?.offer(prompter) {
                    do {
                        try cache.store(VaultCrypto.keyBytes(key), id: file.id, place: place, hold: hold, typedAgo: 0)
                        manner?.kept(true, prompter)
                    } catch {
                        manner?.kept(false, prompter)
                        prompter.say("note: the store is not kept unlocked: \(error)")
                    }
                }
                return key
            } catch let e as VaultError where e.kind == .wrongPassphrase {
                lastError = e
                if attempt < attempts { prompter.say("Wrong passphrase, try again.") }
            }
        }
        throw lastError
    }

    /// Whether `key` is the data key of `file`.
    public static func opens(_ file: VaultFile, _ key: SecretBytes) -> Bool {
        (try? VaultCrypto.verify(file, dataKey: SymmetricKey(data: key))) != nil
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
