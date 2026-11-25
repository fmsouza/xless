import CXlessProcess
import Crypto
import Foundation
import Testing
import XlessCore
@testable import XlessAgent

/// An agent in this process, on a thread: the real sockets, the kernel's word about the peer (this process) unless the
/// test puts another one in its place.
final class TestAgent: @unchecked Sendable {
    let scratch = ScratchBox()
    let directory: AgentDirectory
    let state: AgentState
    let clock: TestClock
    let server: AgentServer
    let path: String
    private let done = DispatchSemaphore(value: 0)
    var exit: AgentServer.Exit?

    static var ownSession: AgentSession { .current }

    /// - Parameter grant: the sessions served (default: this process's own).
    init(grant: [AgentSession]? = nil, items: [(String, String)] = [("a", "one")], options: AgentServer.Options = .init(),
         peer: AgentServer.PeerCheck? = nil, in shared: AgentDirectory? = nil, bound given: AgentDirectory.Bound? = nil) throws {
        // As the agent itself does, with no word of why: a session whose leader has ended is served nothing.
        try #require(Self.ownSession.isUsable, "these tests need a session whose leader still runs: not a script left behind by the shell that started it")
        directory = shared ?? AgentDirectory(path: scratch.path + "/xless-agent")
        clock = TestClock()
        state = AgentState(clock: clock.clock)
        for session in grant ?? [Self.ownSession] { state.grant(session) }
        for (name, text) in items {
            try state.put(name, label: name, SecretBytes(utf8: text), hold: SecretHold(seconds: 3600, idle: 600, maximum: 7200), typedAgo: 0)
        }
        let bound = try given ?? directory.bind()
        path = bound.path
        var options = options
        options.tickMilliseconds = min(options.tickMilliseconds, 20)
        options.isAlive = { _ in true }
        server = AgentServer(bound: bound, directory: directory, state: state, clock: clock.clock, options: options)
        if let peer { server.peerCheck = peer }
        Thread.detachNewThread { [self] in
            exit = server.run()
            done.signal()
        }
    }

    /// What `xless lock` does; whether the agent said it would.
    func lock() throws -> Bool { try AgentClient(directory: directory).lockAll() == AgentLocked(ended: 1, unanswered: []) }

    /// Waits for the agent to end; why it did.
    func waitForExit(_ seconds: Double = 10) -> AgentServer.Exit? {
        done.wait(timeout: .now() + seconds) == .success ? exit : nil
    }

    func link(timeout: Int = 5000, terms: AgentTerms = AgentTerms()) throws -> AgentLink {
        try AgentLink.connect(path: path, directory: directory, terms: terms, timeout: timeout)
    }
}

/// A short-named directory (a socket's path is short), removed when the tests end: the agents of the tests, which run
/// until then, use it.
final class ScratchBox {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String] = []
    private static let atEnd: Void = {
        atexit { ScratchBox.made.forEach { try? FileManager.default.removeItem(atPath: $0) } }
    }()

    let path: String
    init() {
        var template = Array("/tmp/xa-XXXXXX".utf8CString)
        path = String(cString: template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) })
        _ = Self.atEnd
        Self.lock.withLock { Self.made.append(path) }
    }
}

/// Connected to `path` with nothing in between; the test speaks as it pleases.
final class RawPeer {
    let fd: Int32
    init(_ path: String) throws {
        var c = xless_unix_connect(path)
        for _ in 0..<100 where c == -ECONNREFUSED || c == -EAGAIN {
            usleep(20_000)
            c = xless_unix_connect(path)
        }
        fd = c
        guard fd >= 0 else { throw AgentError.gone }
        _ = fcntl(fd, F_SETFL, 0)
        _ = xless_unix_passcred(fd)
        var t = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { close(fd) }
    @discardableResult func send(_ bytes: [UInt8]) -> Int { bytes.withUnsafeBytes { xless_unix_send(fd, $0.baseAddress, $0.count) } }
    func send(_ frame: SecretPages) { send(frame.withUnsafeBytes { Array($0) }) }
    /// The next answer's header and body, nil when the agent closed.
    func answer() -> (AgentFrame.Header, [UInt8])? {
        func read(_ n: Int) -> [UInt8]? {
            var out: [UInt8] = []
            while out.count < n {
                var chunk = [UInt8](repeating: 0, count: n - out.count)
                let got = recv(fd, &chunk, chunk.count, 0)
                guard got > 0 else { return nil }
                out += chunk[..<got]
            }
            return out
        }
        guard let h = read(AgentFrame.headerSize), let header = h.withUnsafeBytes({ try? AgentFrame.header($0) }), let body = read(header.length) else { return nil }
        return (header, body)
    }
    /// Whether the agent has closed the connection (what it said before that is read).
    func isClosed() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = recv(fd, &chunk, chunk.count, 0)
            if got > 0 { continue }
            return got == 0 || errno == ECONNRESET
        }
    }
}

