import Foundation
import Testing
import XlessAgent
import XlessCore
@testable import XlessAppleID
@testable import XlessVault
@testable import xless

/// The agents of this user, in memory: one this session is granted, whose word is believed.
final class FakeAgents: AgentHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (seed: AgentSeed, bytes: SecretBytes)] = [:]
    private(set) var typed: [Int] = []
    private(set) var witnessed = 0
    private(set) var dropped: [(String, String)] = []
    var obstacle: AgentError?
    var problem: AgentError?
    var refuses = false
    var needsWitness = false

    var names: [String] { lock.withLock { items.keys.sorted() } }
    func hold(_ name: String) -> SecretHold? { lock.withLock { items[name]?.seed.hold } }
    func label(_ name: String) -> String? { lock.withLock { items[name]?.seed.label } }

    func get(_ name: String, using: Bool, accept: (SecretBytes) -> Bool) -> SecretBytes? {
        guard let bytes = lock.withLock({ items[name]?.bytes }), accept(bytes) else { return nil }
        return bytes
    }
    func get(_ name: String, using: Bool, witness: () -> AgentWitness?) -> SecretBytes? {
        guard let bytes = lock.withLock({ items[name]?.bytes }) else { return nil }
        guard needsWitness else { return bytes }
        lock.withLock { witnessed += 1 }
        return witness() == nil ? nil : bytes
    }
    func put(_ seeds: [AgentSeed], witness: () -> AgentWitness?) throws {
        if let obstacle { throw obstacle }
        if refuses { throw AgentError(.unavailable, "no agent today", fix: "-") }
        lock.withLock {
            for seed in seeds {
                items[seed.name] = (seed, seed.secret.withUnsafeBytes { SecretBytes(copying: $0) })
                typed.append(seed.typedAgo)
            }
        }
    }
    func drop(prefix: String, label: String) -> Int {
        lock.withLock {
            dropped.append((prefix, label))
            let gone = items.filter { $0.key.hasPrefix(prefix) && (label.isEmpty || $0.value.seed.label == label) }.keys
            for name in gone { items[name] = nil }
            return gone.count
        }
    }
    var unreached: AgentError?
    func statuses() -> [AgentStatus] {
        lock.withLock {
            guard !items.isEmpty else { return [] }
            let list = items.values.map { AgentItemStatus(name: $0.seed.name, label: $0.seed.label, remaining: $0.seed.hold.seconds, idle: $0.seed.hold.idle, idleRemaining: $0.seed.hold.idle) }
            return [AgentStatus(isGranted: true, count: list.count, remaining: list.map(\.remaining).max() ?? 0, sessions: 1, items: list.sorted { $0.name < $1.name })]
        }
    }
}

/// The kernel keyring, in memory.
final class FakeKeyring: VaultKeyCache, SessionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SecretBytes] = [:]
    private(set) var seconds: [String: Int] = [:]
    /// The seconds since what is held was typed.
    var typedAgo: Int? = 0
    let isAvailable: Bool
    init(available: Bool = true) { isAvailable = available }

    var names: [String] { lock.withLock { keys.keys.sorted() } }
    func load(id: String, using: Bool, accept: (SecretBytes) -> Bool) throws -> SecretBytes? { lock.withLock { keys[id].flatMap { accept($0) ? $0 : nil } } }
    func store(_ key: SecretBytes, id: String, place: String, hold: SecretHold, typedAgo: Int) throws { try put(id, key, hold: hold); lock.withLock { self.typedAgo = typedAgo } }
    func forget(id: String) throws -> Bool { try revoke(id) }
    func forget(place: String) throws { lock.withLock { keys = [:] } }
    func held(id: String) -> HeldUnlock? { lock.withLock { keys[id] == nil ? nil : HeldUnlock(backend: .keyring, expires: nil, typedAgo: typedAgo) } }
    func allowed(_ hold: SecretHold) -> Int { min(hold.seconds, 3600) }
    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {
        lock.withLock { keys[name] = secret; seconds[name] = hold.seconds }
    }
    func get(_ name: String, using: Bool) throws -> SecretBytes? { lock.withLock { keys[name] } }
    func revoke(_ name: String) throws -> Bool { lock.withLock { keys.removeValue(forKey: name) != nil } }
}

