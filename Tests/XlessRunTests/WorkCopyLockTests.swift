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
            return (lock.contains("pid=4242\nstarted=Tue Nov 24 09:00:00 2026\nhost=here\nmark=own mark\nprogram=/own/xless\nmachine=this one\nwork=")
                && lock.contains("\njob=50") && lock.contains("\njobmark=") ? 0 : 1, "")
        }
        #expect(try run(host) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: RunFiles.parent(path)).isEmpty)
    }

    @Test func aLiveRunIsNotDisturbed() throws {
        let runs = FakeRunHost.Process(started: "Mon Nov 23 10:00:00 2026", command: "anything")
        for (process, started, machine, more) in [(runs, runs.started, "here", ""),
                                                  // a clock that stepped, while the system's own mark of the process stays
                                                  (.init(mark: "boot 12"), "then", "here", "mark=boot 12\n"),
                                                  // a machine that had another name
                                                  (.init(mark: "boot 12"), "then", "there", "mark=boot 12\nmachine=this one\n")] {
            try leave(pid: 77, started: started, on: machine, more: more)
            let host = FakeRunHost(processes: [77: process])
            #expect(try run(host) == 2)
            #expect(host.lines.last?.contains("is in use by another run (pid 77 on \(machine), started \(started)); wait for it to end, or stop it: kill 77") == true, "\(host.lines)")
            #expect(host.killed.isEmpty && home.exists(path))
        }
    }

    /// Where its secrets are is in the lock itself too: the file that `materialize` prints it to may be gone, or on another machine.
    @Test func aRunNotesItsSecrets() throws {
        let path = path, answer = home.answer(), locks = Notes()
        let host = FakeRunHost { host, step in
            if step.isContainer { locks.add((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") }
            return answer(host, step)
        }
        #expect(try home.run([home.project], docker: true, host: host) == 0, "\(host.lines)")
        #expect(locks.lines.count == 1 && locks.lines[0].contains("\nsecrets_out=/") && locks.lines[0].contains("\nsecrets=\(home.secrets)\n"), "\(locks.lines)")
    }

    /// Where the system does not say which process it is, its start time alone does not say that a run is gone (a clock steps), nor
    /// what it was started as that it is not one.
    @Test func aRunThatMayBeLiveIsNotDisturbed() throws {
        let old = "Mon Nov 23 10:00:00 2026"
        for process in [FakeRunHost.Process(command: "/a/b/xless run p"), .init(command: "/a/b/xless --no-input run --docker p"),
                        .init(command: "xless --no-input\nrun p"), .init(command: "/opt/xless-1.0/bin/xless run one\ntwo"),
                        .init(command: "qemu-x86_64 /a/xless ship", file: "/usr/bin/qemu-x86_64"), .init(command: "bash /s/scripts/testflight.sh p", file: "/bin/bash"),
                        .init(command: "/bin/sh -e testflight.sh p", file: "/usr/bin/dash"), .init(command: "ci-run run p", file: "/opt/tool"),
                        .init(command: "ci-run run p", file: "/opt/tool (deleted)"), .init(command: "another", file: "/b/xless"),
                        .init(command: "another", file: "/b/xless (deleted)"), .init(command: "", file: ""), .init(started: "", command: "x")] {
            try leave(pid: 77, started: old, more: "mark=boot 11\nprogram=/opt/tool\n")
            try refused(FakeRunHost(processes: [77: process]), "pid 77 runs, and it cannot be told whether it is that run", "\(process)")
        }
        // one that says no start time, one on another machine (as far as that can be told), and one that cannot be read
        try leave(pid: 77, started: "")
        try refused(FakeRunHost(processes: [77: .init()]), "pid 77 runs, and it cannot be told")
        for machine in ["", "machine=\n", "machine=that one\n"] {
            try leave(pid: 77, started: old, on: "there", more: machine)
            try refused(FakeRunHost(), "it is on there, and this machine's name is here", machine)
        }
        for text in ["", "pid=\n", "pid=77x\nhost=here\n", "pid=-1\nhost=here\n", "pid=0\nhost=here\n", "\u{0}\u{0}"] {
            try leave(text)
            try refused(FakeRunHost(), "its lock says no process", text)
        }
    }

    private func refused(_ host: FakeRunHost, _ why: String, _ what: String = "", first: String = "") throws {
        #expect(try run(host) == 2, "\(what)")
        let last = host.lines.last ?? ""
        #expect(last.contains("the work copy \(key) may be in use by another run") && last.contains(why), "\(what): \(last)")
        #expect(last.hasSuffix("wait for it to end, or stop it; when no run works there any more, \(first)remove \(path) and run again"), "\(last)")
        #expect(host.killed.isEmpty && home.exists(path), "\(what)")
    }

    /// A refused run says what is left once the lock is gone, which is the only place that has it.
    @Test func aRefusalNamesWhatTheOtherRunMayHaveLeft() throws {
        let secrets = home.secrets, out = try home.write("out", "\(secrets)\n"), old = "Mon Nov 23 10:00:00 2026"
        try FileManager.default.createDirectory(atPath: "\(secrets)/sign", withIntermediateDirectories: true)
        let sure = [Int32(77): FakeRunHost.Process(command: "xless run"), 88: .init(started: "then")]
        let job = "stop its step, if it still runs (kill 88), then ", there = "stop its step, if it still runs (on there: kill 88), then "
        for lines in ["secrets_out=\(out)\n", "secrets=\(secrets)\n", "secrets_out=\(out)\nsecrets=\(secrets)\n"] {
            try leave(pid: 77, started: old, more: lines + "job=88 then\n")
            try refused(FakeRunHost(processes: sure), "pid 77 runs", first: job + "remove the secrets that it may have left (rm -rf \(secrets)), then ")
            #expect(home.exists(secrets))
        }
        try leave(pid: 77, started: old, on: "there", more: "secrets_out=\(out)\nsecrets=\(secrets)\njob=88 then\n")
        try refused(FakeRunHost(), "it is on there", first: there + "remove the secrets that it may have left (on there: rm -rf \(secrets)), then ")
        try leave(pid: 77, started: old, on: "there", more: "secrets_out=/tmp/of there\n")
        try refused(FakeRunHost(), "it is on there", first: "remove the secrets that it may have left (on there: rm -rf \"$(head -n 1 '/tmp/of there')\"), then ")
        // on this machine, what is not there (any more) is not named
        for lines in ["secrets=\(home.root)/xless/\(String(repeating: "1b", count: 16))\n", "secrets_out=\(home.root)/none\n", "secrets=\(home.root)\n", "job=99 then\n", "job=88 before\n"] {
            try leave(pid: 77, started: old, more: lines)
            try refused(FakeRunHost(processes: sure), "pid 77 runs", lines)
        }
        // a name that a shell would take apart
        let odd = "\(home.root)/it's $x/xless/\(String(repeating: "0a", count: 16))"
        try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        try leave(pid: 77, started: old, more: "secrets=\(odd)\n")
        try refused(FakeRunHost(processes: sure), "pid 77 runs", first: "remove the secrets that it may have left (rm -rf '\(home.root)/it'\\''s $x/xless/\(String(repeating: "0a", count: 16))'), then ")
    }

    /// Another process has its PID: the system's mark of it says so, whatever else they share; or everything else does.
    @Test func aReusedPIDIsNotTheRun() throws {
        let old = "Mon Nov 23 10:00:00 2026"
        func taken(_ pid: Int32, _ process: FakeRunHost.Process, _ more: String) throws {
            try leave(pid: pid, started: old, more: more)
            let host = FakeRunHost(processes: [pid: process])
            #expect(try run(host) == 0, "\(process): \(host.lines)")
            #expect(host.lines.contains { $0.contains("the run that held it (pid \(pid)) is gone") } && host.killed.isEmpty, "\(process)")
        }
        let marks = "mark=boot 11\nprogram=/opt/xless\n"
        try taken(77, .init(command: "bash -c x", mark: "boot 12", file: "/bin/bash"), marks)
        try taken(77, .init(started: old, command: "/opt/xless run p", mark: "boot 12", file: "/opt/xless"), marks)
        try taken(77, .init(command: "xless run", mark: "boot 12", file: ""), marks)
        // no mark of one of them
        for (command, file) in [("vim /p/xless.yml", "/usr/bin/vim"), ("less xless", "/usr/bin/less"), ("tail -f /var/log/xless/run.log", "/usr/bin/tail"),
                                ("vim scripts/testflight.sh", "/usr/bin/vim"), ("bash -c cd xless; make", "/bin/bash"), ("bash ./other.sh testflight.sh", "/bin/bash"),
                                ("qemu-x86_64 /bin/sh xless", "/usr/bin/qemu-x86_64"), ("node /srv/xless-docs/serve.js xless", "/usr/bin/node"), ("/opt/xless-docs/bin/serve", "/opt/xless-docs/bin/serve")] {
            try taken(77, .init(command: command, file: file), "program=/opt/tool\n")
            try taken(77, .init(command: command, file: file), "")
        }
        // this run's own PID, as in a container that was started again
        try taken(4242, .init(started: old, command: "xless run", file: "/own/xless"), "program=/own/xless\n")
    }

    /// The machine is known by what does not move with the network: its name may have.
    @Test(arguments: ["machine=this one\n", "machine=another\n", ""]) func aGoneRunOfThisMachineIsTakenOver(_ machine: String) throws {
        let secrets = home.secrets
        try FileManager.default.createDirectory(atPath: "\(secrets)/sign", withIntermediateDirectories: true)
        let named = machine == "machine=this one\n" // else by its name
        for pid: Int32 in [77, 78] {
            try leave(pid: pid, on: named ? "there" : "here", more: "\(machine)secrets=\(secrets)\njob=88 then\n")
            let host = FakeRunHost(processes: [78: .init(), 88: .init(started: "then")])
            #expect(try run(host) == 0)
            #expect(host.killed == [88] && !home.exists(secrets) && !home.exists(path))
        }
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
