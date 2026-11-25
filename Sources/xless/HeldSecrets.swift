import Foundation
import XlessAgent
import XlessAppleID
import XlessCore
import XlessVault

// Where an unlock and an Apple ID session are held for later commands (`xless unlock`, `--remember`, `--keep`): the
// xless agent, or the Linux kernel keyring for an hour or less (and where no agent can run).

/// The agents of this user, as these adapters use them (`AgentClient`; a fake in tests).
protocol AgentHolding: Sendable {
    var obstacle: AgentError? { get }
    var problem: AgentError? { get }
    func get(_ name: String, using: Bool, accept: (SecretBytes) -> Bool) -> SecretBytes?
    func get(_ name: String, using: Bool, witness: () -> AgentWitness?) -> SecretBytes?
    func put(_ seeds: [AgentSeed], typed: Bool, witness: () -> AgentWitness?) throws
    func drop(prefix: String, label: String) -> Int
    func lockAll() throws -> Int
    func statuses() -> [AgentStatus]
}

extension AgentClient: AgentHolding {}

enum HeldSecrets {
    /// XLESS_NO_SECRET_STORE=1 (build code's environment): nothing held is looked for.
    static let isOff = ProcessInfo.processInfo.environment["XLESS_NO_SECRET_STORE"] == "1"

    /// `unlock:` in config.yml.
    static let settings = Result { try UserConfig.unlockSettings() }

    static let agents: AgentClient = {
        let s = (try? settings.get()) ?? UnlockSettings()
        return AgentClient(locking: AgentLocking(onSleep: s.lockOnSleep, onScreenLock: s.lockOnScreenLock))
    }()

    static func say(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }

    static func name(ofVault id: String) -> String { vaultPrefix + id }
    static let vaultPrefix = "xless-vault:"

    /// Why nothing can be kept where there is neither.
    static func reason(_ agents: any AgentHolding) -> String {
        "there is no kernel keyring here (macOS, or a container that blocks it), and \(agents.obstacle?.cause ?? "the xless agent cannot be used")"
    }

    /// Whether `hold` goes to the kernel keyring: an hour or less where there is one (as before there was an agent).
    static func fitsKeyring(_ hold: SecretHold) -> Bool { hold.seconds <= KernelKeyring.maximumTimeout }
}

/// Says each thing once per process.
private final class SayOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var said: Set<String> = []
    private let say: @Sendable (String) -> Void

    init(_ say: @escaping @Sendable (String) -> Void) { self.say = say }

    func callAsFunction(_ line: String) {
        if lock.withLock({ said.insert(line).inserted }) { say(line) }
    }

    func problem(of agents: any AgentHolding) {
        if let problem = agents.problem { self("note: \(problem)") }
    }
}

/// The secret store's unlock.
struct HeldKeyCache: VaultKeyCache {
    let agents: any AgentHolding
    let keyring: any VaultKeyCache
    let isOff: Bool
    private let say: SayOnce

    init(agents: any AgentHolding = HeldSecrets.agents, keyring: any VaultKeyCache = KernelKeyringCache(), isOff: Bool = HeldSecrets.isOff,
         say: @escaping @Sendable (String) -> Void = HeldSecrets.say) {
        self.agents = agents
        self.keyring = keyring
        self.isOff = isOff
        self.say = SayOnce(say)
    }

    var isAvailable: Bool { !isOff && (keyring.isAvailable || agents.obstacle == nil) }

    func load(id: String, using: Bool, accept: (SecretBytes) -> Bool) throws -> SecretBytes? {
        guard !isOff else { return nil }
        let name = HeldSecrets.name(ofVault: id)
        var seen = false
        if let key = agents.get(name, using: using, accept: { seen = true; return accept($0) }) { return key }
        if seen { _ = agents.drop(prefix: name, label: "") }
        if let key = try keyring.load(id: id, using: using, accept: accept) { return key }
        say.problem(of: agents)
        return nil
    }

