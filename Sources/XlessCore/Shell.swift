import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Shell {
    /// Secrets never handed to child processes: builds run third-party package code (SwiftPM macros and plugins,
    /// unsandboxed on Linux), and signing/notarization get their keys through 0600 temp files instead. The list is
    /// `SecretEnvironment`'s registry: a new secret is added there.
    public static var scrubbedEnvironment: [String] { SecretEnvironment.scrubbed }
    /// Runs `executable` (resolved via PATH) with `arguments`. Throws XlessError(stage) on non-zero exit.
    /// The child inherits `baseEnvironment` (default: this process's environment; tests inject one instead of mutating the process) minus `scrubbedEnvironment`, plus `env` (explicit entries win;
    /// a nil value removes a variable), plus `XLESS_NO_SECRET_STORE=1`; it starts in a session of its own, with no terminal,
    /// and an empty session keyring (`ChildProcess`). passthrough: stream output to the terminal instead of capturing it.
    /// captureTo: stream stdout and stderr to the terminal (like passthrough) and also write both, in order, to this file, so a caller
    /// can parse the full output (the error's tail keeps only 20 lines); the run returns once both pipes have ended.
    /// keepErrorLine: which stderr lines may appear in the error's 20-line tail (drops known noise, e.g. a linker
    /// warning repeated per input, so the real error stays visible).
    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, env: [String: String?] = [:],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        stage: Stage, passthrough: Bool = false, captureTo: URL? = nil, keepErrorLine: (Substring) -> Bool = { _ in true }
    ) throws -> ShellResult {
        let environment = ChildProcess.environment(baseEnvironment, extra: env)

        let tmp = Files.temporary.appendingPathComponent("xless-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("out"), errURL = tmp.appendingPathComponent("err")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        // captureTo: one reader per pipe copies its data, as it arrives, to the terminal stream and to `log` (one handle,
        // writes serialised by `lock`) until the pipe ends, which is when its last writer closes it: a background child
        // may still write after the process exited. The run waits for both readers, so no tail is lost.
        var log: FileHandle?
        let readers = DispatchGroup()
        var pipes: [(Pipe, FileHandle)] = []
        if let captureTo {
            _ = FileManager.default.createFile(atPath: captureTo.path, contents: nil)
            log = try FileHandle(forWritingTo: captureTo)
            pipes = [(Pipe(), FileHandle.standardOutput), (Pipe(), FileHandle.standardError)]
        }
        let streams: [FileHandle?] = pipes.isEmpty ? (passthrough ? [nil, nil] : [out, err]) : pipes.map(\.0.fileHandleForWriting)
        let p: ToolProcess
        do {
            p = try ChildProcess.start("/usr/bin/env", [executable] + arguments, environment: environment, cwd: cwd,
                                       stdout: streams[0]?.fileDescriptor, stderr: streams[1]?.fileDescriptor, stage: stage)
        } catch let e as XlessError {
            try? log?.close()
            throw e
        } catch {
            try? log?.close()
            throw XlessError(stage, "cannot start \(executable): \(error)", fix: "install \(executable) or check PATH")
        }
        for (pipe, _) in pipes { try? pipe.fileHandleForWriting.close() } // the tool's now: the pipe ends with its last writer
        if let log {
            let lock = NSLock()
            for (pipe, terminal) in pipes {
                let source = pipe.fileHandleForReading
                DispatchQueue.global().async(group: readers) {
                    while true {
                        let d = source.availableData
                        if d.isEmpty { break }
                        lock.lock(); terminal.write(d); log.write(d); lock.unlock()
                    }
                }
            }
        }
        let status = p.wait()
        readers.wait()
        try? log?.close()
        try out.close()
        try err.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if status != 0 {
            let tail = stderr.split(separator: "\n").filter(keepErrorLine).suffix(20).joined(separator: "\n")
            throw XlessError(stage, "`\(TerminalText.escaped("\(executable) \(arguments.joined(separator: " "))"))` exited with \(status)\(tail.isEmpty ? "" : ":\n\(tail)")",
                             fix: "see the tool output above")
        }
        return ShellResult(status: status, stdout: stdout, stderr: stderr)
    }
}
