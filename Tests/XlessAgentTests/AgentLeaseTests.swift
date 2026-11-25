import CXlessProcess
import Foundation
import Testing
import XlessCore
@testable import XlessAgent

// An agent on a lease (`xless session`): it ends with the process that holds the other end of its channel, whatever ends
// that process, and only the commands told of it use it.

private let key = SecretBytes(copying: [UInt8](repeating: 9, count: 32))
private let keyText = String(decoding: [UInt8](repeating: 9, count: 32), as: UTF8.self)
private let hold = SecretHold(seconds: 500, idle: 400, maximum: 5000)
private let witness = AgentWitness(item: "xless-vault:1", key: key)

/// A lease's two ends: the agent's, and the one its holder closes.
private func lease(_ items: [(String, String)] = [("xless-vault:1", keyText)], grant: [AgentSession]? = nil, in directory: AgentDirectory? = nil) throws -> (agent: TestAgent, holder: Int32) {
    var fds: [Int32] = [-1, -1]
    try #require(xless_unix_pair(&fds) == 0)
    var options = AgentServer.Options()
    options.lease = try AgentChannel(fd: fds[1])
    return (try TestAgent(grant: grant, items: items, options: options, in: directory), fds[0])
}

private func client(_ directory: AgentDirectory, session: String? = nil, starts: @escaping @Sendable ([AgentSeed]) -> Void = { _ in }) -> AgentClient {
    AgentClient(directory: directory, session: session, obstacle: { nil }, start: { seeds, _ in starts(seeds) })
}

@Test func aLeasedAgentEndsWhenItsHolderDoes() throws {
    let (agent, holder) = try lease()
    #expect(client(agent.directory, session: agent.path).get("xless-vault:1") { $0 == key } == key)
    close(holder)
    #expect(agent.waitForExit() == .leaseEnded)
    #expect(agent.state.isEmpty)
    #expect(agent.directory.identity(of: agent.path) == nil)
}

@Test func aLeasedAgentEndsWhenItsHolderSaysAnything() throws {
    // Its holder says nothing after the start: whatever comes is the end.
    let (agent, holder) = try lease()
    _ = [UInt8](repeating: 0, count: 4).withUnsafeBytes { xless_unix_send(holder, $0.baseAddress, 4) }
    #expect(agent.waitForExit() == .leaseEnded)
    close(holder)
}

@Test func aLeasedAgentRunsOnWithNothingInIt() throws {
    let (agent, holder) = try lease([])
    defer { close(holder) }
    let c = client(agent.directory, session: agent.path)
    try c.put([AgentSeed(name: "a", label: "", secret: key, hold: hold)])
    #expect(c.drop(prefix: "a") == 1)
    #expect(agent.waitForExit(0.3) == nil)
}

@Test func lockEndsALeasedAgentToo() throws {
    let (agent, holder) = try lease()
    defer { close(holder) }
    #expect(try agent.lock())
    #expect(agent.waitForExit() == .locked)
}

@Test func onlyTheCommandsToldOfALeaseUseIt() throws {
    let (agent, holder) = try lease()
    defer { close(holder) }
    let outside = client(agent.directory)
    #expect(outside.get("xless-vault:1") { $0 == key } == nil)
    #expect(outside.get("xless-vault:1", witness: { witness }) == nil)
    #expect(outside.statuses().isEmpty)
    let elsewhere = client(agent.directory, session: agent.directory.path + "/0123456789abcdef.sock")
    #expect(elsewhere.get("xless-vault:1") { $0 == key } == nil)
    let inside = client(agent.directory, session: agent.path)
    #expect(inside.get("xless-vault:1") { $0 == key } == key)
    #expect(inside.statuses().first?.items.map(\.name) == ["xless-vault:1"])
}

@Test func whatIsKeptInASessionGoesWithItAndWhatIsKeptOutsideDoesNot() throws {
    let box = ScratchBox(), directory = AgentDirectory(path: box.path + "/xless-agent")
    let (leased, holder) = try lease(in: directory)
    defer { close(holder) }
    let usual = try TestAgent(items: [("a", "one")], in: directory)
    try client(directory, session: leased.path).put([AgentSeed(name: "in", label: "", secret: key, hold: hold)])
    try client(directory).put([AgentSeed(name: "out", label: "", secret: key, hold: hold)])
    #expect(leased.state.heldBytes("in") != nil && usual.state.heldBytes("in") == nil)
    #expect(usual.state.heldBytes("out") != nil && leased.state.heldBytes("out") == nil)
    // What was held before the session serves it too.
    #expect(client(directory, session: leased.path).get("a") { $0.utf8String() == "one" } != nil)
}

@Test func withNothingElseThereWhatIsKeptOutsideASessionGetsAnAgentOfItsOwn() throws {
    let (agent, holder) = try lease()
    defer { close(holder) }
    let started = Started()
    try client(agent.directory, starts: { _ in started.note() }).put([AgentSeed(name: "b", label: "", secret: key, hold: hold)], witness: { witness })
    #expect(started.count == 1)
    #expect(agent.state.heldBytes("b") == nil)
}

@Test func onceASessionHasEndedNothingIsKeptFromInsideIt() throws {
    let (agent, holder) = try lease()
    let path = agent.path
    close(holder)
    #expect(agent.waitForExit() == .leaseEnded)
    let started = Started()
    let error = #expect(throws: AgentError.self) {
        try client(agent.directory, session: path, starts: { _ in started.note() }).put([AgentSeed(name: "b", label: "", secret: key, hold: hold)])
    }
    #expect(error?.kind == .refused)
    #expect(error?.cause.contains("xless session") == true)
    #expect(started.count == 0)
}

@Test func aLeasedAgentIsJoinedByNobody() throws {
    let (agent, holder) = try lease(grant: [AgentSession(id: 77, leaderStart: 7)])
    defer { close(holder) }
    #expect(client(agent.directory, session: agent.path).get("xless-vault:1", witness: { witness }) == nil)
    #expect(agent.state.sessions == 1)
    let link = try agent.link()
    #expect(try !link.join("xless-vault:1", key: witness.symmetric))
}

@Test func aSessionsAgentMayBeItsLeadersAnUnlocksMayNot() {
    // xless leading its own session (`ssh -t host xless session -- …`) ends with the script it runs; an unlock would too.
    let me = AgentSession(id: getpid(), leaderStart: 5)
    #expect(AgentLauncher.obstacle(session: me, lease: true) == nil)
    #expect(AgentLauncher.obstacle(session: me, lease: false) != nil)
    #expect(AgentLauncher.obstacle(session: AgentSession(id: 0, leaderStart: 0), lease: true) != nil)
}

private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func note() { lock.withLock { n += 1 } }
}
