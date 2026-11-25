import CXlessProcess
import Crypto
import Foundation
import XlessCore

/// Why a request was refused, on the wire.
enum AgentRefusal: UInt8 {
    case version = 1, notGranted = 2, malformed = 3, limit = 4
}

/// Proofs that one has the key held as an item, for one connection only.
enum AgentProof {
    private static func mac(_ key: SymmetricKey, _ purpose: String, _ fields: (inout WireWriter) -> Void) -> [UInt8] {
        var w = WireWriter()
        fields(&w)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("xless-agent/1 \(purpose)".utf8), outputByteCount: 32)
        return w.frame(code: .ok).withUnsafeBytes { Array(HMAC<SHA256>.authenticationCode(for: $0, using: derived)) }
    }

    /// The agent's: that it holds `item`, to whoever sent `nonce`.
    static func holds(_ item: String, key: SymmetricKey, nonce: [UInt8], agent: [UInt8]) -> [UInt8] {
        mac(key, "holds") { $0.put(item); $0.put(bytes: nonce); $0.put(bytes: agent) }
    }

    /// A command's: that its session may use the agent. It names the session, so sent on by another process it grants nothing.
    static func join(_ item: String, key: SymmetricKey, session: AgentSession, nonce: [UInt8], agent: [UInt8]) -> [UInt8] {
        mac(key, "join") {
            $0.put(item); $0.put(bytes: nonce); $0.put(bytes: agent)
            $0.put(Int64(session.id)); $0.put(session.leaderStart)
        }
    }

    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool { SecretBytes(copying: a) == SecretBytes(copying: b) }

    static func nonce() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }
}

/// The agent: one thread, one `poll`. It answers the commands of the sessions it was granted, and ends (everything
/// zeroed) when it holds nothing, serves nobody, is told to lock, or the system sleeps or locks the screen.
///
/// Who may use it: a process of this user, whose POSIX session (by the kernel's word about the process that speaks, see
/// `AgentChannel`) was granted; on macOS running the program the agent runs. The tools xless runs are in sessions of
/// their own (`ChildProcess`), which a process cannot leave for an existing one.
final class AgentServer: @unchecked Sendable {
    typealias PeerCheck = (AgentChannel) throws -> AgentPeer

    enum Exit: Equatable {
        case empty, locked, noSessions, socketGone, slept, screenLocked, stopped
    }

    struct Options {
        /// The program a command must run (macOS); nil: not checked.
        var executable: AgentExecutable?
        var lockOnSleep = true
        var lockOnScreenLock = true
        var screenIsLocked: () -> Bool = { false }
        var isAlive: (AgentSession) -> Bool = { $0.isAlive }
        var tickMilliseconds = 2000
    }

    private final class Connection {
        let channel: AgentChannel
        let deadline: Int64
        let nonce = AgentProof.nonce()
        var proved = false
        var granted = false
        var terms: AgentTerms?
        var requests = 0
        /// Closed as soon as what was said has been sent.
        var ending = false

        init(channel: AgentChannel, deadline: Int64) { self.channel = channel; self.deadline = deadline }
    }

    private let bound: AgentDirectory.Bound
    private let directory: AgentDirectory
    private let state: AgentState
    private let clock: AgentClock
    var options: Options
    var peerCheck: PeerCheck = { try $0.peer() }
    var readPeer: AgentChannel.PeerReader = AgentChannel.kernelPeer
    private let id = AgentProof.nonce()
    private var connections: [Connection] = []
    private var exit: Exit?
    private let stopping = NSLock()
    private var stopped = false
    private var asleep: Int64 = 0
    private var screenWasLocked = false
    private var touched: Int64 = 0

    init(bound: AgentDirectory.Bound, directory: AgentDirectory, state: AgentState, clock: AgentClock, options: Options) {
        self.bound = bound
        self.directory = directory
        self.state = state
        self.clock = clock
        self.options = options
    }

    /// Ends `run` soon, from any thread.
    func stop() { stopping.withLock { stopped = true } }

    private var isStopped: Bool { stopping.withLock { stopped } || AgentSignals.terminated }

    // MARK: the loop

    func run() -> Exit {
        let start = clock.now
        asleep = start.continuous - start.awake
        touched = start.continuous
        screenWasLocked = options.lockOnScreenLock && options.screenIsLocked()
        var nextTick = xless_clock_awake_ms()
        while true {
            if xless_clock_awake_ms() >= nextTick {
                tick()
                nextTick = xless_clock_awake_ms() + Int64(options.tickMilliseconds)
            }
            if exit == nil, isStopped { exit = .stopped }
            if let exit {
                finish()
                return exit
            }
            var polled = [pollfd(fd: bound.fd, events: Int16(POLLIN), revents: 0)]
            polled += connections.map { pollfd(fd: $0.channel.fd, events: Int16(POLLIN) | ($0.channel.hasOutput ? Int16(POLLOUT) : 0), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), Int32(max(1, nextTick - xless_clock_awake_ms())))
            guard ready > 0 else { continue }
            checkTriggers() // a sleep or an expiry between two ticks counts before anything is answered
            guard exit == nil else { continue }
            for (connection, p) in zip(connections, polled.dropFirst()) where p.revents != 0 && exit == nil { serve(connection) }
            connections.removeAll { $0.ending && !$0.channel.hasOutput }
            if polled[0].revents != 0, exit == nil { accept() }
        }
    }

