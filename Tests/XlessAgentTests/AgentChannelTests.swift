import CXlessProcess
import Foundation
import Testing
import XlessCore
@testable import XlessAgent

private let hello: SecretPages = {
    var w = WireWriter()
    w.put(bytes: [UInt8](repeating: 1, count: 16)); w.put("test")
    return w.frame(code: .hello)
}()

/// What `message` is sent by: a child of this very session, which ends then; the connection stays open here.
private func sentAndEnded(_ message: SecretPages, over far: FileHandle) throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hello-\(UUID().uuidString)")
    try message.withUnsafeBytes { Data($0) }.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.arguments = [file.path]
    child.standardOutput = far
    try child.run()
    child.waitUntilExit()
    #expect(child.terminationStatus == 0)
}

@Test func aProcessThatSpokeAndEndedIsNobodyToServe() throws {
    var fds: [Int32] = [-1, -1]
    #expect(xless_unix_pair(&fds) == 0)
    let channel = try AgentChannel(fd: fds[0])
    let far = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
    try sentAndEnded(hello, over: far)
    #expect(try channel.next(limit: 4096) != nil) // what it said is heard (`lock` is for everybody)
    #expect(throws: AgentError.self) { try channel.peer() }
    withExtendedLifetime(far) {}
}

/// As an agent that was stopped meanwhile finds it.
@Test func aLockThatItsSenderDidNotWaitForIsKept() throws {
    let scratch = ScratchBox()
    let directory = AgentDirectory(path: scratch.path + "/xless-agent")
    let clock = TestClock()
    let state = AgentState(clock: clock.clock)
    state.grant(.current)
    try state.put("a", label: "", SecretBytes(utf8: "x"), hold: SecretHold(seconds: 3600, idle: 600, maximum: 7200), typedAgo: 0)
    let bound = try directory.bind()
    var options = AgentServer.Options()
    options.isAlive = { _ in true }
    let server = AgentServer(bound: bound, directory: directory, state: state, clock: clock.clock, options: options)
    let fd = xless_unix_connect(bound.path)
    #expect(fd >= 0)
    let far = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try sentAndEnded(WireWriter().frame(code: .lock), over: far)
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { server.stop() }
    #expect(server.run() == .locked)
    #expect(state.isEmpty)
    withExtendedLifetime(far) {}
}

#if os(macOS)
/// What the kernel says of the other end, as the test wants it (`LOCAL_PEERTOKEN` is the token of whatever process has
/// the peer's pid when it is asked).
private final class Kernel: @unchecked Sendable {
    private let lock = NSLock()
    private var change: (inout xless_peer) -> Void = { _ in }
    private var fails = false
    private var count = 0

    var reads: Int { lock.withLock { count } }
    func alter(_ change: @escaping (inout xless_peer) -> Void) { lock.withLock { self.change = change; fails = false } }
    /// EINVAL: the process that had the pid has ended.
    func end() { lock.withLock { fails = true } }

    func read(_ fd: Int32) -> xless_peer? {
        lock.withLock {
            count += 1
            guard !fails else { return nil }
            guard var peer = AgentChannel.kernelPeer(fd) else { return nil }
            change(&peer)
            return peer
        }
    }
}

/// Two connected ends, the far one written to by this process.
private func pair(_ kernel: Kernel) throws -> (AgentChannel, far: Int32) {
    var fds: [Int32] = [-1, -1]
    #expect(xless_unix_pair(&fds) == 0)
    return (try AgentChannel(fd: fds[0], readPeer: kernel.read), fds[1])
}

@Test func aPeerIsTheProcessThatSpokeFirst() throws {
    let kernel = Kernel()
    let (channel, far) = try pair(kernel)
    defer { close(far) }
    #expect(throws: AgentError.self) { try channel.peer() } // it has said nothing yet
    #expect(kernel.reads == 0)
    _ = hello.withUnsafeBytes { xless_unix_send(far, $0.baseAddress, $0.count) }
    #expect(try channel.next(limit: 4096) != nil)
    #expect(kernel.reads == 1) // before anything is answered
    #expect(try channel.peer().pid == getpid())
    #expect(try channel.peer().session == .current)
}

@Test func aPidThatIsAnotherProcesssByNowIsRefused() throws {
    // The same pid, uid, session and program: only the process version of the audit token tells. And any other part of it.
    let changes: [(inout xless_peer) -> Void] = [{ $0.token.7 += 1 }, { $0.token.0 += 1 }, { $0.token.6 += 1 }]
    for change in changes {
        let kernel = Kernel()
        let (channel, far) = try pair(kernel)
        defer { close(far) }
        _ = hello.withUnsafeBytes { xless_unix_send(far, $0.baseAddress, $0.count) }
        #expect(try channel.next(limit: 4096) != nil)
        _ = try channel.peer()
        kernel.alter(change)
        #expect(throws: AgentError.self) { try channel.peer() }
        kernel.alter { _ in } // and that is the end of it
        #expect(throws: AgentError.self) { try channel.peer() }
    }
}

