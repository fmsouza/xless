import Foundation
import XlessCore

/// How long something is held.
public struct AgentHold: Sendable, Equatable {
    /// From now.
    public var seconds: Int
    /// Dropped after this long without being used.
    public var idle: Int
    /// The longest it may be held, renewals included, since the secret was last typed.
    public var maximum: Int

    public init(seconds: Int, idle: Int, maximum: Int) {
        self.seconds = seconds; self.idle = idle; self.maximum = maximum
    }
}

/// A POSIX session, told apart from a later one with the same number by when its leader started.
public struct AgentSession: Sendable, Hashable {
    public let id: Int32
    public let leaderStart: UInt64

    public init(id: Int32, leaderStart: UInt64) { self.id = id; self.leaderStart = leaderStart }

    /// Whether it can be granted: it has a number in this PID namespace, and its leader runs.
    public var isUsable: Bool { id > 0 && leaderStart != 0 }
}

public struct AgentItemStatus: Sendable, Equatable {
    public let name: String
    /// What it is for (the store's path), or empty.
    public let label: String
    /// Seconds until it is dropped whatever happens.
    public let remaining: Int
    public let idle: Int
    /// Seconds until it is dropped when nobody uses it.
    public let idleRemaining: Int

    public init(name: String, label: String, remaining: Int, idle: Int, idleRemaining: Int) {
        self.name = name; self.label = label; self.remaining = remaining; self.idle = idle; self.idleRemaining = idleRemaining
    }
}

/// What an agent holds, for how long, and for whom. Synchronised: tests look at it while the agent's thread uses it.
final class AgentState: @unchecked Sendable {
    private struct Item {
        let name: String
        let label: String
        let secret: SecretPages
        /// The end of the longest hold since the secret was typed.
        let cap: AgentDeadline
        var expires: AgentDeadline
        var idle: Int
        var idleEnds: AgentDeadline
    }

    private var items: [String: Item] = [:]
    private var granted: Set<AgentSession> = []
    private let clock: AgentClock
    private let lock = NSRecursiveLock()

    init(clock: AgentClock) { self.clock = clock }

    // MARK: items

    /// Holds `secret` as `name`. `typed`: the person just gave it, so its longest hold starts again; else the same
    /// secret is renewed within the longest hold it already has.
    func put(_ name: String, label: String, _ secret: SecretBytes, hold: AgentHold, typed: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !name.isEmpty, name.utf8.count <= AgentLimits.nameBytes else { throw AgentError.limit("that name") }
        guard label.utf8.count <= AgentLimits.labelBytes else { throw AgentError.limit("a label that long") }
        guard secret.count <= AgentLimits.itemBytes else { throw AgentError.limit("more than \(AgentLimits.itemBytes) bytes at once") }
        guard hold.seconds > 0, hold.idle > 0, hold.maximum > 0 else { throw AgentError.limit("a time of 0") }
        dropExpired()
        let now = clock.now
        let seconds = min(hold.seconds, AgentLimits.seconds), idle = min(hold.idle, AgentLimits.seconds)
        let old = items[name]
        let renews = !typed && (old.map { SecretPages.same($0.secret, secret) } ?? false)
        if !label.isEmpty {
            // Another secret for the same place: the store was replaced, so its old key opens nothing any more.
            for (other, item) in items where other != name && item.label == label {
                item.secret.wipe()
                items[other] = nil
            }
        }
        guard items[name] != nil || items.count < AgentLimits.items else { throw AgentError.limit("more than \(AgentLimits.items) secrets") }
        let cap = renews ? old!.cap : AgentDeadline(now, in: min(hold.maximum, AgentLimits.seconds))
        items[name] = Item(name: name, label: label, secret: renews ? old!.secret : SecretPages(secret), cap: cap,
                           expires: .earlier(AgentDeadline(now, in: seconds), cap), idle: idle, idleEnds: AgentDeadline(now, in: idle))
    }

    /// The secret held as `name`; using it starts its idle time again.
    func get(_ name: String) -> SecretPages? {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        guard var item = items[name] else { return nil }
        item.idleEnds = AgentDeadline(clock.now, in: item.idle)
        items[name] = item
        return item.secret
    }

    /// Without using it.
    func heldBytes(_ name: String) -> SecretPages? { lock.withLock { items[name]?.secret } }

    /// The person typed what proves they may have `name`: its longest hold starts again, and it lasts at least as long
    /// as it did.
    func renew(_ name: String, hold: AgentHold) {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        guard let item = items[name], hold.seconds > 0, hold.idle > 0, hold.maximum > 0 else { return }
        let now = clock.now
        let cap = AgentDeadline(now, in: min(hold.maximum, AgentLimits.seconds))
        let seconds = min(max(hold.seconds, item.expires.remaining(now)), AgentLimits.seconds)
        items[name] = Item(name: name, label: item.label, secret: item.secret, cap: cap,
                           expires: .earlier(AgentDeadline(now, in: seconds), cap), idle: min(hold.idle, AgentLimits.seconds),
                           idleEnds: AgentDeadline(now, in: min(hold.idle, AgentLimits.seconds)))
    }

    /// Drops every item whose name starts with `prefix`; how many.
    @discardableResult func drop(prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        let names = items.keys.filter { $0.hasPrefix(prefix) }
        for name in names { items.removeValue(forKey: name)?.secret.wipe() }
        return names.count
    }

    /// Drops everything now, its bytes zeroed.
    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        for item in items.values { item.secret.wipe() }
        items = [:]
        granted = []
    }

    func dropExpired() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        for (name, item) in items where item.expires.passed(now) || item.idleEnds.passed(now) {
            item.secret.wipe()
            items[name] = nil
        }
    }

    var isEmpty: Bool { lock.withLock { dropExpired(); return items.isEmpty } }

    func statuses() -> [AgentItemStatus] {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        let now = clock.now
        return items.values.sorted { $0.name < $1.name }.map {
            AgentItemStatus(name: $0.name, label: $0.label, remaining: $0.expires.remaining(now), idle: $0.idle,
                            idleRemaining: min($0.idleEnds.remaining(now), $0.expires.remaining(now)))
        }
    }

    func status(of name: String) -> AgentItemStatus? { statuses().first { $0.name == name } }

    // MARK: who

    /// Serves `session` from now on, up to the limit.
    func grant(_ session: AgentSession) {
        lock.lock()
        defer { lock.unlock() }
        guard session.isUsable, granted.count < AgentLimits.sessions else { return }
        granted.insert(session)
    }

    func isGranted(_ session: AgentSession) -> Bool { lock.withLock { session.isUsable && granted.contains(session) } }

    /// Stops serving the sessions that are over.
    func pruneSessions(_ isAlive: (AgentSession) -> Bool) { lock.withLock { granted = granted.filter(isAlive) } }

    var sessions: Int { lock.withLock { granted.count } }
}