private let other = AgentSession(id: 2, leaderStart: 5)
private func elsewhere(_ session: AgentSession = other) -> AgentServer.PeerCheck {
    { _ in AgentPeer(pid: 999_999, uid: geteuid(), session: session, program: nil) }
}

// MARK: use

@Test func aCommandOfTheGrantedSessionGetsWhatIsHeld() throws {
    let agent = try TestAgent()
    let link = try agent.link()
    #expect(link.isGranted)
    #expect(link.isSameSession)
    let held = try #require(try link.get("a"))
    #expect(held.secret.utf8String() == "one")
    #expect(held.status.remaining == 3600)
    #expect(try link.get("b") == nil)
}

@Test func aSecretIsPutRenewedAndDropped() throws {
    let agent = try TestAgent()
    let link = try agent.link()
    let big = SecretBytes(count: AgentLimits.itemBytes)
    big.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 31) } }
    try link.put("big", label: "here", big, hold: SecretHold(seconds: 100, idle: 100, maximum: 100), typedAgo: 0)
    #expect(try agent.link().get("big")?.secret == big)
    #expect(try link.status()?.items.map(\.name) == ["a", "big"])
    #expect(try link.drop(prefix: "bi") == 1)
    #expect(try link.get("big") == nil)
}

@Test func theAgentEndsWhenItHoldsNothing() throws {
    let agent = try TestAgent()
    #expect(try agent.link().drop(prefix: "a") == 1)
    #expect(agent.waitForExit() == .empty)
    #expect(!FileManager.default.fileExists(atPath: agent.path))
}

@Test func theAgentEndsWhenTheTimeRunsOut() throws {
    let agent = try TestAgent()
    #expect(try agent.link().get("a") != nil)
    agent.clock.advance(600) // idle
    #expect(agent.waitForExit() == .empty)
}

@Test func lockDropsEverythingAndEndsTheAgent() throws {
    let agent = try TestAgent()
    #expect(try agent.lock())
    #expect(agent.waitForExit() == .locked)
    #expect(agent.state.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: agent.path))
}

// MARK: who

@Test func aProcessOfAnotherSessionGetsNothingAndPutsNothing() throws {
    let agent = try TestAgent(peer: elsewhere())
    let link = try agent.link()
    #expect(!link.isGranted)
    #expect(throws: AgentError.self) { try link.get("a") }
    #expect(throws: AgentError.self) {
        try link.put("b", label: "", SecretBytes(utf8: "x"), hold: SecretHold(seconds: 9, idle: 9, maximum: 9), typedAgo: 0)
    }
    let status = try #require(try link.status())
    #expect(!status.isGranted)
    #expect(status.items.isEmpty) // not even names and paths
    #expect(status.count == 1)
    #expect(agent.state.statuses().map(\.name) == ["a"])
    // It may lock: it could end the agent anyway.
    #expect(try agent.lock())
    #expect(agent.waitForExit() == .locked)
}

@Test func theRealKernelIdentityIsThisProcesss() throws {
    let box = PeerBox()
    let agent = try TestAgent()
    let real = agent.server.peerCheck
    agent.server.peerCheck = { channel in
        let peer = try real(channel)
        box.set(peer)
        return peer
    }
    _ = try agent.link().get("a")
    let peer = try #require(box.get())
    #expect(peer.pid == getpid())
    #expect(peer.uid == geteuid())
    #expect(peer.session.id == getsid(0))
    #expect(peer.session.leaderStart == xless_process_start(getsid(0)))
}

final class PeerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: AgentPeer?
    func set(_ p: AgentPeer) { lock.withLock { peer = p } }
    func get() -> AgentPeer? { lock.withLock { peer } }
}

/// The peer as a child process of another session: python speaking the protocol as far as it can.
private func inAnotherSession(_ script: String, _ arguments: [String]) throws -> String {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("agent-peer-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    let child = try ChildProcess.start("/usr/bin/env", ["python3", "-I", "-c", script] + arguments, environment: ProcessInfo.processInfo.environment,
                                       cwd: nil, stdout: handle.fileDescriptor, stderr: handle.fileDescriptor, stage: .build)
    _ = child.wait()
    return try String(contentsOf: output, encoding: .utf8)
}

