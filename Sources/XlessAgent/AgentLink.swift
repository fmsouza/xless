import CXlessProcess
import Crypto
import Foundation
import XlessCore

/// What an agent says of itself.
public struct AgentStatus: Sendable, Equatable {
    /// Whether it serves this process's session: only then are its items named.
    public let isGranted: Bool
    public let count: Int
    /// The seconds its longest hold has left.
    public let remaining: Int
    /// How many terminal sessions it serves.
    public let sessions: Int
    public let items: [AgentItemStatus]

    public init(isGranted: Bool, count: Int, remaining: Int, sessions: Int, items: [AgentItemStatus]) {
        self.isGranted = isGranted
        self.count = count
        self.remaining = remaining
        self.sessions = sessions
        self.items = items
    }
}

public struct AgentHeld: Sendable {
    public let secret: SecretBytes
    public let status: AgentItemStatus
}

/// One command's connection to one agent. The agent is asked who it is in turn: a secret is sent to it, or an Apple ID
/// session taken from it, only when it is a process of this very session (`isSameSession`), or has shown that it holds
/// the store's key (`prove`): build code that listens in the agents' directory is neither.
final class AgentLink {
    let socket: AgentDirectory.Socket
    var path: String { socket.path }
    private let channel: AgentChannel
    private let timeout: Int
    private let terms: AgentTerms
    private var nonce: [UInt8] = []
    private var id: [UInt8] = []
    private(set) var isGranted = false
    private(set) var isSameSession = false
    private(set) var hasProved = false
    /// It is a session's (`xless session`).
    private(set) var isLease = false

    var isTrusted: Bool { isSameSession || hasProved }

    /// - Parameter timeout: milliseconds for each answer.
    static func connect(path: String, directory: AgentDirectory, terms: AgentTerms = AgentTerms(), timeout: Int = 1500,
                        readPeer: @escaping AgentChannel.PeerReader = AgentChannel.kernelPeer) throws -> AgentLink {
        guard let link = try open([path], directory: directory, terms: terms, timeout: timeout, readPeer: readPeer).links.first else { throw AgentError.gone }
        try link.greet()
        try link.meet(until: link.deadline)
        try link.settle(until: link.deadline)
        return link
    }

    struct Opened {
        var links: [AgentLink] = []
        /// Their queue stays full: nobody takes the connections.
        var busy: [AgentUnanswered] = []
        /// Nobody listens, and they are left there for now.
        var dead: [AgentDirectory.Socket] = []
    }

    /// Connections to those of `paths` where somebody listens.
    static func open(_ paths: [String], directory: AgentDirectory, terms: AgentTerms = AgentTerms(), timeout: Int = 1500,
                     readPeer: @escaping AgentChannel.PeerReader = AgentChannel.kernelPeer) throws -> Opened {
        var out = Opened()
        guard try directory.verify() else { return out }
        var left = paths.compactMap { directory.socket(at: $0) }
        for round in 0..<10 where !left.isEmpty {
            // Refused: nobody listens, or (macOS) too many are waiting; EAGAIN (Linux): too many are waiting. A busy
            // agent takes them in no time.
            if round > 0 { usleep(20_000) }
            left = left.filter { socket in
                let fd = xless_unix_connect(socket.path)
                if fd >= 0, let channel = try? AgentChannel(fd: fd, readPeer: readPeer) {
                    out.links.append(AgentLink(channel: channel, socket: socket, terms: terms, timeout: timeout))
                }
                let refused = fd == -ECONNREFUSED || fd == -EAGAIN
                if refused, round == 9 {
                    if fd == -EAGAIN || mayListen(socket.path) {
                        out.busy.append(AgentUnanswered(pid: 0, path: socket.path))
                    } else if !removeStale(socket, directory) {
                        out.dead.append(socket)
                    }
                }
                return refused
            }
        }
        return out
    }

    /// Whether there may be an agent at `path` although a connection to it was refused: macOS says the same when its queue
    /// is full, so it is for the process that made the socket to have ended.
    private static func mayListen(_ path: String) -> Bool {
        #if os(macOS)
        AgentDirectory.Owner(of: path)?.isRunning ?? true
        #else
        false
        #endif
    }

    private init(channel: AgentChannel, socket: AgentDirectory.Socket, terms: AgentTerms, timeout: Int) {
        self.channel = channel
        self.socket = socket
        self.terms = terms
        self.timeout = timeout
    }

    /// A socket nobody listens on is left by an agent that was killed. One made a moment ago may be about to be listened on.
    /// Whether it was removed.
    private static func removeStale(_ socket: AgentDirectory.Socket, _ directory: AgentDirectory) -> Bool {
        var st = stat()
        guard lstat(socket.path, &st) == 0, time(nil) - Int(modified(st)) > 10, directory.socket(at: socket.path) == socket else { return false }
        return unlink(socket.path) == 0
    }