private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var lines: [String] { lock.withLock { all } }
    func say(_ s: String) { lock.withLock { all.append(s) } }
}

private let day = SecretHold(seconds: 8 * 3600, idle: 7200, maximum: 7 * 86400)
private let half = SecretHold(seconds: 1800, idle: 1800, maximum: 7 * 86400)
private func key(_ byte: UInt8 = 7) -> SecretBytes { SecretBytes(copying: [UInt8](repeating: byte, count: 32)) }

@Suite struct HeldKeyCacheTests {
    fileprivate func cache(_ agents: FakeAgents, _ keyring: FakeKeyring, _ notes: Notes = Notes()) -> HeldKeyCache {
        HeldKeyCache(agents: agents, keyring: keyring, say: notes.say)
    }

    @Test func aLongUnlockIsHeldByTheAgentForTheStoresPlace() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        #expect(agents.names == ["xless-vault:ID"])
        #expect(agents.hold("xless-vault:ID") == day)
        #expect(agents.label("xless-vault:ID") == "/store")
        #expect(agents.typed == [0])
        #expect(keyring.names.isEmpty)
        #expect(try c.load(id: "ID", using: true) { $0 == key() } == key())
        #expect(c.held(id: "ID")?.backend == .agent)
        #expect(c.held(id: "ID")?.idle == 7200)
    }

    @Test func anHourOrLessIsHeldByTheAgentToo() throws {
        // The keyring has no idle time, and neither sleep nor a closed terminal ends it.
        let agents = FakeAgents(), keyring = FakeKeyring(), notes = Notes()
        let c = cache(agents, keyring, notes)
        #expect(c.plan(half) == .init(seconds: 1800, idle: 1800))
        try c.store(key(), id: "ID", place: "/store", hold: half, typedAgo: 0)
        #expect(agents.hold("xless-vault:ID") == half)
        #expect(keyring.names.isEmpty && notes.lines.isEmpty)
    }

    @Test func aRenewalStaysWhereTheUnlockIs() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        try c.store(key(), id: "ID", place: "/store", hold: half, typedAgo: 50)
        #expect(agents.hold("xless-vault:ID") == half)
        #expect(keyring.names.isEmpty)
    }

    @Test func movingToTheAgentLeavesNothingInTheKeyring() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try keyring.store(key(), id: "ID", place: "/store", hold: half, typedAgo: 0) // by an older xless, or where no agent could run
        #expect(c.held(id: "ID")?.backend == .keyring)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        #expect(keyring.names.isEmpty)
        #expect(agents.names == ["xless-vault:ID"])
    }

    @Test func whereNoAgentCanRunTheKeyringHoldsItForAnHourAndSaysSo() throws {
        let agents = FakeAgents(), keyring = FakeKeyring(), notes = Notes()
        agents.obstacle = AgentError(.unavailable, "no session here", fix: "-")
        let c = cache(agents, keyring, notes)
        #expect(c.isAvailable)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        #expect(keyring.seconds["ID"] == 3600)
        // What it does not keep is said, not promised.
        #expect(c.plan(day) == .init(seconds: 3600, idle: nil))
        let note = try #require(notes.lines.first)
        #expect(note.contains("for 1 h") && note.contains("no session here") && note.contains("without use does not end it"), "\(note)")
        #expect(c.held(id: "ID")?.idle == nil)
        let nowhere = cache(agents, FakeKeyring(available: false))
        #expect(!nowhere.isAvailable)
        let error = #expect(throws: VaultError.self) { try nowhere.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0) }
        #expect(error?.kind == .cacheUnavailable)
        #expect(error?.cause.contains("no session here") == true)
    }

    @Test func anIdleTimeAskedForIsRefusedWhereItIsNotKept() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        agents.obstacle = AgentError(.unavailable, "no session here", fix: "-")
        let c = cache(agents, keyring)
        var hold = half
        hold.idleAsked = true
        let error = #expect(throws: VaultError.self) { try c.store(key(), id: "ID", place: "/store", hold: hold, typedAgo: 0) }
        #expect(error?.cause.contains("--idle") == true && error?.cause.contains("no session here") == true)
        #expect(keyring.names.isEmpty)
        #expect(throws: VaultError.self) { try c.require(hold) } // before anything is asked
        try c.require(half)
        // The agent, which could run, does not start: refused then, too.
        agents.obstacle = nil
        agents.refuses = true
        try c.require(hold)
        #expect(throws: VaultError.self) { try c.store(key(), id: "ID", place: "/store", hold: hold, typedAgo: 0) }
        #expect(keyring.names.isEmpty)
    }

    @Test func theIdleTimeOfTheCommandLineIsToldFromTheConfiguredOne() throws {
        let settings = UnlockSettings()
        #expect(try settings.hold("1h", idle: "5s", option: "--for", stage: .config).idleAsked)
        #expect(try !settings.hold("1h", option: "--for", stage: .config).idleAsked)
    }

    @Test func aStaleKeyIsDroppedEverywhere() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        #expect(try c.load(id: "ID", using: true) { _ in false } == nil)
        // An agent may be someone else's word: it is asked to drop, and nothing is taken from it.
        #expect(agents.names.isEmpty)
    }

    @Test func forgettingReachesBothBackends() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try c.store(key(), id: "A", place: "/store", hold: day, typedAgo: 0)
        try keyring.store(key(), id: "B", place: "/store", hold: half, typedAgo: 0)
        #expect(try c.forget(id: "A"))
        #expect(try c.forget(id: "B"))
        #expect(try !c.forget(id: "B"))
        try c.store(key(), id: "A", place: "/store", hold: day, typedAgo: 0)
        try c.store(key(), id: "C", place: "/other", hold: day, typedAgo: 0)
        try c.forget(place: "/store")
        #expect(agents.names == ["xless-vault:C"])
    }

    @Test func whatCouldNotBeForgottenIsSaidOnceEverythingElseIs() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try keyring.store(key(), id: "ID", place: "/store", hold: half, typedAgo: 0)
        agents.unreached = AgentError(.silent, "an agent does not answer", fix: "end it")
        let error = #expect(throws: VaultError.self) { try c.forget(id: "ID") }
        #expect(error?.cause == "an agent does not answer")
        #expect(throws: VaultError.self) { try c.forget(place: "/store") }
        #expect(keyring.names.isEmpty)
    }

    @Test func anAgentThatCannotBeUsedIsReportedOnceAndCountsAsLocked() throws {
        let agents = FakeAgents(), notes = Notes()
        agents.problem = AgentError.versionMismatch(theirs: "9.9.9")
        let c = cache(agents, FakeKeyring(), notes)
        #expect(try c.load(id: "ID", using: true) { _ in true } == nil)
        #expect(try c.load(id: "ID", using: true) { _ in true } == nil)
        #expect(notes.lines.count == 1)
        #expect(notes.lines[0].contains("9.9.9") && notes.lines[0].contains("xless lock"))
    }

    @Test func nothingOfItIsForBuildCode() throws {
        // XLESS_NO_SECRET_STORE=1: what a tool xless runs gets, when it runs xless.
        let agents = FakeAgents(), keyring = FakeKeyring()
        try cache(agents, keyring).store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0)
        let c = HeldKeyCache(agents: agents, keyring: keyring, isOff: true, say: { _ in })
        #expect(!c.isAvailable)
        #expect(try c.load(id: "ID", using: true) { _ in true } == nil)
        #expect(throws: VaultError.self) { try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 0) }
        #expect(c.held(id: "ID") == nil)
    }
}