private let pythonClient = """
import os, socket, struct, sys
def frame(code, body, version=\(AgentProtocol.version)): return b'XLAG' + struct.pack('>HHHH', version, code, len(body) >> 16, len(body) & 0xffff) + body
def field(b): return struct.pack('>I', len(b)) + b
def read(s, n):
    out = b''
    while len(out) < n:
        c = s.recv(n - len(out))
        if not c: raise SystemExit('closed')
        out += c
    return out
def answer(s):
    h = read(s, 12)
    _, version, code, hi, lo = struct.unpack('>4sHHHH', h)
    return code, read(s, hi << 16 | lo)
def connect(path):
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(path)
    if sys.platform == 'linux': s.setsockopt(socket.SOL_SOCKET, 16, 1) # SO_PASSCRED: the kernel says who sends
    return s
def handshake(s):
    s.sendall(frame(1, field(b'n' * 16) + field(b'0')))
    code, body = answer(s)
    nonce = body[4 + 16 + 4:4 + 16 + 4 + 16]
    s.sendall(frame(2, field(nonce) + field(b'm' * 16) + struct.pack('>q??', 604800, True, True)))
    return answer(s)
def get(s, name=b'a'):
    s.sendall(frame(11, field(name) + field(b'k' * 16) + b'\\x01'))
    return answer(s)

"""

@Test func aToolStartedByXlessIsRefusedByTheKernelsWordAlone() throws {
    let agent = try TestAgent()
    let said = try inAnotherSession(pythonClient + """
    s = connect(sys.argv[1])
    code, body = handshake(s)
    print('granted', body[-2])
    code, body = get(s)
    print('get', code, b'one' in body)
    """, [agent.path])
    #expect(said.contains("granted 0"), "\(said)")
    #expect(said.contains("get 111 False"), "\(said)")
}

