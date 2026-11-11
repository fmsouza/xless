import CXlessProcess

/// Keeps the sign-in's secrets out of core dumps: `ulimit -c 0` for this process and, on Linux, not dumpable, so no
/// crash and no other process of the same user (ptrace, /proc/<pid>/mem) can read its memory.
public enum CoreDumps {
    public static func disable() { _ = xless_disable_core_dumps() }

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
