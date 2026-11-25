import CXlessProcess
import Foundation

/// How xless starts every tool it runs (`Shell.run`, Swift Build's `swbuild`): the build tools run code xless did not
/// write (SwiftPM plugins and macros, cargo build scripts, npm scripts, build phases), so none of them may reach what
/// xless holds for itself.
///
/// - **A POSIX session of its own** (setsid), with no controlling terminal. A process can only leave its session for a
///   new one, so neither the tool nor anything it starts is ever again in the terminal's session, the one the xless
///   agent serves (`XlessAgent`): it cannot get a held unlock or Apple ID session, even by running xless. Its standard
///   input is never a terminal: without one of its own, nothing would stop it from reading what is typed there.
/// - **An empty session keyring.** The child starts in a fresh, empty session keyring, so a remembered store unlock or a
///   kept Apple ID session (possessor-only keys in the user's session keyring) and the agent's access token are out of
///   its reach and its descendants'. xless itself keeps the user's keyring: a later stage still finds a remembered unlock.
/// - **`XLESS_NO_SECRET_STORE=1`**, so an xless the build runs never opens the store (and leaves the keyring too).
/// - **No secret variable**: `Shell.scrubbedEnvironment` (the registered secrets and every name the run resolved).
/// - **xless is not dumpable** (`SecretScope`): the child cannot attach to xless or read its memory or its environment
///   (`/proc/<pid>/environ`, which holds the secret variables it was started with).
public enum ChildProcess {
    /// The variable that keeps a nested xless out of the secret store (read in `main`).
    public static let noSecretStore = "XLESS_NO_SECRET_STORE"

    /// A child's environment: `base` without the secret variables, then `extra` (nil removes), then
    /// `XLESS_NO_SECRET_STORE=1`, which nothing overrides.
    public static func environment(_ base: [String: String], extra: [String: String?] = [:]) -> [String: String] {
        var environment = base
        for name in Shell.scrubbedEnvironment { environment[name] = nil }
        for (k, v) in extra { environment[k] = v }
        environment[noSecretStore] = "1"
        return environment
    }

    /// Starts `executable` (an absolute path) in a session of its own and a fresh, empty session keyring. Where there is no
    /// keyring to hide (macOS, a container whose seccomp profile blocks the calls), it keeps xless's; where there is one but
    /// a new one cannot be joined, the child is not started: `XlessError(stage)`.
    /// - Parameters:
    ///   - environment: the whole environment (`environment(_:extra:)`).
    ///   - stdout, stderr: descriptors for the tool's output and error output (nil: xless's own).
    @discardableResult
    public static func start(_ executable: String, _ arguments: [String], environment: [String: String], cwd: URL? = nil,
                             stdout: Int32? = nil, stderr: Int32? = nil, stage: Stage) throws -> ToolProcess {
        SecretScope.enter()
        let spawn = { @Sendable in
            try ToolProcess(executable: executable, arguments: arguments, environment: environment, cwd: cwd, stdout: stdout, stderr: stderr)
        }
        #if os(Linux)
        guard KernelKeyring.isAvailable else { return try spawn() }
        // Linux credentials (the session keyring among them) are per thread, and a forked child gets the credentials of
        // the thread that forked it: this thread joins a new anonymous keyring, starts the child and ends. The process's
        // other threads, and so xless's own later lookups, keep the user's keyring.
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let name = (executable as NSString).lastPathComponent
        let thread = Thread {
            defer { done.signal() }
            do {
                try KernelKeyring.joinNewSession()
            } catch {
                outcome.error = XlessError(stage, "cannot start \(name) in an empty session keyring: \(error)",
                                           fix: "the build tools must not share your session keyring; check `cat /proc/sys/kernel/keys/maxkeys` and your key quota (`cat /proc/key-users`), or run `xless lock` and retry")
                return
            }
            do { outcome.tool = try spawn() } catch { outcome.error = error }
        }
        thread.start()
        done.wait()
        if let error = outcome.error { throw error }
        guard let tool = outcome.tool else { throw POSIXError(.ECHILD) }
        return tool
        #else
        return try spawn()
        #endif
    }
}

/// A tool `ChildProcess` started: wait for it once, from any thread.
public final class ToolProcess: @unchecked Sendable {
    public let processIdentifier: pid_t
    private let lock = NSLock()
    private var status: Int32?

    fileprivate init(executable: String, arguments: [String], environment: [String: String], cwd: URL?, stdout: Int32?, stderr: Int32?) throws {
        var pid: Int32 = 0
        var started: Int32 = 0
        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        // ETXTBSY: another thread's fork still held the tool open for writing (a script written just now); it passes.
        for attempt in 0..<20 {
            started = withCStrings(argv) { a in
                withCStrings(envp) { e in xless_spawn_session(executable, a, e, cwd?.path, stdout ?? -1, stderr ?? -1, &pid) }
            }
            guard started == ETXTBSY, attempt < 19 else { break }
            usleep(50_000)
        }
        guard started == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(started), userInfo: [NSLocalizedDescriptionKey: "\(executable): \(String(cString: strerror(started)))"])
        }
        processIdentifier = pid
    }

    /// Waits for the tool: its exit status, or the number of the signal that killed it.
    @discardableResult
    public func wait() -> Int32 {
        lock.withLock {
            if let status { return status }
            var code: Int32 = -1
            _ = xless_wait(processIdentifier, &code)
            status = code
            return code
        }
    }
}

/// `body` with `strings` as a NULL-terminated C array.
public func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private final class Outcome: @unchecked Sendable {
    var error: Error?
    var tool: ToolProcess?
}
