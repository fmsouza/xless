import Foundation
import XlessASC
import XlessCargo
import XlessCore
import XlessReactNative
import XlessTauri
import XlessXcode

struct Context {
    let project: URL
    let config: ProjectConfig
    let platform: Platform
    let paths: StagePaths
    let secrets: Secrets
    /// `--build-number` or `XLESS_BUILD_NUMBER`, when given (re-resolved on every invocation).
    let buildOverride: String?
    /// With `--config`: the parsed Tauri overlay, the source tree it points at and the work copy location.
    var overlay: TauriOverlay? = nil
    var sourceRoot: URL? = nil
    var workRoot: URL? = nil
    var tauri: ResolvedTauri? = nil
    /// With `--config` and `--platform macos`: the resolved desktop app (`tauri` is nil then).
    var tauriMac: ResolvedTauriMac? = nil

    /// With `--config` and a `type: react-native` overlay (`overlay` is nil then).
    var rnOverlay: ReactNativeOverlay? = nil
    var reactNative: ResolvedReactNative? = nil
    /// `--destination simulator` (React Native overlays only): stages after build are refused.
    var simulator = false

    /// With `--config` and a `type: cargo` overlay (`overlay` is nil then), for either platform.
    var cargo: CargoOverlay? = nil
    /// The cargo overlay resolved for `platform`; its `config` is the settled one (`config`).
    var cargoResolved: ResolvedCargo? = nil

    /// True with `--config` and a Tauri overlay, for either platform.
    var isTauri: Bool { overlay != nil }
    /// True with `--config` and a React Native overlay.
    var isReactNative: Bool { rnOverlay != nil }
    /// True with `--config` and a cargo overlay.
    var isCargo: Bool { cargo != nil }
    /// Overlays build from a work copy that `prepare` syncs: a build without it is never right.
    var hasPrepare: Bool { isTauri || isReactNative || isCargo }

    /// The Tauri stages' view of this context; nil without `--config` or for `--platform macos`.
    var tauriBuild: TauriBuildContext? {
        guard let overlay, let sourceRoot, let workRoot, let tauri else { return nil }
        return TauriBuildContext(overlay: overlay, resolved: tauri, sourceRoot: sourceRoot, workRoot: workRoot, paths: paths)
    }

    /// The macOS Tauri stages' view of this context; nil without `--config … --platform macos`.
    var tauriMacBuild: TauriMacBuildContext? {
        guard let overlay, let sourceRoot, let workRoot, let tauriMac else { return nil }
        return TauriMacBuildContext(overlay: overlay, resolved: tauriMac, sourceRoot: sourceRoot, workRoot: workRoot, paths: paths)
    }

    /// The React Native stages' view of this context; nil without a `type: react-native` overlay.
    var reactNativeBuild: ReactNativeBuildContext? {
        guard let rnOverlay, let sourceRoot, let workRoot, let reactNative else { return nil }
        return ReactNativeBuildContext(overlay: rnOverlay, resolved: reactNative, sourceRoot: sourceRoot, workRoot: workRoot, paths: paths,
                                       destination: simulator ? .iphonesimulator : .iphoneos)
    }

    /// The cargo stages' view of this context; nil without a `type: cargo` overlay.
    var cargoBuild: CargoBuildContext? {
        guard let cargo, let cargoResolved, let sourceRoot, let workRoot else { return nil }
        return CargoBuildContext(overlay: cargo, resolved: cargoResolved, platform: platform, sourceRoot: sourceRoot, workRoot: workRoot, paths: paths)
    }