@Test func aPeerThatHasEndedIsRefusedAlsoWhenItsPidComesBack() throws {
    let kernel = Kernel()
    let (channel, far) = try pair(kernel)
    defer { close(far) }
    kernel.end() // already when its first message is read
    _ = hello.withUnsafeBytes { xless_unix_send(far, $0.baseAddress, $0.count) }
    #expect(try channel.next(limit: 4096) != nil)
    #expect(throws: AgentError.self) { try channel.peer() }
    kernel.alter { _ in } // another process has its pid now
    #expect(throws: AgentError.self) { try channel.peer() }
}

@Test func theAgentServesOneProcessOnAConnectionToItsEnd() throws {
    let agent = try TestAgent()
    let kernel = Kernel()
    agent.server.readPeer = kernel.read
    let link = try agent.link()
    #expect(link.isGranted)
    #expect(try link.get("a") != nil)
    kernel.alter { $0.token.7 += 1 }
    #expect(throws: AgentError.self) { try link.get("a") }
    kernel.alter { _ in }
    let another = try agent.link()
    #expect(try another.get("a") != nil)
    kernel.end()
    #expect(throws: AgentError.self) { try another.get("a") }
}

/// As when its file was replaced or removed, so the kernel cannot say which program it runs.
@Test func anAgentOfAnUnknownProgramIsNotUsed() throws {
    let agent = try TestAgent()
    do {
        _ = try AgentLink.connect(path: agent.path, directory: agent.directory, timeout: 5000) { fd -> xless_peer? in
            guard var peer = AgentChannel.kernelPeer(fd) else { return nil }
            (peer.exe_device, peer.exe_inode) = (0, 0)
            return peer
        }
        Issue.record("it was used")
    } catch let e as AgentError {
        #expect(e.kind == .version)
    }
}

@Test func aCommandDealsWithOneAgentProcessOnAConnectionToItsEnd() throws {
    let agent = try TestAgent()
    let kernel = Kernel()
    // The agent ends while the two greet each other, and a process of this session has its pid by the end of it.
    var answers = 0
    #expect(throws: AgentError.self) {
        try AgentLink.connect(path: agent.path, directory: agent.directory, timeout: 5000) { fd -> xless_peer? in
            answers += 1
            guard var peer = AgentChannel.kernelPeer(fd) else { return nil }
            peer.token.7 += UInt32(answers)
            return peer
        }
    }
    let link = try AgentLink.connect(path: agent.path, directory: agent.directory, timeout: 5000, readPeer: kernel.read)
    #expect(link.isSameSession)
    #expect(try link.get("a") != nil)
    kernel.alter { $0.token.7 += 1 }
    #expect(throws: AgentError.self) { try link.get("a") } // what it gave is not taken
    #expect(throws: AgentError.self) { // and it is sent nothing
        try link.put("b", label: "", SecretBytes(utf8: "x"), hold: SecretHold(seconds: 9, idle: 9, maximum: 9), typedAgo: 0)
    }
    #expect(agent.state.status(of: "b") == nil)
}

@Test func aSecondProcessOnTheConnectionIsRefused() throws {
    // It writes, or it only reads what was sent to the first one (the challenge).
    for (tool, arguments) in [("/bin/echo", ["x"]), ("/usr/bin/head", ["-c", "1"])] {
        var fds: [Int32] = [-1, -1]
        #expect(xless_unix_pair(&fds) == 0)
        let channel = try AgentChannel(fd: fds[0])
        _ = fcntl(fds[1], F_SETFL, 0)
        _ = hello.withUnsafeBytes { xless_unix_send(fds[1], $0.baseAddress, $0.count) }
        #expect(try channel.next(limit: 4096) != nil)
        channel.send(hello)
        try channel.flush()
        #expect(try channel.peer().pid == getpid())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: tool)
        child.arguments = arguments
        let far = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        if tool == "/bin/echo" { child.standardOutput = far } else {
            child.standardInput = far
            child.standardOutput = FileHandle.nullDevice
        }
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(throws: AgentError.self, "\(tool)") { try channel.peer() }
        withExtendedLifetime(far) {}
    }
}
#endif

@Test func aProcessIsToldByTheProgramItRuns() throws {
    let mine = try #require(AgentExecutable(runBy: getpid()))
    #expect(AgentExecutable.current == mine)
    #if os(macOS)
    #expect(AgentExecutable(at: try AgentLauncher.executablePath()) == mine)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    defer { child.terminate() }
    #expect(AgentExecutable(runBy: child.processIdentifier) == AgentExecutable(at: "/bin/sleep"))
    #expect(AgentExecutable(runBy: child.processIdentifier) != mine)
    #else
    #expect(AgentExecutable(runBy: 1) == nil) // a command that holds secrets hides it
    #endif
}