@Test func aToolThatDaemonisesOrStartsAnotherSessionIsRefusedToo() throws {
    let agent = try TestAgent()
    let said = try inAnotherSession(pythonClient + """
    for how in ('fork', 'double', 'setsid'):
        sys.stdout.flush()
        pid = os.fork()
        if pid == 0:
            if how == 'setsid': os.setsid()
            if how == 'double' and os.fork(): os._exit(0)
            s = connect(sys.argv[1])
            code, body = handshake(s)
            print(how, 'granted', body[-2], 'get', get(s)[0])
            sys.stdout.flush()
            os._exit(0)
        os.waitpid(pid, 0)
    import time; time.sleep(1)
    """, [agent.path])
    for how in ["fork", "double", "setsid"] { #expect(said.contains("\(how) granted 0 get 111"), "\(said)") }
}

@Test func aConnectionHandedToAnotherProcessIsNotTheSamePeer() throws {
    // The connection is made and proved by this process (of the granted session) and used by a child of another one.
    let agent = try TestAgent()
    let raw = try RawPeer(agent.path)
    var w = WireWriter()
    w.put(bytes: [UInt8](repeating: 1, count: 16)); w.put("test")
    raw.send(w.frame(code: .hello))
    let (_, welcome) = try #require(raw.answer())
    var r = WireWriter()
    r.put(bytes: Array(welcome[24..<40])); r.put(bytes: [UInt8](repeating: 2, count: 16)); AgentTerms().write(&r)
    raw.send(r.frame(code: .prove))
    let (_, verdict) = try #require(raw.answer())
    #expect(verdict.dropLast().last == 1) // granted; then whether it is on a lease
    let copy = dup(raw.fd) // not close-on-exec; passed on as the child's standard error
    let child = try ChildProcess.start("/usr/bin/env", ["python3", "-I", "-c", pythonClient + """
    s = socket.socket(fileno=os.dup(2)); s.settimeout(10)
    try:
        code, body = get(s)
        raise SystemExit(0 if code == 11 * 10 else 1)
    except Exception:
        raise SystemExit(1)
    """], environment: ProcessInfo.processInfo.environment, cwd: nil, stdout: 1, stderr: copy, stage: .build)
    close(copy)
    #expect(child.wait() == 1)
}

@Test func aPeerThatDoesNotAnswerTheChallengeGetsNothing() throws {
    // Of the granted session, but what it sent before it was asked anything may be a process's that has ended since.
    let agent = try TestAgent()
    func get() -> SecretPages {
        var w = WireWriter()
        w.put("a"); w.put(bytes: [UInt8](repeating: 1, count: 16)); w.put(true)
        return w.frame(code: .get)
    }
    let silent = try RawPeer(agent.path)
    silent.send(get())
    #expect(try #require(silent.answer()).0.code == AgentCode.refused.rawValue)
    let wrong = try RawPeer(agent.path)
    var hello = WireWriter()
    hello.put(bytes: [UInt8](repeating: 1, count: 16)); hello.put("test")
    wrong.send(hello.frame(code: .hello))
    _ = try #require(wrong.answer())
    var proof = WireWriter()
    proof.put(bytes: [UInt8](repeating: 0, count: 16)); proof.put(bytes: [UInt8](repeating: 2, count: 16)); AgentTerms().write(&proof)
    wrong.send(proof.frame(code: .prove))
    #expect(try #require(wrong.answer()).0.code == AgentCode.refused.rawValue)
    #expect(wrong.isClosed())
    #expect(try agent.link().get("a") != nil) // and who does is served
}

@Test func aSessionThatEndedIsServedNoMore() throws {
    let ended = Flag()
    let agent = try TestAgent()
    agent.server.options.isAlive = { _ in !ended.isSet }
    #expect(try agent.link().get("a") != nil)
    ended.set()
    #expect(agent.waitForExit() == .noSessions)
    #expect(agent.state.isEmpty)
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isSet: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}

#if os(macOS)
@Test func anotherProgramOfTheSameSessionIsRefused() throws {
    var options = AgentServer.Options()
    options.program = AgentProgram(file: AgentExecutable(device: 1, inode: 1), code: Array(repeating: 1, count: 20)) // not this one
    let agent = try TestAgent(options: options)
    let link = try agent.link()
    #expect(!link.isGranted)
    #expect(throws: AgentError.self) { try link.get("a") }
}

@Test func theProgramThatStartedTheAgentIsServed() throws {
    var options = AgentServer.Options()
    options.program = AgentProgram.current
    #expect(try TestAgent(options: options).link().get("a") != nil)
}
#endif

// MARK: joining

private var vaultKey: SymmetricKey { SymmetricKey(data: Data(repeating: 9, count: 32)) }
private let vaultItem = ("xless-vault:1", String(decoding: Data(repeating: 9, count: 32), as: UTF8.self))

@Test func aTerminalThatProvesItHasTheStoresKeyIsGranted() throws {
    // The agent sees this process as one of another session; the client computes its proof for that session.
    let agent = try TestAgent(grant: [AgentSession(id: 77, leaderStart: 7)], items: [vaultItem, ("a", "one")])
    let link = try agent.link()
    #expect(!link.isGranted)
    #expect(try link.join("xless-vault:1", key: vaultKey))
    #expect(link.isGranted)
    #expect(try link.get("a")?.secret.utf8String() == "one")
    #expect(try agent.link().get("a") != nil)
}

@Test func joiningWithAnotherKeyOrForAnotherItemIsRefused() throws {
    let agent = try TestAgent(grant: [AgentSession(id: 77, leaderStart: 7)], items: [vaultItem])
    let wrong = SymmetricKey(data: Data(repeating: 8, count: 32))
    #expect(try agent.link().join("xless-vault:1", key: wrong) == false)
    #expect(try agent.link().join("xless-vault:2", key: vaultKey) == false)
    #expect(try !agent.link().isGranted)
}

@Test func aProofRelayedBySomeoneElseGrantsNothing() throws {
    // The real client (this process's session) made the proof; the agent sees it come from build code's session.
    let agent = try TestAgent(grant: [AgentSession(id: 77, leaderStart: 7)], items: [vaultItem], peer: elsewhere())
    #expect(try agent.link().join("xless-vault:1", key: vaultKey) == false)
    #expect(!agent.state.isGranted(other))
}

@Test func anAgentOfAnotherSessionIsTrustedOnlyWhenItProvesItHasTheStoresKey() throws {
    let agent = try TestAgent(items: [vaultItem])
    let link = try agent.link()
    link.pretendAnotherSession()
    #expect(!link.isTrusted)
    #expect(try link.prove(has: "xless-vault:1", key: SymmetricKey(size: .bits256)) == false)
    #expect(!link.isTrusted)
    #expect(try link.prove(has: "xless-vault:1", key: vaultKey))
    #expect(link.isTrusted)
}

@Test func aSecretIsNeverSentToAnAgentThatIsNotTrusted() throws {
    let agent = try TestAgent()
    let link = try agent.link()
    link.pretendAnotherSession()
    #expect(throws: AgentError.self) {
        try link.put("b", label: "", SecretBytes(utf8: "x"), hold: SecretHold(seconds: 9, idle: 9, maximum: 9), typedAgo: 0)
    }
    #expect(agent.state.statuses().map(\.name) == ["a"])
}

