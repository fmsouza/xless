import Foundation
import Testing
import XlessAgent
import XlessCore
@testable import xless

private let refused = XlessError(.config, "no", fix: "-")

@Test func lockingRunsEveryStepAndThenReports() {
    var ran: [String] = []
    let all = LockCommand.lock(agents: { ran.append("agents"); return AgentLocked(ended: 1, unanswered: [AgentUnanswered(pid: 77, path: "/d/a.sock")]) },
                               keys: { ran.append("keys"); throw refused }, saved: { ran.append("saved"); return true })
    #expect(ran == ["agents", "keys", "saved"])
    #expect(all.dropped == 2)
    #expect(all.failures.count == 2)
    #expect(all.failures[0].cause.contains("77") && all.failures[0].fix.contains("kill -9 77"), "\(all.failures)")
    #expect(all.failures[1].cause == "no")
    // What the directory of the agents says is no reason to leave the rest.
    ran = []
    let unsafe = LockCommand.lock(agents: { throw AgentError(.unsafePath, "somebody else's", fix: "-") }, keys: { ran.append("keys"); return 3 }, saved: { ran.append("saved"); return false })
    #expect(ran == ["keys", "saved"])
    #expect(unsafe.dropped == 3 && unsafe.failures.map(\.cause) == ["somebody else's"])
}

@Test func severalFailuresOfLockingAreOneError() {
    let one = LockCommand.error([refused])
    #expect(one?.cause == "no" && one?.stage == .config)
    let two = LockCommand.error([refused, XlessError(.config, "nor this", fix: "do that")])
    #expect(two?.cause == "no; nor this")
    #expect(LockCommand.error([]) == nil)
}
