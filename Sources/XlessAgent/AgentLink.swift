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
    private let channel: AgentChannel
    private let timeout: Int
    private var nonce: [UInt8] = []
    private var id: [UInt8] = []
    private(set) var isGranted = false
    private(set) var isSameSession = false
    private(set) var hasProved = false

    var isTrusted: Bool { isSameSession || hasProved }

    /// - Parameter timeout: milliseconds for each answer.
    static func connect(path: String, directory: AgentDirectory, timeout: Int = 1500,
                        readPeer: @escaping AgentChannel.PeerReader = AgentChannel.kernelPeer) throws -> AgentLink {
        let link = try AgentLink(path: path, directory: directory, timeout: timeout, readPeer: readPeer)
        try link.handshake()
        return link
    }

    private init(path: String, directory: AgentDirectory, timeout: Int, readPeer: @escaping AgentChannel.PeerReader = AgentChannel.kernelPeer) throws {
        guard try directory.verify(), let identity = directory.identity(of: path) else { throw AgentError.gone }
        // Refused: nobody listens, or (macOS) too many are waiting. A busy agent takes them in no time.
        var fd = xless_unix_connect(path)
        for _ in 0..<10 where fd == -ECONNREFUSED || fd == -EAGAIN {
            usleep(20_000)
            fd = xless_unix_connect(path)
        }
        if fd == -ECONNREFUSED { Self.removeStale(path, identity, directory) }
        guard fd >= 0 else { throw AgentError.gone }
        channel = try AgentChannel(fd: fd, readPeer: readPeer)
        self.timeout = timeout
    }

    /// A socket nobody listens on is left by an agent that was killed. One made a moment ago may be about to be listened on.
    private static func removeStale(_ path: String, _ identity: AgentDirectory.Identity, _ directory: AgentDirectory) {
        var st = stat()
        guard lstat(path, &st) == 0, time(nil) - Int(modified(st)) > 10, directory.identity(of: path) == identity else { return }
        unlink(path)
    }

    private static func modified(_ st: stat) -> time_t {
        #if os(macOS)
        st.st_mtimespec.tv_sec
        #else
        st.st_mtim.tv_sec
        #endif
    }

    // MARK: messages

    private func receive() throws -> AgentMessage {
        guard let message = try channel.wait(limit: AgentLimits.message, milliseconds: timeout) else { throw AgentError.gone }
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
        case .malformed, nil: return .malformed(printable(text))
        }
    }

    /// Text of unknown origin, fit for a terminal.
    private static func printable(_ text: String) -> String {
        String(text.unicodeScalars.prefix(200).map { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) ? "?" : Character($0) })
    }

    private func request(_ code: AgentCode, _ expected: AgentCode = .ok, _ body: (inout WireWriter) -> Void = { _ in }) throws -> AgentMessage {
        var w = WireWriter()
        body(&w)
        channel.send(w.frame(code: code))
        let message = try receive()
        guard message.code == expected else { throw AgentError.malformed("answer \(message.header.code)") }
        return message
    }

    /// Each end sends the other something to send back, so each knows that the process the kernel named is there now.
    private func handshake() throws {
        let first = AgentProof.nonce(), second = AgentProof.nonce()
        let welcome = try request(.hello, .welcome) {
            $0.put(bytes: first)
            $0.put(XlessVersion.current)
        }
        let echo: [UInt8]
        let version: String
        (echo, nonce, id, version) = try welcome.body { (try $0.bytes(max: 16), try $0.bytes(max: 16), try $0.bytes(max: 16), try $0.string(max: 64)) }
        guard AgentProof.equal(echo, first) else { throw AgentError.malformed("not the nonce it was given") }
        let verdict = try request(.prove, .verdict) {
            $0.put(bytes: nonce)
            $0.put(bytes: second)
        }
        let answer: [UInt8]
        (answer, isGranted) = try verdict.body { (try $0.bytes(max: 16), try $0.bool()) }
        guard AgentProof.equal(answer, second) else { throw AgentError.malformed("not the nonce it was given") }
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
            let status = AgentItemStatus(name: name, label: try r.string(max: AgentLimits.labelBytes), remaining: try r.int(), idle: try r.int(), idleRemaining: try r.int())
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
    func put(_ name: String, label: String, _ secret: SecretBytes, hold: SecretHold, typed: Bool) throws {
        guard isTrusted else { throw AgentError(.refused, "the xless agent is not one this command can trust", fix: "run `xless lock`, then `xless unlock`") }
        _ = try channel.peer() // still the process that was looked at
        try request(.put) {
            $0.put(name); $0.put(label)
            $0.put(hold.seconds); $0.put(hold.idle); $0.put(hold.maximum)
            $0.put(typed)
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
                                remaining: try r.int(), idle: try r.int(), idleRemaining: try r.int())
            }
            return AgentStatus(isGranted: granted, count: count, remaining: remaining, sessions: sessions, items: items)
        }
    }

    /// Tells the agent at `path`, of whatever version, to drop everything and end; whether one answered.
    static func lock(path: String, directory: AgentDirectory, timeout: Int = 1500) throws -> Bool {
        let link = try AgentLink(path: path, directory: directory, timeout: timeout)
        link.channel.send(WireWriter().frame(code: .lock))
        return try link.channel.wait(limit: AgentLimits.message, milliseconds: timeout)?.code == .ok
    }
}
