import Foundation

/// The parts of the Xcode that every command reads: the Darwin SDK, its toolchain metadata, the Swift toolchain that
/// compiles app code (Ruling R10), the include directory Apple's clang finds in its toolchain, and Swift Build. They are
/// found the same way on a host and in a container: in the Xcode pack `XcodeResolver` chooses (`XLESS_XCODE`, else the
/// store, by the pin in `XLESS_XCODE_PIN` or the newest), with the single-part overrides on top.
///
/// The overrides win part by part:
/// - the SDK: an SDK installed under `XDG_CONFIG_HOME` (`DarwinSDKLocator`). The variable alone is no override (a host
///   often sets it for other reasons): only when an SDK bundle is there;
/// - the metadata: `XLESS_TOOLCHAIN_META`;
/// - the toolchain record: `XLESS_SWIFT_TOOLCHAIN`.
/// With all three set no pack is needed (`pack` is nil when none fits). A machine whose store has no pack at all, and no
/// `XLESS_XCODE`, is read where the images and the native setup kept the parts before the packs (`legacyLocations`);
/// when there is nothing there either, the resolver's problem names the setup.
///
/// A Mac building with its own Xcode reads none of this (`MacNative`, `DarwinSDK(xcode:)`).
public struct XcodeEnvironment: Sendable {
    /// The project's pin, which `xless run` gives the stage commands it starts.
    public static let pinVariable = "XLESS_XCODE_PIN"

    /// nil: no pack (every part overridden, or a machine set up before the packs).
    public let pack: XcodePack?
    public let sdkBundle: URL
    public let meta: URL
    /// The Swift toolchain record in use; nil when there is none.
    public let record: URL?
    /// Swift's `swift/bridging` and its module map, for `-idirafter` (`SwiftBuildEnvironment`).
    public let include: URL?
    /// `<pack>/swift-build/swbuild`, else the `swbuild` on PATH; nil when there is neither.
    public let swbuild: URL?
    private let loaded: Result<SwiftToolchain?, XlessError>

    public init(pack: XcodePack?, sdkBundle: URL, meta: URL, record: URL?, include: URL?, swbuild: URL?, toolchain: SwiftToolchain?) {
        self.pack = pack; self.sdkBundle = sdkBundle; self.meta = meta; self.record = record
        self.include = include; self.swbuild = swbuild; loaded = .success(toolchain)
    }

    private init(pack: XcodePack?, sdkBundle: URL, meta: URL, record: URL?, recordIsOverride: Bool, include: URL?, swbuild: URL?) {
        self.pack = pack; self.sdkBundle = sdkBundle; self.meta = meta; self.record = record; self.include = include; self.swbuild = swbuild
        guard let record else { loaded = .success(nil); return }
        if recordIsOverride, !FileManager.default.fileExists(atPath: record.path) {
            loaded = .failure(XlessError(.build, "XLESS_SWIFT_TOOLCHAIN names \(record.path), which does not exist", fix: "unset it, or point it at a toolchain record"))
            return
        }
        do { loaded = .success(try SwiftToolchain.load(record: record)) } catch let e as XlessError { loaded = .failure(e) } catch {
            loaded = .failure(XlessError(.build, "\(error)", fix: "run xless setup --xcode <Xcode.xip> again"))
        }
    }

    /// The Swift toolchain that compiles, its root an absolute path; nil without a record, or with one that cannot be
    /// read (`loadToolchain` says why).
    public var toolchain: SwiftToolchain? { try? loaded.get() }

    /// `toolchain`, or the error of a record that cannot be read (or of `XLESS_SWIFT_TOOLCHAIN` naming none) in `stage`.
    public func loadToolchain(stage: Stage = .build) throws -> SwiftToolchain? {
        do { return try loaded.get() } catch { throw XlessError(stage, error.cause, fix: error.fix) }
    }

    /// The directory SwiftPM looks for the SDK in. The pack is mounted read-only, so SwiftPM gets it with
    /// `--swift-sdks-path` (`swiftSDKsArguments`) and keeps its own state in a writable `XDG_CONFIG_HOME` outside the pack
    /// (docs/research/xcode-pack-relocation.md).
    public var swiftSDKsPath: URL { sdkBundle.deletingLastPathComponent() }
    /// For `swift build` against the Darwin SDK.
    public var swiftSDKsArguments: [String] { ["--swift-sdks-path", swiftSDKsPath.path] }

