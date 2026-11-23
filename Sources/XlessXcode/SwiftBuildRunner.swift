import Foundation
import XlessCore

/// Runs `swbuild build <pif> --derivedDataPath <dd> --buildRequestFile <request>` in a `SwiftBuildEnvironment`. Its
/// stdout (framed JSON messages) goes to `log`, which the caller keeps; stderr passes through.
public enum SwiftBuildRunner {
    /// Writes the environment's toolset to `<directory>/toolset.json` and returns its overrides with `extra` applied on
    /// top (an `extra` value replaces the environment's for the same setting).
    public static func prepareOverrides(_ environment: SwiftBuildEnvironment, directory dir: URL, extra: [String: String] = [:],
                                        stage: Stage) throws -> [String: String] {
        let toolset = dir.appendingPathComponent("toolset.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try environment.toolset().write(to: toolset, options: .atomic)
        } catch {
            throw XlessError(stage, "cannot write \(toolset.path): \(error.localizedDescription)", fix: "check the derived data directory")
        }
        return environment.overrides(toolset: toolset).merging(extra) { _, new in new }
    }

    /// `extraEnvironment` (applied last; nil removes) and `baseEnvironment` (default: this process's) are used by the
    /// build stage (Task 8), which adds React Native variables and runs from a scrubbed environment.
    @discardableResult
    public static func build(pif: URL, request: URL, derivedData: URL, environment: SwiftBuildEnvironment, log: URL,
                             extraEnvironment: [String: String?] = [:], stage: Stage,
                             baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> SwiftBuildOutput.Summary {
        var extra: [String: String?] = environment.processEnvironment(path: baseEnvironment["PATH"]).mapValues { $0 }
        for (k, v) in extraEnvironment { extra[k] = v }
        let env = ChildProcess.environment(baseEnvironment, extra: extra)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swbuild", "build", pif.path, "--derivedDataPath", derivedData.path, "--buildRequestFile", request.path]
        p.environment = env
        do {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let out = try FileHandle(forWritingTo: log)
            defer { try? out.close() }
            p.standardOutput = out
            try ChildProcess.start(p, stage: stage)
            p.waitUntilExit()
        } catch let e as XlessError {
            throw e
        } catch {
            throw XlessError(stage, "cannot run swbuild: \(error)", fix: "run in the xless-rn image, which has Swift Build's swbuild on PATH")
        }
        let data = (try? Data(contentsOf: log)) ?? Data()
        var summary = SwiftBuildOutput.summarize(data)
        if p.terminationStatus != 0 { summary.succeeded = false }
        return summary
    }
}
