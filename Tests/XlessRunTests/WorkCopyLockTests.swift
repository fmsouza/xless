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

    /// A directory of secrets, as `materialize` makes one.
    private func makeSecrets(_ path: String? = nil) throws -> String {
        let path = path ?? home.secrets
        try FileManager.default.createDirectory(atPath: "\(path)/sign", withIntermediateDirectories: true)
        chmod(path, 0o700)
        return path
    }

    private func run(_ host: FakeRunHost, docker: Bool = false) throws -> Int32 {
        try home.run([home.project, "--to", "finalize"], docker: docker, host: host)
    }

    @Test func aRunHoldsItsWorkCopyAndNamesItsStep() throws {
        let path = path
        let host = FakeRunHost { host, step in
            guard step.words.contains("ship") else { return (0, "") }
            let lock = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return (lock.contains("pid=4242\nstarted=Tue Nov 24 09:00:00 2026\nhost=here\nmark=own mark\nprogram=/own/xless\nmachine=this one\nnamespace=pid:[1]\nwork=")
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
                                                  (.init(mark: "boot 12"), "then", "there", "mark=boot 12\nmachine=this one\nnamespace=pid:[1]\n")] {
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
        let secrets = try makeSecrets(), out = try home.write("out", "\(secrets)\n"), old = "Mon Nov 23 10:00:00 2026"
        let sure = [Int32(77): FakeRunHost.Process(command: "xless run"), 88: .init(started: "then")]
        let job = "stop its step, if it still runs (kill 88), then ", there = "stop its step, if it still runs (on there: kill 88, the process that started then), then "
        for lines in ["secrets_out=\(out)\n", "secrets=\(secrets)\n", "secrets_out=\(out)\nsecrets=\(secrets)\n"] {
            try leave(pid: 77, started: old, more: lines + "job=88 then\n")
            try refused(FakeRunHost(processes: sure), "pid 77 runs", first: job + "remove the secrets that it may have left (rm -rf \(secrets)), then ")
            #expect(home.exists(secrets))
        }
        try leave(pid: 77, started: old, on: "there", more: "secrets_out=\(out)\nsecrets=\(secrets)\njob=88 then\n")
        try refused(FakeRunHost(), "it is on there", first: there + "remove the secrets that it may have left (on there: rm -rf \(secrets)), then ")
        try leave(pid: 77, started: old, on: "there", more: "secrets_out=/tmp/of there\n")
        try refused(FakeRunHost(), "it is on there", first: "remove the secrets that it may have left (on there: the directory \u{2026}/xless/<32 hex digits> that the first line of '/tmp/of there' names), then ")
        // on this machine, what is not there (any more) is not named
        for lines in ["secrets=\(home.root)/xless/\(String(repeating: "1b", count: 16))\n", "secrets_out=\(home.root)/none\n", "secrets=\(home.root)\n", "job=99 then\n", "job=88 before\n"] {
            try leave(pid: 77, started: old, more: lines)
            try refused(FakeRunHost(processes: sure), "pid 77 runs", lines)
        }
        // one that is not as a run's secrets are is nothing to remove unseen
        chmod(secrets, 0o755)
        try leave(pid: 77, started: old, more: "secrets=\(secrets)\n")
        try refused(FakeRunHost(processes: sure), "pid 77 runs", first: "look whether it left secrets in \(secrets), then ")
        chmod(secrets, 0o700)
        // a name that a shell would take apart
        let odd = "\(home.root)/it's $x/xless/\(String(repeating: "0a", count: 16))"
        _ = try makeSecrets(odd)
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
        // this run's own PID, in the same PID namespace
        try taken(4242, .init(started: old, command: "xless run", file: "/own/xless"), "program=/own/xless\nnamespace=pid:[1]\n")
    }

    /// What is known of the machine that a lock is from, and of the one the new run is on.
    struct Place: Sendable, CustomTestStringConvertible {
        var what: String
        var name = "here", lines = "", pid: Int32 = 77, isMac = false, machine = "this one", boot = "boot", namespace = "pid:[1]"
        var testDescription: String { what }

        func host() -> FakeRunHost {
            let host = FakeRunHost(isMac: isMac, processes: [78: .init(), 88: .init(started: "then"), 99: .init(started: "Mon Nov 23 10:00:00 2026", command: "xless run", mark: "boot 9", file: "/own/xless")])
            (host.machine, host.boot, host.namespace) = (machine, isMac ? "" : boot, isMac ? "" : namespace)
            return host
        }
    }

    /// The run is of this machine, and of its PIDs: its name may have changed, or the system been started again, since.
    @Test(arguments: [
        Place(what: "the same machine and name", lines: "machine=this one\nnamespace=pid:[1]\n"),
        Place(what: "another process has the PID", lines: "machine=this one\nnamespace=pid:[1]\n", pid: 78),
        Place(what: "a Mac by another name", name: "there", lines: "machine=this one\nnamespace=\n", isMac: true),
        Place(what: "a Mac by another name, another process has the PID", name: "there", lines: "machine=this one\n", pid: 78, isMac: true),
        Place(what: "a Mac, this run's own PID", lines: "machine=this one\n", pid: 4242, isMac: true),
        Place(what: "Linux by another name, the same boot", name: "there", lines: "machine=this one\nnamespace=pid:[1]\nmark=boot 11\n"),
        Place(what: "Linux, no boot ID to be seen", lines: "machine=this one\nnamespace=pid:[1]\nmark=\n", boot: ""),
        Place(what: "started again since", lines: "machine=this one\nnamespace=pid:[1]\nmark=before 11\n"),
        Place(what: "started again since, an xless of the same second has the PID", lines: "machine=this one\nnamespace=pid:[1]\nmark=before 9\nprogram=/own/xless\n", pid: 99),
        Place(what: "started again since, in another PID namespace", lines: "machine=this one\nnamespace=pid:[2]\nmark=before 11\n"),
        Place(what: "started again since, with this run's PID", lines: "machine=this one\nmark=before 11\n", pid: 4242),
        Place(what: "this run's own PID", lines: "machine=this one\nnamespace=pid:[1]\nmark=boot 11\n", pid: 4242),
        Place(what: "no ID in the lock"), Place(what: "no ID in the lock, started again since", lines: "mark=before 11\n"),
        Place(what: "no ID of this machine", lines: "machine=this one\nnamespace=pid:[1]\n", machine: ""),
    ]) func aGoneRunOfThisMachineIsTakenOver(_ place: Place) throws {
        let secrets = try makeSecrets()
        try leave(pid: place.pid, on: place.name, more: "\(place.lines)secrets=\(secrets)\njob=88 then\n")
        let host = place.host()
        #expect(try run(host) == 0, "\(host.lines)")
        #expect(host.lines.contains("==> removed the secrets it left in \(secrets)"))
        // (its step: a lock that has a mark says it for the step too)
        #expect(host.killed == (place.lines.contains("mark=") && !place.lines.contains("mark=\n") ? [] : [88]) && !home.exists(secrets) && !home.exists(path))
    }

    /// Another machine may have the same name (a container that was given it), or the same ID (a copy of a virtual machine); and in
    /// another PID namespace a PID that is not there says nothing.
    @Test(arguments: [
        Place(what: "Linux by another name, no boot in the lock", name: "there", lines: "machine=this one\nnamespace=pid:[1]\n"),
        Place(what: "Linux by another name, another boot", name: "there", lines: "machine=this one\nnamespace=pid:[1]\nmark=before 11\n"),
        Place(what: "Linux by another name, no boot ID to be seen", name: "there", lines: "machine=this one\nnamespace=pid:[1]\nmark=boot 11\n", boot: ""),
        Place(what: "the same name, another ID", lines: "machine=another\nnamespace=pid:[1]\nmark=boot 11\n"),
        Place(what: "the same name, another ID and boot", lines: "machine=another\nnamespace=pid:[1]\nmark=before 11\n"),
        Place(what: "a Mac of the same name, another ID", lines: "machine=another\n", isMac: true),
        Place(what: "another name, no ID in the lock", name: "there"),
        Place(what: "another name, the same boot, no ID in the lock", name: "there", lines: "mark=boot 11\n"),
        Place(what: "another name, no ID of this machine", name: "there", lines: "machine=this one\n", machine: ""),
        Place(what: "a Mac by another name, no ID in the lock", name: "there", isMac: true),
        Place(what: "another PID namespace", lines: "machine=this one\nnamespace=pid:[2]\nmark=boot 11\n"),
        Place(what: "another PID namespace, no boot in the lock", lines: "machine=this one\nnamespace=pid:[2]\n"),
        Place(what: "another PID namespace, no ID in the lock", lines: "namespace=pid:[2]\nmark=boot 11\n"),
        Place(what: "another PID namespace, this run's own PID", lines: "machine=this one\nnamespace=pid:[2]\nmark=boot 11\n", pid: 4242),
        Place(what: "no PID namespace to be seen", lines: "machine=this one\nnamespace=pid:[1]\nmark=boot 11\n", namespace: ""),
        Place(what: "this run's own PID, in what PID namespace is not said", lines: "machine=this one\nmark=boot 11\n", pid: 4242),
        Place(what: "this run's own PID, nothing else said", pid: 4242),
        Place(what: "in what PID namespace is not said", lines: "machine=this one\nmark=boot 11\n"),
        Place(what: "in what PID namespace was not known", lines: "machine=this one\nnamespace=\nmark=boot 11\n"),
    ]) func whatMayBeAnothersIsNotTakenOver(_ place: Place) throws {
        let secrets = try makeSecrets()
        try leave(pid: place.pid, on: place.name, more: "\(place.lines)secrets=\(secrets)\njob=88 then\n")
        let host = place.host()
        #expect(try run(host) == 2, "\(host.lines)")
        let last = host.lines.last ?? ""
        #expect(last.contains("may be in use by another run") && last.contains("rm -rf \(secrets)") && last.hasSuffix("remove \(path) and run again"), "\(last)")
        #expect(host.killed.isEmpty && home.exists(secrets) && home.exists(path))
    }

    /// A lock that has the system's mark of its run has it of its step too, which is never the process that all others are under.
    @Test func aStepIsNotBelievedByItsTimeWhereThereAreMarks() throws {
        for (lines, stops) in [("mark=boot 11\njob=88 then\n", false), ("mark=boot 11\njob=88 then\njobmark=\n", false), ("job=88 then\n", true),
                               ("job=1 then\n", false), ("job=1 then\njobmark=boot 1\n", false), ("job=0 then\n", false), ("job=-88 then\n", false), ("job=4242 then\n", false)] {
            try leave(pid: 77, more: lines)
            let host = FakeRunHost(processes: [1: .init(started: "then", children: [88], mark: "boot 1"), 88: .init(started: "then"), 4242: .init(started: "then")])
            #expect(try run(host) == 0)
            #expect(host.killed == (stops ? [88] : []), "\(lines)")
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
        let secrets = try makeSecrets()
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

    /// What a lock names is removed as secrets only where it is as `materialize` made it.
    @Test func onlyAPrivateDirectoryIsRemoved() throws {
        let id = String(repeating: "0c", count: 16), behind = try makeSecrets("\(home.root)/behind/xless/\(id)")
        func left(_ lines: String, _ path: String, says: Bool = true) throws {
            try leave(pid: 77, more: lines)
            let host = FakeRunHost()
            #expect(try run(host) == 0, "\(host.lines)")
            #expect(home.exists(path) && !host.lines.contains { $0.contains("removed the secrets") }, "\(lines)")
            #expect(host.lines.contains { $0.contains("is not removed: it is no directory that only you may use") } == says, "\(host.lines)")
        }
        // a link in the path, and as its last part
        try FileManager.default.createDirectory(atPath: "\(home.root)/d", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(home.root)/d/xless", withDestinationPath: "\(home.root)/behind/xless")
        try left("secrets=\(home.root)/d/xless/\(id)\n", behind)
        let link = "\(home.root)/run/xless/\(String(repeating: "0d", count: 16))"
        try FileManager.default.createDirectory(atPath: "\(home.root)/run/xless", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: behind)
        try left("secrets=\(link)\n", link)
        #expect(home.exists(behind))
        // one that others may read, and a file
        let shared = try makeSecrets("\(home.root)/run/xless/\(String(repeating: "0e", count: 16))")
        chmod(shared, 0o755)
        try left("secrets=\(shared)\n", shared)
        let file = try home.write("run/xless/\(String(repeating: "0f", count: 16))", "x")
        try left("secrets=\(file)\n", file)
        // the lock says where they are: the file does not
        let other = try makeSecrets(), out = try home.write("out", "\(other)\n")
        try left("secrets=\(home.root)/run/xless/\(String(repeating: "1a", count: 16))\nsecrets_out=\(out)\n", other, says: false)
        // a file that is no file of the run's: a link, a FIFO (which nobody writes to), a directory
        try FileManager.default.createSymbolicLink(atPath: "\(home.root)/outlink", withDestinationPath: out)
        try #require(mkfifo("\(home.root)/fifo", 0o600) == 0)
        for name in ["outlink", "fifo", "run", "none"] { try left("secrets_out=\(home.root)/\(name)\n", other, says: false) }
    }

    /// What was not removed is not said to be.
    @Test func secretsThatCannotBeRemovedStopTheRun() throws {
        let secrets = try makeSecrets()
        try leave(pid: 77, more: "secrets=\(secrets)\n")
        let host = FakeRunHost()
        host.keepsTrees = true
        #expect(try run(host) == 2)
        #expect(host.lines.last == "testflight: could not remove the secrets that the run that held the work copy \(key) left in \(secrets); remove them with: rm -rf \(secrets)")
        #expect(!host.lines.contains { $0.contains("removed the secrets") } && !host.allSteps.contains { $0.words.contains("ship") })
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