    func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typed: Bool) throws {
        guard !isOff else { throw VaultError(.cacheUnavailable, "XLESS_NO_SECRET_STORE=1 is set: nothing is kept unlocked", fix: "unset it") }
        let name = HeldSecrets.name(ofVault: id)
        if HeldSecrets.fitsKeyring(hold), keyring.isAvailable, held(id: id)?.backend != .agent {
            return try keyring.store(key, id: id, place: place, hold: hold, typed: typed)
        }
        do {
            try agents.put([AgentSeed(name: name, label: place, secret: key, hold: hold)], typed: typed) { AgentWitness(item: name, key: key) }
            try keyring.forget(id: id)
        } catch let e as AgentError {
            guard keyring.isAvailable else {
                throw VaultError(.cacheUnavailable, "the store cannot be kept unlocked here: \(agents.obstacle == nil ? e.cause : HeldSecrets.reason(agents))", fix: e.fix)
            }
            say("note: \(e.cause); the kernel keyring keeps the store unlocked instead, for \(HoldDuration.text(min(hold.seconds, KernelKeyring.maximumTimeout)))")
            let shorter = SecretHold(seconds: min(hold.seconds, KernelKeyring.maximumTimeout), idle: hold.idle, maximum: hold.maximum)
            try keyring.store(key, id: id, place: place, hold: shorter, typed: typed)
        }
    }

    func forget(id: String) throws -> Bool {
        let agent = agents.drop(prefix: HeldSecrets.name(ofVault: id), label: "") > 0
        return try keyring.forget(id: id) || agent
    }

    func forget(place: String) throws {
        _ = agents.drop(prefix: HeldSecrets.vaultPrefix, label: place)
        try keyring.forget(place: place)
    }

    func held(id: String) -> HeldUnlock? {
        guard !isOff else { return nil }
        let name = HeldSecrets.name(ofVault: id), now = Date()
        for status in agents.statuses() where status.isGranted {
            if let item = status.items.first(where: { $0.name == name }) {
                return HeldUnlock(backend: .agent, expires: now + TimeInterval(item.remaining), idle: item.idle, idleExpires: now + TimeInterval(item.idleRemaining))
            }
        }
        return keyring.held(id: id)
    }
}

/// The Apple ID session.
struct HeldSessionStore: SessionKeyStore {
    let agents: any AgentHolding
    let keyring: any SessionKeyStore
    let isOff: Bool
    /// What shows an agent of another terminal that this one has the store unlocked (never asked for).
    let witness: @Sendable () -> AgentWitness?
    private let say: SayOnce

    init(agents: any AgentHolding = HeldSecrets.agents, keyring: any SessionKeyStore = KernelKeyringSessionStore(), isOff: Bool = HeldSecrets.isOff,
         witness: @escaping @Sendable () -> AgentWitness?, say: @escaping @Sendable (String) -> Void = HeldSecrets.say) {
        self.agents = agents
        self.keyring = keyring
        self.isOff = isOff
        self.witness = witness
        self.say = SayOnce(say)
    }

    var isAvailable: Bool { !isOff && (keyring.isAvailable || agents.obstacle == nil) }

    /// Why a session cannot be kept.
    var obstacle: String { isOff ? "XLESS_NO_SECRET_STORE=1 is set" : HeldSecrets.reason(agents) }

    func allowed(_ hold: SecretHold) -> Int { agents.obstacle == nil ? hold.seconds : keyring.allowed(hold) }

    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {
        guard isAvailable else { throw AppleSessionCache.unavailable(obstacle) }
        _ = try revoke(name)
        if HeldSecrets.fitsKeyring(hold), keyring.isAvailable { return try keyring.put(name, secret, hold: hold) }
        try agents.put([AgentSeed(name: name, label: "", secret: secret, hold: hold)], typed: true, witness: witness)
    }

    func get(_ name: String, using: Bool) throws -> SecretBytes? {
        guard !isOff else { return nil }
        if let secret = agents.get(name, using: using, witness: witness) { return secret }
        if let secret = try keyring.get(name, using: using) { return secret }
        say.problem(of: agents)
        return nil
    }

    /// What is held of a kept session.
    func held() -> HeldUnlock? {
        guard !isOff else { return nil }
        let now = Date(), name = AppleSessionCache.prefix
        for status in agents.statuses() where status.isGranted {
            if let item = status.items.first(where: { $0.name == name }) {
                return HeldUnlock(backend: .agent, expires: now + TimeInterval(item.remaining), idle: item.idle, idleExpires: now + TimeInterval(item.idleRemaining))
            }
        }
        return ((try? keyring.get(name, using: false)) ?? nil) == nil ? nil : HeldUnlock(backend: .keyring, expires: nil)
    }

    func revoke(_ name: String) throws -> Bool {
        let agent = agents.drop(prefix: name, label: "") > 0
        return try keyring.revoke(name) || agent
    }
}