    /// `--distribution` (ship): replaces the platform's configured distribution for this run; the config file is
    /// untouched. Applied after validation, so sign/package/upload all see it.
    static func load(_ opts: ProjectOptions, distribution: Distribution? = nil, env: [String: String] = ProcessInfo.processInfo.environment, fresh: Bool = false) async throws -> Context {
        let override = opts.buildNumber ?? env["XLESS_BUILD_NUMBER"].flatMap { $0.isEmpty ? nil : $0 }
        let kind = try opts.configURL.map(OverlayKind.of)
        if let configURL = opts.configURL, kind == .reactNative {
            guard opts.platform == .ios else {
                throw XlessError(.config, "React Native overlays build iOS apps only", fix: "use --platform ios")
            }
            let (overlay, sourceRoot, workRoot) = try ReactNativeOverlay.load(from: configURL, sourceOverride: opts.source, env: env)
            // Before prepare has generated the Xcode project some values are provisional (ResolvedReactNative); the
            // commands that run prepare load the context again after it.
            var resolved = try ReactNativeProject.resolve(overlay: overlay, source: sourceRoot, work: workRoot)
            // A simulator build has its own stage directory (and build number record), and is never uploaded: a dated
            // build number is chosen without App Store Connect.
            let simulator = opts.destination == .simulator
            let paths = simulator ? StagePaths.iosSimulator(project: workRoot) : StagePaths(project: workRoot, platform: .ios)
            try await DatedBuildNumber.settle(&resolved.config, override: override, file: paths.root.appendingPathComponent("build-number"),
                                              secrets: Secrets(env: env), fresh: fresh, local: simulator)
            resolved.config = try resolved.config.overridingDistribution(distribution, for: .ios)
            return Context(project: workRoot, config: resolved.config, platform: .ios, paths: paths, secrets: Secrets(env: env),
                           buildOverride: override, sourceRoot: sourceRoot, workRoot: workRoot, rnOverlay: overlay, reactNative: resolved,
                           simulator: simulator)
        }
        try StagePolicy.requireReactNativeForSimulator(simulator: opts.destination == .simulator, isReactNative: false)
        if let configURL = opts.configURL, kind == .cargo {
            let (overlay, sourceRoot, workRoot) = try CargoOverlay.load(from: configURL, sourceOverride: opts.source, env: env)
            // The config holds only this platform: a macOS build's dated number is chosen locally (`isMacOnly`).
            var resolved = try CargoProject.resolve(overlay: overlay, platform: opts.platform, source: sourceRoot)
            try await settleBuild(&resolved.config, platform: opts.platform, override: override, workRoot: workRoot, env: env, fresh: fresh)
            return Context(project: workRoot, config: resolved.config, platform: opts.platform,
                           paths: StagePaths(project: workRoot, platform: opts.platform), secrets: Secrets(env: env),
                           buildOverride: override, sourceRoot: sourceRoot, workRoot: workRoot, cargo: overlay, cargoResolved: resolved)
        }
        if let configURL = opts.configURL {
            let loc = try OverlayLocation.load(from: configURL, sourceOverride: opts.source, env: env)
            if opts.platform == .macos {
                var mac = try TauriProject.resolveMac(overlay: loc.overlay, source: loc.sourceRoot)
                try await settleBuild(&mac.config, platform: .macos, override: override, workRoot: loc.workRoot, env: env, fresh: fresh)
                mac.config = try mac.config.overridingDistribution(distribution, for: .macos)
                return Context(project: loc.workRoot, config: mac.config, platform: .macos,
                               paths: StagePaths(project: loc.workRoot, platform: .macos), secrets: Secrets(env: env),
                               buildOverride: override, overlay: loc.overlay, sourceRoot: loc.sourceRoot, workRoot: loc.workRoot, tauriMac: mac)
            }
            var resolved = try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot)
            _ = try resolved.config.platform(opts.platform)
            try await settleBuild(&resolved.config, platform: .ios, override: override, workRoot: loc.workRoot, env: env, fresh: fresh)
            resolved.config = try resolved.config.overridingDistribution(distribution, for: opts.platform)
            return Context(project: loc.workRoot, config: resolved.config, platform: opts.platform,
                           paths: StagePaths(project: loc.workRoot, platform: opts.platform), secrets: Secrets(env: env),
                           buildOverride: override, overlay: loc.overlay, sourceRoot: loc.sourceRoot, workRoot: loc.workRoot, tauri: resolved)
        }
        let project = opts.projectURL
        var config = try ProjectConfig.load(from: project.appendingPathComponent("xless.yml"), buildOverride: override)
        _ = try config.platform(opts.platform)
        try await settleBuild(&config, platform: .ios, override: override, workRoot: project, env: env, fresh: fresh)
        config = try config.overridingDistribution(distribution, for: opts.platform)
        return Context(project: project, config: config, platform: opts.platform,
                       paths: StagePaths(project: project, platform: opts.platform), secrets: Secrets(env: env),
                       buildOverride: override)
    }

    /// Simulator builds end at `build`: the stages after it (assets copy-through, finalize's App Store metadata and
    /// checks, signing with a distribution identity, packaging, upload) are for device builds.
    func requireDevice(_ stage: Stage) throws { try StagePolicy.requireDevice(stage, simulator: simulator, appDir: paths.app) }

    /// The run's build number: the override (a dated overlay keeps its scheme), or for `build: dated` the recorded (or, for
    /// a run that starts, freshly chosen) number. Inside the `config` stage (`DatedBuildNumber.settle`).
    private static func settleBuild(_ config: inout ProjectConfig, platform: Platform, override: String?, workRoot: URL, env: [String: String], fresh: Bool) async throws {
        let file = StagePaths(project: workRoot, platform: platform).root.appendingPathComponent("build-number")
        try await DatedBuildNumber.settle(&config, override: override, file: file, secrets: Secrets(env: env), fresh: fresh)
    }
}
