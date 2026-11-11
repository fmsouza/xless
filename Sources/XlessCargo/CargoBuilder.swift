import Foundation
import XlessCore
import XlessTauri

/// What the Cargo stages need from the CLI's context.
public struct CargoBuildContext: Sendable {
    public var overlay: CargoOverlay
    /// The settled config: `resolved.config.build` is the real build number.
    public var resolved: ResolvedCargo
    public var platform: Platform
    public var sourceRoot: URL
    public var workRoot: URL
    public var paths: StagePaths
    public var sdk: DarwinSDK
    public var env: [String: String]

    public init(overlay: CargoOverlay, resolved: ResolvedCargo, platform: Platform, sourceRoot: URL, workRoot: URL, paths: StagePaths,
                sdk: DarwinSDK = DarwinSDK(), env: [String: String] = ProcessInfo.processInfo.environment) {
        self.overlay = overlay; self.resolved = resolved; self.platform = platform; self.sourceRoot = sourceRoot
        self.workRoot = workRoot; self.paths = paths; self.sdk = sdk; self.env = env
    }

    var cargoHome: String { env["CARGO_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (env["HOME"] ?? NSHomeDirectory()) + "/.cargo" }
    /// Child-process additions: rustup's bin dir first on PATH (rustup-init may have just created it).
    var tools: [String: String] { ["PATH": "\(cargoHome)/bin:\(env["PATH"] ?? "/usr/bin:/bin")"] }
    /// The cargo targets of this platform: on macOS, those of `macos.architectures`.
    var rustTargets: [String] { platform == .ios ? [RustApple.iosTarget] : resolved.platform.architectures.map(\.rustTarget) }
    var inputsRecord: URL { workRoot.appendingPathComponent(".xless/cargo-inputs.json") }
}

/// The `prepare` and `build` stages for `type: cargo` overlays: a Rust binary built with cargo for iOS (device) or macOS
/// (universal, or the one architecture of `macos.architectures`) and packaged into its `.app` by `CargoBundler`, with no Xcode.
public enum CargoBuilder {
    /// What `prepare` leaves for `build`: the inputs' directories, by environment variable and by input name.
    struct InputsRecord: Codable, Equatable {
        var env: [String: String]
        var paths: [String: String]
    }

    // MARK: prepare

    /// Syncs the work copy, materializes the build inputs and installs the Rust toolchain with this platform's targets.
    @discardableResult
    public static func prepare(ctx: CargoBuildContext) async throws -> URL {
        try await withStage(.prepare) {
            log("syncing \(ctx.sourceRoot.path) → \(ctx.workRoot.path)")
            // In docker every source is mounted at /source; scripts/testflight.sh names the host path in XLESS_SOURCE_ORIGIN.
            let origin = ctx.env["XLESS_SOURCE_ORIGIN"].flatMap { $0.isEmpty ? nil : $0 }
            let count = try WorkCopy.sync(source: ctx.sourceRoot, to: ctx.workRoot, origin: origin, baseEnvironment: ctx.env)
            log("\(count) tracked files")

            let cache = ctx.env["XLESS_CACHE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: (ctx.env["HOME"] ?? NSHomeDirectory()) + "/.cache/xless")
            let mounted = ctx.env["XLESS_INPUTS_MOUNTED"] == "1" ? URL(fileURLWithPath: "/inputs", isDirectory: true) : nil
            let byEnv = try CargoInputs.materialize(ctx.overlay.inputs, sourceRoot: ctx.sourceRoot, cache: cache.appendingPathComponent("inputs"),
                                                    mounted: mounted, env: ctx.env)
            try writeRecord(InputsRecord(env: byEnv, paths: Dictionary(uniqueKeysWithValues: ctx.overlay.inputs.compactMap { input in
                byEnv[input.env].map { (input.name, $0) }
            })), to: ctx.inputsRecord)

            try RustApple.bootstrap(searchFrom: ctx.workRoot, workRoot: ctx.workRoot, toolchain: ctx.overlay.toolchain, targets: ctx.rustTargets,
                                    env: ctx.tools, baseEnvironment: ctx.env, log: { log($0) })
            return ctx.workRoot
        }
    }

    // MARK: build

    /// cargo for the platform (on macOS one run per chosen darwin triple, two merged into a universal executable), then
    /// the `.app` in `ctx.paths.app`.
    public static func build(ctx: CargoBuildContext) async throws -> URL {
        try await withStage(.build) {
            let r = ctx.resolved, block = r.platform, work = ctx.workRoot
            let minOS = try r.config.platform(ctx.platform).minimumOS
            let record = try readRecord(ctx)
            let inputURLs = record.paths.mapValues { URL(fileURLWithPath: $0, isDirectory: true) }
            let swift = try SwiftToolchain.load(env: ctx.env)
            let toolchain = ctx.overlay.toolchain

            func environment(platform: [String: String]) -> [String: String] {
                buildEnvironment(base: ctx.tools, overlayEnv: ctx.overlay.env, inputs: record.env, toolchain: toolchain, platformEnv: platform)
            }
            func cargo(_ arguments: [String], env: [String: String]) throws -> String {
                try Shell.run("cargo", arguments, cwd: work, env: env, baseEnvironment: ctx.env, stage: .build, passthrough: arguments.first == "build").stdout
            }

            let metadata = try readMetadata(cargo(["metadata", "--format-version", "1", "--no-deps"], env: environment(platform: [:])), package: block.package)
            let bin = block.bin ?? metadata.onlyBin ?? block.package

            let executable: URL
            switch ctx.platform {
            case .ios:
                let target = RustApple.iosTarget
                let platformEnv = try RustApple.iosCargoEnv(minOS: minOS, sdk: ctx.sdk, workRoot: work, swift: swift)
                try runCargo(target: target, bin: bin, block: block, env: environment(platform: platformEnv), cargo: cargo)
                executable = metadata.targetDir.appendingPathComponent("\(target)/release/\(bin)")
            case .macos:
                var thins: [(triple: String, url: URL)] = []
                for triple in ctx.rustTargets {
                    let platformEnv = try RustApple.macCargoEnv(target: triple, minOS: minOS, sdk: ctx.sdk, workRoot: work, swift: swift)
                    try runCargo(target: triple, bin: bin, block: block, env: environment(platform: platformEnv), cargo: cargo)
                    thins.append((triple, metadata.targetDir.appendingPathComponent("\(triple)/release/\(bin)")))
                }
                let staging = work.appendingPathComponent(".xless/cargo-mac", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                executable = staging.appendingPathComponent(bin)
                try RustApple.macExecutable(thins, binary: bin).write(to: executable)
            }

            let vars = try builtInVariables(ctx)
            let privacy = r.config.privacyManifest.map { URL(fileURLWithPath: $0) }
            return try Files.atomicOutput(ctx.paths.app) {
                try CargoBundler.assemble(resolved: r, platform: ctx.platform, work: work, inputs: inputURLs, vars: vars,
                                          executable: executable, privacyManifest: privacy, into: $0)
            }
        }
    }

    private static func runCargo(target: String, bin: String, block: CargoPlatform, env: [String: String],
                                 cargo: ([String], [String: String]) throws -> String) throws {
        let arguments = cargoArguments(platform: target == RustApple.iosTarget ? .ios : .macos, target: target, package: block.package,
                                       bin: bin, features: block.features)
        log("cargo \(arguments.joined(separator: " "))")
        _ = try cargo(arguments, env)
    }

    // MARK: pure pieces

    /// `cargo build` for one target: release, the lockfile as committed, one package and binary.
    static func cargoArguments(platform: Platform, target: String, package: String, bin: String, features: [String]) -> [String] {
        var arguments = ["build", "--release", "--locked", "-p", package, "--bin", bin, "--target", target]
        if !features.isEmpty { arguments += ["--features", features.joined(separator: ",")] }
        return arguments
    }

    /// cargo's environment: `base`, then the build inputs' variables, the overlay's `env:` and the platform's variables,
    /// each over the one before; the pinned toolchain (`RUSTUP_TOOLCHAIN`, which beats a repository's rust-toolchain file)
    /// is set on top. The overlay may not set it itself.
    static func buildEnvironment(base: [String: String], overlayEnv: [String: String], inputs: [String: String], toolchain: String?,
                                 platformEnv: [String: String]) -> [String: String] {
        var env = base
        for layer in [inputs, overlayEnv, platformEnv] { env.merge(layer) { _, new in new } }
        if let toolchain { env["RUSTUP_TOOLCHAIN"] = toolchain }
        return env
    }

    /// The values the Info.plist templates may name (`@VERSION@`…).
    private static func builtInVariables(_ ctx: CargoBuildContext) throws -> [String: String] {
        let sha: String
        do {
            sha = try Shell.run("git", WorkCopy.git(ctx.sourceRoot, ["rev-parse", "HEAD"]), baseEnvironment: ctx.env, stage: .build)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as XlessError {
            throw XlessError(.build, "cannot read the git commit of \(ctx.sourceRoot.path): \(e.cause)",
                             fix: "build from a git checkout with at least one commit (GIT_SHA is an Info.plist placeholder value)")
        }
        return ["VERSION": ctx.resolved.fullVersion, "SHORT_VERSION": ctx.resolved.config.version,
                "BUILD_NUMBER": ctx.resolved.config.build, "GIT_SHA": sha]
    }

    // MARK: cargo metadata

    struct Metadata {
        var targetDir: URL
        /// The package's binary, when it has exactly one.
        var onlyBin: String?
    }

    static func readMetadata(_ json: String, package: String) throws -> Metadata {
        struct Raw: Decodable {
            struct Package: Decodable {
                struct Target: Decodable { var name: String; var kind: [String] }
                var name: String; var targets: [Target]
            }
            var packages: [Package]?; var target_directory: String
        }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: Data(json.utf8)) } catch {
            throw XlessError(.build, "cannot read cargo metadata: \(error)", fix: "run `cargo metadata --format-version 1 --no-deps` in the work copy to see what fails")
        }
        let bins = raw.packages?.first { $0.name == package }?.targets.filter { $0.kind.contains("bin") }.map(\.name) ?? []
        return Metadata(targetDir: URL(fileURLWithPath: raw.target_directory, isDirectory: true), onlyBin: bins.count == 1 ? bins[0] : nil)
    }

    // MARK: inputs record

    static func writeRecord(_ record: InputsRecord, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch {
            throw XlessError(.prepare, "cannot write \(url.path): \(error)", fix: "check disk space and permissions")
        }
    }

    private static func readRecord(_ ctx: CargoBuildContext) throws -> InputsRecord {
        let url = ctx.inputsRecord
        guard let data = FileManager.default.contents(atPath: url.path), let record = try? JSONDecoder().decode(InputsRecord.self, from: data) else {
            throw XlessError(.build, "\(url.path) is missing or unreadable", fix: "run the prepare stage first (`xless ship --from prepare`)")
        }
        let missing = ctx.overlay.inputs.filter { record.env[$0.env] == nil || record.paths[$0.name] == nil }.map(\.name)
        guard missing.isEmpty else {
            throw XlessError(.build, "the prepared inputs lack \(missing.joined(separator: ", ")), which the overlay declares", fix: "run the prepare stage again (`xless ship --from prepare`)")
        }
        return record
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("xless: \(message)\n".utf8))
    }
}
