import Foundation

/// One run per work copy. A run holds a lock on its work copy, ~/.cache/xless/locks/<hash>.lock: its PID, the start time of
/// that process (so a reused PID is not taken for it), its host (for the messages) and, while a step runs, the step's. A run on
/// a work copy that a live run holds is refused. A SIGKILL leaves no chance to clean up, so the next run on that work copy takes
/// the lock over and stops what the killed run left: the step it recorded, the secrets it wrote, and every container labelled
/// xless.work=<hash> (every run that labels a container so holds the lock while it runs).
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
        owner = "pid=\(me)\nstarted=\(host.started(me))\nhost=\(host.hostName)\nwork=\(key)\n"
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
            old.split(separator: "\n").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) } ?? ""
        }
        let pid = field("pid"), started = field("started")
        if holds(Int32(pid) ?? 0, started) {
            throw RunStop.usage("the work copy \(key) is in use by another run (pid \(pid) on \(field("host")), started \(started)); wait for it to end, or stop it: kill \(pid)")
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
        let step = field("job").split(separator: " ", maxSplits: 1).map(String.init)
        if step.count == 2, let job = Int32(step[0]), isProcess(job, step[1]) {
            host.say("==> stopping its step (pid \(job))")
            RunCleanup.stopTree(job, host)
            for _ in 0..<50 where isProcess(job, step[1]) { host.pause(0.1) }
            guard !isProcess(job, step[1]) else { throw RunStop.usage("the step of the run that held the work copy \(key) (pid \(job)) does not stop; stop it: kill -9 \(job)") }
        }
        // The secrets it wrote from the store: their run directory is the first line of the file it recorded.
        let file = field("secrets_out")
        var isDirectory: ObjCBool = false
        if !file.isEmpty, let left = RunCleanup.firstLine(file), RunText.isSecretsDirectory(left),
           FileManager.default.fileExists(atPath: left, isDirectory: &isDirectory), isDirectory.boolValue {
            host.say("==> removing the secrets it left in \(left)")
            host.removeTree(left)
        }
    }

    /// `pid` runs, and is the process that started then (not a reused PID).
    private func isProcess(_ pid: Int32, _ started: String) -> Bool {
        !started.isEmpty && host.started(pid) == started && host.isRunning(pid)
    }

    /// The run that wrote a lock is alive. When in doubt, it is: a start time that cannot be told, or one that moved (a clock
    /// stepped under a long build), still counts for a PID that runs xless (or the script that did this before).
    private func holds(_ pid: Int32, _ started: String) -> Bool {
        guard pid > 0, host.isRunning(pid) else { return false }
        let now = host.started(pid)
        if started.isEmpty || now.isEmpty || started == now { return true }
        let command = host.commandLine(pid)
        return command.contains("testflight.sh") || command.wholeMatch(of: /.*xless[^ ]* (run|docker)( .*)?/) != nil
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
            let text = owner + (job.map { "job=\($0) \(host.started($0))\n" } ?? "")
            let aside = "\(path).\(host.processID)"
            if (try? Data(text.utf8).write(to: URL(fileURLWithPath: aside))) != nil { _ = host.rename(aside, path) }
        }
    }
}
