import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessRun

extension Stage: ExpressibleByArgument {}

struct ShipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ship", abstract: "Run [prepare →] build → assets → finalize → sign → package → upload (upload: iOS, and a macOS App Store package with --to upload); --from/--to select a range. With --destination simulator: [prepare →] build.")
    @OptionGroup var options: ProjectOptions
    @Option(help: "Resume from this stage.") var from: Stage = .build
    @Option(help: "Stop after this stage (default: upload, or package for macOS, where --to upload uploads an app-store build; build with --destination simulator).") var to: Stage?
    @Option(help: "Distribution for this run, overriding the config's `distribution`: app-store or developer-id (macOS; iOS is always app-store). Sign/package/upload all see it; the config file is untouched.") var distribution: Distribution?

    /// Given by `xless run` (`RunConfiguration`).
    @Option(help: .hidden) var expectConfig: String?

    @OptionGroup var updatesOff: ProvisioningUpdatesOption

    /// The last stage: `--to`, else upload (build for a simulator build, which has no later stage).
    var last: Stage { StagePolicy.lastStage(to: to, simulator: options.destination == .simulator) }

    func validate() throws {
        if expectConfig != nil, options.configURL != nil { throw ValidationError("\(RunConfiguration.option) is of a project's xless.yml") }
        if let problem = StagePolicy.shipRangeProblem(from: from, last: last, simulator: options.destination == .simulator) {
            throw ValidationError(problem)
        }
    }

    func run() async throws {
        try NativeOverlay.clearTemporary()
        var ctx = try await Context.load(options, distribution: distribution, fresh: DatedBuildNumber.isFreshRun(command: "ship", from: from),
                                         expecting: expectConfig)
        let steps: [(Stage, (Context) async throws -> String)] = [
            (.prepare, { try await StageRunner.prepare($0) }),
            (.build, { try await StageRunner.build($0).path }),
            (.assets, { try await StageRunner.assets($0).path }),
            (.finalize, { try await StageRunner.finalize($0).path }),
            (.sign, { [updatesOff] in try await StageRunner.sign($0, noUpdates: updatesOff.flag).path }),
            (.package, { try await StageRunner.package($0).path }),
            (.upload, { try await StageRunner.upload($0).report() }),
        ]
        let stages = StagePolicy.shipStages(from: from, to: to, simulator: options.destination == .simulator, hasPrepare: ctx.hasPrepare,
                                            platform: ctx.platform, distribution: ctx.config.distribution(for: ctx.platform))
        // On a Mac an overlay's build has its own xless, in a sandbox.
        let inside = try NativeOverlay.isOutside(ctx) ? stages.filter { $0 <= .finalize } : []
        try await NativeOverlay.build(ctx, options: options, distribution: distribution, stages: inside, output: .standardOutput)
        if !inside.isEmpty, ctx.isReactNative { ctx = try await Context.load(options, distribution: distribution, fresh: false) }
        for (stage, step) in steps where stages.contains(stage) && !inside.contains(stage) {
            print("==> \(stage.rawValue)")
            fflush(nil)
            print(try await step(ctx))
            fflush(nil) // (a pipe, with what the tools write to it in between)
            // React Native: the Xcode project exists only after prepare; resolve again (the run's build number is recorded).
            if stage == .prepare, ctx.isReactNative { ctx = try await Context.load(options, distribution: distribution, fresh: false) }
        }
    }
}
