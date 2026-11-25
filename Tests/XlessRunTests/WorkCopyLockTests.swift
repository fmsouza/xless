import Foundation
import Testing
@testable import XlessRun

@Suite struct WorkCopyLockTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    private var key: String { home.project }
    private var path: String { "\(home.home)/.cache/xless/locks/\(WorkCopyLock.hash(of: key)).lock" }

    private func leave(pid: Int32, started: String = "Mon Nov 23 10:00:00 2026", more: String = "") throws {
        try FileManager.default.createDirectory(atPath: RunFiles.parent(path), withIntermediateDirectories: true)
        try Data("pid=\(pid)\nstarted=\(started)\nhost=there\nwork=\(key)\n\(more)".utf8).write(to: URL(fileURLWithPath: path))
    }

    private func run(_ host: FakeRunHost, docker: Bool = false) throws -> Int32 {
        try home.run([home.project, "--to", "finalize"], docker: docker, host: host)
    }

    @Test func aRunHoldsItsWorkCopyAndNamesItsStep() throws {
        let path = path
        let host = FakeRunHost { host, step in
            guard step.words.contains("ship") else { return (0, "") }
            let lock = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return (lock.contains("pid=4242\nstarted=Tue Nov 24 09:00:00 2026\nhost=here\n") && lock.contains("\njob=50") ? 0 : 1, "")
        }
        #expect(try run(host) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: RunFiles.parent(path)).isEmpty)
    }

    @Test func aLiveRunIsNotDisturbed() throws {
        let runs = FakeRunHost.Process(started: "Mon Nov 23 10:00:00 2026", command: "anything")
        for (process, started) in [(runs, runs.started), (.init(started: "", command: "x"), runs.started), (runs, ""),
                                   // a clock that stepped: still a run of xless
                                   (.init(command: "/a/b/xless run p"), "then"), (.init(command: "bash /s/scripts/testflight.sh p"), "then")] {
            try leave(pid: 77, started: started)
            let host = FakeRunHost(processes: [77: process])
            #expect(try run(host) == 2)
            #expect(host.lines.last?.contains("is in use by another run (pid 77 on there") == true, "\(host.lines)")
            #expect(host.killed.isEmpty && home.exists(path))
        }
    }

    @Test func aGoneRunsLeftoversAreStopped() throws {
        let secrets = home.secrets
        try FileManager.default.createDirectory(atPath: "\(secrets)/sign", withIntermediateDirectories: true)
        let out = try home.write("out", "\(secrets)\n")
        try leave(pid: 77, more: "secrets_out=\(out)\njob=88 Mon Nov 23 10:00:01 2026\n")
        // 77 is another process by now
        let host = FakeRunHost(processes: [77: .init(), 88: .init(started: "Mon Nov 23 10:00:01 2026", children: [89]), 89: .init()]) { _, step in
            step.line.contains("label=xless.work=") ? (0, "c0ffee dead\n") : (0, "")
        }
        #expect(try run(host, docker: true) == 0)
        #expect(host.killed == [89, 88] && !home.exists(secrets))
        #expect(host.allSteps.contains { $0.line == "docker rm -f c0ffee dead" })
        #expect(!home.exists(path) && !home.exists("\(path).takeover"))
    }

    /// A lock names a directory to remove: only one that a run's secrets were written to.
    @Test func nothingElseIsRemovedAsSecrets() throws {
        let precious = "\(home.root)/precious"
        try FileManager.default.createDirectory(atPath: precious, withIntermediateDirectories: true)
        try leave(pid: 77, more: "secrets_out=\(try home.write("out", precious))\n")
        #expect(try run(FakeRunHost()) == 0)
        #expect(home.exists(precious))
    }

    @Test func aStepThatDoesNotStopIsNotBuiltOver() throws {
        try leave(pid: 77, more: "job=88 then\n")
        let host = FakeRunHost(processes: [88: .init(started: "then", stubborn: true)])
        #expect(try run(host) == 2)
        #expect(host.lines.last?.contains("does not stop; stop it: kill -9 88") == true && !host.allSteps.contains { $0.words.contains("ship") })
    }

    @Test func oneRunTakesOverAtATime() throws {
        try leave(pid: 77)
        try FileManager.default.createDirectory(atPath: "\(path).takeover", withIntermediateDirectories: true)
        let host = FakeRunHost()
        #expect(try run(host) == 2)
        #expect(host.lines.last?.contains("another run is taking over") == true && home.exists("\(path).takeover") && home.exists(path))
    }
}
