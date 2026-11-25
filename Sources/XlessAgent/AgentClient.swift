import CXlessProcess
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

/// An agent that is there and did not do as it was asked.
public struct AgentUnanswered: Sendable, Equatable {
    /// 0: not known.
    public let pid: Int32
    public let path: String

    public init(pid: Int32, path: String) { self.pid = pid; self.path = path }

    /// Nobody takes connections there: the process its name says, when that one runs (here: a container may have
    /// another's directory, and other pids).
    init(busy path: String) { self.init(pid: AgentDirectory.Owner(of: path).flatMap { $0.isRunning ? $0.pid : nil } ?? 0, path: path) }

    public var cause: String { "an xless agent (\(pid > 0 ? "process \(pid), " : "")\(path)) does not answer: what it holds may still be held" }
    public var fix: String {
        // By the time it is read the process may have ended, and its pid be another one's.
        let end = pid > 0 ? "if `ps -p \(pid) -o args=` still says `xless __agent`, end it (`kill -9 \(pid)`)" : "end every agent of yours (`pkill -9 -f 'xless __agent'`)"
        return "\(end), then run `xless lock`"
    }
}

/// What a drop came to.
public struct AgentDropped: Sendable, Equatable {
    public let count: Int
    /// Why not every agent could be told; nil: every one was.
    public let unreached: AgentError?

    public init(count: Int, unreached: AgentError?) { self.count = count; self.unreached = unreached }
}

/// What `lockAll` came to.
public struct AgentLocked: Sendable, Equatable {
    public let ended: Int
    public let unanswered: [AgentUnanswered]

    public init(ended: Int, unanswered: [AgentUnanswered]) { self.ended = ended; self.unanswered = unanswered }
}

/// A command's side of the agents: every one of the user's in the directory is looked at, what one says is taken only
/// when it may be believed, and what cannot be used counts as not held (`problem` says why).
public final class AgentClient: @unchecked Sendable {
    private let directory: AgentDirectory
    private let terms: AgentTerms
    /// The socket of the session's agent (`xless session`) this command runs in.
    private let session: String?
    private let findObstacle: @Sendable () -> AgentError?
    private let startAgent: @Sendable ([AgentSeed], AgentDirectory) throws -> Void
    private let lock = NSLock()
    private var lastProblem: AgentError?
    /// The sockets that did not answer this process, and who listens: they are not waited for again.
    private var silent: [AgentDirectory.Socket: Int32] = [:]
    /// Where nobody listened.
    private var dead: Set<AgentDirectory.Socket> = []
    private let timeout: Int
    /// For tests: no agent here is of this session.
    var seesEveryAgentAsAnotherSessions = false

    /// - Parameters:
    ///   - session: the socket of the agent of the `xless session` this command runs in: the only agent on a lease it
    ///     uses, and where what it keeps goes.
    ///   - timeout: milliseconds for the answers to one question, however many agents there are.
    public convenience init(directory: AgentDirectory = AgentDirectory(), terms: AgentTerms = AgentTerms(), session: String? = nil, timeout: Int = 1500) {
        self.init(directory: directory, terms: terms, session: session, timeout: timeout, obstacle: { AgentLauncher.obstacle() }) { seeds, directory in
            try AgentLauncher.start(seeds, directory: directory, terms: terms)
        }
    }

    init(directory: AgentDirectory, terms: AgentTerms = AgentTerms(), session: String? = nil, timeout: Int = 1500, obstacle: @escaping @Sendable () -> AgentError?,
         start: @escaping @Sendable ([AgentSeed], AgentDirectory) throws -> Void) {
        self.directory = directory
        self.terms = terms
        self.session = session
        self.timeout = timeout
        findObstacle = obstacle
        startAgent = start
    }

    /// Why no agent can be started here; nil when one can, as far as that can be told before one is.
    public var obstacle: AgentError? { findObstacle() ?? directory.obstacle() }

    /// Why an agent that is there could not be used, the last time one was looked for.
    public var problem: AgentError? { lock.withLock { lastProblem } }

