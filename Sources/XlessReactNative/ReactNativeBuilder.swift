import Crypto
import Foundation
import XlessCore
import XlessTauri
import XlessXcode

/// What the React Native stages need from the CLI's context.
public struct ReactNativeBuildContext: Sendable {
    public var overlay: ReactNativeOverlay
    public var resolved: ResolvedReactNative
    public var sourceRoot: URL
    public var workRoot: URL
    public var paths: StagePaths
    public var env: [String: String]
    /// The device (`iphoneos`, the default) or the iOS Simulator (`SimulatorBuild`).
    public var destination: BuildRequest.Destination

    public init(overlay: ReactNativeOverlay, resolved: ResolvedReactNative, sourceRoot: URL, workRoot: URL, paths: StagePaths,
                env: [String: String] = ProcessInfo.processInfo.environment, destination: BuildRequest.Destination = .iphoneos) {
        self.overlay = overlay; self.resolved = resolved; self.sourceRoot = sourceRoot; self.workRoot = workRoot
        self.paths = paths; self.env = env; self.destination = destination
    }

    var appDir: URL { workRoot.appendingPathComponent(overlay.appDir, isDirectory: true).standardizedFileURL }
    var iosDir: URL { appDir.appendingPathComponent("ios", isDirectory: true) }
    /// Swift Build's derived data, kept between builds (incremental builds); never inside a stage output. Simulator
    /// builds have their own, so they never disturb the device build's.
    var derivedData: URL {
        workRoot.appendingPathComponent(destination == .iphoneos ? ".xless/derived-data" : ".xless/derived-data-simulator", isDirectory: true)
    }
    var stateFile: URL { ReactNativeProject.stateFile(work: workRoot) }
    /// The toolchain identity (`ReactNativeBuilder.toolchainIdentity`) that made the work copy's JS dependency trees.
    var toolchainFile: URL { workRoot.appendingPathComponent(".xless/rn-toolchain") }
    /// Written by `build` for the sign stage.
    public var entitlementsFile: URL { paths.root.appendingPathComponent("entitlements.json") }
    public var packagesFile: URL { paths.root.appendingPathComponent("packages.json") }
}

/// The `prepare` and `build` stages for `type: react-native` overlays: on Linux, what an Expo app's iOS build does on a
/// Mac (`expo prebuild`, `pod install`, `xcodebuild` of the workspace), with Swift Build in place of Xcode. Procedure
/// and every setting: docs/research/react-native-ios-contract.md (gates G1–G4); user guide: docs/react-native.md;
/// regression: scripts/test-rn-linux.sh.
public enum ReactNativeBuilder {
    // MARK: prepare

