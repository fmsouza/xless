import Foundation
import XlessCore
import XlessRun

/// The docker of the commands that talk to it from here (`xless setup`, `xless clean`, `xless sdk export`), as `xless run` chooses
/// it (`DockerContext`): the DOCKER_CONTEXT of the run's file of settings (testflight.env, whose values win there) or of the
/// environment, else colima-xless when docker has it, else docker's current one. Decided once a process; every docker command of
/// these goes through `docker(_:)`, and a command calls `check()` before it does anything.
enum HostDocker {
    typealias Ask = (_ arguments: [String], _ environment: [String: String]) -> (code: Int32, output: String)

    /// The context: nil for docker's current one.
    static func decide(environment: [String: String], read: (String) -> String?, ask: Ask) throws(DockerContext.Problem) -> String? {
        let path = ProjectRun.environmentFile(environment)
        // As the run reads it: data, never run. A file it would refuse sets nothing here; the run says why.
        let fileValue = read(path).flatMap { try? EnvFile.parse($0, environment: environment) }?.last { $0.name == DockerContext.variable }?.value
        let setting = DockerContext.setting(environment: environment, file: (path, fileValue))
        let listing = ask(DockerContext.listing, environment.filter { $0.key != DockerContext.variable })
        return try DockerContext.choose(setting, contexts: listing.code == 0 ? DockerContext.listed(listing.output) : nil)
    }

    static func error(_ problem: DockerContext.Problem) -> XlessError { XlessError(.config, problem.cause, fix: problem.fix, code: 2) }

    /// This process's.
    static let decided: Result<String?, XlessError> = {
        let environment = ProcessInfo.processInfo.environment
        do throws(DockerContext.Problem) {
            return .success(try decide(environment: environment, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) { arguments, environment in
                guard let answer = try? Shell.docker(arguments, baseEnvironment: environment, stage: .config) else { return (1, "") }
                return (0, answer.stdout)
            })
        } catch { return .failure(Self.error(error)) }
    }()

    /// Stops a command whose DOCKER_CONTEXT docker does not have, before it does anything.
    static func check() throws { _ = try decided.get() }

    /// The environment of a program that calls docker itself (scripts/docker-images.sh): the context as `--context` gives it,
    /// which a DOCKER_HOST does not override.
    static func environment(_ base: [String: String], context: String?) -> [String: String] {
        guard let context else { return base }
        var out = base
        out["DOCKER_HOST"] = nil
        out[DockerContext.variable] = context
        return out
    }

    /// This process's environment, for such a program.
    static func environment() throws -> [String: String] { environment(ProcessInfo.processInfo.environment, context: try decided.get()) }

    /// `Shell.docker` with the context.
    @discardableResult
    static func docker(_ arguments: [String], baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, stage: Stage, passthrough: Bool = false) throws -> ShellResult {
        try Shell.docker(DockerContext.arguments(decided.get()) + arguments, baseEnvironment: baseEnvironment, stage: stage, passthrough: passthrough)
    }
}
