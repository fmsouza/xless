import Foundation
import XlessASC
import XlessAssets
import XlessBuild
import XlessCargo
import XlessCore
import XlessFinalize
import XlessPackage
import XlessReactNative
import XlessSign
import XlessTauri

/// One function per stage. Each runs inside `withStage`, so every failure (including raw App Store Connect,
/// network and file errors) prints `[stage] cause — fix` and exits with that stage's code.
enum StageRunner {
    /// Overlays only: contract checks, the work copy and what the build needs (Tauri: toolchains; React Native: the JS
    /// install, Expo prebuild, CocoaPods; cargo: the build inputs and the Rust toolchain).
    /// The image is checked first (`BuildSDKCheck`, as the build stage will): a wrong or missing SDK or Swift toolchain
    /// is refused before the work copy, the JS install, prebuild and CocoaPods run.
    static func prepare(_ ctx: Context) async throws -> String {
        if ctx.hasPrepare {
            try await withStage(.prepare) { _ = try BuildSDKCheck.check(pin: ctx.config.xcode, platform: ctx.platform, file: pinFile(ctx), stage: .prepare) }
        }
        if let rn = ctx.reactNativeBuild { return try await ReactNativeBuilder.prepare(ctx: rn).path }
        if let cargo = ctx.cargoBuild { return try await CargoBuilder.prepare(ctx: cargo).path }
        if let mac = ctx.tauriMacBuild { return try await TauriBuilder.prepareMac(ctx: mac).path }
        guard let tauri = ctx.tauriBuild else { return "skipped (not an overlay project)" }
        return try await TauriBuilder.prepare(ctx: tauri).path
    }

    static func build(_ ctx: Context) async throws -> URL {
        try await withStage(.build) { try checkSDK(ctx) }
        if let rn = ctx.reactNativeBuild { return try await ReactNativeBuilder.build(ctx: rn) }
        if let cargo = ctx.cargoBuild { return try await CargoBuilder.build(ctx: cargo) }
        if let mac = ctx.tauriMacBuild { return try await TauriBuilder.buildMac(ctx: mac) }
        if let tauri = ctx.tauriBuild { return try await TauriBuilder.build(ctx: tauri) }
        return try await withStage(.build) {
            switch ctx.platform {
            case .ios: return try IOSBuilder.build(project: ctx.project, config: ctx.config, paths: ctx.paths)
            case .macos: return try MacBuilder.build(project: ctx.project, config: ctx.config, paths: ctx.paths)
            }
        }
    }

    /// Ruling R8: the image's SDK (its toolchain metadata) against the project's `xcode:` pin, then recorded next to the
    /// build's output (`BuildSDKRecord`) and printed; finalize stamps from the same SDK. Without metadata (a host with no
    /// SDK installed) and without a pin there is nothing to check or record.
    /// Ruling R10: the image's Swift toolchain must be the one that Xcode ships (`SwiftToolchain.check`); it is recorded
    /// and printed with the SDK, and put on this process's PATH before the image's own Swift (`activate`), so every
    /// compile the build runs uses it (Swift Build also gets it through its toolset: `SwiftBuildEnvironment`).
    /// The checks and the record are `BuildSDKCheck`'s (tested there).
    static func checkSDK(_ ctx: Context) throws {
        let (result, sdk) = try BuildSDKCheck.checkAndRecord(stageRoot: ctx.paths.root, pin: ctx.config.xcode, platform: ctx.platform, file: pinFile(ctx))
        result.toolchain?.activate()
        if let sdk {
            FileHandle.standardError.write(Data("xless: SDK: \(sdk.summary(platform: ctx.platform)) (recorded in \(BuildSDKRecord.url(in: ctx.paths.root).path))\n".utf8))
        }
        if let swift = result.swift { FileHandle.standardError.write(Data("xless: compiler: \(swift.summary)\n".utf8)) }
    }

    /// Where the pin is written, for the refusals.
    static func pinFile(_ ctx: Context) -> String { ctx.hasPrepare ? "the overlay" : "xless.yml" }

    static func assets(_ ctx: Context) async throws -> URL {
        try await withStage(.assets) {
            try ctx.requireDevice(.assets)
            let input = try ctx.paths.bundle(in: ctx.paths.app, stage: .assets)
            // Tauri on macOS: nothing to compile (the icon is bundle.icon's .icns, copied by the build); React Native:
            // Swift Build compiled the asset catalogs and storyboards (actool/ibtool shims); cargo on macOS without an
            // asset catalog: the build copied `icon`'s .icns, or there is no icon. Copy through.
            if ctx.tauriMac != nil || ctx.isReactNative || cargoMacWithoutCatalog(ctx) { return try Files.atomicOutput(ctx.paths.assets) { try Files.copyBundle(input, intoFreshDir: $0) } }
            return try await AssetsStage.run(input: input, outputDir: ctx.paths.assets, platform: ctx.platform, config: ctx.config, project: ctx.project,
                                             profile: { try XcodeToolsProfile.forImage(stage: .assets) })
        }
    }

