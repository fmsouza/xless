import Foundation

/// One run per work copy. A run holds a lock on its work copy, ~/.cache/xless/locks/<hash>.lock: its PID, the start time of
/// that process, the system's own mark of it and the program it runs (so a reused PID is not taken for it), the machine it is on,
/// where its secrets are and, while a step runs, the step's PID. A run on a work copy that a live run holds, or may hold, is refused. A SIGKILL leaves no
/// chance to clean up, so the next run on that work copy takes the lock over and stops what the killed run left: the step it
/// recorded, the secrets it wrote, and every container labelled xless.work=<hash> (every run that labels a container so holds
/// the lock while it runs).
final class WorkCopyLock {
    private let host: any RunHost
    private let cleanup: RunCleanup
    private let path: String
    private var owner: String

    static func hash(of key: String) -> String { String(RunText.sha256(key).prefix(12)) }

    /// Takes the lock of the work copy `key` names (a path, or a docker volume). `docker`: the words that run docker, and their
    /// environment, when the run is in containers.
    init(_ key: String, home: String, docker: (cli: [String], environment: [String: String])?, host: any RunHost, cleanup: RunCleanup) throws {
        self.host = host
        self.cleanup = cleanup
        let hash = Self.hash(of: key), directory = "\(home)/.cache/xless/locks", me = host.processID
        let lock = "\(directory)/\(hash).lock", new = "\(directory)/\(hash).\(me)"
        path = lock
        owner = "pid=\(me)\nstarted=\(host.started(me))\nhost=\(host.hostName)\nmark=\(host.mark(me))\nprogram=\(host.programFile(me))\nmachine=\(host.machine)\nwork=\(key)\n"
        cleanup.change { $0.temporary += [new, "\(new).new", "\(lock).\(me)"] }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(owner.utf8).write(to: URL(fileURLWithPath: new))
        } catch { throw RunStop.usage("cannot create \(directory), for the lock of the work copy \(key)") }
        // A hard link: created whole, and only when no lock is there.
        let held = cleanup.change { state in
            let held = host.link(new, lock)
            if held { state.lock = lock }
            return held
        }
        if !held { try takeOver(key, new: new) }
        if let (cli, environment) = docker {
            let ids = RunCleanup.containers(cli, environment, label: "xless.work=\(hash)", host)
            if !ids.isEmpty {
                host.say("==> work copy \(key): removing the containers a gone run left on it: \(ids.joined(separator: " "))")
                guard RunCleanup.remove(ids, cli, environment, host) else {
                    throw RunStop.usage("could not remove the containers a gone run left on the work copy \(key); remove them with: \((cli + ["rm", "-f"] + ids).joined(separator: " "))")
                }
            }
        }
    }

    private func takeOver(_ key: String, new: String) throws {
        let takeover = "\(path).takeover"
        guard let old = try? String(contentsOfFile: path, encoding: .utf8) else { throw RunStop.usage("cannot take the lock \(path) of the work copy \(key)") }
        func field(_ name: String) -> String {
            RunText.lines(old).lazy.compactMap { RunText.value(of: "\(name)=", in: $0) }.first ?? ""
        }
        let pid = field("pid"), started = field("started")
        let who = "another run (pid \(pid) on \(field("host")), started \(started))"
        let isHere = field("host") == host.hostName || !host.machine.isEmpty && field("machine") == host.machine
        // The step it was at, and the secrets it wrote from the store: where they are, and in the file it recorded before they were
        // (the first line). Nothing else has them once the lock is gone.
        let job = Self.job(field("job")), mark = field("jobmark")
        func isJob(_ job: (pid: Int32, started: String)) -> Bool { isProcess(job.pid, job.started, mark) }
        let secrets = [field("secrets"), field("secrets_out").isEmpty || !isHere ? "" : RunCleanup.firstLine(field("secrets_out")) ?? ""]
            .first { RunText.isSecretsDirectory($0) && (!isHere || Self.isDirectory($0)) }
        switch state(Int32(pid) ?? 0, elsewhere: isHere ? nil : field("host"), started: started, mark: field("mark"), program: field("program")) {
        case .gone: break
        case .live: throw RunStop.usage("the work copy \(key) is in use by \(who); wait for it to end, or stop it: kill \(pid)")
        case .unsure(let why):
            let there = isHere ? "" : "on \(field("host")): "
            var first = ""
            if let job, !isHere || isJob(job) { first += "stop its step, if it still runs (\(there)kill \(job.pid)), then " }
            if let what = secrets.map(RunText.quoted) ?? (isHere || field("secrets_out").isEmpty ? nil : "\"$(head -n 1 \(RunText.quoted(field("secrets_out"))))\"") {
                first += "remove the secrets that it may have left (\(there)rm -rf \(what)), then "
            }
            throw RunStop.usage("the work copy \(key) may be in use by \(who): \(why); wait for it to end, or stop it; when no run works there any more, \(first)remove \(path) and run again")
        }
        // That run is gone: take the lock over, one taker at a time (the .takeover directory). The lock is replaced by a rename,
        // so it never disappears and no new run can take it in between.
        let taken = cleanup.change { state in
            guard host.makeDirectory(takeover) else { return false }
            state.takeover = takeover
            defer { host.removeEmptyDirectory(takeover); state.takeover = nil }
            guard (try? String(contentsOfFile: path, encoding: .utf8)) == old,
                  (try? Data(owner.utf8).write(to: URL(fileURLWithPath: "\(new).new"))) != nil, host.rename("\(new).new", path) else { return false }
            state.lock = path
            return true
        }
        guard taken else { throw RunStop.usage("another run is taking over the work copy \(key); run again (if none is, remove \(takeover))") }
        host.say("==> work copy \(key): the run that held it (pid \(pid)) is gone without cleaning up; stopping what it left")
        if let job, isJob(job) {
            host.say("==> stopping its step (pid \(job.pid))")
            RunCleanup.stopTree(job.pid, host)
            for _ in 0..<50 where isJob(job) { host.pause(0.1) }
            guard !isJob(job) else { throw RunStop.usage("the step of the run that held the work copy \(key) (pid \(job.pid)) does not stop; stop it: kill -9 \(job.pid)") }
        }
        if let secrets {
            host.say("==> removing the secrets it left in \(secrets)")
            host.removeTree(secrets)
        }
    }

    /// `job=`: a PID and when it started.
    private static func job(_ text: String) -> (pid: Int32, started: String)? {
        let parts = RunText.cut(text, at: " ", max: 1, keepingEmpty: true)
        return parts.count == 2 ? Int32(parts[0]).map { ($0, parts[1]) } : nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `pid` runs, and is the process that started then (not a reused PID): by the system's mark of it, and where there is none by
    /// the time.
    private func isProcess(_ pid: Int32, _ started: String, _ mark: String) -> Bool {
        guard host.isRunning(pid) else { return false }
        let now = host.mark(pid)
        return mark.isEmpty || now.isEmpty ? !started.isEmpty && host.started(pid) == started : mark == now
    }

    private enum RunState { case live, gone, unsure(String) }

    /// Whether the run that wrote a lock is alive, as far as that is seen from this machine. The system's mark says so; where one of them has none, it is
    /// gone only when its PID is not there any more, or is another process's by its start time (which alone moves with the clock:
    /// one stepped under a long build) and by what that one runs.
    private func state(_ pid: Int32, elsewhere machine: String?, started: String, mark: String, program: String) -> RunState {
        guard pid > 0 else { return .unsure("its lock says no process") }
        if let machine { return .unsure("it is on \(machine), and this machine's name is \(host.hostName)") }
        guard pid != host.processID, host.isRunning(pid) else { return .gone }
        let now = (started: host.started(pid), mark: host.mark(pid), program: host.programFile(pid))
        if !mark.isEmpty, !now.mark.isEmpty { return mark == now.mark ? .live : .gone }
        if !started.isEmpty, started == now.started { return .live }
        if started.isEmpty || now.started.isEmpty || now.program.isEmpty || isRun(now.program, host.commandLine(pid), program) {
            return .unsure("pid \(pid) runs, and it cannot be told whether it is that run")
        }
        return .gone
    }

    /// Whether a process may be a run: it runs the program that wrote the lock, or an xless (also one that an upgrade replaced), or
    /// is a shell that runs the script that did this before. (A word of its arguments alone says nothing.)
    private func isRun(_ file: String, _ command: String, _ program: String) -> Bool {
        func isXless(_ word: String) -> Bool { ["xless", "xless (deleted)"].contains(RunFiles.name(word)) }
        if !program.isEmpty, file == program || file == "\(program) (deleted)" { return true }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if isXless(file) || words.first.map(isXless) == true { return true }
        // What an interpreter runs: the first of its words that is no option.
        guard let runs = words.dropFirst().first(where: { !RunText.has("-", before: $0) }) else { return false }
        let interpreter = RunFiles.name(file)
        if RunText.has("qemu-", before: interpreter) { return isXless(runs) }
        return ["sh", "bash", "dash", "zsh", "ksh", "busybox"].contains(interpreter) && RunFiles.name(runs) == "testflight.sh"
    }

    /// A line of the lock, for the run that takes it over if this one is killed.
    func note(_ line: String) {
        owner += line + "\n"
        note(job: nil)
    }

    /// The step that runs. Best effort: a lock without its step still guards the work copy. (Written aside, then renamed: never
    /// read half-written; and only while the lock is still this run's.)
    func note(job: Int32?) {
        cleanup.change { _ in
            guard RunCleanup.isOwn(path, host) else { return }
            let text = owner + (job.map { "job=\($0) \(host.started($0))\njobmark=\(host.mark($0))\n" } ?? "")
            let aside = "\(path).\(host.processID)"
            if (try? Data(text.utf8).write(to: URL(fileURLWithPath: aside))) != nil { _ = host.rename(aside, path) }
        }
    }
}
