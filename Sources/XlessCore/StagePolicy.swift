import Foundation

/// Which stages a run may reach. A simulator build (`--destination simulator`: React Native overlays, and xless.yml projects on a Mac) ends at
/// `build`: its app is signed ad hoc there, and every later stage (the assets copy-through, finalize's App Store metadata
/// and checks, signing with a distribution identity, packaging, upload) is for device builds. The CLI (`ship`, the
/// stage commands, `Context`) asks this type, so the refusals are tested here (Tests/XlessCoreTests/StagePolicyTests).
public enum StagePolicy {
    /// The stages `ship` runs, in order.
    public static let pipeline: [Stage] = [.prepare, .build, .assets, .finalize, .sign, .package, .upload]

    /// `ship`'s last stage: `--to`, else upload (build for a simulator build, which has no later stage).
    public static func lastStage(to: Stage?, simulator: Bool) -> Stage { to ?? (simulator ? .build : .upload) }

    /// The stages `ship` runs. An overlay build without a freshly synced work copy is never right: starting at build
    /// includes prepare. A Mac app is uploaded only when `--to upload` says so and it is built for the App Store: without
    /// either, `ship` ends at its package.
    public static func shipStages(from: Stage, to: Stage?, simulator: Bool, hasPrepare: Bool, platform: Platform, distribution: Distribution) -> [Stage] {
        let start: Stage = from == .build && hasPrepare ? .prepare : from
        let last = lastStage(to: to, simulator: simulator)
        return pipeline.filter { stage in
            guard stage >= start, stage <= last else { return false }
            if stage == .prepare { return hasPrepare }
            if stage == .upload, platform == .macos { return to == .upload && distribution == .appStore }
            return true
        }
    }

    /// `ship --from … --to …`: nil when the range is allowed, else the usage message.
    public static func shipRangeProblem(from: Stage, last: Stage, simulator: Bool) -> String? {
        let stages = "use one of: " + pipeline.map(\.rawValue).joined(separator: ", ")
        for (flag, stage) in [("--from", from), ("--to", last)] where !pipeline.contains(stage) {
            return "\(flag) \(stage.rawValue): `\(stage.rawValue)` is not a ship pipeline stage; \(stages)"
        }
        if last < from { return "--to \(last.rawValue) comes before --from \(from.rawValue)" }
        if simulator, last > .build { return "--to \(last.rawValue): --destination simulator builds stop at build (prepare, build)" }
        return nil
    }

    /// The first check of every stage after build: refused for a simulator build, with the stage's own exit code.
    /// `appDir` is where the simulator app is (`StagePaths.app`).
    public static func requireDevice(_ stage: Stage, simulator: Bool, appDir: URL) throws {
        guard simulator else { return }
        throw XlessError(stage, "--destination simulator builds stop at build (its .app is already signed ad hoc for the simulator)",
                         fix: "install \(appDir.path)/<App>.app with `xcrun simctl install`, or drop --destination simulator for a device build")
    }

    /// `--destination simulator` for anything but a React Native overlay is refused; a Mac's Xcode builds xless.yml projects for it
    /// too (`builds`).
    public static func requireReactNativeForSimulator(simulator: Bool, isReactNative: Bool, builds: Bool = false) throws {
        guard simulator, !isReactNative, !builds else { return }
        throw XlessError(.config, "--destination simulator builds React Native overlays only (and xless.yml projects, on a Mac with Xcode)",
                         fix: "drop --destination, or build a type: react-native overlay")
    }
}