    /// A cargo overlay's macOS app whose icon is a ready `.icns` (`macos.icon`) or absent: only `macos.assets` is compiled.
    static func cargoMacWithoutCatalog(_ ctx: Context) -> Bool {
        guard ctx.platform == .macos, let block = ctx.cargoResolved?.platform else { return false }
        return block.assets == nil
    }

    static func finalize(_ ctx: Context) async throws -> URL {
        try await withStage(.finalize) {
            try ctx.requireDevice(.finalize)
            let input = try ctx.paths.bundle(in: ctx.paths.assets, stage: .finalize)
            let meta = try ToolchainMeta.load(from: ToolchainMeta.defaultLocation())
            let kind: ProjectKind = ctx.isReactNative ? .reactNative : ctx.isCargo ? .cargo : ctx.isTauri ? .tauri : .xlessYML
            let built = BuildSDKRecord.load(in: ctx.paths.root)
            // Ruling R10: the compiler the build recorded (DTCompiler stays Xcode's compiler identifier for every Swift).
            if let swift = built?.swift { FileHandle.standardError.write(Data("xless: built with \(swift.summary)\n".utf8)) }
            return try Finalizer.run(input: input, outputDir: ctx.paths.final, platform: ctx.platform, config: ctx.config, meta: meta, kind: kind,
                                     built: built, identifiers: ctx.rnOverlay?.identifiers ?? .none)
        }
    }

    static func sign(_ ctx: Context) async throws -> URL {
        try await withStage(.sign) {
            try ctx.requireDevice(.sign)
            let input = try ctx.paths.bundle(in: ctx.paths.final, stage: .sign)
            // The Info.plists carry the map finalize applied: an overlay edited since (`--from sign`) is refused.
            try (ctx.rnOverlay?.identifiers ?? .none).checkFinalized(in: ctx.paths.final)
            let client = ASCClient(credentials: try ASCCredentials.fromSecrets(ctx.secrets, stage: .sign))
            // React Native: every bundle's entitlements as the build recorded them, with the overlay's edits.
            let manifest = ctx.reactNativeBuild.map { EntitlementsManifest(file: $0.entitlementsFile, rewrites: $0.overlay.entitlements) }
            return try await SignStage.run(input: input, outputDir: ctx.paths.signed, platform: ctx.platform, config: ctx.config,
                                           project: ctx.project, secrets: ctx.secrets, client: client, manifest: manifest)
        }
    }

    static func package(_ ctx: Context) async throws -> URL {
        try await withStage(.package) {
            try ctx.requireDevice(.package)
            let input = try ctx.paths.bundle(in: ctx.paths.signed, stage: .package)
            switch ctx.platform {
            case .ios: return try Packager.ipa(signedApp: input, outputDir: ctx.paths.out)
            // App Store mac (TestFlight's flat package, explicit via the distribution): the pkg.
            // Takes priority over the overlay branches: an appStore run never produces a DMG.
            case .macos where ctx.config.distribution(for: .macos) == .appStore:
                return try await PkgBuilder.appStore(signedApp: input, outputDir: ctx.paths.out, config: ctx.config, secrets: ctx.secrets)
            // Tauri and cargo overlays: a signed, notarized, stapled DMG; xless.yml: a notarized zip of the signed app.
            case .macos where ctx.tauriMac != nil || ctx.isCargo:
                return try await DmgBuilder.notarizedDMG(signedApp: input, outputDir: ctx.paths.out, config: ctx.config, secrets: ctx.secrets)
            case .macos: return try Packager.notarizedZip(signedApp: input, outputDir: ctx.paths.out, secrets: ctx.secrets)
            }
        }
    }

    struct UploadOutcome {
        var record: UploadRecord
        /// Present when xless.yml has a `testflight:` block.
        var testflight: TestFlightResult?

        /// Terminal output: the build line, then the TestFlight delivery summary when configured (warnings go to stderr).
        func report() -> String {
            "build \(record.buildID ?? "?") \(record.processingState ?? record.state)"
                + (testflight.map { "\n" + $0.summary.joined(separator: "\n") } ?? "")
        }
    }

