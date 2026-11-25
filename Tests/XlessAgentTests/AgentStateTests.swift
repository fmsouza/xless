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

private let hold = SecretHold(seconds: 3600, idle: 600, maximum: 7200)

@Test func anItemIsHeldUntilItsTimeRunsOut() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    #expect(s.get("a")?.utf8String() == "one")
    for _ in 0..<7 { clock.advance(500); #expect(s.get("a") != nil) }
    clock.advance(100) // 3600 s
    #expect(s.get("a") == nil)
    #expect(s.isEmpty)
}

@Test func anItemNobodyUsesIsDroppedAfterItsIdleTime() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    clock.advance(599)
    #expect(s.get("a") != nil) // used: the idle time starts again
    clock.advance(599)
    #expect(s.get("a") != nil)
    clock.advance(600)
    #expect(s.get("a") == nil)
}

@Test func theTimeSpentAsleepCounts() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: SecretHold(seconds: 3600, idle: 3600, maximum: 7200), typedAgo: 0)
    clock.sleep(3600)
    #expect(s.get("a") == nil)
}

@Test func aWallClockSetBackDoesNotLengthenAHoldAndOneSetForwardEndsIt() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: SecretHold(seconds: 3600, idle: 3600, maximum: 7200), typedAgo: 0)
    clock.wall -= 100_000
    clock.advance(3600)
    #expect(s.get("a") == nil)
    try s.put("b", label: "", secret("two"), hold: hold, typedAgo: 0)
    clock.wall += 3600
    #expect(s.get("b") == nil)
}

@Test func aRenewalWithoutThePassphraseNeverPassesTheMaximumSinceItWasTyped() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0) // at most 7200 s from now
    for _ in 0..<14 {
        clock.advance(500)
        try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 1)
    }
    #expect(s.status(of: "a")?.remaining == 200) // 7000 s later
    clock.advance(200)
    #expect(s.get("a") == nil)
}

@Test func theMaximumIsCountedFromWhenTheSecretWasTyped() throws {
    // Moved here from another backend 3000 s after the passphrase was typed, for 7200 s, with a maximum of 7200 s.
    let clock = TestClock(), s = state(clock)
    let wanted = SecretHold(seconds: 7200, idle: 7200, maximum: 7200)
    try s.put("a", label: "", secret("one"), hold: wanted, typedAgo: 3000)
    #expect(s.status(of: "a")?.remaining == 4200)
    #expect(s.status(of: "a")?.typedAgo == 3000)
    clock.advance(200)
    #expect(s.status(of: "a")?.typedAgo == 3200)
    // A renewal counts from the earliest time known, whatever it claims; typing it again starts again.
    try s.put("a", label: "", secret("one"), hold: wanted, typedAgo: 1)
    #expect(s.status(of: "a")?.remaining == 4000)
    #expect(s.status(of: "a")?.typedAgo == 3200)
    try s.put("a", label: "", secret("one"), hold: wanted, typedAgo: 0)
    #expect(s.status(of: "a")?.remaining == 7200)
    #expect(s.status(of: "a")?.typedAgo == 0)
    // One that is over by its maximum is not held at all; nor is one from the future.
    #expect(throws: AgentError.self) { try s.put("b", label: "", secret("two"), hold: wanted, typedAgo: 7200) }
    #expect(throws: AgentError.self) { try s.put("b", label: "", secret("two"), hold: wanted, typedAgo: -1) }
    #expect(s.get("b") == nil)
}

@Test func theTimeSinceTypingCountsSleepAndAClockSetForward() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    clock.sleep(100)
    #expect(s.status(of: "a")?.typedAgo == 100)
    clock.wall -= 5000
    #expect(s.status(of: "a")?.typedAgo == 100)
    clock.wall += 5400
    #expect(s.status(of: "a")?.typedAgo == 500)
}

@Test func aLoweredMaximumCountsAtTheNextUseAndARaisedOneNever() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0) // 3600 s, at most 7200
    clock.advance(500)
    s.tighten(maximum: 100_000)
    #expect(s.status(of: "a")?.remaining == 3100)
    s.tighten(maximum: 1000)
    #expect(s.status(of: "a")?.remaining == 500)
    s.tighten(maximum: 7200) // it stays lowered
    #expect(s.status(of: "a")?.remaining == 500)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 500)
    #expect(s.status(of: "a")?.remaining == 500)
    s.tighten(maximum: 400) // over already
    #expect(s.get("a") == nil)
    #expect(s.isEmpty)
}