// MARK: hostile peers

@Test func junkLiesAndOversizedMessagesAreClosedAndTheAgentGoesOn() throws {
    let agent = try TestAgent()
    let huge = Array("XLAG".utf8) + [0, UInt8(AgentProtocol.version), 0, 12, 0xFF, 0xFF, 0xFF, 0xFF]      // a put of 4 GiB
    let notYet = Array("XLAG".utf8) + [0, UInt8(AgentProtocol.version), 0, 12, 0, 1, 0, 0]                // 64 KiB before it said who it is
    for bytes in [Array("GET / HTTP/1.0\r\n\r\n".utf8), [UInt8](repeating: 0, count: 64), huge, notYet] {
        let raw = try RawPeer(agent.path)
        raw.send(bytes)
        #expect(raw.isClosed())
    }
    for code in [AgentCode.get, .put, .join, .hello, .prove, .drop, .configure, .welcome, .ok] {
        let raw = try RawPeer(agent.path)
        var w = WireWriter()
        w.put(bytes: [1, 2, 3])
        w.put(UInt32(0xFFFF_FFFF))
        raw.send(w.frame(code: code))
        #expect(raw.answer()?.0.code == AgentCode.refused.rawValue || raw.isClosed(), "\(code)")
    }
    #expect(try agent.link().get("a") != nil)
}

@Test func randomBytesNeverHurtTheAgent() throws {
    let agent = try TestAgent()
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let raw = try RawPeer(agent.path)
        var bytes = (0..<Int.random(in: 1...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        if Bool.random(using: &rng) {
            let code = UInt8.random(in: 0...25, using: &rng)
            bytes = Array("XLAG".utf8) + [0, UInt8(AgentProtocol.version), 0, code, 0, 0, UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)] + bytes
        }
        guard bytes.count < 8 || bytes[7] != UInt8(AgentCode.lock.rawValue) else { continue } // lock is for everyone
        raw.send(bytes)
    }
    #expect(try agent.link().get("a") != nil)
}

@Test func slowClientsAndManyClientsDoNotHoldUpOthers() throws {
    let agent = try TestAgent()
    var slow: [RawPeer] = []
    for _ in 0..<(AgentLimits.connections * 2) {
        let raw = try RawPeer(agent.path)
        raw.send(Array("XLAG".utf8)) // and nothing more
        slow.append(raw)
    }
    #expect(try agent.link().get("a") != nil)
    agent.clock.advance(30) // past the deadline of a connection
    #expect(slow.allSatisfy { $0.isClosed() })
    #expect(try agent.link().get("a") != nil)
}

@Test func aClientThatDoesNotReadItsAnswersIsClosed() throws {
    let agent = try TestAgent()
    let raw = try RawPeer(agent.path)
    let status = WireWriter().frame(code: .status).withUnsafeBytes { Array($0) }
    for _ in 0..<(AgentLimits.requestsPerConnection + 50) { if raw.send(status) < 0 { break } }
    #expect(raw.isClosed())
    #expect(try agent.link().get("a") != nil)
}

@Test func descriptorsSentToTheAgentAreNotKept() throws {
    let agent = try TestAgent()
    let box = ScratchBox()
    let file = box.path + "/sent"
    #expect(FileManager.default.createFile(atPath: file, contents: Data()))
    var sent = stat()
    try #require(stat(file, &sent) == 0)
    // Of that file only: other tests open and close theirs meanwhile.
    func kept() -> Int {
        (0..<1024).filter {
            var st = stat()
            return fstat(Int32($0), &st) == 0 && st.st_dev == sent.st_dev && st.st_ino == sent.st_ino
        }.count
    }
    let said = try inAnotherSession("""
    import socket, sys, os, array
    fd = os.open(sys.argv[2], os.O_RDONLY)
    def send(data, count):
        s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
        try: s.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd] * count))])
        except OSError as e: print(count, e)
        else: print('sent', count)
        s.close()
    for _ in range(50): send(b'XLAG', 2)
    for count in (100, 250, 500): send(b'XLAG', count)
    for count in (1, 250): send(b'', count)
    """, [agent.path, file])
    #expect(said.contains("sent 2\n") && said.contains("sent 250\n"), "\(said)")
    for _ in 0..<20 { _ = try agent.link().get("a") }
    #expect(kept() == 0)
}