    /// 1. contract checks (CocoaPods/Bundler from the source's Gemfile.lock); 2. the work copy; 3. the JS install (from
    /// empty dependency trees after a toolchain change or with `XLESS_RN_CLEAN=1`: `resetJSDependencies`), then
    /// the React Native / Expo contract check on what was installed, then the overlay's `prepare.run`; 4. Expo prebuild
    /// unless `ios/` is tracked; 5. `bundle install` + `bundle exec pod install`. Steps 4–5 are skipped when nothing they
    /// read changed since the last successful prepare (`fingerprint`) and the pods are installed, unless
    /// `XLESS_RN_CLEAN=1`; with a tracked `ios/`, there is no prebuild and `pod install` always runs (it is quick when the
    /// pods are current).
    @discardableResult
    public static func prepare(ctx: ReactNativeBuildContext) async throws -> URL {
        try await withStage(.prepare) {
            let image = try SwiftBuildEnvironment.fromProcess(ctx.env, stage: .prepare)
            let o = ctx.overlay
            try ReactNativeContract.checkRuby(appDir: ctx.sourceRoot.appendingPathComponent(o.appDir), root: ctx.sourceRoot)
            let iosTracked = try isTracked(ios: "\(o.appDir == "." ? "" : o.appDir + "/")ios", in: ctx.sourceRoot, env: ctx.env)
            // Only the overlay's env is part of the fingerprint; a variable the app reads from the host environment is not.
            for name in o.env.keys.sorted() where ctx.env[name] != nil {
                log("warning: \(name) is set both in the overlay's env and in xless's environment; the overlay's value is used")
            }

            log("syncing \(ctx.sourceRoot.path) → \(ctx.workRoot.path)")
            let origin = ctx.env["XLESS_SOURCE_ORIGIN"].flatMap { $0.isEmpty ? nil : $0 }
            let count = try WorkCopy.sync(source: ctx.sourceRoot, to: ctx.workRoot, origin: origin, baseEnvironment: ctx.env)
            log("\(count) tracked files")

            let env = ReactNativeEnvironment.prepare(overlay: o, shimDirectory: image.shimDirectory, base: ctx.env)
            let app = ctx.appDir
            guard let jsRoot = jsRoot(app: app, work: ctx.workRoot), let install = try TauriBuilder.installCommand(appRoot: jsRoot) else {
                throw XlessError(.prepare, "no package.json with a lockfile in \(o.appDir) or above it", fix: "commit the app's package.json and its lockfile")
            }
            // Before the install: whether it starts from empty dependency trees depends on the toolchain (Ruling R6).
            let tools = try toolVersions(installer: Array(install.arguments.prefix(install.arguments.first == "corepack" ? 2 : 1)), jsRoot: jsRoot, env: env, ctx: ctx)
            let toolchain = toolchainIdentity(ctx, tools: tools)
            let clean = ctx.env["XLESS_RN_CLEAN"] == "1"
            try resetDerivedData(ctx, toolchain: toolchain, clean: clean)
            try resetJSDependencies(ctx, jsRoot: jsRoot, toolchain: toolchain, clean: clean)
            var installArgs = install.arguments
            if install.lockfile == "pnpm-lock.yaml" {
                // The store next to the work copies (the same volume in docker), so pnpm hard-links instead of copying.
                installArgs += ["--store-dir", ctx.workRoot.deletingLastPathComponent().appendingPathComponent(".pnpm-store").path]
            }
            log("\(installArgs.joined(separator: " ")) (\(install.lockfile) in \(relative(jsRoot, to: ctx.workRoot)))")
            try run(installArgs, cwd: jsRoot, env: env, ctx: ctx)
            try Data(toolchain.utf8).write(to: ctx.toolchainFile, options: .atomic)
            try ReactNativeContract.checkJavaScript(appDir: app, root: ctx.workRoot)

            for command in o.prepareRun {
                log("prepare.run: \(command)")
                try run(["sh", "-c", command], cwd: ctx.workRoot, env: env, ctx: ctx)
            }

            let fingerprint = try self.fingerprint(ctx, toolchain: toolchain)
            if clean { log("XLESS_RN_CLEAN=1: regenerating the native project") }
            let steps = nativeSteps(iosTracked: iosTracked, recorded: clean ? nil : try? String(contentsOf: ctx.stateFile, encoding: .utf8),
                                    fingerprint: fingerprint, podsInstalled: podsInstalled(ios: ctx.iosDir),
                                    hasWorkspace: (try? ReactNativeProject.workspaceURL(ios: ctx.iosDir, scheme: o.scheme, stage: .prepare)) != nil)
            switch steps {
            case .upToDate:
                log("native project up to date (sources, overlay, image and pods unchanged): no prebuild, no pod install")
                // Normally a no-op (the last prepare switched them); it repairs a tree a hand-run build switched back.
                try ConfigurationSwitches.run(ios: ctx.iosDir, configuration: o.configuration, env: env, baseEnvironment: ctx.env)
                return ctx.workRoot
            case .pods:
                log("ios/ is tracked: no expo prebuild")
            case .prebuildAndPods:
                break
            }
            try? FileManager.default.removeItem(at: ctx.stateFile)
            if steps == .prebuildAndPods {
                // A clean native project every time the inputs change, as `expo prebuild --clean` makes it (the work
                // copy's ios/ is generated, never tracked).
                try? FileManager.default.removeItem(at: ctx.iosDir)
                guard let expo = binary("expo", from: app, work: ctx.workRoot) else {
                    throw XlessError(.prepare, "the expo CLI is not installed (no node_modules/.bin/expo for \(o.appDir))",
                                     fix: "add expo to the app's dependencies; apps without the expo package are not supported")
                }
                log("expo prebuild --platform ios --no-install")
                var prebuildEnv = env
                prebuildEnv["CI"] = "1"                   // never prompt
                prebuildEnv["EXPO_NO_GIT_STATUS"] = "1"   // the work copy is not a git repository
                try run([expo.path, "prebuild", "--platform", "ios", "--no-install"], cwd: app, env: prebuildEnv, ctx: ctx)
            }
            guard FileManager.default.fileExists(atPath: ctx.iosDir.appendingPathComponent("Podfile").path) else {
                throw XlessError(.prepare, "no ios/Podfile in \(o.appDir) after prebuild", fix: "check the expo prebuild output above")
            }
            log("bundle install (ios)")
            try run(["bundle", "install"], cwd: ctx.iosDir, env: env, ctx: ctx)
            log("bundle exec pod install")
            try run(["bundle", "exec", "pod", "install"], cwd: ctx.iosDir, env: env, ctx: ctx)
            guard podsInstalled(ios: ctx.iosDir) else {
                throw XlessError(.prepare, "pod install finished but Pods/Manifest.lock differs from Podfile.lock", fix: "check the pod install output above")
            }
            _ = try ReactNativeProject.workspaceURL(ios: ctx.iosDir, scheme: o.scheme, stage: .prepare)
            // The pods' configuration switches (prebuilt Debug → the overlay's configuration), now rather than mid-build.
            log("configuration switches of the prebuilt pods (\(o.configuration))")
            try ConfigurationSwitches.run(ios: ctx.iosDir, configuration: o.configuration, env: env, baseEnvironment: ctx.env)
            try Data(fingerprint.utf8).write(to: ctx.stateFile, options: .atomic)
            return ctx.workRoot
        }
    }

