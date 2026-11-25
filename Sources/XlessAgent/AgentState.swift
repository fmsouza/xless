import Foundation
import XlessCore

/// What an agent holds, for how long, and for whom. Synchronised: tests look at it while the agent's thread uses it.
final class AgentState: @unchecked Sendable {
    private struct Item {
        let name: String
        let label: String
        let secret: SecretPages
        let typed: AgentDeadline
        /// The end of the longest hold, counted from `typed`.
        var cap: AgentDeadline
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

    /// Holds `secret` as `name`.
    /// - Parameter typedAgo: the seconds since the person typed it, from where its longest hold counts; 0 when they just
    ///   did. A secret renewed later keeps the earliest time known and the shortest longest hold it was given.
    func put(_ name: String, label: String, _ secret: SecretBytes, hold: SecretHold, typedAgo: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !name.isEmpty, name.utf8.count <= AgentLimits.nameBytes else { throw AgentError.limit("that name") }
        guard label.utf8.count <= AgentLimits.labelBytes else { throw AgentError.limit("a label that long") }
        guard secret.count <= AgentLimits.itemBytes else { throw AgentError.limit("more than \(AgentLimits.itemBytes) bytes at once") }
        guard hold.seconds > 0, hold.idle > 0, hold.maximum > 0 else { throw AgentError.limit("a time of 0") }
        guard typedAgo >= 0, typedAgo < min(hold.maximum, AgentLimits.seconds) else { throw AgentError.limit("what was typed too long ago") }
        dropExpired()
        let now = clock.now
        let seconds = min(hold.seconds, AgentLimits.seconds), idle = min(hold.idle, AgentLimits.seconds)
        let old = items[name]
        let same = old.map { SecretPages.same($0.secret, secret) } ?? false
        let renews = same && typedAgo > 0
        if !label.isEmpty {
            // Another secret for the same place: the store was replaced, so its old key opens nothing any more.
            for (other, item) in items where other != name && item.label == label {
                item.secret.wipe()
                items[other] = nil
            }
        }
        guard items[name] != nil || items.count < AgentLimits.items else { throw AgentError.limit("more than \(AgentLimits.items) secrets") }
        var origin = AgentDeadline(now, in: -typedAgo)
        if renews { origin = .earlier(origin, old!.typed) }
        var cap = origin.later(by: min(hold.maximum, AgentLimits.seconds))
        if renews { cap = .earlier(cap, old!.cap) }
        items[name] = Item(name: name, label: label, secret: same ? old!.secret : SecretPages(secret), typed: origin, cap: cap,
                           expires: .earlier(AgentDeadline(now, in: seconds), cap), idle: idle, idleEnds: AgentDeadline(now, in: idle))
    }

    /// The secret held as `name`; using it (not only looking at it) starts its idle time again.
    func get(_ name: String, using: Bool = true) -> SecretPages? {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        guard var item = items[name] else { return nil }
        if using {
            item.idleEnds = AgentDeadline(clock.now, in: item.idle)
            items[name] = item
        }
        return item.secret
    }

    /// A maximum a command was given since: nothing is held longer than that after it was typed.
    func tighten(maximum: Int) {
        lock.lock()
        defer { lock.unlock() }
        for name in items.keys {
            let cap = AgentDeadline.earlier(items[name]!.cap, items[name]!.typed.later(by: max(0, min(maximum, AgentLimits.seconds))))
            items[name]!.cap = cap
            items[name]!.expires = .earlier(items[name]!.expires, cap)
        }
    }

    /// Without using it.
    func heldBytes(_ name: String) -> SecretPages? { lock.withLock { items[name]?.secret } }

    /// Drops every item whose name starts with `prefix` (and is for `label`, unless it is empty); how many.
    @discardableResult func drop(prefix: String, label: String = "") -> Int {
        lock.lock()
        defer { lock.unlock() }
        dropExpired()
        let names = items.filter { $0.key.hasPrefix(prefix) && (label.isEmpty || $0.value.label == label) }.keys
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
                            idleRemaining: min($0.idleEnds.remaining(now), $0.expires.remaining(now)), typedAgo: $0.typed.age(now))
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
