import Foundation
import XlessAgent
import XlessAppleID
import XlessCore
import XlessVault

// Where an unlock and an Apple ID session are held for later commands (`xless unlock`, `--remember`, `--keep`): the
// xless agent or, where none can run, the Linux kernel keyring, for an hour at most and with less to end it.

/// The agents of this user, as these adapters use them (`AgentClient`; a fake in tests).
protocol AgentHolding: Sendable {
    var obstacle: AgentError? { get }
    var problem: AgentError? { get }
    func get(_ name: String, using: Bool, accept: (SecretBytes) -> Bool) -> SecretBytes?
    func get(_ name: String, using: Bool, witness: () -> AgentWitness?) -> SecretBytes?
    func put(_ seeds: [AgentSeed], witness: () -> AgentWitness?) throws
    func drop(prefix: String, label: String) -> AgentDropped
    func discard(_ names: [String], witness: () -> AgentWitness?) -> Bool
    func statuses() -> [AgentStatus]
    func leases() -> [AgentStatus]
}

extension AgentClient: AgentHolding {}

enum HeldSecrets {
    /// XLESS_NO_SECRET_STORE=1 (build code's environment): nothing held is looked for.
    static let isOff = ProcessInfo.processInfo.environment["XLESS_NO_SECRET_STORE"] == "1"

    /// `unlock:` in config.yml.
    static let settings = Result { try UserConfig.unlockSettings() }

    /// The longest anything is held after it was typed.
    static var maximum: Int { ((try? settings.get()) ?? UnlockSettings()).maximum }

    static let agents = AgentClient(terms: terms, session: XlessSession.agent)

    /// What the agents keep to.
    static var terms: AgentTerms {
        let s = (try? settings.get()) ?? UnlockSettings()
        return AgentTerms(maximum: s.maximum, lockOnSleep: s.lockOnSleep, lockOnScreenLock: s.lockOnScreenLock)
    }

    static func say(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }

    static func name(ofVault id: String) -> String { vaultPrefix + id }
    static let vaultPrefix = "xless-vault:"

    /// Whether anything can be kept: in an agent, or where none can run in the keyring. What is wrong with an agent that
    /// could run is put right, not worked round with what keeps less.
    static func canKeep(_ agents: any AgentHolding, keyring: Bool) -> Bool {
        guard let obstacle = agents.obstacle else { return true }
        return obstacle.kind == .unavailable && keyring
    }

    /// Why nothing can be kept.
    static func reason(_ agents: any AgentHolding) -> String {
        if let obstacle = agents.obstacle, obstacle.kind != .unavailable { return obstacle.cause }
        return "there is no kernel keyring here (macOS, or a container that blocks it), and \(agents.obstacle?.cause ?? "the xless agent cannot be used")"
    }

    /// What the kernel keyring holds instead of the agent, and what does not end it there.
    static func fallback(_ what: String, seconds: Int, because why: String) -> String {
        "note: \(why); the kernel keyring keeps \(what) instead, for \(HoldDuration.text(seconds)): a time without use does not end it there, nor do sleep, a locked screen or closing this terminal (`xless lock` in this login does)"
    }
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

private final class FirstFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: AgentError?

    var first: AgentError? { lock.withLock { failure } }
    func note(_ error: AgentError?) { lock.withLock { failure = failure ?? error } }
}

/// The secret store's unlock.
struct HeldKeyCache: VaultKeyCache {
    let agents: any AgentHolding
    let keyring: any VaultKeyCache
    let isOff: Bool
    /// The longest a hold lasts after the passphrase was typed, as the settings say now.
    let maximum: Int
    private let say: SayOnce

    init(agents: any AgentHolding = HeldSecrets.agents, keyring: any VaultKeyCache = KernelKeyringCache(), isOff: Bool = HeldSecrets.isOff,
         maximum: Int = HeldSecrets.maximum, say: @escaping @Sendable (String) -> Void = HeldSecrets.say) {
        self.agents = agents
        self.keyring = keyring
        self.isOff = isOff
        self.maximum = maximum
        self.say = SayOnce(say)
    }

    var isAvailable: Bool { !isOff && HeldSecrets.canKeep(agents, keyring: keyring.isAvailable) }

    func load(id: String, using: Bool, accept: (SecretBytes) -> Bool) throws -> SecretBytes? {
        guard !isOff else { return nil }
        let name = HeldSecrets.name(ofVault: id)
        var seen = false
        if let key = agents.get(name, using: using, accept: { seen = true; return accept($0) }) { return key }
        if seen { _ = agents.drop(prefix: name, label: "") }
        if let age = keyring.held(id: id)?.typedAgo, age >= maximum { _ = try keyring.forget(id: id) }
        if let key = try keyring.load(id: id, using: using, accept: accept) { return key }
        say.problem(of: agents)
        return nil
    }

    /// What is kept of a hold.
    struct Plan: Equatable {
        let seconds: Int
        /// nil: no idle time.
        let idle: Int?
    }

    /// What will be kept of `hold` here.
    func plan(_ hold: SecretHold) -> Plan {
        agents.obstacle == nil ? Plan(seconds: hold.seconds, idle: hold.idle) : Plan(seconds: min(hold.seconds, KernelKeyring.maximumTimeout), idle: nil)
    }

    /// That `hold` can be kept here, with the idle time when one was asked for: checked before anything is asked.
    func require(_ hold: SecretHold) throws {
        guard isAvailable else {
            throw VaultError(.cacheUnavailable, "the store cannot be kept unlocked here: \(isOff ? "XLESS_NO_SECRET_STORE=1 is set" : HeldSecrets.reason(agents))",
                             fix: agents.obstacle.flatMap { $0.kind == .unavailable ? nil : $0.fix } ?? "run without it; each command that needs the store asks the passphrase")
        }
        if let obstacle = agents.obstacle, hold.idleAsked { throw Self.noIdle(obstacle) }
    }

