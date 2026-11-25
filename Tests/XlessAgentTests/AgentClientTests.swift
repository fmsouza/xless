import CXlessProcess
import Foundation
import Testing
import XlessCore
@testable import XlessAgent

private final class Starts: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[AgentSeed]] = []
    var count: Int { lock.withLock { all.count } }
    var names: [[String]] { lock.withLock { all.map { $0.map(\.name) } } }
    func note(_ seeds: [AgentSeed]) { lock.withLock { all.append(seeds) } }
}

private let far = AgentSession(id: 77, leaderStart: 7)
private let key = SecretBytes(copying: [UInt8](repeating: 9, count: 32))
private let keyText = String(decoding: [UInt8](repeating: 9, count: 32), as: UTF8.self)
private let hold = SecretHold(seconds: 500, idle: 400, maximum: 5000)
private let witness = AgentWitness(item: "xless-vault:1", key: key)

private func client(_ directory: AgentDirectory, _ starts: Starts = Starts(), terms: AgentTerms = AgentTerms(), obstacle: AgentError? = nil) -> AgentClient {
    AgentClient(directory: directory, terms: terms, obstacle: { obstacle }, start: { seeds, _ in starts.note(seeds) })
}

private func sharedDirectory() -> (ScratchBox, AgentDirectory) {
    let box = ScratchBox()
    return (box, AgentDirectory(path: box.path + "/xless-agent"))
}

@Test func withNoAgentNothingIsHeldAndNothingIsMade() throws {
    let (box, directory) = sharedDirectory()
    let c = client(directory)
    #expect(c.get("a") { _ in true } == nil)
    #expect(c.get("a", witness: { witness }) == nil)
    #expect(c.statuses().isEmpty)
    #expect(try c.lockAll() == 0)
    #expect(c.drop(prefix: "a") == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    _ = box
}

@Test func anUnsafeDirectoryIsReportedAndNothingIsTakenFromIt() throws {
    let agent = try TestAgent()
    chmod(agent.directory.path, 0o755)
    let c = client(agent.directory)
    #expect(c.get("a") { _ in true } == nil)
    #expect(c.problem?.kind == .unsafePath)
    #expect(throws: AgentError.self) { try c.put([AgentSeed(name: "b", label: "", secret: key, hold: hold)]) }
}

@Test func aSecretIsTakenOnlyWhenTheCommandAcceptsIt() throws {
    let agent = try TestAgent()
    let c = client(agent.directory)
    #expect(c.get("a") { $0.utf8String() == "one" }?.utf8String() == "one")
    #expect(c.get("a") { _ in false } == nil)
}

@Test func aSecretGoesToTheAgentOfThisSessionElseToANewOne() throws {
    let agent = try TestAgent()
    let starts = Starts()
    try client(agent.directory, starts).put([AgentSeed(name: "b", label: "", secret: key, hold: hold)])
    #expect(starts.count == 0)
    #expect(agent.state.heldBytes("b")?.copy() == key)
    let foreign = try TestAgent(grant: [far])
    try client(foreign.directory, starts).put([AgentSeed(name: "b", label: "", secret: key, hold: hold)])
    #expect(starts.names == [["b"]])
    #expect(foreign.state.heldBytes("b") == nil)
}

@Test func whereNoAgentCanRunPuttingSaysWhy() throws {
    let (box, directory) = sharedDirectory()
    let no = AgentError(.unavailable, "no way", fix: "none")
    let c = client(directory, obstacle: no)
    #expect(throws: no) { try c.put([AgentSeed(name: "b", label: "", secret: key, hold: hold)]) }
    _ = box
}

