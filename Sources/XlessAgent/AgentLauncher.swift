import CXlessProcess
import Foundation
import XlessCore

/// A secret an agent is started with.
public struct AgentSeed: Sendable {
    public let name: String
    public let label: String
    public let secret: SecretBytes
    public let hold: SecretHold
    /// The seconds since it was typed, rounded up: 0 only when it was typed for this.
    public let typedAgo: Int

    public init(name: String, label: String, secret: SecretBytes, hold: SecretHold, typedAgo: Int = 0) {
        self.name = name; self.label = label; self.secret = secret; self.hold = hold; self.typedAgo = typedAgo
    }
}

/// What a command's settings (`unlock:` in config.yml) ask of an agent it uses: an agent keeps to the strictest of those
/// it was told, for as long as it runs.
public struct AgentTerms: Sendable, Equatable {
    /// The longest anything is held after it was typed, in seconds.
    public var maximum: Int
    public var lockOnSleep: Bool
    public var lockOnScreenLock: Bool

    public init(maximum: Int = HoldDuration.maximum, lockOnSleep: Bool = true, lockOnScreenLock: Bool = true) {
        self.maximum = maximum; self.lockOnSleep = lockOnSleep; self.lockOnScreenLock = lockOnScreenLock
    }

    init(_ r: inout WireReader) throws { self.init(maximum: try r.int(), lockOnSleep: try r.bool(), lockOnScreenLock: try r.bool()) }

    func write(_ w: inout WireWriter) {
        w.put(maximum)
        w.put(lockOnSleep)
        w.put(lockOnScreenLock)
    }
}

/// Starts an agent: this very program, detached, in this POSIX session (so the two can tell each other from everything
/// in another one), with an empty environment. What it holds goes over a socket pair made for it only.
public enum AgentLauncher {
    /// The one argument of an agent. It does nothing for anyone but the command that made its channel.
    public static let argument = "__agent"
    static let channel: Int32 = 3

    /// This program's file.
    static var executablePath: String? {
        #if os(macOS)
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
        #else
        // What this process runs, even when the file was replaced since.
        return "/proc/self/exe"
        #endif
    }

    /// Why no agent can serve this process's session; nil when one can.
    /// - Parameter lease: for one that ends with this process (`xless session`), which may lead the session.
    public static func obstacle(session: AgentSession = .current, lease: Bool = false) -> AgentError? {
        guard session.isUsable else {
            return AgentError(.unavailable, "this terminal session has no leader the xless agent could watch", fix: "run it in an interactive shell")
        }
        guard lease || session.id != getpid() else {
            return AgentError(.unavailable, "xless leads its own session here (docker exec, ssh <host> xless …), which ends with it", fix: "run it in a shell that stays open")
        }
        #if os(Linux)
        let pidfd = xless_pidfd_open(getpid())
        guard pidfd >= 0 else {
            return AgentError(.unavailable, "the xless agent needs Linux 5.3 or newer (pidfd_open: \(String(cString: strerror(-pidfd))))",
                              fix: "use a newer kernel")
        }
        close(pidfd)
        #endif
        return nil
    }

    /// Starts an agent that holds `seeds` for this session. Returns once it listens.
    static func start(_ seeds: [AgentSeed], directory: AgentDirectory, terms: AgentTerms, executable: String? = nil) throws {
        _ = try start(seeds, directory: directory, terms: terms, lease: false, executable: executable)
    }

    /// Starts one that ends with this process.
    static func lease(_ seeds: [AgentSeed], directory: AgentDirectory, terms: AgentTerms, executable: String? = nil) throws -> AgentLease {
        let (channel, path) = try start(seeds, directory: directory, terms: terms, lease: true, executable: executable)
        return AgentLease(channel: channel, path: path)
    }

    private static func start(_ seeds: [AgentSeed], directory: AgentDirectory, terms: AgentTerms, lease: Bool,
                              executable: String?) throws -> (AgentChannel, String) {
        if let obstacle = obstacle(lease: lease) { throw obstacle }
        guard let program = executable ?? executablePath else {
            throw AgentError(.unavailable, "xless does not find its own program file to start its agent", fix: "run it by its full path")
        }
        try directory.prepare()
        var fds: [Int32] = [-1, -1]
        guard xless_unix_pair(&fds) == 0 else { throw failure("socketpair", errno) }
        let mine = try AgentChannel(fd: fds[0])
        let error = withCStrings(["xless", argument]) { xless_spawn_detached(program, $0, fds[1], 1) }
        close(fds[1])
        guard error == 0 else { throw failure(program, error) }
        var w = WireWriter()
        w.put(directory.path)
        w.put(Int64(AgentSession.current.id))
        w.put(lease)
        terms.write(&w)
        w.put(UInt32(seeds.count))
        for seed in seeds {
            w.put(seed.name); w.put(seed.label)
            w.put(seed.hold.seconds); w.put(seed.hold.idle); w.put(seed.hold.maximum)
            w.put(seed.typedAgo)
            w.put(secret: seed.secret)
        }
        mine.send(w.frame(code: .configure))
        guard let answer = try mine.wait(limit: AgentLimits.smallMessage, milliseconds: 10_000) else {
            throw AgentError(.failed, "the xless agent did not start in time", fix: "try again")
        }
        guard answer.code == .ok else {
            let (why, text) = try answer.body { (try $0.uint8(), try $0.string(max: 2048)) }
            throw AgentError(AgentRefusal(rawValue: why) == .unavailable ? .unavailable : .failed, text, fix: "fix that, and try again")
        }
        return (mine, try answer.body { try $0.string(max: 4096) })
    }

    private static func failure(_ what: String, _ code: Int32) -> AgentError {
        AgentError(.failed, "cannot start the xless agent (\(what): \(String(cString: strerror(code))))", fix: "try again")
    }
}

/// The process's end of an agent it started for itself. The agent ends when this is closed: by `end`, by `deinit`, or by
/// the kernel with the process, however that ends.
public final class AgentLease: @unchecked Sendable {
    /// The agent's socket.
    public let path: String
    private let lock = NSLock()
    private var channel: AgentChannel?

    init(channel: AgentChannel, path: String) { self.channel = channel; self.path = path }

    /// Has the agent drop everything and end, and waits (two seconds at most) until it has.
    public func end() {
        guard let channel = lock.withLock({ () -> AgentChannel? in defer { self.channel = nil }; return self.channel }) else { return }
        shutdown(channel.fd, Int32(SHUT_WR))
        _ = try? channel.wait(limit: AgentLimits.smallMessage, milliseconds: 2000) // nothing comes but its end
        channel.end()
    }
}