    private static func noIdle(_ why: AgentError) -> VaultError {
        VaultError(.cacheUnavailable, "--idle cannot be kept here: \(why.cause), and the kernel keyring has no idle time", fix: "\(why.fix), or leave --idle out")
    }

    func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typedAgo: Int) throws {
        guard !isOff else { throw VaultError(.cacheUnavailable, "XLESS_NO_SECRET_STORE=1 is set: nothing is kept unlocked", fix: "unset it") }
        do {
            if let obstacle = agents.obstacle { throw obstacle }
            let name = HeldSecrets.name(ofVault: id)
            try agents.put([AgentSeed(name: name, label: place, secret: key, hold: hold, typedAgo: typedAgo)]) { AgentWitness(item: name, key: key) }
            try keyring.forget(id: id)
        } catch let e as AgentError {
            guard e.kind == .unavailable, keyring.isAvailable else {
                throw VaultError(.cacheUnavailable, "the store cannot be kept unlocked here: \(agents.obstacle == nil ? e.cause : HeldSecrets.reason(agents))", fix: e.fix)
            }
            if hold.idleAsked { throw Self.noIdle(e) }
            let shorter = SecretHold(seconds: min(hold.seconds, KernelKeyring.maximumTimeout), idle: hold.idle, maximum: hold.maximum)
            say(HeldSecrets.fallback("the store unlocked", seconds: shorter.seconds, because: e.cause))
            try keyring.store(key, id: id, place: place, hold: shorter, typedAgo: typedAgo)
        }
    }

    func forget(id: String) throws -> Bool {
        let dropped = agents.drop(prefix: HeldSecrets.name(ofVault: id), label: "")
        let any = try keyring.forget(id: id) || dropped.count > 0
        if let unreached = dropped.unreached { throw VaultError(.cacheUnavailable, unreached.cause, fix: unreached.fix) }
        return any
    }

    func forget(place: String) throws {
        let dropped = agents.drop(prefix: HeldSecrets.vaultPrefix, label: place)
        try keyring.forget(place: place)
        if let unreached = dropped.unreached { throw VaultError(.cacheUnavailable, unreached.cause, fix: unreached.fix) }
    }

    /// Drops an unlock that was typed nobody knows when, or too long ago: the keyring's. An agent knows, and keeps none.
    func forgetUndated(id: String, maximum: Int) throws {
        if let held = keyring.held(id: id), (held.typedAgo ?? maximum) >= maximum { _ = try keyring.forget(id: id) }
    }

    func held(id: String) -> HeldUnlock? {
        guard !isOff else { return nil }
        let name = HeldSecrets.name(ofVault: id), now = Date()
        for status in agents.statuses() where status.isGranted {
            if let item = status.items.first(where: { $0.name == name }) {
                return HeldUnlock(backend: .agent, expires: now + TimeInterval(item.remaining), idle: item.idle, idleExpires: now + TimeInterval(item.idleRemaining), typedAgo: item.typedAgo)
            }
        }
        return keyring.held(id: id).flatMap { ($0.typedAgo ?? 0) < maximum ? $0 : nil }
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
    private let failures = FirstFailure()

    init(agents: any AgentHolding = HeldSecrets.agents, keyring: any SessionKeyStore = KernelKeyringSessionStore(), isOff: Bool = HeldSecrets.isOff,
         witness: @escaping @Sendable () -> AgentWitness?, say: @escaping @Sendable (String) -> Void = HeldSecrets.say) {
        self.agents = agents
        self.keyring = keyring
        self.isOff = isOff
        self.witness = witness
        self.say = SayOnce(say)
    }

    var isAvailable: Bool { !isOff && HeldSecrets.canKeep(agents, keyring: keyring.isAvailable) }

    /// Why a session cannot be kept.
    var obstacle: String { isOff ? "XLESS_NO_SECRET_STORE=1 is set" : HeldSecrets.reason(agents) }

    func allowed(_ hold: SecretHold) -> Int { agents.obstacle == nil ? hold.seconds : keyring.allowed(hold) }

    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {
        guard isAvailable else { throw AppleSessionCache.unavailable(obstacle) }
        do {
            if let obstacle = agents.obstacle { throw obstacle }
            try agents.put([AgentSeed(name: name, label: "", secret: secret, hold: hold)], witness: witness)
            _ = try keyring.revoke(name)
        } catch let e as AgentError {
            guard e.kind == .unavailable, keyring.isAvailable, keyring.allowed(hold) == hold.seconds else { throw e }
            say(HeldSecrets.fallback("the Apple ID session", seconds: hold.seconds, because: e.cause))
            try keyring.put(name, secret, hold: hold)
        }
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
                return HeldUnlock(backend: .agent, expires: now + TimeInterval(item.remaining), idle: item.idle, idleExpires: now + TimeInterval(item.idleRemaining), typedAgo: item.typedAgo)
            }
        }
        return ((try? keyring.get(name, using: false)) ?? nil) == nil ? nil : HeldUnlock(backend: .keyring, expires: nil)
    }

    func revoke(_ name: String) throws -> Bool {
        let dropped = agents.drop(prefix: name, label: "")
        failures.note(dropped.unreached)
        return try keyring.revoke(name) || dropped.count > 0
    }

    func discard(_ names: [String]) throws {
        if !agents.discard(names, witness: witness) { try keyring.discard(names) }
    }

    /// Why not every agent was reached by what was revoked: the first failure.
    var unreached: AgentError? { failures.first }
}
