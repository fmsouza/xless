import Foundation

/// Writes a file that this process, or a child it starts, runs next: a script, a wrapper, a test's stand-in tool.
///
/// Linux refuses to start a file that any process holds open for writing (`ETXTBSY`, "Text file busy"). A descriptor
/// this process opens is copied into every child that another of its threads starts meanwhile, and stays open there
/// until that child's exec, however briefly; so a script written with `Data.write` and run right after fails now and
/// then in a process that starts children from several threads at once (the test suite does, and failed so in CI).
/// Here this process never opens the executable at all: the contents go to a staging file next to it, which is never
/// run, a short-lived `cp` makes the executable from that (its only writer is that child, which has exited when `cp`
/// returns), and a rename puts it in place, replacing any file of that name.
public enum ExecutableFile {
    public static func write(_ contents: Data, to url: URL, mode: mode_t = 0o755, stage: Stage) throws {
        let fm = FileManager.default
        let tag = "\(url.lastPathComponent).\(UUID().uuidString)"
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(tag).contents")
        let made = url.deletingLastPathComponent().appendingPathComponent(".\(tag).new")
        defer {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: made)
        }
        try contents.write(to: staged)
        try Shell.run("/bin/cp", [staged.path, made.path], stage: stage)
        guard chmod(made.path, mode) == 0, rename(made.path, url.path) == 0 else {
            throw XlessError(stage, "cannot write the executable \(url.path): \(String(cString: strerror(errno)))",
                             fix: "check that its directory is writable")
        }
    }

    public static func write(_ text: String, to url: URL, mode: mode_t = 0o755, stage: Stage) throws {
        try write(Data(text.utf8), to: url, mode: mode, stage: stage)
    }
}
