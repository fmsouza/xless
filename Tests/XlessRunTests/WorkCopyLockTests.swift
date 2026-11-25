import Foundation
import Testing
@testable import XlessRun

@Suite struct WorkCopyLockTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    private var key: String { home.project }
    private var path: String { "\(home.home)/.cache/xless/locks/\(WorkCopyLock.hash(of: key)).lock" }

    private func leave(pid: Int32, started: String = "Mon Nov 23 10:00:00 2026", on machine: String = "here", more: String = "") throws {
        try leave("pid=\(pid)\nstarted=\(started)\nhost=\(machine)\nwork=\(key)\n\(more)")
    }

    private func leave(_ lock: String) throws {
        try FileManager.default.createDirectory(atPath: RunFiles.parent(path), withIntermediateDirectories: true)
        try Data(lock.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func run(_ host: FakeRunHost, docker: Bool = false) throws -> Int32 {
        try home.run([home.project, "--to", "finalize"], docker: docker, host: host)
    }

    @Test func aRunHoldsItsWorkCopyAndNamesItsStep() throws {
        let path = path
        let host = FakeRunHost { host, step in
            guard step.words.contains("ship") else { return (0, "") }
            let lock = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return (lock.contains("pid=4242\nstarted=Tue Nov 24 09:00:00 2026\nhost=here\nmark=own mark\nprogram=/own/xless\nwork=")
                && lock.contains("\njob=50") && lock.contains("\njobmark=") ? 0 : 1, "")
        }
        #expect(try run(host) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: RunFiles.parent(path)).isEmpty)
    }

    @Test func aLiveRunIsNotDisturbed() throws {
        let runs = FakeRunHost.Process(started: "Mon Nov 23 10:00:00 2026", command: "anything")
        for (process, started, more) in [(runs, runs.started, ""),
                                         // a clock that stepped, while the system's own mark of the process stays
                                         (.init(mark: "boot 12"), "then", "mark=boot 12\n")] {
            try leave(pid: 77, started: started, more: more)
            let host = FakeRunHost(processes: [77: process])
            #expect(try run(host) == 2)
            #expect(host.lines.last?.contains("is in use by another run (pid 77 on here, started \(started)); wait for it to end, or stop it: kill 77") == true, "\(host.lines)")
            #expect(host.killed.isEmpty && home.exists(path))
        }
    }

    /// No one value says that a run is gone: not its start time (a clock steps), nor what it was started as.
    @Test func aRunThatMayBeLiveIsNotDisturbed() throws {
        let old = "Mon Nov 23 10:00:00 2026"
        for process in [FakeRunHost.Process(command: "/a/b/xless run p"), .init(command: "/a/b/xless --no-input run --docker p"),
                        .init(command: "xless --no-input\nrun p"), .init(command: "/opt/xless-1.0/bin/xless run one\ntwo"),
                        .init(command: "qemu-x86_64 /a/xless ship"), .init(command: "bash /s/scripts/testflight.sh p"),
                        .init(command: "bash -c line\nscripts/testflight.sh"), .init(command: "ci-run run p", file: "/opt/tool"),
                        .init(command: "ci-run run p", file: "/opt/tool (deleted)"), .init(command: "another", file: "/b/xless"),
                        .init(command: "", file: ""), .init(started: "", command: "x")] {
            try leave(pid: 77, started: old, more: "mark=boot 11\nprogram=/opt/tool\n")
            try refused(FakeRunHost(processes: [77: process]), "pid 77 runs, and it cannot be told whether it is that run", "\(process)")
        }
        // one that says no start time, one on a machine with another name, and one that cannot be read
        try leave(pid: 77, started: "")
        try refused(FakeRunHost(processes: [77: .init()]), "pid 77 runs, and it cannot be told")
        try leave(pid: 77, started: old, on: "there")
        try refused(FakeRunHost(), "it is on there, and this machine's name is here")
        try leave(pid: 4242, started: old, more: "program=/opt/tool\n") // this run's own PID
        try refused(FakeRunHost(processes: [4242: .init(command: "xless run")]), "pid 4242 runs")
        for text in ["", "pid=\n", "pid=77x\nhost=here\n", "pid=-1\nhost=here\n", "pid=0\nhost=here\n", "\u{0}\u{0}"] {
            try leave(text)
            try refused(FakeRunHost(), "its lock says no process", text)
        }
    }

    private func refused(_ host: FakeRunHost, _ why: String, _ what: String = "") throws {
        #expect(try run(host) == 2, "\(what)")
        let last = host.lines.last ?? ""
        #expect(last.contains("the work copy \(key) may be in use by another run") && last.contains(why), "\(what): \(last)")
        #expect(last.hasSuffix("wait for it to end, or stop it; when no run works there any more, remove \(path) and run again"), "\(last)")
        #expect(host.killed.isEmpty && home.exists(path), "\(what)")
    }

    /// What differs in everything is another process.
    @Test func aReusedPIDIsNotTheRun() throws {
        try leave(pid: 77, more: "mark=boot 11\nprogram=/opt/xless\n")
        let host = FakeRunHost(processes: [77: .init(command: "bash -c x", mark: "boot 12", file: "/bin/bash")])
        #expect(try run(host) == 0)
        #expect(host.lines.contains { $0.contains("the run that held it (pid 77) is gone") } && host.killed.isEmpty)
    }

    /// The step of a gone run is known by the system's mark of it, also when a clock stepped since.
    @Test func aStepIsKnownByItsMark() throws {
        for (mark, stops) in [("boot 12", true), ("boot 11", false)] {
            try leave(pid: 77, more: "job=88 then\njobmark=\(mark)\n")
            let host = FakeRunHost(processes: [88: .init(started: mark == "boot 11" ? "then" : "now", mark: "boot 12")])
            #expect(try run(host) == 0)
            #expect(host.killed == (stops ? [88] : []), "\(mark)")
        }
    }

    @Test func aGoneRunsLeftoversAreStopped() throws {
        let secrets = home.secrets
        try FileManager.default.createDirectory(atPath: "\(secrets)/sign", withIntermediateDirectories: true)
        let out = try home.write("out", "\(secrets)\n")
        try leave(pid: 77, more: "secrets_out=\(out)\njob=88 Mon Nov 23 10:00:01 2026\n")
        // 77 is another process by now
        let host = FakeRunHost(processes: [77: .init(), 88: .init(started: "Mon Nov 23 10:00:01 2026", children: [89]), 89: .init()],
                               answer: home.answer { $0.line.contains("label=xless.work=") ? (0, "c0ffee dead\n") : nil })
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

    /// The xless.yml of a run in containers, which no clean-up took away: where it is, is in the lock before it is there.
    @Test func aGoneRunsConfigurationIsRemoved() throws {
        let path = path, left = Notes()
        let host = FakeRunHost(answer: home.answer { step in
            guard step.isContainer else { return nil }
            left.add((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            return nil
        })
        #expect(try home.run([home.project], docker: true, host: host, environment: home.files()) == 0)
        let lock = left.lines.joined(separator: "\n").split(separator: "\n")
        let directory = try #require(lock.first { $0.hasPrefix("configuration=") }).dropFirst("configuration=".count).description
        #expect(RunFiles.parent(directory) == "\(home.home)/.cache/xless/run" && !home.exists(directory))
        // as a run that is killed leaves it
        try make(directory)
        try leave(pid: 77, more: "configuration=\(directory)\n")
        #expect(try run(FakeRunHost()) == 0)
        #expect(!home.exists(directory))
        // one that a live run has
        try make(directory)
        try leave(pid: 77, more: "configuration=\(directory)\n")
        #expect(try run(FakeRunHost(processes: [77: .init(started: "Mon Nov 23 10:00:00 2026")])) == 2)
        #expect(home.exists(directory))
    }

    /// And nothing else: only a private directory of this user's, where a run makes it.
    @Test func nothingElseIsRemovedAsAConfiguration() throws {
        let id = String(repeating: "0a", count: 16), base = "\(home.home)/.cache/xless/run"
        let precious = ["\(home.root)/precious", "\(home.root)/run/\(id)", "\(base)/other", "\(base)/\(id.uppercased())", "\(base)/\(id)/\(id)", "\(base)/\(id)0"]
        for directory in precious { try make(directory) }
        for named in precious + [base, "\(base)/", "\(base)/..", "\(base)/../run/\(id)", "\(base)/./\(id)", "\(base)//\(id)", "\(base)/\(id)/", "/", ""] {
            try leave(pid: 77, more: "configuration=\(named)\n")
            #expect(try run(FakeRunHost()) == 0)
            for directory in precious { #expect(home.exists("\(directory)/xless.yml"), "\(named)") }
        }
        // open to others, a file, and a link to a directory that is private
        for mode in [0o755, 0o770, 0o600] as [mode_t] {
            let open = "\(base)/\(String(repeating: "0b", count: 16))"
            try make(open)
            #expect(chmod(open, mode) == 0)
            try leave(pid: 77, more: "configuration=\(open)\n")
            #expect(try run(FakeRunHost()) == 0)
            #expect(home.exists(open), "\(mode)")
            #expect(chmod(open, 0o700) == 0)
            guard getuid() == 0 else { continue }
            #expect(chown(open, 1, 1) == 0)
            try leave(pid: 77, more: "configuration=\(open)\n")
            #expect(try run(FakeRunHost()) == 0)
            #expect(home.exists(open), "another user's")
            #expect(chown(open, 0, 0) == 0)
        }
        let file = "\(base)/\(String(repeating: "0c", count: 16))", link = "\(base)/\(String(repeating: "0d", count: 16))"
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: precious[0])
        for named in [file, link] {
            try leave(pid: 77, more: "configuration=\(named)\n")
            #expect(try run(FakeRunHost()) == 0)
            #expect((try? FileManager.default.attributesOfItem(atPath: named)) != nil && home.exists("\(precious[0])/xless.yml"), "\(named)")
        }
    }

    private func make(_ directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        #expect(chmod(directory, 0o700) == 0)
        try Data("name: App\n".utf8).write(to: URL(fileURLWithPath: "\(directory)/xless.yml"))
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
