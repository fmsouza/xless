import Foundation

/// The parts of the Xcode that every command reads: the Darwin SDK, its toolchain metadata, the Swift toolchain that
/// compiles app code (Ruling R10), the include directory Apple's clang finds in its toolchain, and Swift Build. They are
/// found the same way on a host and in a container: in the Xcode pack `XcodeResolver` chooses (`XLESS_XCODE`, else the
/// store, by the pin in `XLESS_XCODE_PIN` or the newest), with the single-part overrides on top.
///
/// The overrides win part by part:
/// - the SDK: an SDK installed under `XDG_CONFIG_HOME` (`DarwinSDKLocator`). The variable alone is no override (a host
///   often sets it for other reasons): only when an SDK bundle is there. Beside a pack that is found, only with
///   `XLESS_TOOLCHAIN_META` set as well (an explicit override of the SDK with its metadata, as the images and the test
///   fixtures give): an SDK left there by the native setup of before the packs never pairs with another Xcode's
///   metadata and toolchain;
/// - the metadata: `XLESS_TOOLCHAIN_META`;
/// - the toolchain record: `XLESS_SWIFT_TOOLCHAIN`;
/// - without a pack, the include directory: `XLESS_TOOLCHAIN_INCLUDE`.
/// With the first three set no pack is needed (`pack` is nil when none fits). A machine whose store has no pack at all,
/// and no `XLESS_XCODE`, has the overrides alone: an SDK none names is `DarwinSDKLocator`'s, metadata none names is
/// missing (`toolchain-meta.json` at the store's root, which no setup writes: reading it names the store), and no
/// toolchain record or include directory. With no override either it has no Xcode, and the resolver's problem names the
/// setup. Nothing of an older native install or of an image of before the packs is read. A pack a setup left aside while replacing it (`<name>.old`) is no pack here: setup puts it
/// back (`PackPlan.recover`), a build never renames anything.
///
/// A Mac building with its own Xcode reads none of this (`MacNative`, `DarwinSDK(xcode:)`).
public struct XcodeEnvironment: Sendable {
    /// The project's pin, which `xless run` gives the stage commands it starts, and a command sets when it loads the
    /// project (`pin(configured:env:)`).
    public static let pinVariable = "XLESS_XCODE_PIN"

    /// The value `pinVariable` takes in a command that has loaded a project whose `xcode:` is `configured`, so that a
    /// stage run by hand, the shims it starts and every child find the Xcode `xless run` would. nil: leave it alone
    /// (a value in `env` wins: a run has set it), or the project pins nothing.
    public static func pin(configured: String?, env: [String: String]) -> String? {
        guard value(env, pinVariable) == nil, let configured, !configured.isEmpty else { return nil }
        return configured
    }

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

    /// The environment of a tool that finds the SDK only through `XDG_CONFIG_HOME` (xtool), and `PATH` with the toolchain
    /// (`SwiftToolchain.path`). When the SDK is not already where that variable points (it is in a pack), the variable
    /// names a scratch configuration (`xtoolConfig`) whose `swiftpm/swift-sdks` links to the pack's: SwiftPM and xtool
    /// write their own state there, and nothing ever writes to the pack. An SDK override leaves it alone.
    public func toolEnvironment(_ env: [String: String]) throws -> [String: String] {
        var out = env
        if sdkBundle.standardizedFileURL.path != DarwinSDKLocator.bundle(env: env).standardizedFileURL.path {
            out["XDG_CONFIG_HOME"] = try xtoolConfig(env: env).path
        }
        if let toolchain { out["PATH"] = toolchain.path(env["PATH"]) }
        return out
    }

