#if os(Windows)
import CXlessWindows
import Foundation
#else
import CXlessProcess
#endif

/// The process hardening every command that reads a secret enters before it does (Apple ID sign-in, API keys, signing
/// keys): no core file (`RLIMIT_CORE` 0, on Linux 1, inherited by the tools it runs, which get keys too) and, on Linux, not dumpable
/// (`PR_SET_DUMPABLE` 0), so no crash and no other process of the same user (ptrace, /proc/<pid>/mem) can read its memory.
///
/// There is no way out of the scope: secrets are not kept longer than the command, and neither is the process. Entering
/// it again is harmless. `Secrets` enters it whenever it hands out a value, so a stage reading a key is covered even if
/// its command did not enter the scope itself.
///
/// On Windows, which has neither, it is what `xless_disable_core_dumps` of CXlessWindows says. There a process that cannot be kept
/// from leaving a secret in an error report gets none: `enter` ends it.
public enum SecretScope {
    #if os(Windows)
    public static func enter() {
        guard let refused = refusal(xless_disable_core_dumps()) else { return }
        FileHandle.standardError.write(Data((refused.description + "\n").utf8))
        exit(refused.exitCode)
    }

    /// Why no secret is read, or nil: what `xless_disable_core_dumps` answers is which of its steps Windows refused.
    static func refusal(_ step: Int32) -> XlessError? {
        guard step != 0 else { return nil }
        return XlessError(.config, "Windows does not let xless keep secrets out of error reports (step \(step)); none is read",
                          fix: "run xless where error reporting can be changed by a program (not under a policy that forbids it)")
    }

    /// What is in force (`XLESS_HARDENED_*`).
    static var hardening: UInt32 { xless_hardening() }
    #else
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
    #endif
}
