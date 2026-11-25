import CXlessProcess
import Foundation
import XlessCore

/// A secret an agent is started with.
public struct AgentSeed: Sendable {
    public let name: String
    public let label: String
    public let secret: SecretBytes
    public let hold: SecretHold

    public init(name: String, label: String, secret: SecretBytes, hold: SecretHold) {
        self.name = name; self.label = label; self.secret = secret; self.hold = hold
    }
}

/// What an agent does besides waiting for its time to run out.
public struct AgentLocking: Sendable, Equatable {
    public var onSleep: Bool
    public var onScreenLock: Bool

    public init(onSleep: Bool = true, onScreenLock: Bool = true) { self.onSleep = onSleep; self.onScreenLock = onScreenLock }
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
    public static func obstacle() -> AgentError? {
        let session = AgentSession.current
        guard session.isUsable else {
            return AgentError(.unavailable, "this terminal session has no leader the xless agent could watch", fix: "run it in an interactive shell")
        }
        guard session.id != getpid() else {
            return AgentError(.unavailable, "xless leads its own session here (docker exec, ssh <host> xless …), which ends with it", fix: "run it in a shell that stays open")
        }
        #if os(Linux)
        let pidfd = xless_pidfd_open(getpid())
        guard pidfd >= 0 else {
            return AgentError(.unavailable, "the xless agent needs Linux 5.3 or newer (pidfd_open: \(String(cString: strerror(-pidfd))))",
                              fix: "use a shorter time, which the kernel keyring can keep")
        }
        close(pidfd)
        #endif
        return nil
    }

    /// Starts an agent that holds `seeds` for this session. Returns once it listens.
    static func start(_ seeds: [AgentSeed], directory: AgentDirectory, locking: AgentLocking, executable: String? = nil) throws {
        if let obstacle = obstacle() { throw obstacle }
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
        w.put(locking.onSleep)
        w.put(locking.onScreenLock)
        w.put(UInt32(seeds.count))
        for seed in seeds {
            w.put(seed.name); w.put(seed.label)
            w.put(seed.hold.seconds); w.put(seed.hold.idle); w.put(seed.hold.maximum)
            w.put(secret: seed.secret)
        }
        mine.send(w.frame(code: .configure))
        guard let answer = try mine.wait(limit: AgentLimits.smallMessage, milliseconds: 10_000) else {
            throw AgentError(.unavailable, "the xless agent did not start in time", fix: "try again")
        }
        guard answer.code == .ok else {
            let (_, text) = try answer.body { (try $0.uint8(), try $0.string(max: 2048)) }
            throw AgentError(.unavailable, text, fix: "fix that, or use a shorter time where a kernel keyring can keep it")
        }
    }

    private static func failure(_ what: String, _ code: Int32) -> AgentError {
        AgentError(.unavailable, "cannot start the xless agent (\(what): \(String(cString: strerror(code))))", fix: "try again")
    }
}