// MARK: versions

@Test func anotherVersionIsToldSoAndMayStillLock() throws {
    let agent = try TestAgent()
    let raw = try RawPeer(agent.path)
    raw.send(WireWriter().frame(code: .hello, version: 99))
    let (header, body) = try #require(raw.answer())
    #expect(header.code == AgentCode.refused.rawValue)
    #expect(header.version == AgentProtocol.version)
    #expect(String(decoding: body, as: UTF8.self).contains(XlessVersion.current))
    #expect(raw.isClosed())
    let second = try RawPeer(agent.path)
    second.send(WireWriter().frame(code: .lock, version: 99))
    #expect(second.answer()?.0.code == AgentCode.ok.rawValue)
    #expect(agent.waitForExit() == .locked)
}

@Test func aClientOfAnAgentOfAnotherVersionSaysSo() throws {
    let scratch = ScratchBox()
    let directory = AgentDirectory(path: scratch.path + "/xless-agent")
    let bound = try directory.bind()
    Thread.detachNewThread {
        var fd: Int32 = -1
        for _ in 0..<500 where fd < 0 {
            fd = xless_unix_accept(bound.fd)
            if fd < 0 { usleep(10_000) }
        }
        var w = WireWriter()
        w.put(UInt8(AgentRefusal.version.rawValue)); w.put("7.7.7")
        w.frame(code: .refused, version: 42).withUnsafeBytes { _ = xless_unix_send(fd, $0.baseAddress, $0.count) }
        usleep(2_000_000)
        close(fd); close(bound.fd)
    }
    do {
        _ = try AgentLink.connect(path: bound.path, directory: directory, timeout: 5000)
        Issue.record("connected to an agent of another version")
    } catch let e as AgentError {
        #expect(e.kind == .version)
        #expect(e.description.contains("7.7.7"))
    }
}

@Test func anAgentThatSaysNothingTimesOut() throws {
    let scratch = ScratchBox()
    let directory = AgentDirectory(path: scratch.path + "/xless-agent")
    let bound = try directory.bind() // listens, never accepts
    defer { close(bound.fd) }
    let start = Date()
    #expect(throws: AgentError.self) { try AgentLink.connect(path: bound.path, directory: directory, timeout: 300) }
    #expect(Date().timeIntervalSince(start) < 5)
}

// MARK: ends

@Test func theAgentEndsWhenItsSocketIsRemovedOrReplaced() throws {
    let gone = try TestAgent()
    unlink(gone.path)
    #expect(gone.waitForExit() == .socketGone)
    #expect(gone.state.isEmpty)
    let replaced = try TestAgent()
    unlink(replaced.path)
    let fd = xless_unix_listen(replaced.path, 1)
    defer { close(fd) }
    #expect(replaced.waitForExit() == .socketGone)
    #expect(FileManager.default.fileExists(atPath: replaced.path)) // not its own: left alone
}

@Test func theAgentLocksWhenTheSystemSleepsUnlessToldNotTo() throws {
    let agent = try TestAgent()
    _ = try agent.link()
    agent.clock.sleep(60)
    #expect(agent.waitForExit() == .slept)
    var options = AgentServer.Options()
    options.lockOnSleep = false
    let kept = try TestAgent(options: options)
    _ = try kept.link(terms: AgentTerms(lockOnSleep: false, lockOnScreenLock: false))
    kept.clock.sleep(60)
    usleep(200_000)
    #expect(try kept.link(terms: AgentTerms(lockOnSleep: false, lockOnScreenLock: false)).get("a") != nil)
}

@Test func theAgentLocksWhenTheScreenIsLockedUnlessToldNotTo() throws {
    let locked = Flag()
    var options = AgentServer.Options()
    options.screenIsLocked = { locked.isSet }
    let agent = try TestAgent(options: options)
    options.lockOnScreenLock = false
    let kept = try TestAgent(options: options)
    _ = try agent.link()
    locked.set()
    #expect(agent.waitForExit() == .screenLocked)
    usleep(200_000)
    #expect(try kept.link(terms: AgentTerms(lockOnSleep: false, lockOnScreenLock: false)).get("a") != nil)
    // Started with the screen locked already (over ssh): only a later lock counts.
    options.lockOnScreenLock = true
    let remote = try TestAgent(options: options)
    usleep(200_000)
    #expect(try remote.link().get("a") != nil)
}