    /// `<cache>/xless/xtool-config/<pack>` (`$XDG_CACHE_HOME`, else `~/.cache`), holding `swiftpm/swift-sdks` as a
    /// link to the directory of the SDK bundle; made when missing, the link replaced when it points elsewhere (a moved pack).
    func xtoolConfig(env: [String: String]) throws -> URL {
        let fm = FileManager.default
        let cache = Self.value(env, "XDG_CACHE_HOME").flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? URL(fileURLWithPath: Self.value(env, "HOME") ?? NSHomeDirectory()).appendingPathComponent(".cache")
        let config = cache.appendingPathComponent("xless/xtool-config").appendingPathComponent(pack?.root.lastPathComponent ?? "xcode")
        let swiftpm = config.appendingPathComponent("swiftpm"), link = swiftpm.appendingPathComponent("swift-sdks")
        let target = swiftSDKsPath.path
        func linked() -> Bool { (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target }
        do {
            try fm.createDirectory(at: swiftpm, withIntermediateDirectories: true)
            if linked() { return config }
            // A new link renamed over the old one (rename(2) replaces it in one step), so two builds that both find it
            // missing or stale each leave the right one, and neither removes what the other made.
            let fresh = swiftpm.appendingPathComponent(".swift-sdks.\(UUID().uuidString)")
            try fm.createSymbolicLink(atPath: fresh.path, withDestinationPath: target)
            defer { try? fm.removeItem(at: fresh) }
            if rename(fresh.path, link.path) != 0 {
                // A directory is there (rename does not replace one): removed, unless another build already did.
                do { try fm.removeItem(at: link) } catch where !fm.fileExists(atPath: link.path) || linked() {}
                // errno is taken at once: `linked()` reads the link, which may set it again
                if !linked(), case let failed = rename(fresh.path, link.path) != 0 ? errno : 0, failed != 0, !linked() {
                    throw XlessError(.build, "cannot link \(link.path): \(String(cString: strerror(failed)))", fix: "remove \(link.path)")
                }
            }
        } catch {
            throw XlessError(.build, "xtool's configuration \(config.path) cannot be made: \(error.localizedDescription)",
                             fix: "make \(cache.path) writable, or set XDG_CACHE_HOME to a writable directory")
        }
        return config
    }

    /// The Xcode's parts in `env`. Throws `XcodeProblem` when no pack fits (missing, of another version or architecture,
    /// stale, or without a part in `needs`) and the overrides do not stand in for it, or when there is nothing at all.
    /// Beside a found pack, an SDK under `XDG_CONFIG_HOME` counts only with `XLESS_TOOLCHAIN_META` (see the type).
    public static func current(env: [String: String] = ProcessInfo.processInfo.environment,
                               needs: Set<XcodeResolver.Need> = [.sdk]) throws -> XcodeEnvironment {
        if let found = try lookup(env: env, needs: needs) { return found }
        _ = try resolve(env, needs: needs) // the store is empty: the problem names it and the setup
        throw XcodeProblem("there is no Xcode pack", fix: XcodeResolver.setUp(nil))
    }

    /// `current`, or nil when this machine has no Xcode at all: no pack in the store, no `XLESS_XCODE` and no override.
    /// A pack that does not fit still throws. With a pack found, its SDK wins over
    /// one under `XDG_CONFIG_HOME` unless `XLESS_TOOLCHAIN_META` is set too.
    public static func lookup(env: [String: String] = ProcessInfo.processInfo.environment,
                              needs: Set<XcodeResolver.Need> = [.sdk]) throws -> XcodeEnvironment? {
        let fm = FileManager.default
        let sdkOverride: URL? = value(env, "XDG_CONFIG_HOME").flatMap { _ in
            let bundle = DarwinSDKLocator.bundle(env: env)
            return fm.fileExists(atPath: bundle.path) ? bundle : nil
        }
        let metaOverride = value(env, "XLESS_TOOLCHAIN_META").map { URL(fileURLWithPath: $0) }
        let recordOverride = value(env, "XLESS_SWIFT_TOOLCHAIN").map { URL(fileURLWithPath: $0) }
        let includeOverride = value(env, "XLESS_TOOLCHAIN_INCLUDE").map { URL(fileURLWithPath: $0) }
        let overridden = sdkOverride != nil && metaOverride != nil && recordOverride != nil
        let anyOverride = sdkOverride != nil || metaOverride != nil || recordOverride != nil || includeOverride != nil
        let path = env["PATH"]

        let store = XcodeStore(env: env)
        let storeIsEmpty = value(env, "XLESS_XCODE") == nil
            && store.subdirectories().allSatisfy { !fm.fileExists(atPath: $0.appendingPathComponent("pack.json").path) }
        if !storeIsEmpty {
            do {
                let pack = try resolve(env, needs: needs)
                return XcodeEnvironment(
                    pack: pack, sdkBundle: (metaOverride != nil ? sdkOverride : nil) ?? pack.sdkBundle, meta: metaOverride ?? pack.meta,
                    record: recordOverride ?? (fm.fileExists(atPath: pack.record.path) ? pack.record : nil), recordIsOverride: recordOverride != nil,
                    include: fm.fileExists(atPath: pack.include.path) ? pack.include : nil,
                    swbuild: pack.has(.swiftBuild) ? pack.swiftBuild.appendingPathComponent("swbuild") : which("swbuild", path: path))
            } catch let problem as XcodeProblem where overridden {
                _ = problem // every part is overridden: the pack is not needed
            }
        }
        if storeIsEmpty, !anyOverride { return nil }
        return XcodeEnvironment(pack: nil, sdkBundle: sdkOverride ?? DarwinSDKLocator.bundle(env: env),
                                meta: metaOverride ?? store.root.appendingPathComponent("toolchain-meta.json"),
                                record: recordOverride, recordIsOverride: recordOverride != nil,
                                include: includeOverride, swbuild: which("swbuild", path: path))
    }

    /// The toolchain alone (`loadToolchain`); nil on a machine with no Xcode at all (the `swift` on PATH compiles, as
    /// before Ruling R10). A pack that does not fit (`XcodeProblem`) is `stage`'s error, as is a record that cannot be read.
    public static func toolchain(env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage = .build) throws -> SwiftToolchain? {
        do { return try lookup(env: env)?.loadToolchain(stage: stage) } catch let problem as XcodeProblem { throw problem.stageError(stage) }
    }

    // MARK: -

    private static func resolve(_ env: [String: String], needs: Set<XcodeResolver.Need>) throws -> XcodePack {
        let recipe = Recipe(env: env)
        return try XcodeResolver.resolve(env: env, pin: value(env, pinVariable), arch: hostArch, order: recipe.order, needs: needs,
                                         expected: recipe.expected)
    }

    /// What this xless's share says of the packs: the order of the Xcode table, and the recipe hash of a pack's part. The
    /// image sets `XLESS_SHARE`, so a stage command in a container checks its pack as one on a host does; with no share at
    /// all (an xless installed without one) nothing is stale (`XcodeResolver.resolve`). As a run's pack choice
    /// (`RunPack`): a pack of an Xcode this xless has no recipe for (versions.env maps it to no Swift toolchain) is used as it
    /// is, with a note; a recipe input the share lacks stops it, since whether the pack is current cannot be told then.
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

        func expected(_ pack: XcodePack, _ part: PackPart) throws -> String? {
            guard let share else { return nil }
            let m = pack.manifest
            guard !(table["XCODE_SWIFT_\(m.build)"] ?? "").isEmpty else {
                XcodeEnvironment.note("note: the pack \(pack.name) is of Xcode \(m.xcode) (\(m.build)), which this xless has no recipe for (versions.env maps it "
                     + "to no Swift toolchain, XCODE_SWIFT_\(m.build)): it is used as it is, and whether it is current is not checked")
                return nil
            }
            do { return try PackRecipe.hash(part, build: m.build, arch: m.arch, table: table, share: share) } catch let e as XlessError {
                throw XcodeProblem("cannot tell whether the pack \(pack.name) is current: \(e.cause)", fix: e.fix)
            }
        }
    }

