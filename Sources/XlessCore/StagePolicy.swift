import Foundation

/// Which stages a run may reach. A simulator build (`--destination simulator`, React Native overlays only) ends at
/// `build`: its app is signed ad hoc there, and every later stage (the assets copy-through, finalize's App Store metadata
/// and checks, signing with a distribution identity, packaging, upload) is for device builds. The CLI (`ship`, the
/// stage commands, `Context`) asks this type, so the refusals are tested here (Tests/XlessCoreTests/StagePolicyTests).
public enum StagePolicy {
    /// The stages `ship` runs, in order.
    public static let pipeline: [Stage] = [.prepare, .build, .assets, .finalize, .sign, .package, .upload]

    /// `ship`'s last stage: `--to`, else upload (build for a simulator build, which has no later stage).
    public static func lastStage(to: Stage?, simulator: Bool) -> Stage { to ?? (simulator ? .build : .upload) }

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

    /// `--destination simulator` for anything but a React Native overlay (a Tauri overlay, xless.yml) is refused.
    public static func requireReactNativeForSimulator(simulator: Bool, isReactNative: Bool) throws {
        guard simulator, !isReactNative else { return }
        throw XlessError(.config, "--destination simulator builds React Native overlays only",
                         fix: "drop --destination, or build a type: react-native overlay")
    }
}

/// Rulings R8 and R10 at the start of a build: the image's SDK (toolchain metadata) against the project's `xcode:` pin,
/// and its Swift toolchain against the SDK's Xcode. `prepare` runs the same checks first (nothing recorded), so a wrong
/// image is refused before the JS install, prebuild and CocoaPods run; `build` checks again and records the result
/// (`BuildSDKRecord`, `<stage dir>/sdk.json`).
public enum BuildSDKCheck {
    public struct Result {
        /// nil without toolchain metadata (a host with no SDK installed, no pin).
        public var meta: ToolchainMeta?
        public var swift: BuildSwiftRecord?
        public var toolchain: SwiftToolchain?
    }

    /// The checks, without recording. `file` words the refusal ("the overlay", "xless.yml"). A pinned project needs
    /// metadata and a toolchain record; the pin must be the metadata's Xcode, and the toolchain the Swift that Xcode ships.
    public static func check(pin: String?, platform: Platform, file: String, stage: Stage,
                             metaURL: URL = ToolchainMeta.defaultLocation(),
                             loadToolchain: () throws -> SwiftToolchain? = { try SwiftToolchain.load(stage: .build) }) throws -> Result {
        var meta: ToolchainMeta?
        do { meta = try ToolchainMeta.load(from: metaURL) } catch let e as XlessError {
            if let pin {
                throw XlessError(stage, "xcode: \"\(pin)\" is pinned, but \(e.cause)", fix: "install Xcode \(pin) (`xless setup --xcode <path to Xcode \(pin)'s .xip>`), or build in an xless image made from it (`xless setup --docker --xcode …`, tags *-xcode\(pin))")
            }
        }
        if let meta { try XcodePin.check(pin: pin, meta: meta, platform: platform, file: file, stage: stage) }
        let toolchain: SwiftToolchain?
        do { toolchain = try loadToolchain() } catch let e as XlessError { throw XlessError(stage, e.cause, fix: e.fix) }
        let swift = try SwiftToolchain.check(toolchain, meta: meta, pin: pin, stage: stage)
        return Result(meta: meta, swift: swift, toolchain: toolchain)
    }

    /// The build stage's form: the previous record is deleted first (a refused build leaves none), then `check`, then the
    /// record is written when there is metadata.
    public static func checkAndRecord(stageRoot: URL, pin: String?, platform: Platform, file: String,
                                      metaURL: URL = ToolchainMeta.defaultLocation(),
                                      loadToolchain: () throws -> SwiftToolchain? = { try SwiftToolchain.load(stage: .build) }) throws -> (Result, BuildSDKRecord?) {
        try? FileManager.default.removeItem(at: BuildSDKRecord.url(in: stageRoot))
        let result = try check(pin: pin, platform: platform, file: file, stage: .build, metaURL: metaURL, loadToolchain: loadToolchain)
        guard let meta = result.meta else { return (result, nil) }
        let record = BuildSDKRecord(pin: pin, toolchain: meta, swift: result.swift)
        try record.write(in: stageRoot)
        return (result, record)
    }
}
