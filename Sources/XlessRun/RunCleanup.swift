import Foundation

/// What a run must not leave behind, and its removal: when the run ends, and when it is asked to stop (SIGINT, SIGTERM,
/// SIGHUP), from whatever it is doing then.
final class RunCleanup: @unchecked Sendable {
    struct State {
        /// The step that runs.
        var job: Int32?
        /// The run's containers: the words that run docker, its environment, and the label they have. (`--rm` acts only once a
        /// container exits by itself.)
        var containers: (cli: [String], environment: [String: String], label: String)?
        /// The lock of the work copy, once it is this run's, and the directory that says one is being taken over.
        var lock: String?
        var takeover: String?
        /// The secrets written for this run: their directory, and the file `xless secrets materialize` prints it to first, even
        /// when it is stopped half-way.
        var secrets: String?
        var secretsFile: String?
        var temporary: [String] = []
    }

    private let host: any RunHost
    private let lock = NSLock()
    private var state = State()
    private var ended = false

    init(_ host: any RunHost) { self.host = host }

    /// Changes what there is to clean up, or does something that must not happen once the run is being stopped. Never comes
    /// back then: the process ends when the clean-up has.
    @discardableResult
    func change<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        while host.stopping {
            lock.unlock()
            host.pause(1)
            lock.lock()
        }
        defer { lock.unlock() }
        return try body(&state)
    }

    /// Starts a step as the one to stop: none is ever started that a stop would miss.
    func start(_ step: RunStep) throws -> StartedStep {
        try change { state in
            let started = try host.start(step)
            state.job = started.pid
            return started
        }
    }

    /// The run is over.
    func finish() {
        change { state in
            cleanUp(&state)
            ended = true
        }
    }

    /// The run is asked to stop. (The lock is not given back: nothing more happens in this process.)
    func stop(_ code: Int32) -> Never {
        lock.lock()
        if !ended { cleanUp(&state) }
        host.end(code)
    }

    private func cleanUp(_ state: inout State) {
        if let job = state.job { // and wait (5 s at most) for it, before another run may take the work copy
            Self.stopTree(job, host)
            for _ in 0..<50 where host.isRunning(job) { host.pause(0.1) }
        }
        if let (cli, environment, label) = state.containers {
            let ids = Self.containers(cli, environment, label: label, host)
            if !ids.isEmpty, !Self.remove(ids, cli, environment, host) {
                host.say("testflight: could not remove this run's containers; remove them with: \((cli + ["rm", "-f"] + ids).joined(separator: " "))")
            }
        }
        if let path = state.lock, Self.isOwn(path, host) { host.removeFile(path) }
        if let path = state.takeover { host.removeEmptyDirectory(path) }
        Self.dropSecrets(state, nil, host)
        for path in state.temporary { host.removeFile(path) }
        state = State()
    }

    /// Removes the secrets written for this run: one container's (`set`), or all of them.
    func dropSecrets(_ set: String? = nil) { change { Self.dropSecrets($0, set, host) } }

    private static func dropSecrets(_ state: State, _ set: String?, _ host: any RunHost) {
        guard let directory = state.secrets ?? state.secretsFile.flatMap(firstLine), RunText.isSecretsDirectory(directory) else { return }
        host.removeTree(set.map { "\(directory)/\($0)" } ?? directory)
    }

    static func firstLine(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8)).map { String($0.prefix { $0 != "\n" }) }
    }

    /// The lock at `path` is still this process's.
    static func isOwn(_ path: String, _ host: any RunHost) -> Bool {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").contains("pid=\(host.processID)")
    }

    /// Ends a process and every one under it, the deepest first: a step ignores the interrupt that the terminal sends to all.
    static func stopTree(_ pid: Int32, _ host: any RunHost) {
        let children = host.children()
        func stop(_ pid: Int32, _ above: Set<Int32>) {
            for child in children[pid] ?? [] where !above.contains(child) { stop(child, above.union([pid])) }
            host.terminate(pid)
        }
        stop(pid, [])
    }

    static func containers(_ cli: [String], _ environment: [String: String], label: String, _ host: any RunHost) -> [String] {
        let step = RunStep(cli + ["ps", "-aq", "--filter", "label=\(label)"], environment: environment, output: .captured, quiet: true)
        guard let started = try? host.start(step) else { return [] }
        let (code, output) = host.finish(started)
        return code == 0 ? output.split(whereSeparator: \.isWhitespace).map(String.init) : []
    }

    static func remove(_ ids: [String], _ cli: [String], _ environment: [String: String], _ host: any RunHost) -> Bool {
        guard let started = try? host.start(RunStep(cli + ["rm", "-f"] + ids, environment: environment, output: .captured)) else { return false }
        return host.finish(started).code == 0
    }
}