    static func upload(_ ctx: Context) async throws -> UploadOutcome {
        try await withStage(.upload) {
            try ctx.requireDevice(.upload)
            // The App Store mac: the pkg (from package) to ASC's build-upload API under the mac
            // bundle id. Developer-ID mac builds stay distributed directly (the refusal below).
            if ctx.platform == .macos {
                guard ctx.config.distribution(for: .macos) == .appStore else {
                    throw XlessError(.upload, "upload is App Store only; macOS Developer ID builds are distributed directly", fix: "use the notarized zip from `xless package --platform macos`")
                }
                let app = try ctx.paths.bundle(in: ctx.paths.signed, stage: .package)
                return try await uploadPkg(ctx: ctx, app: app, bundleID: ctx.config.bundleID(for: .macos))
            }
            guard ctx.platform == .ios else {
                throw XlessError(.upload, "upload is App Store only; macOS Developer ID builds are distributed directly", fix: "use the notarized zip from `xless package --platform macos`")
            }
            let ipas = ((try? FileManager.default.contentsOfDirectory(at: ctx.paths.out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "ipa" }
            let product = try ctx.config.platform(.ios).product
            guard !ipas.isEmpty else { throw XlessError(.upload, "no .ipa in \(ctx.paths.out.path)", fix: "run `xless package --platform ios` first") }
            let matching = ipas.first { $0.deletingPathExtension().lastPathComponent == product }
            guard let ipa = matching ?? (ipas.count == 1 ? ipas[0] : nil) else {
                throw XlessError(.upload, "multiple .ipa files in \(ctx.paths.out.path) and none is named \(product).ipa",
                                 fix: "remove stale .ipa files, or run `xless package --platform ios` again")
            }
            // Declare what the ipa carries, not the current config: the build number is re-resolved on every run.
            let versions = try IPAInfo.uploadVersions(ipa: ipa, buildOverride: ctx.buildOverride)
            return try await uploadPackage(ctx: ctx, asset: ipa, name: ipa.lastPathComponent, bundleID: ctx.config.bundleID(for: .ios),
                                           version: versions.version, build: versions.build, platform: .ios)
        }
    }

    /// One artifact's ride to App Store Connect and — when the config has a testflight block — to the
    /// groups it names. The ipa and the mac pkg share this tail; every caller declares the file itself
    /// (its name, the bundle id and versions) so nothing assumes where the artifact came from.
    private static func uploadPackage(ctx: Context, asset: URL, name: String, bundleID: String,
                                      version: String, build: String, platform: Platform) async throws -> UploadOutcome {
        let client = ASCClient(credentials: try ASCCredentials.fromSecrets(ctx.secrets, stage: .upload))
        let recordURL = ctx.paths.uploadRecord
        try? FileManager.default.removeItem(at: recordURL)
        let record = try await BuildUploader(client: client).upload(ipa: asset, bundleID: bundleID,
                                                              version: version, build: build, platform: platform) { record in
            // Written on every state change, so the build ID survives a processing failure or timeout.
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(record).write(to: recordURL, options: .atomic)
        }
        guard let tf = ctx.config.testflight, let buildID = record.buildID else { return UploadOutcome(record: record, testflight: nil) }
        let result = try await TestFlightPublisher(client: client).publish(
            bundleID: bundleID, buildID: buildID, buildNumber: build, config: tf)
        for w in result.warnings { FileHandle.standardError.write(Data((w + "\n").utf8)) }
        return UploadOutcome(record: record, testflight: result)
    }

    /// The mac App Store pkg's upload: the pkg `package` made, the versions read from the signed app's
    /// plist (the same plist the payload carries).
    private static func uploadPkg(ctx: Context, app: URL, bundleID: String) async throws -> UploadOutcome {
        let product = try ctx.config.platform(.macos).product
        let pkgs = ((try? FileManager.default.contentsOfDirectory(at: ctx.paths.out, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pkg" }
        guard let pkg = pkgs.first(where: { $0.deletingPathExtension().lastPathComponent == product }) ?? (pkgs.count == 1 ? pkgs[0] : nil) else {
            throw XlessError(.upload, "no \(product).pkg in \(ctx.paths.out.path)",
                             fix: "run `xless package --platform macos --distribution app-store` first")
        }
        let versions = try IPAInfo.uploadVersions(app: app, buildOverride: ctx.buildOverride)
        return try await uploadPackage(ctx: ctx, asset: pkg, name: pkg.lastPathComponent, bundleID: bundleID,
                                       version: versions.version, build: versions.build, platform: .macos)
    }
}