extension HeldKeyCacheTests {
    @Test func whatMovesToTheAgentTakesTheTimeItWasTypedAlong() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let c = cache(agents, keyring)
        try c.store(key(), id: "ID", place: "/store", hold: day, typedAgo: 3540)
        #expect(agents.typed == [3540])
        #expect(c.held(id: "ID")?.typedAgo == 0) // the agent's word
    }

    @Test func aLoweredMaximumEndsAHoldOfTheKeyring() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        try keyring.store(key(), id: "ID", place: "/store", hold: half, typedAgo: 0)
        let c = HeldKeyCache(agents: agents, keyring: keyring, maximum: 600, say: { _ in })
        keyring.typedAgo = 599
        #expect(try c.load(id: "ID", using: true) { _ in true } != nil)
        keyring.typedAgo = 600
        #expect(c.held(id: "ID") == nil)
        #expect(try c.load(id: "ID", using: true) { _ in true } == nil)
        #expect(keyring.names.isEmpty)
    }
}

@Suite struct HeldSessionStoreTests {
    private func store(_ agents: FakeAgents, _ keyring: FakeKeyring, witness: AgentWitness? = nil, off: Bool = false) -> HeldSessionStore {
        HeldSessionStore(agents: agents, keyring: keyring, isOff: off, witness: { witness }, say: { _ in })
    }

