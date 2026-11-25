import Foundation
import XlessCore
import XlessXcode

/// The Pods project's configuration-switch phases, run by `prepare` so that they are no-ops during the build.
///
/// Several pods ship a prebuilt framework for each configuration and leave the Debug one in place at `pod install`:
/// Expo's precompiled modules (`[CP-User] [Expo] Switch <Pod> XCFramework for build configuration`, state in
/// `Pods/<Pod>/artifacts/.last_build_configuration`) and React Native's core, dependencies and Hermes
/// (`[CP-User] [RNCore|RNDeps|Hermes] Replace … for the right configuration, if needed`). Their phase deletes the tree and
/// extracts the configuration's tarball in its place. During a Swift Build build, other targets have already scanned
/// the Debug tree's headers (Swift Build caches file-system state in its process; on Linux the deleted files' inode
/// numbers are reused by the new ones at once), and clean builds then failed now and again with a header "not found"
/// that is there, or with a crash of the build service (contract doc, "Configuration switches at prepare").
/// Running the same phases first, as the build would run them, leaves nothing to replace mid-build.
enum ConfigurationSwitches {
    /// A phase whose name says it switches prebuilt binaries per configuration.
    static func isSwitch(_ name: String) -> Bool {
        name.wholeMatch(of: /\[CP-User\] \[[A-Za-z]+\] (Switch .+ XCFramework for build configuration|Replace .+ for the right configuration, if needed)/) != nil
    }

    struct Phase: Equatable {
        var target: String
        var name: String
        var shellPath: String
        var script: String
    }

    /// The switch phases of `project` (a Pods project), in target order.
    static func phases(in project: XcodeProject) -> [(target: Target, phase: Phase)] {
        project.targets.flatMap { target in
            target.phases.compactMap { p -> (Target, Phase)? in
                guard case .shellScript(let s) = p.kind, let name = p.name, isSwitch(name) else { return nil }
                return (target, Phase(target: target.name, name: name, shellPath: s.shellPath, script: s.script))
            }
        }
    }

    /// Runs every switch phase of `ios/Pods/Pods.xcodeproj` for `configuration` as Swift Build runs a script phase: the
    /// script with its `shellPath`, in the project's directory, with the target's build settings for the configuration
    /// in the environment on top of `env` (which carries `PATH` with node, `TAR_OPTIONS`). Returns the phases' names.
    /// Every error is a `prepare` one: the project and build-setting readers (`XcodeProject`, `TargetSettings`) throw
    /// `build` errors, as they do for the build stage.
    @discardableResult
    static func run(ios: URL, configuration: String, env: [String: String?], baseEnvironment: [String: String],
                    passthrough: Bool = true) throws -> [String] {
        try restage(.prepare) { try runPhases(ios: ios, configuration: configuration, env: env, baseEnvironment: baseEnvironment, passthrough: passthrough) }
    }

    private static func runPhases(ios: URL, configuration: String, env: [String: String?], baseEnvironment: [String: String],
                                  passthrough: Bool) throws -> [String] {
        let url = ios.appendingPathComponent("Pods/Pods.xcodeproj")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let project = try XcodeProject.load(url)
        var ran: [String] = []
        for (target, phase) in phases(in: project) {
            let settings = try TargetSettings(project: project, target: target, configuration: configuration, overrides: [:])
            var environment = env
            for (k, v) in try settings.environment() { environment[k] = v }
            let script = Files.temporary.appendingPathComponent("xless-switch-\(UUID().uuidString).sh")
            try Data(phase.script.utf8).write(to: script)
            defer { try? FileManager.default.removeItem(at: script) }
            log("\(phase.target): \(phase.name)")
            do {
                try Shell.run(phase.shellPath, [script.path], cwd: project.directory, env: environment, baseEnvironment: baseEnvironment,
                              stage: .prepare, passthrough: passthrough)
            } catch let e as XlessError {
                throw XlessError(.prepare, "\(phase.target)'s phase '\(phase.name)' failed: \(e.cause)",
                                 fix: "this is the pod's own build phase, run before the build so it does not replace files mid-build; check its output above")
            }
            ran.append("\(phase.target): \(phase.name)")
        }
        return ran
    }
}