    private var deadline: Int64 { xless_clock_awake_ms() + Int64(timeout) }

    /// Connections to the agents this command uses: another session's is not one.
    private func links() -> [AgentLink] {
        let (links, problem) = links { try directory.sockets() }
        lock.withLock { lastProblem = problem }
        return links.filter { !$0.isLease || isMySession($0) }
    }

    private func isMySession(_ link: AgentLink) -> Bool {
        guard let session, link.isLease else { return false }
        return link.path == session || directory.identity(of: session) == link.socket.identity
    }

    /// Connections to the agents at `paths`, which are all asked at once; and why one that is there could not be used.
    private func links(_ paths: () throws -> [String]) -> ([AgentLink], AgentError?) {
        var problem: AgentError?
        var links: [AgentLink] = []
        func each(_ step: (AgentLink) throws -> Void) {
            links = links.filter { link in
                do {
                    try step(link)
                    return true
                } catch let e as AgentError {
                    switch e.kind {
                    case .version, .unsafePath: problem = e
                    case .silent: lock.withLock { silent[link.socket] = link.listener }
                    default: break // gone, or not an agent
                    }
                } catch {}
                return false
            }
        }
        do {
            let skipped = lock.withLock { dead.union(silent.keys) }
            let paths = try paths().filter { path in directory.socket(at: path).map { !skipped.contains($0) } ?? false }
            let opened = try AgentLink.open(paths, directory: directory, terms: terms, timeout: timeout)
            links = opened.links
            lock.withLock {
                dead.formUnion(opened.dead)
                for busy in opened.busy { if let socket = directory.socket(at: busy.path) { silent[socket] = busy.pid } }
            }
            each { try $0.greet() }
            let welcome = deadline
            each { try $0.meet(until: welcome) }
            let verdict = deadline
            each { try $0.settle(until: verdict) }
            if seesEveryAgentAsAnotherSessions { links.forEach { $0.pretendAnotherSession() } }
        } catch {
            problem = error as? AgentError
        }
        return (links.sorted { $0.isSameSession && !$1.isSameSession }, problem ?? lock.withLock { silent.values.min() }.map { .silent($0) })
    }

    /// Every socket there is, some at a time: however many there are, each gets a connection.
    private func batches() throws -> [[String]] {
        let all = try directory.sockets(limit: .max)
        return stride(from: 0, to: all.count, by: AgentLimits.sockets).map { Array(all[$0..<min($0 + AgentLimits.sockets, all.count)]) }
    }

    /// What is held as `name`, when `accept` recognises it (a store's key opens the store: nobody else can make one up).
    public func get(_ name: String, using: Bool = true, accept: (SecretBytes) -> Bool) -> SecretBytes? {
        for link in links() where link.isGranted {
            if let held = try? link.get(name, using: using) {
                if accept(held.secret) { return held.secret }
                held.secret.wipe()
            }
        }
        return nil
    }

    /// What is held as `name` by an agent that can be believed: one of this session, or one that shows it has the key of
    /// `witness`. That key also has this session granted by an agent that did not know it yet.
    public func get(_ name: String, using: Bool = true, witness: () -> AgentWitness?) -> SecretBytes? {
        let links = links()
        for link in links where link.isGranted && link.isSameSession {
            if let held = try? link.get(name, using: using) { return held.secret }
        }
        let others = links.filter { !($0.isGranted && $0.isSameSession) }
        guard !others.isEmpty, let witness = witness() else { return nil }
        for link in others where trusted(link, witness) {
            if let held = try? link.get(name, using: using) { return held.secret }
        }
        return nil
    }

    /// Whether `link` grants this session (having it granted if need be) and has the witness's key.
    private func trusted(_ link: AgentLink, _ witness: AgentWitness) -> Bool {
        if !link.isGranted, (try? link.join(witness.item, key: witness.symmetric)) != true { return false }
        return (try? link.prove(has: witness.item, key: witness.symmetric)) == true
    }