    @Test func aSessionIsHeldByTheAgent() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        let s = store(agents, keyring)
        #expect(s.allowed(day) == day.seconds)
        try s.put("xless-apple-session", key(1), hold: day)
        #expect(agents.names == ["xless-apple-session"])
        #expect(try s.get("xless-apple-session", using: true) == key(1))
        try keyring.put("xless-apple-session", key(3), hold: half)
        try s.put("xless-apple-session", key(2), hold: half)
        #expect(agents.hold("xless-apple-session") == half)
        #expect(keyring.names.isEmpty)
        #expect(try s.get("xless-apple-session", using: true) == key(2)) // replaced, wherever it was
        #expect(try s.revoke("xless-apple-session"))
        #expect(try s.get("xless-apple-session", using: true) == nil)
        #expect(try !s.revoke("xless-apple-session"))
    }

    @Test func whereNoAgentCanRunASessionIsKeptAnHour() throws {
        let agents = FakeAgents()
        agents.obstacle = AgentError(.unavailable, "no session here", fix: "-")
        let notes = Notes(), keyring = FakeKeyring()
        let s = HeldSessionStore(agents: agents, keyring: keyring, isOff: false, witness: { nil }, say: notes.say)
        #expect(s.isAvailable)
        #expect(s.allowed(day) == 3600)
        #expect(!store(agents, FakeKeyring(available: false)).isAvailable)
        try s.put("xless-apple-session", key(1), hold: SecretHold(seconds: 3600, idle: 3600, maximum: 86400))
        try s.put("xless-apple-session-key", key(2), hold: SecretHold(seconds: 3600, idle: 3600, maximum: 86400))
        #expect(keyring.names == ["xless-apple-session", "xless-apple-session-key"])
        #expect(notes.lines.count == 1 && notes.lines[0].contains("without use does not end it"), "\(notes.lines)")
        // An agent that does not start: for what fits, and no longer.
        agents.obstacle = nil
        agents.refuses = true
        try s.put("xless-apple-session", key(4), hold: half)
        #expect(try keyring.get("xless-apple-session", using: true) == key(4))
        #expect(throws: AgentError.self) { try s.put("xless-apple-session", key(5), hold: day) }
        #expect(try keyring.get("xless-apple-session", using: true) == nil)
    }

    @Test func aSessionIsTakenFromAnotherTerminalsAgentOnlyWithTheStoresKey() throws {
        let agents = FakeAgents()
        agents.needsWitness = true
        try store(agents, FakeKeyring()).put("xless-apple-session", key(1), hold: day)
        #expect(try store(agents, FakeKeyring()).get("xless-apple-session", using: true) == nil)
        let witness = AgentWitness(item: "xless-vault:ID", key: key(9))
        #expect(try store(agents, FakeKeyring(), witness: witness).get("xless-apple-session", using: true) == key(1))
    }

    @Test func nothingOfItIsForBuildCode() throws {
        let agents = FakeAgents(), keyring = FakeKeyring()
        try store(agents, keyring).put("xless-apple-session", key(1), hold: day)
        let s = store(agents, keyring, off: true)
        #expect(!s.isAvailable)
        #expect(try s.get("xless-apple-session", using: true) == nil)
        #expect(throws: XlessError.self) { try s.put("xless-apple-session", key(1), hold: day) }
    }
}
