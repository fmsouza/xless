import Foundation

/// How xless starts every tool it runs (`Shell.run`, Swift Build's `swbuild`): the build tools run code xless did not
/// write (SwiftPM plugins and macros, cargo build scripts, npm scripts, build phases), so none of them may reach what
/// xless holds for itself.
///
/// - **An empty session keyring.** The child starts in a fresh, empty session keyring, so a remembered store unlock or a
///   kept Apple ID session (possessor-only keys in the user's session keyring) is out of its reach and its
///   descendants'. xless itself keeps the user's keyring: a later stage still finds a remembered unlock.
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

    /// Starts `process` (`Process.run()`) in a fresh, empty session keyring. Where there is no keyring to hide (macOS,
    /// a container whose seccomp profile blocks the calls), it starts as is; where there is one but a new one cannot be
    /// joined, the child is not started: `XlessError(stage)`.
    public static func start(_ process: Process, stage: Stage) throws {
        SecretScope.enter()
        #if os(Linux)
        guard KernelKeyring.isAvailable else { return try process.run() }
        primeProcessManager
        // Linux credentials (the session keyring among them) are per thread, and a spawned child gets the credentials of
        // the thread that spawned it: this thread joins a new anonymous keyring, starts the child and ends. The process's
        // other threads, and so xless's own later lookups, keep the user's keyring.
        let outcome = Outcome()
        nonisolated(unsafe) let child = process
        let done = DispatchSemaphore(value: 0)
        let name = process.executableURL?.lastPathComponent ?? "a tool"
        let thread = Thread {
            defer { done.signal() }
            do {
                try KernelKeyring.joinNewSession()
            } catch {
                outcome.error = XlessError(stage, "cannot start \(name) in an empty session keyring: \(error)",
                                           fix: "the build tools must not share your session keyring; check `cat /proc/sys/kernel/keys/maxkeys` and your key quota (`cat /proc/key-users`), or run `xless secrets lock` and `xless auth logout` and retry")
                return
            }
            do { try child.run() } catch { outcome.error = error }
        }
        thread.start()
        done.wait()
        if let error = outcome.error { throw error }
        #else
        try process.run()
        #endif
    }
}

#if os(Linux)
/// swift-corelibs-foundation starts its process manager thread in the first `Process.run()` of the process, from the
/// calling thread, whose credentials it inherits; that thread lives as long as the process and starts the termination
/// handlers' threads. Started from the thread that joined an empty keyring, it (and they) would have lost the user's
/// keyring: a later stage would ask the passphrase again. So the first isolated start makes corelibs set it up from the
/// caller's thread: `run()` sets the manager up before it checks the executable, and with none set it starts nothing.
private let primeProcessManager: Void = { _ = try? Process().run() }()
#endif

private final class Outcome: @unchecked Sendable {
    var error: Error?
}