    /// What `prepare` does to the native project.
    enum NativeSteps: Equatable {
        /// Nothing: the inputs are those of the last successful prepare, and its pods and workspace are in place.
        case upToDate
        /// `bundle install` + `pod install` on the tracked `ios/` (an app that commits its native project).
        case pods
        /// A clean `ios/` from Expo prebuild, then the pods (Expo CNG: `ios/` is generated, never tracked).
        case prebuildAndPods
    }

    static func nativeSteps(iosTracked: Bool, recorded: String?, fingerprint: String, podsInstalled: Bool, hasWorkspace: Bool) -> NativeSteps {
        if iosTracked { return .pods }
        return recorded == fingerprint && podsInstalled && hasWorkspace ? .upToDate : .prebuildAndPods
    }

    /// Whether the app commits its native project: `ios/Podfile` or an `ios/*.xcodeproj` is tracked (`ios` relative to
    /// `source`). Other tracked files under `ios/` (a stray asset, a README) do not make a native project.
    static func isTracked(ios: String, in source: URL, env: [String: String]) throws -> Bool {
        let out = try Shell.run("git", WorkCopy.git(source, ["ls-files", "-z", "--", "\(ios)/Podfile", "\(ios)/*.xcodeproj/project.pbxproj"]),
                                baseEnvironment: env, stage: .prepare).stdout
        return !out.isEmpty
    }

    /// The nearest directory from `app` up to `work` with a package.json and a lockfile (a monorepo installs at its root).
    static func jsRoot(app: URL, work: URL) -> URL? {
        let fm = FileManager.default
        return walkUp(from: app, to: work) { d in
            fm.fileExists(atPath: d.appendingPathComponent("package.json").path)
                && ["pnpm-lock.yaml", "package-lock.json", "yarn.lock"].contains { fm.fileExists(atPath: d.appendingPathComponent($0).path) } ? d : nil
        }
    }

    /// `node_modules/.bin/<name>` from `app` up to `work`.
    static func binary(_ name: String, from app: URL, work: URL) -> URL? {
        walkUp(from: app, to: work) { d in
            let f = d.appendingPathComponent("node_modules/.bin/\(name)")
            return FileManager.default.isExecutableFile(atPath: f.path) ? f : nil
        }
    }

    static func podsInstalled(ios: URL) -> Bool {
        guard let a = try? Data(contentsOf: ios.appendingPathComponent("Podfile.lock")),
              let b = try? Data(contentsOf: ios.appendingPathComponent("Pods/Manifest.lock")) else { return false }
        return a == b
    }

