import CXlessProcess

/// Memory file systems (tmpfs, ramfs): where secrets may be written for a run without ever reaching a disk.
public enum MemoryFileSystem {
    /// Whether `path` is on one (Linux); false on error and on other systems.
    public static func contains(_ path: String) -> Bool { xless_is_memory_fs(path) == 1 }
}