    private func tick() {
        checkTriggers()
        let now = clock.now
        connections.removeAll { now.continuous >= $0.deadline }
        if exit == nil, directory.identity(of: bound.path) != bound.identity { exit = .socketGone }
        if options.lockOnScreenLock {
            let locked = options.screenIsLocked()
            if locked, !screenWasLocked, exit == nil { exit = .screenLocked }
            screenWasLocked = locked
        }
        if now.continuous - touched > 3_600_000 {
            // What cleans temporary directories leaves what is in use alone.
            touched = now.continuous
            utimes(bound.path, nil)
            utimes(directory.path, nil)
        }
    }

    private func checkTriggers() {
        guard exit == nil else { return }
        let now = clock.now
        let slept = now.continuous - now.awake
        if options.lockOnSleep, slept - asleep > 2000 { exit = .slept; return }
        asleep = slept
        state.pruneSessions(options.isAlive)
        if state.sessions == 0 { exit = .noSessions } else if state.isEmpty { exit = .empty }
    }

    private func finish() {
        state.wipe()
        for connection in connections { try? connection.channel.flush() }
        connections = []
        if directory.identity(of: bound.path) == bound.identity { unlink(bound.path) }
        close(bound.fd)
    }

    private func accept() {
        for _ in 0..<AgentLimits.connections {
            let fd = xless_unix_accept(bound.fd)
            guard fd >= 0 else { return }
            guard let channel = try? AgentChannel(fd: fd, readPeer: readPeer) else { continue } // another user's
            if connections.count >= AgentLimits.connections {
                // The oldest one that has shown no right to be here makes room.
                connections.remove(at: connections.firstIndex { !$0.granted } ?? 0)
            }
            connections.append(Connection(channel: channel, deadline: clock.now.continuous + AgentLimits.connectionMilliseconds))
        }
    }

    private func serve(_ c: Connection) {
        do {
            try c.channel.flush()
            while !c.ending, exit == nil {
                // An answer not read yet: nothing more is done for that peer until it is.
                guard !c.channel.hasOutput else { return }
                guard let message = try c.channel.next(limit: c.granted ? AgentLimits.message : AgentLimits.smallMessage) else { return }
                c.requests += 1
                try answer(message, c)
                try c.channel.flush()
                if c.requests >= AgentLimits.requestsPerConnection { c.ending = true }
            }
        } catch let error as AgentError where error.kind != .gone {
            refuse(c, error.kind == .limit ? .limit : .malformed, error.cause)
            try? c.channel.flush()
        } catch {
            connections.removeAll { $0 === c }
        }
    }

    private func refuse(_ c: Connection, _ why: AgentRefusal, _ text: String, end: Bool = true) {
        var w = WireWriter()
        w.put(why.rawValue)
        w.put(text)
        c.channel.send(w.frame(code: .refused))
        if end { c.ending = true }
    }

    // MARK: requests

    private func answer(_ message: AgentMessage, _ c: Connection) throws {
        // Locking is for every process of the user and every version: it could end the agent by a signal anyway.
        if message.header.code == AgentCode.lock.rawValue {
            c.channel.send(WireWriter().frame(code: .ok))
            exit = .locked
            return
        }
        guard message.header.version == AgentProtocol.version else { return refuse(c, .version, XlessVersion.current) }
        switch message.code {
        case .hello: try hello(message, c)
        case .prove: try prove(message, c)
        case .status: try status(message, c)
        case .get: try get(message, c)
        case .put: try put(message, c)
        case .drop: try drop(message, c)
        case .join: try join(message, c)
        default: refuse(c, .malformed, "request \(message.header.code)")
        }
    }

    private func hello(_ message: AgentMessage, _ c: Connection) throws {
        let nonce = try message.body { r in
            let nonce = try r.bytes(max: 16)
            _ = try r.string(max: 64)
            return nonce
        }
        var w = WireWriter()
        w.put(bytes: nonce)
        w.put(bytes: c.nonce)
        w.put(bytes: id)
        w.put(XlessVersion.current)
        c.channel.send(w.frame(code: .welcome))
    }

    private func prove(_ message: AgentMessage, _ c: Connection) throws {
        let (echo, nonce, terms) = try message.body { (try $0.bytes(max: 16), try $0.bytes(max: 16), try AgentTerms(&$0)) }
        guard AgentProof.equal(echo, c.nonce) else { return refuse(c, .malformed, "not the nonce it was given") }
        c.proved = true
        c.terms = terms
        var w = WireWriter()
        w.put(bytes: nonce)
        w.put(isGranted(c))
        if c.granted { keep(to: terms) }
        c.channel.send(w.frame(code: .verdict))
    }