    /// This machine's architecture, as packs and images name it: arm64 or amd64.
    public static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    /// A note on standard error, once per process and text (a command may look the Xcode up more than once).
    private static func note(_ text: String) {
        noted.withLock { seen in
            guard seen.insert(text).inserted else { return }
            FileHandle.standardError.write(Data("\(text)\n".utf8))
        }
    }
    private static let noted = NoteMemory()

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

/// The notes already written (`XcodeEnvironment.note`).
private final class NoteMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    func withLock(_ body: (inout Set<String>) -> Void) { lock.lock(); defer { lock.unlock() }; body(&seen) }
}

extension XcodeProblem: StageReportableError {
    /// In a stage: the cause and the command that fixes it, with the usage exit code (nothing of the project is wrong).
    public func stageError(_ stage: Stage) -> XlessError { XlessError(stage, cause, fix: fix, code: 2) }
}

extension DarwinSDK {
    /// The Xcode's Darwin SDK (`XcodeEnvironment`). On a machine with no Xcode at all (`XcodeEnvironment.lookup` finds
    /// nothing), where `xtool sdk install` puts one (`DarwinSDKLocator`; no setup does since the packs), so that the
    /// error of what needs it names a path. A pack that does not fit (none for the pin, stale, unreadable) throws its
    /// `XcodeProblem`.
    public init(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.init(bundle: try XcodeEnvironment.lookup(env: env)?.sdkBundle ?? DarwinSDKLocator.bundle(env: env))
    }
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
