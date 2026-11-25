import Foundation

/// One run per work copy. A run holds a lock on its work copy, ~/.cache/xless/locks/<hash>.lock: its PID, the start time of
/// that process, the system's own mark of it and the program it runs (so a reused PID is not taken for it), the machine and the
/// PID namespace it is in, where its secrets are and, while a step runs, the step's PID. A run on a work copy that a live run holds, or may hold, is refused. A SIGKILL leaves no
/// chance to clean up, so the next run on that work copy takes the lock over and stops what the killed run left: the step it
/// recorded, the secrets it wrote, the copy it kept of a project's configuration, and every container labelled xless.work=<hash> (every run that labels a container so holds
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
        owner = "pid=\(me)\nstarted=\(host.started(me))\nhost=\(host.hostName)\nmark=\(host.mark(me))\nprogram=\(host.programFile(me))\nmachine=\(host.machine)\nnamespace=\(host.namespace)\nwork=\(key)\n"
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
        if !held { try takeOver(key, new: new, home: home) }
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

    private func takeOver(_ key: String, new: String, home: String) throws {
        let takeover = "\(path).takeover"
        guard let old = try? String(contentsOfFile: path, encoding: .utf8) else { throw RunStop.usage("cannot take the lock \(path) of the work copy \(key)") }
        func field(_ name: String) -> String {
            RunText.lines(old).lazy.compactMap { RunText.value(of: "\(name)=", in: $0) }.first ?? ""
        }
        let pid = field("pid"), started = field("started")
        let who = "another run (pid \(pid) on \(field("host")), started \(started))"
        let mark = field("mark")
        let place = place(name: field("host"), machine: field("machine"), namespace: field("namespace"), mark: mark)
        var isHere = true
        if case .unsure = place { isHere = false }
        // The step it was at, by the system's mark of it where the lock has the run's too.
        let jobMark = field("jobmark")
        let job = mark.isEmpty || !jobMark.isEmpty ? self.job(field("job")) : nil
        func isJob(_ job: (pid: Int32, started: String)) -> Bool { isProcess(job.pid, job.started, jobMark) }
        // The secrets it wrote from the store: where they are, or in the file it recorded before they were (the first line). Nothing
        // else has them once the lock is gone.
        let out = field("secrets").isEmpty ? field("secrets_out") : "", real = field("secrets_real")
        let printed = out.isEmpty ? field("secrets") : isHere ? host.ownFile(out).map(RunCleanup.firstLine(of:)) : nil
        let secrets = printed.map { isHere ? self.secrets($0, real: real, follows: !out.isEmpty) : [Secrets(path: real.isEmpty ? $0 : real)] } ?? []
        let unread = "the directory \u{2026}/xless/<32 hex digits> that the first line of \(RunText.quoted(out)) "
            + (isHere ? "named, which cannot be read; they are made in xless in $XDG_RUNTIME_DIR, or in xless/secrets in $XDG_CACHE_HOME or ~/.cache" : "names")
        switch state(Int32(pid) ?? 0, in: place, namespace: field("namespace"), started: started, mark: mark, program: field("program")) {
        case .gone: break
        case .live: throw RunStop.usage("the work copy \(key) is in use by \(who); wait for it to end, or stop it: kill \(pid)")
        case .unsure(let why):
            let there = isHere ? "" : field("host") == host.hostName ? "where it runs: " : "on \(field("host")): "
            var first = ""
            if let job, !isHere || isJob(job) { first += "stop its step, if it still runs (\(there)kill \(job.pid)\(isHere || job.started.isEmpty ? "" : ", the process that started \(job.started)")), then " }
            for left in secrets where RunText.isAbsolute(left.path) {
                let path = RunText.quoted(left.path), remove = RunText.isNamedAsSecrets(left.path) ? "rm -rf \(path)" : nil
                if left.doubt == nil, let remove {
                    first += "remove the secrets that it may have left (\(there)\(remove)), then "
                } else {
                    let how = [there.isEmpty ? nil : String(there.dropLast(2)), remove.map { "if so: \($0)" }].compactMap { $0 }.joined(separator: ", ")
                    first += "look whether it left secrets in \(path)\(how.isEmpty ? "" : " (\(how))"), then "
                }
            }
            if printed == nil {
                first += "\(isHere ? "look for" : "remove") the secrets that it may have left (\(there)\(unread)), then "
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
        var failures: [String] = []
        if let job, isJob(job) {
            host.say("==> stopping its step (pid \(job.pid))")
            RunCleanup.stopTree(job.pid, host)
            for _ in 0..<50 where isJob(job) { host.pause(0.1) }
            if isJob(job) { failures.append("the step of the run that held the work copy \(key) (pid \(job.pid)) does not stop; stop it: kill -9 \(job.pid)") }
        }
        // Removed or named, whatever else fails: the lock does not say them any more.
        for left in secrets {
            let path = RunText.quoted(left.path)
            if let doubt = left.doubt {
                let remove = RunText.isNamedAsSecrets(left.path) ? ", and if that is what it left: rm -rf \(path)" : ""
                host.say("==> note: \(left.path), where it may have left secrets, is not removed: \(doubt); look what is in it\(remove)")
                continue
            }
            host.removeTree(left.path)
            if Self.isThere(left.path) {
                failures.insert("could not remove the secrets that the run that held the work copy \(key) left in \(left.path); remove them with: rm -rf \(path)", at: 0)
            } else {
                host.say("==> removed the secrets it left in \(left.path)")
            }
        }
        // The xless.yml of a run in containers: only a private directory of this user's, where a run makes it.
        let configuration = field("configuration")
        var kind = stat()
        if RunText.isConfigurationDirectory(configuration, home: home), lstat(configuration, &kind) == 0, kind.st_uid == geteuid(),
           kind.st_mode & (S_IFMT | 0o777) == S_IFDIR | 0o700 {
            host.say("==> removing the xless.yml it left in \(configuration)")
            host.removeTree(configuration)
        }
        if printed == nil { host.say("==> note: secrets that it may have left are not removed: look for \(unread)") }
        for failure in failures.dropLast() { host.say("testflight: \(failure)") }
        if let failure = failures.last { throw RunStop.usage(failure) }
    }

    /// Secrets that a run may have left, and why they are not removed unseen; nil: they are.
    private struct Secrets {
        var path: String
        var doubt: String?
    }

    /// What is there of the secrets that a run on this machine wrote to `printed`, as `materialize` said it, which is the directory
    /// `real` (empty: it was not recorded; then, if `follows`, the one that `printed` leads to now). Only a directory of a run's
    /// form that still leads there, and is this user's alone there, is removed.
    private func secrets(_ printed: String, real: String, follows: Bool) -> [Secrets] {
        guard RunText.isAbsolute(printed) else { return [] }
        let now = host.realPath(printed), target = !real.isEmpty ? real : follows ? now ?? printed : printed
        let isSame = now?.utf8.elementsEqual(target.utf8) == true
        let doubt: String? = if !RunText.isSecretsDirectory(printed) {
            "its name is not that of a run's secrets"
        } else if !isSame, !real.isEmpty {
            "\(printed) does not lead there as it did"
        } else if !isSame || !Self.isDirectory(printed) || !host.isPrivateDirectory(target) {
            "it is no directory that only you may use, or there is a link in its path"
        } else { nil }
        if doubt == nil { return [Secrets(path: target)] }
        var there: [Secrets] = []
        for path in [target, now ?? printed] where Self.isThere(path) && !there.contains(where: { host.isSame($0.path, path) ?? ($0.path == path) }) {
            there.append(Secrets(path: path, doubt: doubt))
        }
        // Not there: gone with the run, or behind a link to what is not there now (a disk).
        if there.isEmpty, let link = Self.deadLink(printed) ?? Self.deadLink(target) { there = [Secrets(path: target, doubt: "\(link) leads nowhere now")] }
        return there
    }

    /// The first part of a path that is a link which leads nowhere; nil: there is none.
    private static func deadLink(_ path: String) -> String? {
        var path = path
        while path.utf8.count > 1, !isThere(path) { path = RunFiles.parent(path) }
        return isThere(path) && !FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// A directory, and no link to one.
    private static func isDirectory(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// `job=`: a PID and when it started. Never the process that all others are under, nor this one.
    private func job(_ text: String) -> (pid: Int32, started: String)? {
        let parts = RunText.cut(text, at: " ", max: 1, keepingEmpty: true)
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 1, pid != host.processID else { return nil }
        return (pid, parts[1])
    }

    /// There is something at `path`, a link too.
    private static func isThere(_ path: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: path)) != nil }

    /// `pid` runs, and is the process that started then (not a reused PID): by the system's mark of it, and where there is none by
    /// the time.
    private func isProcess(_ pid: Int32, _ started: String, _ mark: String) -> Bool {
        guard host.isRunning(pid) else { return false }
        let now = host.mark(pid)
        return mark.isEmpty || now.isEmpty ? !started.isEmpty && host.started(pid) == started : mark == now
    }

    private enum RunState { case live, gone, unsure(String) }

    /// Where the run that wrote a lock is or was: among the processes of this system (live), on this machine before it was started
    /// again (gone), or where this one cannot see it. A name alone does not say which machine it is (a container may be given
    /// any), nor does an ID on Linux (a copy of a virtual machine has it too): a name that changed is the same machine's there
    /// only since the same start of the system.
    private func place(name: String, machine: String, namespace: String, mark: String) -> RunState {
        let names = "it is on \(name), and this machine's name is \(host.hostName)"
        let parts = RunText.cut(mark, at: " ", keepingEmpty: true)
        let boot = parts.count == 2 && !host.boot.isEmpty ? parts[0] : "" // the system's start, where both are known
        if machine.isEmpty || host.machine.isEmpty {
            guard name == host.hostName else { return .unsure(names) }
        } else {
            guard machine == host.machine else {
                return .unsure(name == host.hostName ? "it is on another machine of the name \(name)" : names)
            }
            guard name == host.hostName || host.isMac || boot == host.boot && !boot.isEmpty else { return .unsure(names) }
        }
        if !boot.isEmpty, boot != host.boot { return .gone }
        // (A lock that says no machine is older than these lines.)
        guard namespace == host.namespace || namespace.isEmpty && machine.isEmpty else {
            return .unsure(namespace.isEmpty || host.namespace.isEmpty ? "it cannot be told whether it is in this PID namespace"
                : "it is in another PID namespace (\(namespace)), as a container has one")
        }
        return .live
    }

    /// Whether the run that wrote a lock is alive, as far as that is seen from here. The system's mark says so; where one of them has none, it is
    /// gone only when its PID is not there any more, or is another process's by its start time (which alone moves with the clock:
    /// one stepped under a long build) and by what that one runs.
    private func state(_ pid: Int32, in place: RunState, namespace: String, started: String, mark: String, program: String) -> RunState {
        guard pid > 0 else { return .unsure("its lock says no process") }
        guard case .live = place else { return place }
        if pid == host.processID {
            return host.isMac || !namespace.isEmpty ? .gone : .unsure("this run has its PID, and it cannot be told whether it was in this PID namespace")
        }
        guard host.isRunning(pid) else { return .gone }
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
