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
private func lease(_ items: [(String, String)] = [("xless-vault:1", keyText)], grant: [AgentSession]? = nil, command: String = "xless session (release.sh)",
                   seconds: Int = 1800, in directory: AgentDirectory? = nil) throws -> (agent: TestAgent, holder: Int32) {
    var fds: [Int32] = [-1, -1]
    try #require(xless_unix_pair(&fds) == 0)
    var options = AgentServer.Options()
    options.lease = .init(channel: try AgentChannel(fd: fds[1]), command: command, seconds: seconds)
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
    #expect(c.drop(prefix: "a").count == 1)
    #expect(agent.waitForExit(0.3) == nil)
}

@Test func aLeasedAgentEndsAfterItsTimeWhateverItWasGivenMeanwhile() throws {
    let (agent, holder) = try lease()
    defer { close(holder) }
    let c = client(agent.directory, session: agent.path)
    agent.clock.advance(1700)
    try c.put([AgentSeed(name: "a", label: "", secret: key, hold: SecretHold(seconds: 5000, idle: 5000, maximum: 5000))])
    #expect(c.statuses().first?.items.map(\.remaining) == [100]) // not what was asked for
    agent.clock.advance(99)
    #expect(c.get("a") { $0 == key } == key)
    agent.clock.advance(1)
    #expect(c.get("a") { $0 == key } == nil)
    #expect(agent.waitForExit() == .leaseEnded)
    #expect(agent.state.isEmpty)
}

@Test func everyTerminalOfTheUserSeesWhatALeaseHoldsWhoseItIsAndUntilWhen() throws {
    let box = ScratchBox(), directory = AgentDirectory(path: box.path + "/xless-agent")
    let (near, a) = try lease([("xless-vault:1", keyText), ("xless-apple-session", "c")], in: directory)
    let (other, b) = try lease(grant: [AgentSession(id: 77, leaderStart: 7)], command: "xless run\u{1B}[2J", seconds: 60, in: directory)
    let (empty, c) = try lease([], in: directory)
    let usual = try TestAgent(in: directory)
    defer { [a, b, c].forEach { close($0) } }
    near.clock.advance(300)
    let all = client(directory).leases().sorted { $0.remaining > $1.remaining }
    #expect(all.map(\.lease) == [AgentLeaseStatus(command: "xless session (release.sh)", remaining: 1500), AgentLeaseStatus(command: "xless run?[2J", remaining: 60)])
    #expect(all.first?.items.map(\.name) == ["xless-apple-session", "xless-vault:1"] && all.first?.isGranted == true && all.first?.isSameSession == true)
    // Another session is told the kinds: not which store, nor where it is.
    #expect(all.last?.items.map(\.name) == ["xless-vault"] && all.last?.items.map(\.label) == [""] && all.last?.isGranted == false)
    // It is looked at, not used, and counts for nothing else.
    #expect(client(directory).statuses().flatMap(\.items).map(\.name) == ["a"])
    #expect(near.state.status(of: "xless-vault:1")?.idleRemaining == 300)
    #expect(client(directory, session: near.path).leases().count == 2)
    _ = (other, empty, usual)
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

@Test func whatIsKeptInASessionIsUsedThereAndReplacesNothingElsewhere() throws {
    let box = ScratchBox(), directory = AgentDirectory(path: box.path + "/xless-agent")
    let usual = try TestAgent(items: [("s", "terminal"), ("s-key", "k")], in: directory)
    var leases: [(agent: TestAgent, holder: Int32)] = []
    for _ in 0..<6 { leases.append(try lease([], in: directory)) } // (the sockets' names say nothing of the order)
    defer { leases.forEach { close($0.holder) } }
    func text(_ session: String?) -> String? { client(directory, session: session).get("s", witness: { nil })?.utf8String() }
    for (i, l) in leases.enumerated() {
        #expect(text(l.agent.path) == "terminal")
        try client(directory, session: l.agent.path).put(["s", "s-key"].map { AgentSeed(name: $0, label: "", secret: SecretBytes(utf8: "in \(i)"), hold: hold) })
    }
    for (i, l) in leases.enumerated() { #expect(text(l.agent.path) == "in \(i)") }
    #expect(text(nil) == "terminal")
    // Replaced, or dropped for not being readable: there only.
    try client(directory).put([AgentSeed(name: "s", label: "", secret: SecretBytes(utf8: "new"), hold: hold)])
    #expect(text(nil) == "new" && text(leases[0].agent.path) == "in 0")
    #expect(client(directory, session: leases[0].agent.path).discard(["s", "s-key"], witness: { nil }))
    #expect(leases[0].agent.state.isEmpty && !usual.state.isEmpty)
    #expect(text(leases[0].agent.path) == "new" && text(leases[1].agent.path) == "in 1")
    #expect(client(directory).discard(["s", "s-key"], witness: { nil }) && usual.state.isEmpty)
    #expect(!client(directory).discard(["s", "s-key"], witness: { nil }))
    #expect(text(leases[1].agent.path) == "in 1")
    // `xless auth logout` reaches all of them.
    #expect(client(directory).drop(prefix: "s").count == 10)
    #expect(leases.allSatisfy { $0.agent.state.isEmpty })
}

@Test func anUnreadableItemIsDroppedOnlyFromAnAgentThatMayBeBelieved() throws {
    let agent = try TestAgent(grant: [AgentSession(id: 77, leaderStart: 7)], items: [("xless-vault:1", keyText), ("s", "x")])
    let c = client(agent.directory)
    c.seesEveryAgentAsAnotherSessions = true
    #expect(!c.discard(["s"], witness: { nil }))
    #expect(!c.discard(["s"], witness: { AgentWitness(item: "xless-vault:1", key: SecretBytes(utf8: "another key")) }))
    #expect(agent.state.heldBytes("s") != nil)
    #expect(c.discard(["s"], witness: { witness }))
    #expect(agent.state.heldBytes("s") == nil)
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