    /// The settings of a command that is served: they tighten what they can, and loosen nothing.
    private func keep(to terms: AgentTerms) {
        state.tighten(maximum: terms.maximum)
        if terms.lockOnSleep { options.lockOnSleep = true }
        if terms.lockOnScreenLock, !options.lockOnScreenLock {
            options.lockOnScreenLock = true
            screenWasLocked = options.screenIsLocked()
        }
    }

    /// The process at the other end, once it has shown it is there now (it answered with what it was sent).
    private func peer(_ c: Connection) -> AgentPeer? {
        guard c.proved, let peer = try? peerCheck(c.channel), peer.uid == geteuid(), peer.session.isUsable else { return nil }
        if let wanted = options.executable, peer.executable != wanted { return nil }
        return peer
    }

    /// Asked again at each request: the peer may have ended, and its session too.
    private func isGranted(_ c: Connection) -> Bool {
        c.granted = peer(c).map { state.isGranted($0.session) } ?? false
        return c.granted
    }

    private func requireGranted(_ c: Connection) -> Bool {
        if isGranted(c) { return true }
        refuse(c, .notGranted, "this process is not of a session the agent serves", end: false)
        return false
    }

    private func status(_ message: AgentMessage, _ c: Connection) throws {
        try message.body { _ in }
        let items = state.statuses()
        let granted = isGranted(c)
        var w = WireWriter()
        w.put(granted)
        w.put(UInt32(items.count))
        w.put(items.map(\.remaining).max() ?? 0)
        w.put(UInt32(state.sessions))
        w.put(UInt32(granted ? items.count : 0))
        for item in items where granted {
            w.put(item.name); w.put(item.label); w.put(item.remaining); w.put(item.idle); w.put(item.idleRemaining); w.put(item.typedAgo)
        }
        c.channel.send(w.frame(code: .ok))
    }

    private func get(_ message: AgentMessage, _ c: Connection) throws {
        let (name, nonce, using) = try message.body { (try $0.string(max: AgentLimits.nameBytes), try $0.bytes(max: 16), try $0.bool()) }
        guard requireGranted(c) else { return }
        var w = WireWriter()
        if let secret = state.get(name, using: using), let status = state.status(of: name) {
            w.put(true)
            w.put(secret: secret)
            w.put(status.label); w.put(status.remaining); w.put(status.idle); w.put(status.idleRemaining); w.put(status.typedAgo)
            w.put(bytes: AgentProof.holds(name, key: secret.withUnsafeBytes { SymmetricKey(data: $0) }, nonce: nonce, agent: id))
        } else {
            w.put(false)
        }
        c.channel.send(w.frame(code: .ok))
    }

    private static func hold(_ r: inout WireReader) throws -> SecretHold {
        SecretHold(seconds: try r.int(), idle: try r.int(), maximum: try r.int())
    }

    private func put(_ message: AgentMessage, _ c: Connection) throws {
        guard requireGranted(c) else { return }
        try message.body { r in
            let name = try r.string(max: AgentLimits.nameBytes), label = try r.string(max: AgentLimits.labelBytes)
            let hold = try Self.hold(&r), typedAgo = try r.int()
            let secret = try r.secret(max: AgentLimits.itemBytes)
            defer { secret.wipe() }
            try state.put(name, label: label, secret, hold: hold, typedAgo: typedAgo)
        }
        c.channel.send(WireWriter().frame(code: .ok))
    }

    /// Also for every process of the user, as `lock` is (`xless secrets lock`, `xless auth logout` from any terminal).
    private func drop(_ message: AgentMessage, _ c: Connection) throws {
        let (prefix, label) = try message.body { (try $0.string(max: AgentLimits.nameBytes), try $0.string(max: AgentLimits.labelBytes)) }
        guard !prefix.isEmpty else { return refuse(c, .malformed, "a drop of nothing") }
        var w = WireWriter()
        w.put(UInt32(state.drop(prefix: prefix, label: label)))
        c.channel.send(w.frame(code: .ok))
    }

    /// Another session (a second terminal) whose command has the key held as an item: its person typed the passphrase.
    private func join(_ message: AgentMessage, _ c: Connection) throws {
        let (name, proof) = try message.body { (try $0.string(max: AgentLimits.nameBytes), try $0.bytes(max: 32)) }
        state.dropExpired()
        guard let peer = peer(c), let key = state.heldBytes(name)?.withUnsafeBytes({ SymmetricKey(data: $0) }),
              AgentProof.equal(proof, AgentProof.join(name, key: key, session: peer.session, nonce: c.nonce, agent: id)) else {
            return refuse(c, .notGranted, "this process did not show that it has the key", end: false)
        }
        state.grant(peer.session)
        if isGranted(c), let terms = c.terms { keep(to: terms) }
        c.channel.send(WireWriter().frame(code: .ok))
    }
}

/// SIGTERM ends the agent as `lock` does.
enum AgentSignals {
    nonisolated(unsafe) private static var flag: sig_atomic_t = 0

    static var terminated: Bool { flag != 0 }

    static func install() { signal(SIGTERM) { _ in AgentSignals.flag = 1 } }
}