    /// The environment of a tool that finds the SDK only through `XDG_CONFIG_HOME` (xtool): that variable at the SDK's
    /// config home when the SDK is not already where it points, and `PATH` with the toolchain (`SwiftToolchain.path`).
    /// SwiftPM, under it, warns that it cannot write its own state there when the pack is read-only.
    public func toolEnvironment(_ env: [String: String]) -> [String: String] {
        var out = env
        if sdkBundle.standardizedFileURL.path != DarwinSDKLocator.bundle(env: env).standardizedFileURL.path {
            out["XDG_CONFIG_HOME"] = sdkBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
        if let toolchain { out["PATH"] = toolchain.path(env["PATH"]) }
        return out
    }

    /// The Xcode's parts in `env`. Throws `XcodeProblem` when no pack fits (missing, of another version or architecture,
    /// stale, or without a part in `needs`) and the overrides do not stand in for it, or when there is nothing at all.
    public static func current(env: [String: String] = ProcessInfo.processInfo.environment,
                               needs: Set<XcodeResolver.Need> = [.sdk]) throws -> XcodeEnvironment {
        if let found = try lookup(env: env, needs: needs) { return found }
        _ = try resolve(env, needs: needs) // the store is empty: the problem names it and the setup
        throw XcodeProblem("there is no Xcode pack", fix: "xless setup --xcode <path to Xcode's .app or .xip>")
    }

    /// `current`, or nil when this machine has no Xcode at all: no pack in the store, no `XLESS_XCODE`, no override and
    /// nothing of before the packs. A pack that does not fit still throws.
    public static func lookup(env: [String: String] = ProcessInfo.processInfo.environment,
                              needs: Set<XcodeResolver.Need> = [.sdk]) throws -> XcodeEnvironment? {
        let fm = FileManager.default
        let sdkOverride: URL? = value(env, "XDG_CONFIG_HOME").flatMap { _ in
            let bundle = DarwinSDKLocator.bundle(env: env)
            return fm.fileExists(atPath: bundle.path) ? bundle : nil
        }
        let metaOverride = value(env, "XLESS_TOOLCHAIN_META").map { URL(fileURLWithPath: $0) }
        let recordOverride = value(env, "XLESS_SWIFT_TOOLCHAIN").map { URL(fileURLWithPath: $0) }
        let overridden = sdkOverride != nil && metaOverride != nil && recordOverride != nil
        let anyOverride = sdkOverride != nil || metaOverride != nil || recordOverride != nil
        let path = env["PATH"]

        let store = XcodeStore(env: env)
        let storeIsEmpty = value(env, "XLESS_XCODE") == nil
            && store.subdirectories().allSatisfy { !fm.fileExists(atPath: $0.appendingPathComponent("pack.json").path) }
        if !storeIsEmpty {
            do {
                let pack = try resolve(env, needs: needs)
                return XcodeEnvironment(
                    pack: pack, sdkBundle: sdkOverride ?? pack.sdkBundle, meta: metaOverride ?? pack.meta,
                    record: recordOverride ?? (fm.fileExists(atPath: pack.record.path) ? pack.record : nil), recordIsOverride: recordOverride != nil,
                    include: fm.fileExists(atPath: pack.include.path) ? pack.include : nil,
                    swbuild: pack.has(.swiftBuild) ? pack.swiftBuild.appendingPathComponent("swbuild") : which("swbuild", path: path))
            } catch let problem as XcodeProblem where overridden {
                _ = problem // every part is overridden: the pack is not needed
            }
        }
        let legacy = legacyLocations(env)
        if storeIsEmpty, !legacy.present, !anyOverride { return nil }
        return XcodeEnvironment(pack: nil, sdkBundle: sdkOverride ?? legacy.sdkBundle, meta: metaOverride ?? legacy.meta,
                                record: recordOverride ?? legacy.record, recordIsOverride: recordOverride != nil,
                                include: legacy.include, swbuild: which("swbuild", path: path))
    }

    /// The toolchain alone (`loadToolchain`); nil on a machine with no Xcode at all (the `swift` on PATH compiles, as
    /// before Ruling R10). A pack that does not fit (`XcodeProblem`) is `stage`'s error, as is a record that cannot be read.
    public static func toolchain(env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage = .build) throws -> SwiftToolchain? {
        do { return try lookup(env: env)?.loadToolchain(stage: stage) } catch let problem as XcodeProblem { throw problem.stageError(stage) }
    }

    // MARK: -

    // LEGACY: where the parts were before the packs, read only when the store holds no pack. Task 8 deletes the native
    // half (the SDK under XDG_CONFIG_HOME or ~/.swiftpm, the metadata under ~/.config/xless, `NativeLayout.record`),
    // Task 9 the image half (the files under /opt/xless, XLESS_TOOLCHAIN_INCLUDE).
    private static func legacyLocations(_ env: [String: String]) -> (sdkBundle: URL, meta: URL, record: URL?, include: URL?, present: Bool) {
        let fm = FileManager.default
        let imageMeta = "/opt/xless/toolchain-meta.json", imageRecord = "/opt/xless/swift-toolchain.json"
        let sdkBundle = DarwinSDKLocator.bundle(env: env)
        let meta = fm.fileExists(atPath: imageMeta) ? URL(fileURLWithPath: imageMeta) : ToolchainMeta.defaultLocation(env: env)
        let record = fm.fileExists(atPath: imageRecord) ? URL(fileURLWithPath: imageRecord) : NativeLayout(env: env).record
        let include = value(env, "XLESS_TOOLCHAIN_INCLUDE").map { URL(fileURLWithPath: $0) }
        let hasRecord = fm.fileExists(atPath: record.path)
        let present = fm.fileExists(atPath: sdkBundle.path) || fm.fileExists(atPath: meta.path) || hasRecord || include != nil
        return (sdkBundle, meta, hasRecord ? record : nil, include, present)
    }

    private static func resolve(_ env: [String: String], needs: Set<XcodeResolver.Need>) throws -> XcodePack {
        let recipe = Recipe(env: env)
        return try XcodeResolver.resolve(env: env, pin: value(env, pinVariable), arch: hostArch, order: recipe.order, needs: needs,
                                         expected: recipe.expected)
    }

    /// What this xless's share says of the packs: the order of the Xcode table, and the recipe hash of a pack's part. A
    /// stage command in a container has no share: then nothing is stale (`XcodeResolver.resolve`).
    private struct Recipe {
        var order: [String] = []
        var table: [String: String] = [:]
        var share: URL?

        init(env: [String: String]) {
            let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            guard let share = try? XlessShare.locate(env: env, executable: exe),
                  let text = try? String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8) else { return }
            self.share = share
            table = KnownXcodes.parseEnv(text)
            order = (table["XCODE_RELEASES"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        }

        func expected(_ pack: XcodePack, _ part: PackPart) -> String? {
            guard let share else { return nil }
            return try? PackRecipe.hash(part, build: pack.manifest.build, arch: pack.manifest.arch, table: table, share: share)
        }
    }

    static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    private static func value(_ env: [String: String], _ name: String) -> String? { env[name].flatMap { $0.isEmpty ? nil : $0 } }

    /// The first executable `name` in `path`'s directories.
    public static func which(_ name: String, path: String?) -> URL? {
        for dir in (path ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

extension XcodeProblem: StageReportableError {
    /// In a stage: the cause and the command that fixes it, with the usage exit code (nothing of the project is wrong).
    public func stageError(_ stage: Stage) -> XlessError { XlessError(stage, cause, fix: fix, code: 2) }
}

extension DarwinSDK {
    /// The Xcode's Darwin SDK (`XcodeEnvironment`). Where there is none, where a native setup puts it
    /// (`DarwinSDKLocator`), so that the error of what needs it names a path; the stages refuse a missing pack first
    /// (`BuildSDKCheck`).
    public init() { self.init(bundle: (try? XcodeEnvironment.current().sdkBundle) ?? DarwinSDKLocator.bundle()) }
}

extension XcodeToolsProfile {
    /// `forImage` with the Xcode's toolchain metadata (`XcodeEnvironment.meta`), read once per call. Missing or invalid
    /// metadata, and no Xcode at all, are refused in `stage`.
    public static func forImage(env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage) throws -> XcodeToolsProfile {
        let meta: ToolchainMeta
        do { meta = try ToolchainMeta.load(from: XcodeEnvironment.current(env: env).meta) } catch let e as XlessError {
            throw XlessError(stage, e.cause, fix: e.fix)
        } catch let problem as XcodeProblem {
            throw problem.stageError(stage)
        }
        return try forImage(meta: meta, stage: stage)
    }
}