@Test func aSecondTerminalsUnlockJoinsTheAgentAndRenewsIt() throws {
    let agent = try TestAgent(grant: [far], items: [("xless-vault:1", keyText), ("xless-apple-session", "cookies")])
    let starts = Starts()
    let c = client(agent.directory, starts)
    #expect(c.get("xless-vault:1") { $0 == key } == nil)
    #expect(c.get("xless-apple-session", witness: { nil }) == nil)
    try c.put([AgentSeed(name: "xless-vault:1", label: "xless-vault:1", secret: key, hold: hold)], witness: { witness })
    #expect(starts.count == 0) // no second agent
    #expect(c.get("xless-vault:1") { $0 == key } == key)
    #expect(agent.state.status(of: "xless-vault:1")?.remaining == 500)
    #expect(c.get("xless-apple-session", witness: { nil })?.utf8String() == "cookies") // in this test, the same session too
}

@Test func aTerminalWithTheStoresKeyJoinsByItselfAndProlongsNothing() throws {
    let agent = try TestAgent(grant: [far], items: [("xless-vault:1", keyText), ("xless-apple-session", "cookies")])
    agent.clock.advance(100)
    let c = client(agent.directory)
    #expect(c.get("xless-apple-session", witness: { witness })?.utf8String() == "cookies")
    #expect(agent.state.status(of: "xless-vault:1")?.remaining == 3500)
    #expect(agent.state.sessions == 2)
}

@Test func lockingReachesEveryAgentAndDroppingToo() throws {
    let (box, directory) = sharedDirectory()
    let one = try TestAgent(in: directory), two = try TestAgent(grant: [far], items: [("a", "x"), ("b", "y")], in: directory)
    let c = client(directory)
    #expect(c.statuses().count == 2)
    #expect(c.drop(prefix: "b") == 1)
    #expect(two.state.statuses().map(\.name) == ["a"])
    #expect(try c.lockAll() == 2)
    #expect(one.waitForExit() == .locked)
    #expect(two.waitForExit() == .locked)
    _ = box
}

@Test func aFakeAgentGetsNoSecretAndGivesNoSession() throws {
    // Build code listening in the agents' directory: an agent of another session that says this one is granted, and
    // does not have the store's key.
    let agent = try TestAgent(items: [("xless-vault:1", "not the key, but thirty-two long"), ("xless-apple-session", "the attacker's")])
    let starts = Starts()
    let c = client(agent.directory, starts)
    c.seesEveryAgentAsAnotherSessions = true
    #expect(c.get("xless-vault:1") { $0 == key } == nil)
    #expect(c.get("xless-apple-session", witness: { nil }) == nil)
    #expect(c.get("xless-apple-session", witness: { witness }) == nil)
    try c.put([AgentSeed(name: "b", label: "", secret: key, hold: hold)], witness: { witness })
    #expect(starts.names == [["b"]]) // a new one instead
    #expect(agent.state.heldBytes("b") == nil)
}

@Test func anAgentOfAnotherVersionIsAProblemToReportNotAFailure() throws {
    let (box, directory) = sharedDirectory()
    let bound = try directory.bind()
    let stop = Flag()
    Thread.detachNewThread {
        while !stop.isSet {
            let fd = xless_unix_accept(bound.fd)
            guard fd >= 0 else { usleep(5000); continue }
            var w = WireWriter()
            w.put(UInt8(AgentRefusal.version.rawValue)); w.put("7.7.7")
            w.frame(code: .refused, version: 42).withUnsafeBytes { _ = xless_unix_send(fd, $0.baseAddress, $0.count) }
            usleep(50_000)
            close(fd)
        }
        close(bound.fd)
    }
    defer { stop.set() }
    let c = client(directory)
    #expect(c.get("a") { _ in true } == nil)
    #expect(c.problem?.kind == .version)
    _ = box
}

@Test func aSocketLeftByAKilledAgentIsRemovedOnceItIsOld() throws {
    let (box, directory) = sharedDirectory()
    let bound = try directory.bind()
    close(bound.fd)
    let c = client(directory)
    #expect(c.statuses().isEmpty)
    #expect(FileManager.default.fileExists(atPath: bound.path)) // it may be an agent about to listen
    var old = [timeval(tv_sec: time(nil) - 60, tv_usec: 0), timeval(tv_sec: time(nil) - 60, tv_usec: 0)]
    utimes(bound.path, &old)
    #expect(c.statuses().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: bound.path))
    _ = box
}

