import Foundation
import Testing
import XlessCore
@testable import XlessAgent

/// A clock the test moves: `sleep` moves the continuous clock (and the wall clock) but not the awake one.
final class TestClock: @unchecked Sendable {
    var continuous: Int64 = 1_000_000
    var awake: Int64 = 500_000
    var wall = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: Int) {
        continuous += Int64(seconds) * 1000
        awake += Int64(seconds) * 1000
        wall += TimeInterval(seconds)
    }
    func sleep(_ seconds: Int) {
        continuous += Int64(seconds) * 1000
        wall += TimeInterval(seconds)
    }
    var now: AgentClock.Now { .init(continuous: continuous, awake: awake, wall: wall) }
    var clock: AgentClock { AgentClock { self.now } }
}

private func secret(_ text: String) -> SecretBytes { SecretBytes(utf8: text) }

private func state(_ clock: TestClock) -> AgentState { AgentState(clock: clock.clock) }

private let hold = AgentHold(seconds: 3600, idle: 600, maximum: 7200)

@Test func anItemIsHeldUntilItsTimeRunsOut() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typed: true)
    #expect(s.get("a")?.utf8String() == "one")
    for _ in 0..<7 { clock.advance(500); #expect(s.get("a") != nil) }
    clock.advance(100) // 3600 s
    #expect(s.get("a") == nil)
    #expect(s.isEmpty)
}

@Test func anItemNobodyUsesIsDroppedAfterItsIdleTime() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typed: true)
    clock.advance(599)
    #expect(s.get("a") != nil) // used: the idle time starts again
    clock.advance(599)
    #expect(s.get("a") != nil)
    clock.advance(600)
    #expect(s.get("a") == nil)
}

@Test func theTimeSpentAsleepCounts() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: AgentHold(seconds: 3600, idle: 3600, maximum: 7200), typed: true)
    clock.sleep(3600)
    #expect(s.get("a") == nil)
}

@Test func aWallClockSetBackDoesNotLengthenAHoldAndOneSetForwardEndsIt() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: AgentHold(seconds: 3600, idle: 3600, maximum: 7200), typed: true)
    clock.wall -= 100_000
    clock.advance(3600)
    #expect(s.get("a") == nil)
    try s.put("b", label: "", secret("two"), hold: hold, typed: true)
    clock.wall += 3600
    #expect(s.get("b") == nil)
}

@Test func aRenewalWithoutThePassphraseNeverPassesTheMaximumSinceItWasTyped() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typed: true) // at most 7200 s from now
    for _ in 0..<14 {
        clock.advance(500)
        try s.put("a", label: "", secret("one"), hold: hold, typed: false)
    }
    #expect(s.status(of: "a")?.remaining == 200) // 7000 s later
    clock.advance(200)
    #expect(s.get("a") == nil)
}

@Test func aRenewalWithAnotherSecretIsANewHold() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typed: true)
    clock.advance(500)
    try s.put("a", label: "", secret("two"), hold: hold, typed: true)
    #expect(s.get("a")?.utf8String() == "two")
    #expect(s.status(of: "a")?.remaining == 3600)
}

@Test func noHoldIsLongerThanSevenDaysWhateverIsAsked() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: AgentHold(seconds: 10_000_000, idle: 10_000_000, maximum: 20_000_000), typed: true)
    #expect(s.status(of: "a")?.remaining == 7 * 86400)
    #expect(s.status(of: "a")?.idle == 7 * 86400)
}

@Test func anItemForTheSamePlaceReplacesTheOneOfAnotherStore() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("xless-vault:1", label: "/store", secret("old"), hold: hold, typed: true)
    try s.put("xless-vault:2", label: "/other", secret("other"), hold: hold, typed: true)
    try s.put("xless-vault:3", label: "/store", secret("new"), hold: hold, typed: true)
    #expect(s.get("xless-vault:1") == nil)
    #expect(s.get("xless-vault:2") != nil)
    #expect(s.get("xless-vault:3") != nil)
}

@Test func itemsAreDroppedByNameOrPrefixAndAllAtOnce() throws {
    let clock = TestClock(), s = state(clock)
    for name in ["xless-vault:1", "xless-vault:2", "xless-apple-session", "xless-apple-session-key"] {
        try s.put(name, label: name, secret("x"), hold: hold, typed: true)
    }
    #expect(s.drop(prefix: "xless-vault:") == 2)
    #expect(s.drop(prefix: "xless-vault:") == 0)
    #expect(s.drop(prefix: "xless-apple-session") == 2)
    #expect(s.isEmpty)
}

@Test func aDroppedItemsBytesAreZeroed() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typed: true)
    let held = try #require(s.heldBytes("a")) // the agent's own buffer
    #expect(held.utf8String() == "one")
    s.wipe()
    #expect(held.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    #expect(s.isEmpty)
}

@Test func theNumberAndSizeOfItemsAreBounded() throws {
    let clock = TestClock(), s = state(clock)
    for i in 0..<AgentLimits.items { try s.put("n\(i)", label: "", secret("x"), hold: hold, typed: true) }
    #expect(throws: AgentError.self) { try s.put("one-more", label: "", secret("x"), hold: hold, typed: true) }
    try s.put("n0", label: "", secret("y"), hold: hold, typed: true) // replacing is fine
    let s2 = state(clock)
    #expect(throws: AgentError.self) { try s2.put("big", label: "", SecretBytes(count: AgentLimits.itemBytes + 1), hold: hold, typed: true) }
    #expect(throws: AgentError.self) { try s2.put(String(repeating: "n", count: 201), label: "", secret("x"), hold: hold, typed: true) }
    #expect(throws: AgentError.self) { try s2.put("", label: "", secret("x"), hold: hold, typed: true) }
    #expect(throws: AgentError.self) { try s2.put("zero", label: "", secret("x"), hold: AgentHold(seconds: 0, idle: 1, maximum: 1), typed: true) }
}

@Test func onlyTheSessionsGrantedMayUseTheAgentAndOnlyWhileTheirLeaderLives() throws {
    let clock = TestClock(), s = state(clock)
    let one = AgentSession(id: 10, leaderStart: 111), two = AgentSession(id: 20, leaderStart: 222)
    s.grant(one)
    #expect(s.isGranted(one))
    #expect(!s.isGranted(two))
    #expect(!s.isGranted(AgentSession(id: 10, leaderStart: 999))) // another session that got its number later
    #expect(!s.isGranted(AgentSession(id: 0, leaderStart: 0)))
    s.grant(two)
    s.pruneSessions { $0 == two }
    #expect(!s.isGranted(one))
    #expect(s.isGranted(two))
    s.pruneSessions { _ in false }
    #expect(s.sessions == 0)
}

@Test func theNumberOfSessionsIsBounded() {
    let s = state(TestClock())
    for i in 1...100 { s.grant(AgentSession(id: Int32(i), leaderStart: 1)) }
    #expect(s.sessions == AgentLimits.sessions)
    #expect(s.isGranted(AgentSession(id: 1, leaderStart: 1)))
}
