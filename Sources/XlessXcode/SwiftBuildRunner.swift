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

    /// The `swbuild` that builds: the Xcode pack's (`SwiftBuildEnvironment.swbuild`), else the first on `path`.
    static func swbuild(_ environment: SwiftBuildEnvironment, path: String?, stage: Stage) throws -> URL {
        guard let swbuild = environment.swbuild ?? XcodeEnvironment.which("swbuild", path: path) else {
            throw XlessError(stage, "Swift Build is not here: the Xcode pack has no swbuild, and none is on PATH",
                             fix: "xless setup --xcode <path to Xcode's .app or .xip> prepares the Swift Build part of its pack")
        }
        return swbuild
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
        let swbuild = try swbuild(environment, path: env["PATH"], stage: stage)
        let status: Int32
        do {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let out = try FileHandle(forWritingTo: log)
            defer { try? out.close() }
            status = try ChildProcess.start(swbuild.path, ["build", pif.path, "--derivedDataPath", derivedData.path, "--buildRequestFile", request.path],
                                            environment: env, stdout: out.fileDescriptor, stage: stage).wait()
        } catch let e as XlessError {
            throw e
        } catch {
            throw XlessError(stage, "cannot run \(swbuild.path): \(error)", fix: "xless setup --xcode <path to Xcode's .app or .xip> prepares the Swift Build part of its pack again")
        }
        let data = (try? Data(contentsOf: log)) ?? Data()
        var summary = SwiftBuildOutput.summarize(data)
        if status != 0 { summary.succeeded = false }
        return summary
    }
}
