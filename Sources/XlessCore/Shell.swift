import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Shell {
    /// Secrets never handed to child processes: builds run third-party package code (SwiftPM macros and plugins,
    /// unsandboxed on Linux), and signing/notarization get their keys through 0600 temp files instead.
    public static let scrubbedEnvironment: [String] = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "XLESS_DIST_KEY", "XLESS_DEVID_KEY", "XLESS_INSTALLER_KEY"]
        .flatMap { [$0, "\($0)_FILE"] }
    /// Runs `executable` (resolved via PATH) with `arguments`. Throws XlessError(stage) on non-zero exit.
    /// The child inherits `baseEnvironment` (default: this process's environment; tests inject one instead of mutating the process) minus `scrubbedEnvironment`, plus `env` (explicit entries win;
    /// a nil value removes a variable). passthrough: stream output to the terminal instead of capturing it.
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + arguments
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = baseEnvironment
        for name in scrubbedEnvironment { environment[name] = nil }
        for (k, v) in env { environment[k] = v }
        p.environment = environment

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-shell-\(UUID().uuidString)")
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
            p.standardOutput = pipes[0].0
            p.standardError = pipes[1].0
        } else if !passthrough {
            p.standardOutput = out
            p.standardError = err
        }
        do { try p.run() } catch {
            try? log?.close()
            throw XlessError(stage, "cannot start \(executable): \(error)", fix: "install \(executable) or check PATH")
        }
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
        p.waitUntilExit()
        readers.wait()
        try? log?.close()
        try out.close()
        try err.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if p.terminationStatus != 0 {
            let tail = stderr.split(separator: "\n").filter(keepErrorLine).suffix(20).joined(separator: "\n")
            throw XlessError(stage, "`\(executable) \(arguments.joined(separator: " "))` exited with \(p.terminationStatus)\(tail.isEmpty ? "" : ":\n\(tail)")",
                             fix: "see the tool output above")
        }
        return ShellResult(status: p.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
