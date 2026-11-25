import Crypto
import Foundation
import XlessCore

/// What shows that a command and an agent have the same store's key.
public struct AgentWitness: Sendable {
    /// The item an agent holds it as.
    public let item: String
    public let key: SecretBytes

    public init(item: String, key: SecretBytes) { self.item = item; self.key = key }

    var symmetric: SymmetricKey { key.withUnsafeBytes { SymmetricKey(data: $0) } }
}

/// A command's side of the agents: every one of the user's in the directory is looked at, what one says is taken only
/// when it may be believed, and what cannot be used counts as not held (`problem` says why).
public final class AgentClient: @unchecked Sendable {
    private let directory: AgentDirectory
    private let locking: AgentLocking
    private let findObstacle: @Sendable () -> AgentError?
    private let startAgent: @Sendable ([AgentSeed], AgentDirectory) throws -> Void
    private let lock = NSLock()
    private var lastProblem: AgentError?
    /// For tests: no agent here is of this session.
    var seesEveryAgentAsAnotherSessions = false

    public convenience init(directory: AgentDirectory = AgentDirectory(), locking: AgentLocking = AgentLocking()) {
        self.init(directory: directory, locking: locking, obstacle: { AgentLauncher.obstacle() }) { seeds, directory in
            try AgentLauncher.start(seeds, directory: directory, locking: locking)
        }
    }

    init(directory: AgentDirectory, locking: AgentLocking = AgentLocking(), obstacle: @escaping @Sendable () -> AgentError?,
         start: @escaping @Sendable ([AgentSeed], AgentDirectory) throws -> Void) {
        self.directory = directory
        self.locking = locking
        findObstacle = obstacle
        startAgent = start
    }

    /// Why no agent can be started here; nil when one can.
    public var obstacle: AgentError? { findObstacle() }

    /// Why an agent that is there could not be used, the last time one was looked for.
    public var problem: AgentError? { lock.withLock { lastProblem } }

    private func links() -> [AgentLink] {
        var problem: AgentError?
        var links: [AgentLink] = []
        do {
            for path in try directory.sockets() {
                do {
                    let link = try AgentLink.connect(path: path, directory: directory)
                    if seesEveryAgentAsAnotherSessions { link.pretendAnotherSession() }
                    links.append(link)
                } catch let e as AgentError where e.kind == .version || e.kind == .unsafePath {
                    problem = e
                } catch {} // gone, or not an agent
            }
        } catch {
            problem = error as? AgentError
        }
        lock.withLock { lastProblem = problem }
        return links.sorted { $0.isSameSession && !$1.isSameSession }
    }

    /// What is held as `name`, when `accept` recognises it (a store's key opens the store: nobody else can make one up).
    public func get(_ name: String, accept: (SecretBytes) -> Bool) -> SecretBytes? {
        for link in links() where link.isGranted {
            if let held = try? link.get(name) {
                if accept(held.secret) { return held.secret }
                held.secret.wipe()
            }
        }
        return nil
    }

    /// What is held as `name` by an agent that can be believed: one of this session, or one that shows it has the key of
    /// `witness`. That key also has this session granted by an agent that did not know it yet.
    public func get(_ name: String, witness: () -> AgentWitness?) -> SecretBytes? {
        let links = links()
        for link in links where link.isGranted && link.isSameSession {
            if let held = try? link.get(name) { return held.secret }
        }
        let others = links.filter { !($0.isGranted && $0.isSameSession) }
        guard !others.isEmpty, let witness = witness() else { return nil }
        for link in others where trusted(link, witness) {
            if let held = try? link.get(name) { return held.secret }
        }
        return nil
    }

    /// Whether `link` grants this session (having it granted if need be) and has the witness's key.
    private func trusted(_ link: AgentLink, _ witness: AgentWitness) -> Bool {
        if !link.isGranted, (try? link.join(witness.item, key: witness.symmetric, hold: nil)) != true { return false }
        return (try? link.prove(has: witness.item, key: witness.symmetric)) == true
    }

    /// Holds `seeds`, in an agent of this session, else one that has the witness's key, else a new one.
    public func put(_ seeds: [AgentSeed], typed: Bool, witness: () -> AgentWitness? = { nil }) throws {
        let links = links()
        if let problem, problem.kind == .unsafePath { throw problem }
        if let link = links.first(where: { $0.isGranted && $0.isSameSession }) ?? links.first(where: { link in witness().map { trusted(link, $0) } ?? false }) {
            for seed in seeds { try link.put(seed.name, label: seed.label, seed.secret, hold: seed.hold, typed: typed) }
            return
        }
        if let obstacle { throw obstacle }
        try startAgent(seeds, directory)
    }

    /// Has this session granted by every agent that holds the witness's key, for at least as long as `hold` (nil: as it
    /// is); whether one did.
    public func join(_ witness: AgentWitness, hold: AgentHold?) -> Bool {
        var any = false
        for link in links() where !link.isGranted {
            if (try? link.join(witness.item, key: witness.symmetric, hold: hold)) == true { any = true }
        }
        return any
    }

    /// Drops what is held under names that start with `prefix`, in every agent; how many.
    @discardableResult public func drop(prefix: String) -> Int { links().reduce(0) { $0 + ((try? $1.drop(prefix: prefix)) ?? 0) } }

    /// Tells every agent, whatever its version, to drop everything and end; how many did.
    @discardableResult public func lockAll() throws -> Int {
        try directory.sockets().count { (try? AgentLink.lock(path: $0, directory: directory)) == true }
    }

    public func statuses() -> [AgentStatus] { links().compactMap { try? $0.status() } }
}