    private static func modified(_ st: stat) -> time_t {
        #if os(macOS)
        st.st_mtimespec.tv_sec
        #else
        st.st_mtim.tv_sec
        #endif
    }

    // MARK: messages

    private var deadline: Int64 { xless_clock_awake_ms() + Int64(timeout) }

    /// The process that listens at the other end, as far as it is known before it said anything.
    var listener: Int32 { channel.listener }

    private func receive(until deadline: Int64) throws -> AgentMessage {
        guard let message = try channel.wait(limit: AgentLimits.message, until: deadline) else { throw AgentError.silent(listener) }
        if message.header.code == AgentCode.refused.rawValue { throw try Self.refusal(message) }
        guard message.header.version == AgentProtocol.version else { throw AgentError.versionMismatch(theirs: "protocol \(message.header.version)") }
        return message
    }

    private static func refusal(_ message: AgentMessage) throws -> AgentError {
        let (why, text) = try message.body { (try $0.uint8(), try $0.string(max: 1024)) }
        switch AgentRefusal(rawValue: why) {
        case .version: return .versionMismatch(theirs: printable(text))
        case .notGranted:
            return AgentError(.refused, "the xless agent does not serve this terminal session", fix: "run `xless unlock` in it")
        case .limit: return AgentError(.limit, "the xless agent refused what it was sent: \(printable(text))", fix: "run `xless lock`, then `xless unlock`")
        case .malformed, .unavailable, nil: return .malformed(printable(text))
        }
    }