@Test func aRenewalWithAnotherSecretIsANewHold() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    clock.advance(500)
    try s.put("a", label: "", secret("two"), hold: hold, typedAgo: 0)
    #expect(s.get("a")?.utf8String() == "two")
    #expect(s.status(of: "a")?.remaining == 3600)
}

@Test func noHoldIsLongerThanSevenDaysWhateverIsAsked() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: SecretHold(seconds: 10_000_000, idle: 10_000_000, maximum: 20_000_000), typedAgo: 0)
    #expect(s.status(of: "a")?.remaining == 7 * 86400)
    #expect(s.status(of: "a")?.idle == 7 * 86400)
}

@Test func anItemForTheSamePlaceReplacesTheOneOfAnotherStore() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("xless-vault:1", label: "/store", secret("old"), hold: hold, typedAgo: 0)
    try s.put("xless-vault:2", label: "/other", secret("other"), hold: hold, typedAgo: 0)
    try s.put("xless-vault:3", label: "/store", secret("new"), hold: hold, typedAgo: 0)
    #expect(s.get("xless-vault:1") == nil)
    #expect(s.get("xless-vault:2") != nil)
    #expect(s.get("xless-vault:3") != nil)
}

@Test func itemsAreDroppedByNameOrPrefixAndAllAtOnce() throws {
    let clock = TestClock(), s = state(clock)
    for name in ["xless-vault:1", "xless-vault:2", "xless-apple-session", "xless-apple-session-key"] {
        try s.put(name, label: name, secret("x"), hold: hold, typedAgo: 0)
    }
    #expect(s.drop(prefix: "xless-vault:") == 2)
    #expect(s.drop(prefix: "xless-vault:") == 0)
    #expect(s.drop(prefix: "xless-apple-session") == 2)
    #expect(s.isEmpty)
}

@Test func aDroppedItemsBytesAreZeroed() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    let held = try #require(s.heldBytes("a")) // the agent's own buffer
    #expect(held.utf8String() == "one")
    s.wipe()
    #expect(held.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    #expect(s.isEmpty)
}

@Test func theNumberAndSizeOfItemsAreBounded() throws {
    let clock = TestClock(), s = state(clock)
    for i in 0..<AgentLimits.items { try s.put("n\(i)", label: "", secret("x"), hold: hold, typedAgo: 0) }
    #expect(throws: AgentError.self) { try s.put("one-more", label: "", secret("x"), hold: hold, typedAgo: 0) }
    try s.put("n0", label: "", secret("y"), hold: hold, typedAgo: 0) // replacing is fine
    let s2 = state(clock)
    #expect(throws: AgentError.self) { try s2.put("big", label: "", SecretBytes(count: AgentLimits.itemBytes + 1), hold: hold, typedAgo: 0) }
    #expect(throws: AgentError.self) { try s2.put(String(repeating: "n", count: 201), label: "", secret("x"), hold: hold, typedAgo: 0) }
    #expect(throws: AgentError.self) { try s2.put("", label: "", secret("x"), hold: hold, typedAgo: 0) }
    #expect(throws: AgentError.self) { try s2.put("zero", label: "", secret("x"), hold: SecretHold(seconds: 0, idle: 1, maximum: 1), typedAgo: 0) }
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

@Test func lookingIsNotUsing() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("a", label: "", secret("one"), hold: hold, typedAgo: 0)
    clock.advance(599)
    #expect(s.get("a", using: false) != nil)
    clock.advance(1)
    #expect(s.get("a", using: false) == nil)
}

@Test func whatIsForOnePlaceCanBeDropped() throws {
    let clock = TestClock(), s = state(clock)
    try s.put("xless-vault:1", label: "/one", secret("x"), hold: hold, typedAgo: 0)
    try s.put("xless-vault:2", label: "/two", secret("y"), hold: hold, typedAgo: 0)
    #expect(s.drop(prefix: "xless-vault:", label: "/one") == 1)
    #expect(s.get("xless-vault:2") != nil)
    #expect(s.drop(prefix: "xless-vault:") == 1)
}