    /// Holds `seeds`: in the agent of the `xless session` this runs in; with none, in an agent of this terminal's session,
    /// else one that has the witness's key, else a new one.
    public func put(_ seeds: [AgentSeed], witness: () -> AgentWitness? = { nil }) throws {
        let links = links()
        if let problem, problem.kind == .unsafePath { throw problem }
        if session != nil {
            guard let link = links.first(where: { isMySession($0) && $0.isGranted && $0.isSameSession }) else {
                throw AgentError(.refused, "the `xless session` this runs in holds nothing any more (it ended, the system slept, or the screen was locked)",
                                 fix: "start it again")
            }
            for seed in seeds { try link.put(seed.name, label: seed.label, seed.secret, hold: seed.hold, typedAgo: seed.typedAgo) }
            return
        }
        if let link = links.first(where: { $0.isGranted && $0.isSameSession }) ?? links.first(where: { link in witness().map { trusted(link, $0) } ?? false }) {
            do {
                for seed in seeds { try link.put(seed.name, label: seed.label, seed.secret, hold: seed.hold, typedAgo: seed.typedAgo) }
                return
            } catch let e as AgentError where e.kind == .gone {} // it ended meanwhile: a new one
        }
        if let obstacle { throw obstacle }
        try startAgent(seeds, directory)
    }

    /// Drops what is held under names that start with `prefix` (for `label` only, unless it is empty), in every agent.
    @discardableResult public func drop(prefix: String, label: String = "") -> AgentDropped {
        var failure: AgentError?
        var count = 0
        do {
            for paths in try batches() {
                let (links, problem) = links { paths }
                failure = failure ?? problem
                for link in links {
                    do { count += try link.drop(prefix: prefix, label: label) } catch let e as AgentError where e.kind != .gone { failure = failure ?? e } catch {}
                }
            }
        } catch {
            failure = error as? AgentError
        }
        return AgentDropped(count: count, unreached: failure)
    }

    /// Tells every agent, whatever its version, to drop everything and end. One that does not answer is ended where that
    /// is safe, else reported.
    public func lockAll() throws -> AgentLocked {
        var ended = 0
        var unanswered: [AgentUnanswered] = []
        for paths in try batches() {
            let opened = try AgentLink.open(paths, directory: directory, timeout: timeout)
            unanswered += opened.busy
            for link in opened.links { try? link.askToLock() }
            let end = deadline
            for link in opened.links {
                switch locking(link, until: end) {
                case .ended: ended += 1
                case .gone: break
                case .unanswered: unanswered.append(AgentUnanswered(pid: link.listener, path: link.path))
                }
            }
        }
        return AgentLocked(ended: ended, unanswered: unanswered)
    }

    private enum Locking { case ended, gone, unanswered }

    private func locking(_ link: AgentLink, until end: Int64) -> Locking {
        do {
            return try link.locks(until: end) ? .ended : .unanswered
        } catch let e as AgentError where e.kind == .silent {
            guard link.kill() else { return .unanswered }
            if directory.socket(at: link.path) == link.socket { unlink(link.path) }
            return .ended
        } catch {
            // It closed: it has ended, unless somebody still listens there.
            let again = try? AgentLink.open([link.path], directory: directory, timeout: timeout)
            return again.map { $0.links.isEmpty && $0.busy.isEmpty } ?? true ? .gone : .unanswered
        }
    }

    /// Why no lease can be started here.
    public var leaseObstacle: AgentError? { AgentLauncher.obstacle(lease: true) ?? directory.obstacle() }

    /// Starts an agent for this process alone to keep: it ends with it, or with `end()`.
    public func lease(_ seeds: [AgentSeed]) throws -> AgentLease {
        try AgentLauncher.lease(seeds, directory: directory, terms: terms)
    }

    /// Whether the agent of the `xless session` this runs in is there, and serves this process.
    public var isInSession: Bool { links().contains { isMySession($0) && $0.isGranted && $0.isSameSession } }

    public func statuses() -> [AgentStatus] { links().compactMap { try? $0.status() } }
}