    /// Text of unknown origin, fit for a terminal.
    private static func printable(_ text: String) -> String {
        String(text.unicodeScalars.prefix(200).map { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) ? "?" : Character($0) })
    }

    private func send(_ code: AgentCode, _ body: (inout WireWriter) -> Void = { _ in }) {
        var w = WireWriter()
        body(&w)
        channel.send(w.frame(code: code))
    }

    private func answer(_ expected: AgentCode, until deadline: Int64) throws -> AgentMessage {
        let message = try receive(until: deadline)
        guard message.code == expected else { throw AgentError.malformed("answer \(message.header.code)") }
        return message
    }

    private func request(_ code: AgentCode, _ expected: AgentCode = .ok, _ body: (inout WireWriter) -> Void = { _ in }) throws -> AgentMessage {
        send(code, body)
        return try answer(expected, until: deadline)
    }

    // Each end sends the other something to send back, so each knows that the process the kernel named is there now. In
    // three steps, so that several agents are asked at once.

    private let first = AgentProof.nonce(), second = AgentProof.nonce()
    private var version = ""

    /// Says hello, and waits for nothing.
    func greet() throws {
        send(.hello) {
            $0.put(bytes: first)
            $0.put(XlessVersion.current)
        }
        try channel.flush()
    }

    /// Takes the answer, and sends back what it asks for.
    func meet(until deadline: Int64) throws {
        let echo: [UInt8]
        (echo, nonce, id, version) = try answer(.welcome, until: deadline).body { (try $0.bytes(max: 16), try $0.bytes(max: 16), try $0.bytes(max: 16), try $0.string(max: 64)) }
        guard AgentProof.equal(echo, first) else { throw AgentError.malformed("not the nonce it was given") }
        send(.prove) {
            $0.put(bytes: nonce)
            $0.put(bytes: second)
            terms.write(&$0)
        }
        try channel.flush()
    }

    /// Takes the verdict, and looks at who gave it.
    func settle(until deadline: Int64) throws {
        let echo: [UInt8]
        (echo, isGranted, isLease) = try answer(.verdict, until: deadline).body { (try $0.bytes(max: 16), try $0.bool(), try $0.bool()) }
        guard AgentProof.equal(echo, second) else { throw AgentError.malformed("not the nonce it was given") }
        let peer = try channel.peer()
        let mine = AgentSession.current
        isSameSession = mine.isUsable && peer.session == mine && peer.uid == geteuid()
        if isSameSession, let theirs = peer.executable, let me = AgentExecutable.current, theirs != me {
            throw AgentError.versionMismatch(theirs: printableVersion(version) + ", another program file")
        }
    }

    private func printableVersion(_ text: String) -> String { Self.printable(text) }

    /// For tests: this connection as a command of another terminal sees it.
    func pretendAnotherSession() { isSameSession = false }

    // MARK: requests

    /// What is held as `name`, nil when nothing is. Throws `refused` when the agent does not serve this session.
    func get(_ name: String, using: Bool = true) throws -> AgentHeld? { try fetch(name, nonce: AgentProof.nonce(), using: using)?.held }

    private func fetch(_ name: String, nonce: [UInt8], using: Bool) throws -> (held: AgentHeld, proof: [UInt8])? {
        let answer = try request(.get) {
            $0.put(name)
            $0.put(bytes: nonce)
            $0.put(using)
        }
        _ = try channel.peer() // still the process that was looked at
        return try answer.body { r in
            guard try r.bool() else { return nil }
            let secret = try r.secret(max: AgentLimits.itemBytes)
            let status = AgentItemStatus(name: name, label: try r.string(max: AgentLimits.labelBytes), remaining: try r.int(), idle: try r.int(), idleRemaining: try r.int(), typedAgo: try r.int())
            return (AgentHeld(secret: secret, status: status), try r.bytes(max: 32))
        }
    }

    /// Whether the agent holds `key` as `item`; if so this connection is trusted.
    @discardableResult func prove(has item: String, key: SymmetricKey) throws -> Bool {
        let nonce = AgentProof.nonce()
        guard let (held, proof) = try fetch(item, nonce: nonce, using: false) else { return false }
        held.secret.wipe()
        guard AgentProof.equal(proof, AgentProof.holds(item, key: key, nonce: nonce, agent: id)) else { return false }
        hasProved = true
        return true
    }

    /// Holds `secret`. Only a trusted agent is sent one.
    func put(_ name: String, label: String, _ secret: SecretBytes, hold: SecretHold, typedAgo: Int) throws {
        guard isTrusted else { throw AgentError(.refused, "the xless agent is not one this command can trust", fix: "run `xless lock`, then `xless unlock`") }
        _ = try channel.peer() // still the process that was looked at
        try request(.put) {
            $0.put(name); $0.put(label)
            $0.put(hold.seconds); $0.put(hold.idle); $0.put(hold.maximum)
            $0.put(typedAgo)
            $0.put(secret: secret)
        }.body { _ in }
    }

    @discardableResult func drop(prefix: String, label: String = "") throws -> Int {
        Int(try request(.drop) { $0.put(prefix); $0.put(label) }.body { try $0.uint32() })
    }

    /// Has this session granted by proving that the command has the key held as `item`; whether it was.
    func join(_ item: String, key: SymmetricKey) throws -> Bool {
        do {
            try request(.join) {
                $0.put(item)
                $0.put(bytes: AgentProof.join(item, key: key, session: .current, nonce: nonce, agent: id))
            }.body { _ in }
            isGranted = true
            return true
        } catch let e as AgentError where e.kind == .refused {
            return false
        }
    }

    func status() throws -> AgentStatus? {
        try request(.status).body { r in
            let granted = try r.bool(), count = Int(try r.uint32()), remaining = try r.int(), sessions = Int(try r.uint32())
            let named = Int(try r.uint32())
            guard named <= AgentLimits.items else { throw AgentError.malformed("\(named) items") }
            let items = try (0..<named).map { _ in
                AgentItemStatus(name: try r.string(max: AgentLimits.nameBytes), label: try r.string(max: AgentLimits.labelBytes),
                                remaining: try r.int(), idle: try r.int(), idleRemaining: try r.int(), typedAgo: try r.int())
            }
            return AgentStatus(isGranted: granted, count: count, remaining: remaining, sessions: sessions, items: items)
        }
    }

    /// Asks the agent, of whatever version, to drop everything and end; waits for nothing.
    func askToLock() throws {
        send(.lock)
        try channel.flush()
    }

    /// Whether the agent says it does.
    func locks(until deadline: Int64) throws -> Bool {
        guard let message = try channel.wait(limit: AgentLimits.message, until: deadline) else { throw AgentError.silent(listener) }
        return message.code == .ok
    }

    /// Whether ending `peer` ends the agent that made the socket, and nothing else: the kernel's word on the peer is of
    /// whoever has the pid it kept, so that must be the process `owner` that the socket's name says, still running.
    static func maySafelyEnd(_ peer: xless_peer, owner: AgentDirectory.Owner?, program: AgentExecutable, isRunning: (AgentDirectory.Owner) -> Bool = \.isRunning) -> Bool {
        guard let owner, owner.pid == peer.pid, isRunning(owner) else { return false }
        return peer.uid == geteuid() && peer.pid != getpid() && AgentExecutable(device: peer.exe_device, inode: peer.exe_inode) == program
    }

    /// Ends the process at the other end, which does not answer, when it is the agent that made the socket and the kernel
    /// says that it is this very program run by this user (macOS); whether it did.
    func kill() -> Bool {
        #if os(macOS)
        guard var peer = AgentChannel.kernelPeer(channel.fd), let me = AgentExecutable.current,
              Self.maySafelyEnd(peer, owner: AgentDirectory.Owner(of: path), program: me), xless_peer_kill(&peer) == 0 else { return false }
        var p = pollfd(fd: channel.fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 2000) > 0 // closed with the process
        #else
        // A process that holds secrets keeps its program from its own user's eyes (it is not dumpable).
        return false
        #endif
    }
}
