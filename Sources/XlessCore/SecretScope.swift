import CXlessProcess

/// The process hardening every command that reads a secret enters before it does (Apple ID sign-in, API keys, signing
/// keys): no core file (`RLIMIT_CORE` 0, inherited by the tools it runs, which get keys too) and, on Linux, not dumpable
/// (`PR_SET_DUMPABLE` 0), so no crash and no other process of the same user (ptrace, /proc/<pid>/mem) can read its memory.
///
/// There is no way out of the scope: secrets are not kept longer than the command, and neither is the process. Entering
/// it again is harmless. `Secrets` enters it whenever it hands out a value, so a stage reading a key is covered even if
/// its command did not enter the scope itself.
public enum SecretScope {
    public static func enter() { _ = xless_disable_core_dumps() }

    /// The core file size limit (nil when unlimited).
    public static var coreFileLimit: Int64? {
        let l = xless_core_file_limit()
        return l < 0 ? nil : Int64(l)
    }

    /// Whether the process is dumpable (Linux), nil where the question does not apply.
    public static var isDumpable: Bool? {
        let d = xless_dumpable()
        return d < 0 ? nil : d != 0
    }
}
