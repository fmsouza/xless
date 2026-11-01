import ArgumentParser
import XlessASC
import XlessCore

extension Stage: ExpressibleByArgument {}

struct ShipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ship", abstract: "Run [prepare →] build → assets → finalize → sign → package → upload (upload: iOS only); --from/--to select a range. With --destination simulator: [prepare →] build.")
    @OptionGroup var options: ProjectOptions
    @Option(help: "Resume from this stage.") var from: Stage = .build
    @Option(help: "Stop after this stage (default: upload, or package for macOS; build with --destination simulator).") var to: Stage?
    @Option(help: "Distribution for this run, overriding the config's `distribution`: app-store or developer-id (macOS; iOS is always app-store). Sign/package/upload all see it; the config file is untouched.") var distribution: Distribution?

    /// The last stage: `--to`, else upload (build for a simulator build, which has no later stage).
    var last: Stage { StagePolicy.lastStage(to: to, simulator: options.destination == .simulator) }

    func validate() throws {
        if let problem = StagePolicy.shipRangeProblem(from: from, last: last, simulator: options.destination == .simulator) {
            throw ValidationError(problem)
        }
    }

    func run() async throws {
        var ctx = try await Context.load(options, distribution: distribution, fresh: DatedBuildNumber.isFreshRun(command: "ship", from: from))
        let steps: [(Stage, (Context) async throws -> String)] = [
            (.prepare, { try await StageRunner.prepare($0) }),
            (.build, { try await StageRunner.build($0).path }),
            (.assets, { try await StageRunner.assets($0).path }),
            (.finalize, { try await StageRunner.finalize($0).path }),
            (.sign, { try await StageRunner.sign($0).path }),
            (.package, { try await StageRunner.package($0).path }),
            (.upload, { try await StageRunner.upload($0).report() }),
        ]
        // An overlay build without a freshly synced work copy is never right: starting at build includes prepare.
        let start: Stage = from == .build && ctx.hasPrepare ? .prepare : from
        for (stage, step) in steps where stage >= start && stage <= last {
            if stage == .upload, ctx.platform == .macos { continue }
            if stage == .prepare, !ctx.hasPrepare { continue }
            print("==> \(stage.rawValue)")
            print(try await step(ctx))
            // React Native: the Xcode project exists only after prepare; resolve again (the run's build number is recorded).
            if stage == .prepare, ctx.isReactNative { ctx = try await Context.load(options, distribution: distribution, fresh: false) }
        }
    }
}