    /// What prebuild and pod install read, hashed: the source's tracked files (index entries plus uncommitted edits;
    /// the work copy mirrors exactly those), the overlay's prepare inputs (only its `env:`; host variables are not
    /// seen), and the toolchain (`toolchainIdentity`).
    static func fingerprint(_ ctx: ReactNativeBuildContext, toolchain: String) throws -> String {
        let src = ctx.sourceRoot
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([0])) }
        // -3: prepare runs the pods' configuration switches, for the overlay's configuration. -4: the toolchain is
        // hashed on its own (Ruling R6).
        add("xless-rn-prepare-4"); add(XlessVersion.current); add(ctx.overlay.appDir); add(ctx.overlay.configuration)
        add(toolchain)
        for (k, v) in ctx.overlay.env.sorted(by: { $0.key < $1.key }) { add(k); add(v) }
        for c in ctx.overlay.prepareRun { add(c) }
        add(try Shell.run("git", WorkCopy.git(src, ["ls-files", "-s", "-z", "--", "."]), baseEnvironment: ctx.env, stage: .prepare).stdout)
        add(try Shell.run("git", WorkCopy.git(src, ["diff", "--no-ext-diff", "--binary", "--", "."]), baseEnvironment: ctx.env, stage: .prepare).stdout)
        return h.finalize().map { String(format: "%02x", $0) }.joined() + "\n"
    }

    /// What builds the app, hashed: the image (`XLESS_IMAGE_ID`, baked in by docker/Dockerfile.rn), the Darwin SDK (its
    /// toolchain metadata: images made from another Xcode share the image ID's commit; Ruling R8), the Swift toolchain that
    /// compiles (Ruling R10), the running xless executable, and the tool versions (`tools`: Node, the JS package manager,
    /// Ruby, Bundler).
    static func toolchainIdentity(_ ctx: ReactNativeBuildContext, tools: [String]) -> String {
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([0])) }
        add("xless-rn-toolchain-2")
        add(ctx.env["XLESS_IMAGE_ID"] ?? "(no image id)")
        add((try? Data(contentsOf: ToolchainMeta.defaultLocation(env: ctx.env))).map { String(decoding: $0, as: UTF8.self) } ?? "(no toolchain metadata)")
        add((try? SwiftToolchain.load(env: ctx.env)).flatMap { $0 }.map { "swift \($0.version) at \($0.root)" } ?? "(no swift toolchain record)")
        add(executableDigest())
        for t in tools { add(t) }
        return h.finalize().map { String(format: "%02x", $0) }.joined() + "\n"
    }

    /// Ruling R6: packages cache their own build outputs inside `node_modules`, keyed on their sources only (Expo's
    /// prebuilt xcframework slices, for one), so a toolchain change would reuse binaries the previous toolchain made.
    /// When the toolchain is not the one recorded after the last JS install (`ctx.toolchainFile`; no record counts as
    /// another toolchain), or with `XLESS_RN_CLEAN=1`, the work copy's JS dependency trees (`jsDependencyTrees`) are
    /// deleted; the install repopulates them from the package manager's store (a cache volume: a reinstall, not a
    /// download). The source checkout is never touched. Returns the deleted trees, relative to the work copy.
    @discardableResult
    static func resetJSDependencies(_ ctx: ReactNativeBuildContext, jsRoot: URL, toolchain: String, clean: Bool) throws -> [String] {
        let recorded = try? String(contentsOf: ctx.toolchainFile, encoding: .utf8)
        guard clean || recorded != toolchain else { return [] }
        let listing = try Shell.run("git", WorkCopy.git(ctx.sourceRoot, ["ls-files", "-z", "--", "package.json", "*/package.json"]),
                                    baseEnvironment: ctx.env, stage: .prepare).stdout
        let trees = jsDependencyTrees(work: ctx.workRoot, jsRoot: jsRoot,
                                      packageJSONs: listing.split(separator: "\0", omittingEmptySubsequences: true).map(String.init))
        guard !trees.isEmpty else { return [] }
        log(clean ? "XLESS_RN_CLEAN=1: reinstalling JS dependencies"
                  : "toolchain changed: reinstalling JS dependencies (cached build outputs in node_modules were made by another toolchain)")
        return try trees.map { tree in
            let rel = relative(tree, to: ctx.workRoot)
            log("deleting \(rel)")
            do { try FileManager.default.removeItem(at: tree) } catch {
                throw XlessError(.prepare, "cannot delete \(rel) in the work copy before the JS reinstall: \(error.localizedDescription)",
                                 fix: "delete the work copy \(ctx.workRoot.path) (or its docker volume) and re-run")
            }
            return rel
        }
    }

    /// Swift Build's derived data (device and simulator) holds module caches and objects of the previous toolchain and
    /// image; an image rebuilt from the same Xcode even changes the SDK files' times, which the module cache's explicit
    /// module builds then refuse ("has been modified since the module file … was built"). On the same condition as
    /// `resetJSDependencies` (another toolchain, or `XLESS_RN_CLEAN=1`), both are deleted. Returns the deleted
    /// directories, relative to the work copy.
    @discardableResult
    static func resetDerivedData(_ ctx: ReactNativeBuildContext, toolchain: String, clean: Bool) throws -> [String] {
        let recorded = try? String(contentsOf: ctx.toolchainFile, encoding: .utf8)
        guard clean || recorded != toolchain else { return [] }
        var deleted: [String] = []
        for d in [BuildRequest.Destination.iphoneos, .iphonesimulator] {
            var c = ctx; c.destination = d
            guard FileManager.default.fileExists(atPath: c.derivedData.path) else { continue }
            let rel = relative(c.derivedData, to: ctx.workRoot)
            log("\(clean ? "XLESS_RN_CLEAN=1" : "toolchain changed"): deleting \(rel)")
            do { try FileManager.default.removeItem(at: c.derivedData) } catch {
                throw XlessError(.prepare, "cannot delete \(rel) in the work copy: \(error.localizedDescription)",
                                 fix: "delete the work copy \(ctx.workRoot.path) (or its docker volume) and re-run")
            }
            deleted.append(rel)
        }
        return deleted
    }

    /// The `node_modules` next to each of `packageJSONs` (the source's tracked package.json files, relative to the work
    /// copy) at or below `jsRoot`: the install's root and its workspace packages, whatever the package manager. Never a
    /// path outside the work copy: a package directory whose real path (symlinks resolved) leaves it is skipped, and a
    /// `node_modules` that is a symlink is returned as itself (deleting it unlinks it; its target is not followed).
    static func jsDependencyTrees(work: URL, jsRoot: URL, packageJSONs: [String]) -> [URL] {
        let fm = FileManager.default
        let root = jsRoot.standardizedFileURL.path
        let resolvedWork = work.resolvingSymlinksInPath().standardizedFileURL.path
        var trees: [URL] = [], seen = Set<String>()
        for path in packageJSONs {
            let parts = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), parts.last == "package.json", !parts.contains(".."), !parts.contains("node_modules") else { continue }
            let dir = parts.dropLast().reduce(work) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
            guard dir.path == root || dir.path.hasPrefix(root + "/") else { continue }
            let real = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard real == resolvedWork || real.hasPrefix(resolvedWork + "/") else { continue }
            let tree = dir.appendingPathComponent("node_modules")
            guard (try? fm.attributesOfItem(atPath: tree.path)) != nil, seen.insert(tree.path).inserted else { continue }
            trees.append(tree)
        }
        return trees
    }

    /// SHA-256 of the running executable (a rebuilt xless may prepare differently while its version string stays).
    static func executableDigest() -> String {
        guard let url = Bundle.main.executableURL, let handle = try? FileHandle(forReadingFrom: url) else { return "(unknown executable)" }
        defer { try? handle.close() }
        var h = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `node --version`, the JS package manager's `--version` (`installer`: e.g. `corepack pnpm`, run in `jsRoot`,
    /// which selects its version), `ruby -v` and `bundle -v`, with the prepare environment.
    static func toolVersions(installer: [String], jsRoot: URL, env: [String: String?], ctx: ReactNativeBuildContext) throws -> [String] {
        try [(["node", "--version"], nil), (installer + ["--version"], jsRoot), (["ruby", "-v"], nil), (["bundle", "-v"], nil)].map { argv, cwd in
            argv.joined(separator: " ") + ": "
                + (try Shell.run(argv[0], Array(argv.dropFirst()), cwd: cwd, env: env, baseEnvironment: ctx.env, stage: .prepare).stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: build

    /// The workspace's Swift packages, the case aliases, the PIF and build request (bundle IDs, versions, team, Linux
    /// overrides), Swift Build, then the `.app` into `ctx.paths.app` with every bundle's version stamped, and
    /// `entitlements.json`, `packages.json` and (device builds) the `dSYMs` next to it. Returns the `.app`.
    public static func build(ctx: ReactNativeBuildContext) async throws -> URL {
        try await withStage(.build) { try restage(.build) { try buildApp(ctx) } }
    }

    /// `build`'s work. XlessXcode reports its refusals (unsupported pbxproj, package requirements, PIF JSON) as
    /// `prepare` errors; `build` re-stages them. A simulator build (`SimulatorBuild`) also links each bundle's
    /// simulated entitlements and signs the app ad hoc.
    static func buildApp(_ ctx: ReactNativeBuildContext) throws -> URL {
        let o = ctx.overlay, config = ctx.resolved.config
        let simulator = ctx.destination == .iphonesimulator, platform = ctx.destination.platformName
        let environment = try SwiftBuildEnvironment.fromProcess(ctx.env, stage: .build)
        let fm = FileManager.default
        for f in [ctx.entitlementsFile, ctx.packagesFile] { try? fm.removeItem(at: f) }

        let wsURL = try ReactNativeProject.workspaceURL(ios: ctx.iosDir, scheme: o.scheme, stage: .build)
        let ws = try XcodeWorkspace.load(wsURL)
        let scheme = try ws.scheme(named: o.scheme)
        let app = try ReactNativeProject.appTarget(ws, scheme: o.scheme, stage: .build)
        let embedded = ReactNativeProject.embeddedTargets(app, in: ws)
        let bundleTargets = [app] + embedded
        let ids = try bundleIDs(overlay: o, app: app.target.name, embedded: embedded.map(\.target.name), workspace: ws)
        log("scheme \(o.scheme): app \(app.target.name) (\(ids[app.target.name]!))\(embedded.map { ", \($0.target.name) (\(ids[$0.target.name]!))" }.joined())")

        let dd = ctx.derivedData, xlessDir = dd.appendingPathComponent("xless")
        let products = dd.appendingPathComponent("Products/\(o.configuration)-\(platform)")
        let extra = ReactNativeEnvironment.buildSettings(overlay: o).merging(simulator ? SimulatorBuild.buildSettings : [:]) { $1 }
        let overrides = try SwiftBuildRunner.prepareOverrides(environment, directory: xlessDir, extra: extra, stage: .build)
        let entitlements = try entitlementsByTarget(bundleTargets, ids: ids, configuration: o.configuration, platform: platform,
                                                    overrides: overrides)

        // Per-target settings: the overlay's bundle IDs and the run's version (ReactNativeEnvironment.targetSettings);
        // for the simulator, the simulated entitlements linked into each bundle's executable.
        var perTarget: [String: [String: String]] = [:]
        for (p, t) in bundleTargets {
            var settings = ReactNativeEnvironment.targetSettings(bundleID: ids[t.name]!, version: config.version, build: config.build)
            if simulator {
                let simulated = SimulatorBuild.simulatedEntitlements(entitlements[t.name]!, teamID: o.teamID, rewrites: o.entitlements)
                settings.merge(try SimulatorBuild.entitlementSections(simulated, target: t.name, in: xlessDir.appendingPathComponent("entitlements"))) { $1 }
            }
            perTarget[PIFWriter.targetGUID(t, in: p, workspace: ws)] = settings
        }
        let built = try ws.overridingTargetSettings(perTarget)

        let (packages, records) = try SwiftPackageCheckouts.resolve(ws, in: xlessDir.appendingPathComponent("packages"), env: ctx.env)
        let aliases = try XCFrameworkAliases.create(pods: ctx.iosDir.appendingPathComponent("Pods"),
                                                    intermediates: products.appendingPathComponent("XCFrameworkIntermediates"))
        if aliases > 0 { log("\(aliases) lowercase framework aliases in XCFrameworkIntermediates") }

        guard fm.isExecutableFile(atPath: ReactNativeEnvironment.hermesc) else {
            throw XlessError(.build, "\(ReactNativeEnvironment.hermesc) is missing", fix: "run in the xless-rn image, which builds hermesc from source")
        }
        let pif = try PIFWriter.write(built, to: xlessDir, packages: packages)
        let request = xlessDir.appendingPathComponent("request.json")
        try BuildRequest.make(workspace: built, scheme: scheme, configuration: o.configuration, overrides: overrides, destination: ctx.destination)
            .write(to: request, options: .atomic)

        log("swbuild \(o.scheme) (\(o.configuration), \(platform)) — log: \(xlessDir.appendingPathComponent("swbuild.log").path)")
        let start = Date()
        let summary = try SwiftBuildRunner.build(pif: pif, request: request, derivedData: dd, environment: environment,
                                                 log: xlessDir.appendingPathComponent("swbuild.log"),
                                                 extraEnvironment: ReactNativeEnvironment.build(overlay: o), stage: .build, baseEnvironment: ctx.env)
        for w in summary.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
        for e in summary.errors { FileHandle.standardError.write(Data("error: \(e)\n".utf8)) }
        FileHandle.standardError.write(Data(failedTasksReport(summary).utf8))
        log("swbuild: \(summary.succeeded ? "succeeded" : "failed"), \(summary.tasks) tasks in \(Int(Date().timeIntervalSince(start))) s")
        let allowedMissing = try checkPhaseOutput(summary, allowed: o.allowMissingCommands,
                                                  log: xlessDir.appendingPathComponent("swbuild.log"))
        for line in allowedMissing { FileHandle.standardError.write(Data("warning: a build phase ran a missing command (allowed by allowMissingCommands): \(line)\n".utf8)) }

        guard let productRef = app.target.productReferenceID, let product = app.project.fileReferences[productRef] else {
            throw XlessError(.build, "the app target \(app.target.name) has no product reference", fix: "regenerate the project (expo prebuild)")
        }
        let builtApp = products.appendingPathComponent((product.path as NSString).lastPathComponent)
        guard fm.fileExists(atPath: builtApp.appendingPathComponent("Info.plist").path) else {
            throw XlessError(.build, "Swift Build reported success but \(builtApp.path) is not a built app", fix: "see \(xlessDir.appendingPathComponent("swbuild.log").path)")
        }

        let result = try Files.atomicOutput(ctx.paths.app) { dir -> URL in
            let copy = try Files.copyBundle(builtApp, intoFreshDir: dir)
            let byPath = try finish(copy, appTarget: app.target.name, ids: ids, entitlements: entitlements, ctx: ctx)
            try BuiltApp.entitlementsJSON(byPath).write(to: ctx.entitlementsFile, options: .atomic)
            if simulator {
                // No finalize for the simulator: the Info.plist identifiers are replaced here, before the ad-hoc signature.
                let replaced = try o.identifiers.rewriteInfoPlists(in: copy, stage: .build)
                if !o.identifiers.isEmpty {
                    log("identifiers.replace: \(replaced.count) Info.plist value(s) replaced\(replaced.isEmpty ? "" : ": " + replaced.joined(separator: ", "))")
                }
                try finishSimulator(copy, nested: byPath.keys.filter { !$0.isEmpty }.sorted(), scratch: xlessDir, ctx: ctx)
            }
            return copy
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(["packages": records]).write(to: ctx.packagesFile, options: .atomic)
        if !simulator {
            let dSYMs = try BuiltApp.copyDSYMs(from: products, to: ctx.paths.dSYMs)
            log("dSYMs: \(dSYMs.isEmpty ? "none (DEBUG_INFORMATION_FORMAT is not dwarf-with-dsym)" : dSYMs.joined(separator: ", "))")
        }
        return result
    }

    /// The overlay's bundle IDs checked against the project: the app target and every bundle it embeds need one, and
    /// nothing else may have one (a misspelt or stale target name). Embedded IDs must extend the app's.
    static func bundleIDs(overlay o: ReactNativeOverlay, app: String, embedded: [String], workspace ws: Workspace) throws -> [String: String] {
        let wanted = [app] + embedded
        for name in wanted where o.bundleIDs[name] == nil {
            throw XlessError(.build, name == app ? "bundleIDs has no entry for the app target \(name)" : "the app embeds \(name), which has no entry in bundleIDs",
                             fix: "add \(name): <bundle ID> to bundleIDs\(name == app ? "" : " (e.g. \(o.bundleIDs[app] ?? "<app ID>").\(name))")")
        }
        for name in o.bundleIDs.keys.sorted() where !wanted.contains(name) {
            let exists = ws.projects.contains { $0.target(named: name) != nil }
            throw XlessError(.build, exists ? "bundleIDs.\(name) names a target the app \(app) does not embed" : "bundleIDs.\(name) names no target of \(ws.path.lastPathComponent)",
                             fix: "bundleIDs maps the app target and the extensions it embeds: \(wanted.joined(separator: ", "))")
        }
        let appID = o.bundleIDs[app]!
        for name in embedded where !o.bundleIDs[name]!.hasPrefix(appID + ".") {
            throw XlessError(.build, "bundleIDs.\(name) '\(o.bundleIDs[name]!)' does not start with the app's \(appID) + '.'",
                             fix: "App Store apps require it, e.g. \(appID).\(name)")
        }
        return o.bundleIDs
    }

    /// Each failed task with the tail of its output (`Summary.failedTaskOutput`), for stderr.
    static func failedTasksReport(_ summary: SwiftBuildOutput.Summary) -> String {
        summary.failedTasks.indices.map { i in
            "failed: \(summary.failedTasks[i])\n" + (i < summary.failedTaskOutput.count ? summary.failedTaskOutput[i] : []).map { "  | \($0)\n" }.joined()
        }.joined()
    }

    /// Ruling R4 on the build's task output (on a Mac the tools exist and take these calls, so the app would silently
    /// differ), then the build's result. In order, the build fails on:
    /// - a shim refusal (`Summary.shimRefusals`) anywhere, even in a task that succeeded: a phase that tests a tool
    ///   (`xcrun --find actool` inside `[ … ]`) or ignores its status goes on without it. `allowMissingCommands` does
    ///   not apply: the tool exists, and the call is one xless has not measured against Xcode's. The cause is the
    ///   first refusal in a failed task's output, else the first one;
    /// - a missing command (`Summary.commandsNotFound`) not named in `allowed` (returned: the allowed ones, to warn about);
    /// - a failed build.
    static func checkPhaseOutput(_ summary: SwiftBuildOutput.Summary, allowed: [String], log: URL) throws -> [String] {
        if let refusal = summary.firstShimRefusal {
            throw XlessError(.build, summary.succeeded ? "a build phase went on after an xless shim refused a call: \(refusal)" : refusal,
                             fix: "the shims refuse calls they were not measured for against Xcode's tools (the task and its output are in \(log.path)); the call needs shim support")
        }
        var ok: [String] = []
        for line in summary.commandsNotFound {
            guard let name = SwiftBuildOutput.missingCommandName(line[...]) else { continue }
            if allowed.contains(name) || allowed.contains((name as NSString).lastPathComponent) { ok.append(line); continue }
            throw XlessError(.build, "a build phase ran a missing command (\(name)): \(line)",
                             fix: "provide \((name as NSString).lastPathComponent) in the image (a shim), or, if the app is right without it, add it to allowMissingCommands in the overlay")
        }
        guard summary.succeeded else {
            throw XlessError(.build, "Swift Build failed: \(summary.failedTasks.first ?? summary.errors.first ?? "no failed task reported")",
                             fix: "see the errors above and \(log.path)")
        }
        return ok
    }

    static func entitlementsByTarget(_ targets: [(project: XcodeProject, target: Target)], ids: [String: String], configuration: String,
                                     platform: String = "iphoneos", overrides: [String: String]) throws -> [String: BuiltApp.Entitlements] {
        var out: [String: BuiltApp.Entitlements] = [:]
        for (p, t) in targets {
            let id = ids[t.name]!
            let settings = try TargetSettings(project: p, target: t, configuration: configuration, platform: platform,
                                              overrides: overrides.merging(["PRODUCT_BUNDLE_IDENTIFIER": id]) { $1 })
            out[t.name] = try BuiltApp.entitlements(settings, bundleID: id)
        }
        return out
    }

    /// The built app's bundles: each one's bundle ID checked, its version stamped, its entitlements keyed by its path;
    /// the overlay's privacy manifest copied in.
    static func finish(_ app: URL, appTarget: String, ids: [String: String], entitlements: [String: BuiltApp.Entitlements],
                       ctx: ReactNativeBuildContext) throws -> [String: BuiltApp.Entitlements] {
        let bundles = try BuiltApp.bundles(in: app)
        var byPath: [String: BuiltApp.Entitlements] = [:]
        for b in bundles {
            let target = b.path.isEmpty ? appTarget : ids.first { $0.value == b.bundleID }?.key
            guard let target, let e = entitlements[target] else {
                throw XlessError(.build, "the app contains \(b.path) (bundle ID \(b.bundleID)), which comes from no target in bundleIDs",
                                 fix: "map the target that builds \((b.path as NSString).lastPathComponent) in bundleIDs")
            }
            guard b.bundleID == ids[target] else {
                throw XlessError(.build, "\(b.path.isEmpty ? app.lastPathComponent : b.path) has bundle ID \(b.bundleID), not the overlay's \(ids[target]!)",
                                 fix: "make \(target)'s Info.plist use $(PRODUCT_BUNDLE_IDENTIFIER) for CFBundleIdentifier")
            }
            byPath[b.path] = e
        }
        for target in entitlements.keys.sorted() where !byPath.values.contains(where: { $0.target == target }) {
            throw XlessError(.build, "the app does not contain the bundle of \(target)", fix: "check the app target's Copy Files phases")
        }
        let config = ctx.resolved.config
        let changed = try BuiltApp.stampVersions(app: app, bundles: bundles, version: config.version, build: config.build)
        log("version \(config.version) (\(config.build)) in \(bundles.count) bundle(s)\(changed.isEmpty ? "" : "; stamped \(changed.map { $0.isEmpty ? app.lastPathComponent : $0 }.joined(separator: ", "))")")
        if let privacy = ctx.overlay.privacyManifest {
            let dest = app.appendingPathComponent("PrivacyInfo.xcprivacy")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: URL(fileURLWithPath: privacy), to: dest) } catch {
                throw XlessError(.build, "cannot copy privacyManifest \(privacy): \(error.localizedDescription)", fix: "check privacyManifest in the overlay")
            }
        }
        return byPath
    }

    /// The simulator app after `finish`: refused when dyld would refuse one of its images (as `finalize` does for the
    /// device), then signed ad hoc (`SimulatorBuild`), so `simctl install` takes it as it is.
    static func finishSimulator(_ app: URL, nested: [String], scratch: URL, ctx: ReactNativeBuildContext) throws {
        let problems = try SimulatorBuild.linkeditProblems(in: app)
        guard problems.isEmpty else {
            throw XlessError(.build, "dyld would refuse \(problems.count) image(s) of the simulator app: \(problems.joined(separator: ", "))",
                             fix: "report this binary to the xless maintainers")
        }
        log("signing \(app.lastPathComponent) ad hoc for the simulator (rcodesign, no key)")
        try SimulatorBuild.signAdHoc(app, nested: nested, scratch: scratch, baseEnvironment: ctx.env)
    }

    // MARK: helpers

    private static func run(_ argv: [String], cwd: URL, env: [String: String?], ctx: ReactNativeBuildContext) throws {
        try Shell.run(argv[0], Array(argv.dropFirst()), cwd: cwd, env: env, baseEnvironment: ctx.env, stage: .prepare, passthrough: true)
    }

    static func relative(_ url: URL, to base: URL) -> String {
        let p = url.standardizedFileURL.path, b = base.standardizedFileURL.path
        return p == b ? "." : p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : p
    }
}