@Test func lookingAndDroppingForOnePlaceReachTheAgent() throws {
    let agent = try TestAgent(items: [("a", "one"), ("b", "two")]) // labelled with their names
    let c = client(agent.directory)
    agent.clock.advance(500)
    #expect(c.get("a", using: false) { _ in true } != nil)
    #expect(c.get("b", using: true) { _ in true } != nil)
    agent.clock.advance(100)
    #expect(agent.state.statuses().map(\.name) == ["b"])
    #expect(c.drop(prefix: "b", label: "elsewhere") == 0)
    #expect(c.drop(prefix: "b", label: "b") == 1)
}

// MARK: the settings of the commands that use an agent

@Test func aLoweredMaximumEndsAHoldAtTheNextCommand() throws {
    let agent = try TestAgent(items: [("a", "one"), ("b", "two")]) // 3600 s, at most 7200
    agent.clock.advance(500)
    let c = client(agent.directory, terms: AgentTerms(maximum: 1000))
    #expect(c.get("a") { _ in true } != nil)
    #expect(agent.state.statuses().map(\.remaining) == [500, 500])
    #expect(c.statuses().first?.items.map(\.typedAgo) == [500, 500])
    #expect(client(agent.directory, terms: AgentTerms(maximum: 500)).get("a") { _ in true } == nil)
    #expect(agent.waitForExit() == .empty)
}

@Test func aProcessThatIsNotServedChangesNoTerms() throws {
    let agent = try TestAgent(grant: [far])
    #expect(client(agent.directory, terms: AgentTerms(maximum: 1)).statuses().first?.isGranted == false)
    #expect(agent.state.statuses().map(\.remaining) == [3600])
}

@Test func theSettingsOfATerminalThatJoinsCountAndOnlyTighten() throws {
    let locked = Flag()
    var options = AgentServer.Options()
    options.lockOnSleep = false
    options.lockOnScreenLock = false
    options.screenIsLocked = { locked.isSet }
    let lax = AgentTerms(lockOnSleep: false, lockOnScreenLock: false)
    // A lax command changes nothing; one that minds sleep does, and a lax one after it does not undo that.
    let agent = try TestAgent(options: options)
    #expect(client(agent.directory, terms: lax).get("a") { _ in true } != nil)
    agent.clock.sleep(60)
    usleep(100_000)
    #expect(client(agent.directory, terms: lax).get("a") { _ in true } != nil)
    #expect(client(agent.directory, terms: AgentTerms(lockOnSleep: true, lockOnScreenLock: false)).get("a") { _ in true } != nil)
    #expect(client(agent.directory, terms: lax).get("a") { _ in true } != nil)
    agent.clock.sleep(60)
    #expect(agent.waitForExit() == .slept)
    // By joining, with the store's key.
    let other = try TestAgent(grant: [far], items: [("xless-vault:1", keyText), ("a", "one")], options: options)
    #expect(client(other.directory, terms: AgentTerms(maximum: 1000, lockOnSleep: false, lockOnScreenLock: true)).get("a", witness: { witness }) != nil)
    #expect(other.state.statuses().map(\.remaining) == [1000, 1000])
    locked.set()
    #expect(other.waitForExit() == .screenLocked)
}

@Test func aSecretMovedToAnAgentKeepsTheTimeItWasTyped() throws {
    let agent = try TestAgent()
    let seed = AgentSeed(name: "b", label: "", secret: key, hold: hold, typedAgo: 4800)
    try client(agent.directory).put([seed])
    #expect(agent.state.status(of: "b")?.remaining == 200) // of at most 5000
    #expect(agent.state.status(of: "b")?.typedAgo == 4800)
}
