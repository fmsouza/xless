import ArgumentParser
import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// `xless setup`: on a Mac, by default, a check of the Xcode that is installed there, which a native build uses (nothing is
/// downloaded or changed); on Linux, by default, a native install of what the images carry (`NativeSetupPlan`: xtool and
/// rcodesign, and the Xcode pack of the Xcode, with its open-source Swift and the Darwin SDK exported from it), with no
/// Docker and no sudo. With `--docker`,
/// the image of this xless, xless:<version>-<arch> (no Xcode goes into it), and the Xcode pack of an Xcode .xip or Xcode.app
/// prepared by that image's own setup in a container, into a volume: Docker and nothing else, no Mac, no Apple binary
/// executed (xtool reads the Xcode in the container), no checkout. `--with` adds the kits: what Tauri, Cargo, React Native
/// and Expo apps need on top of the image, which `xless run --docker` otherwise builds when it needs them.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Prepare an Xcode's pack (its SDK, with the Swift toolchain fitted to it) natively from its .xip (on a Mac: check the installed Xcode), or with --docker the xless image and the pack in a Docker volume.",
        discussion: """
        On a Mac, without --docker, it checks the Xcode that native builds use (DEVELOPER_DIR, xcode-select or /Applications; \
        --xcode <Xcode.app> checks that one) and says which tools they run. It downloads and changes nothing. The rest is for \
        Linux and for --docker.

        The Xcode is identified by its content (a .xip's SHA-256, an Xcode.app's version.plist), never by its name. The Darwin \
        SDK is exported into $XDG_CACHE_HOME/xless/sdk/xcode<V>-<B>/ (default ~/.cache/xless) and reused by later runs \
        (--reexport exports again).

        Once exported, the Xcode is no longer needed: --sdk <dir> sets up from that export instead (its toolchain-meta.json \
        names the Xcode, which must be one versions.env supports), and with neither --xcode nor --sdk setup reuses the \
        cache's export when exactly one holds the architectures it sets up. Nothing is exported then, so the cache's \
        free-space check is skipped.

        Native (the default, Linux only): xtool and rcodesign are downloaded (each checked against versions.env's sha256) into \
        $XLESS_NATIVE_HOME (default $XDG_DATA_HOME/xless-native, else ~/.local/share/xless-native), and the Xcode pack of \
        that Xcode is prepared in the store, $XLESS_XCODES (default the native home's xcodes/): the open-source Swift \
        toolchain of that Xcode's Swift, the SDK installed for xtool and SwiftPM, the toolchain fitted to it. Several Xcodes \
        live side by side, one pack each; a project's xcode: picks one, else the newest is used. A pack is prepared beside \
        its place and put there whole, so a failed setup leaves the pack that was there; a second setup of the same pack \
        waits for the first. The store must be on a case-sensitive file system. No Docker and no sudo; the host commands it \
        needs (\(NativeSetupPlan.requiredCommands.joined(separator: ", "))) are checked first, and free space: \
        XLESS_SETUP_CACHE_GB under the cache (only when the SDK is exported) and XLESS_SETUP_NATIVE_GB under the store (only \
        when a pack is prepared).

        --docker: the image of this xless, xless:<version>-<arch>, one per xless and architecture, with nothing of an Xcode in \
        it (built unless it is there), and the Xcode pack, prepared by that image's own xless setup in a container: in the \
        volume xless-xcode-<version>-<build>-<arch> (one per pack), or in the directory XLESS_XCODES names. The container \
        mounts the Xcode read-only, the SDK export of the cache (written when it is exported there), and the store; nothing \
        else of this machine. The pack is left as it is when it is current (its recipes are this xless's), so a new xless \
        reuses it; a part that is not is prepared again alone. --with adds the kits on top of the image: tauri (Tauri and \
        Cargo apps) and react-native (React Native and Expo apps), comma separated; xless run --docker builds the one it needs \
        by itself. With neither --xcode nor --sdk, --with adds them to the image, and with no SDK export in the cache either \
        setup builds the image alone. The Linux xless that goes into the image: XLESS_BIN_ARM64 / XLESS_BIN_AMD64 when set, \
        else this xless on a Linux host of that arch, else, for a checkout, the one the image compiles from it, else the \
        release's linux tarball, checked against its SHA256SUMS. Before any step it checks that Docker answers, that buildx \
        is installed, and that there is free space, per architecture: XLESS_SETUP_CACHE_GB under the cache (only when the \
        SDK is exported) and, on Linux, XLESS_SETUP_DOCKER_GB under Docker's data root.

        Each figure is versions.env's; an environment variable of the same name wins. --dry-run prints the plan and what \
        the disk check asks for, and runs nothing.
        """)

    @Option(help: "The Xcode: a downloaded Xcode .xip (any name) or an Xcode.app. Not needed once its SDK is exported (see --sdk).") var xcode: String?
    @Option(help: ArgumentHelp("Set up from this SDK export instead of an Xcode: a directory an earlier setup exported into (e.g. ~/.cache/xless/sdk/xcode27.0-27A266a). Without --xcode or --sdk: the cache's one export.",
                               valueName: "dir")) var sdk: String?
    @Flag(help: "Build the xless Docker image, and prepare the Xcode's pack in a container of it, instead of installing natively.") var docker = false
    @Option(parsing: .upToNextOption, help: "With --docker: architectures arm64 and/or amd64 (default: this machine's).") var arch: [String] = []
    @Option(help: ArgumentHelp("With --docker: also build the kits for these kinds of app, comma separated (\(Kit.names.joined(separator: ", "))).", valueName: "kinds")) var with: String?
    @Flag(help: "Export the SDK again even when an export of this Xcode exists (needs --xcode).") var reexport = false
    @Flag(help: "Print the plan (each step's command) and run nothing.") var dryRun = false

    func run() async throws {
        do { try setup() } catch let e as XlessError { throw e } catch let problem as ImageProblem {
            throw XlessError(.sdk, problem.cause, fix: problem.fix)
        } catch {
            throw XlessError(.sdk, "\(error.localizedDescription)", fix: "see the output above, then run xless setup again")
        }
    }

    /// What this run sets up from, as its arguments spell it: for a fix that names the same setup with other flags.
    private var sourceArgs: String {
        if let xcode { return " --xcode \(ShellWord.quoted(xcode))" }
        if let sdk { return " --sdk \(ShellWord.quoted(sdk))" }
        return " [--xcode <Xcode .xip or Xcode.app>]"
    }

    private func setup() throws {
        if xcode != nil, sdk != nil {
            throw XlessError(.sdk, "--xcode and --sdk both name what to set up from",
                             fix: "pass one: --xcode to export the SDK from that Xcode, or --sdk to reuse an export")
        }
        if reexport, xcode == nil {
            throw XlessError(.sdk, "--reexport exports the SDK again, which needs the Xcode",
                             fix: "pass it: xless setup --xcode <Xcode .xip or Xcode.app> --reexport")
        }
        let kits = try self.kits()
        if !docker {
            guard kits.isEmpty else {
                throw XlessError(.sdk, "--with adds to the Docker image", fix: "add --docker, or drop --with")
            }
            guard arch.allSatisfy({ $0 == Self.hostArch }) else {
                throw XlessError(.sdk, "--arch \(arch.joined(separator: " ")) needs --docker: a native setup installs for this machine (\(Self.hostArch)) only",
                                 fix: "drop --arch, or add --docker to set up the xless image and the Xcode packs for those architectures")
            }
            guard Self.isLinux else { return try macSetup() }
        }
        var archs: [String] = []
        for a in docker && !arch.isEmpty ? arch : [Self.hostArch] where !archs.contains(a) {
            guard a == "arm64" || a == "amd64" else {
                throw XlessError(.sdk, "unknown architecture '\(a)'", fix: "pass --arch arm64 and/or --arch amd64")
            }
            archs.append(a)
        }
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let share = try XlessShare.root(env: env, executable: exe)
        let versionsEnv = share.appendingPathComponent("versions.env")
        let known = try KnownXcodes.load(versionsEnv: versionsEnv)
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        let table = KnownXcodes.parseEnv((try? String(contentsOf: versionsEnv, encoding: .utf8)) ?? "")
        let cacheRoot = SetupPlan.cacheRoot(env: env, home: home)
        let source: XcodeSource.Identified?
        if let xcode {
            if !dryRun { say("==> identifying \(xcode)") }
            source = try XcodeSource.identify(path: xcode, known: known, cwd: cwd, home: home)
        } else if let sdk {
            source = try XcodeSource.identifyExport(path: sdk, known: known, cwd: cwd, home: home)
        } else if docker, !kits.isEmpty || !Self.hasExports(cacheRoot) {
            // The image needs no Xcode: --with alone adds the kits to it, and with no export to prepare a pack from, it is built alone.
            source = nil
        } else {
            source = try XcodeSource.findExport(cacheRoot: cacheRoot, known: known, archs: archs)
        }
        if let source {
            // Before anything is downloaded, built or started: an Xcode that no pack can be prepared of.
            try XcodeSupport.require(source.xcode, known: known, table: table, share: share)
            // An export is reused as it is: every architecture this run sets up must already be in it.
            if source.kind == .export { try XcodeSource.checkExport(source.url, holds: archs) }
        }
        if docker {
            try dockerSetup(source: source, archs: archs, kits: kits, env: env, exe: exe, share: share, home: home, cwd: cwd, table: table, cacheRoot: cacheRoot)
        } else if let source {
            try nativeSetup(source: source, env: env, share: share, table: table, cacheRoot: cacheRoot)
        }
    }

    // MARK: - Native

    /// A Mac builds with its own Xcode: there is nothing to install, so this checks it and says what a build would use.
    private func macSetup() throws {
        var env = ProcessInfo.processInfo.environment
        guard sdk == nil, !reexport, xcode?.hasSuffix(".xip") != true else {
            throw XlessError(.sdk, "on a Mac xless builds with the Xcode that is installed, not with an exported SDK\(xcode.map { " (\($0))" } ?? "")",
                             fix: "xless setup checks it (an Xcode .xip: open it, and move the Xcode to /Applications); to build in Docker: xless setup --docker\(sourceArgs)")
        }
        let given = xcode.map { XcodeSource.absolute($0, cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), home: URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())).path }
        let chosen = try? XcodeFinder(environment: env).find(pin: nil, stage: .sdk)
        if let given { env["DEVELOPER_DIR"] = given }
        let native = try MacNative.find(pin: nil, stage: .sdk, env: env)
        for p in Platform.allCases { try Requirements.checkSDK(native.meta.sdk(for: p), platform: p, stage: .sdk) }
        let xcodebuild = try native.xcode.require(.xcodebuild, stage: .sdk)
        let launched = (try? Shell.run(xcodebuild.path, ["-checkFirstLaunchStatus"], env: native.xcode.environment(env), stage: .sdk)) != nil
        say("==> \(native.xcode.summary)")
        say("    " + (try Platform.allCases.map { let s = try native.meta.sdk(for: $0); return "\(s.sdkName) SDK (\(s.sdkBuild))" }).joined(separator: ", ") + "; \(native.compiler)")
        say("    \(native.tools.summary(of: native.xcode))")
        let signer = try MacNative.signer(env: env)
        say("    rcodesign, which signs: " + (signer.isInstalled ? "in \(signer.download.final.path)" : "the first run that signs fetches it (\(signer.download.url.lastPathComponent), checked against its SHA-256)"))
        if given != nil, chosen?.app != native.xcode.app {
            say("note: a build uses \(chosen?.summary ?? "no Xcode yet"): to build with this one, export DEVELOPER_DIR=\(ShellWord.quoted(native.xcode.developer.path))")
        }
        if !launched { say("note: this Xcode has not finished its first launch: if a tool of it fails, open it once (it installs what is missing and asks for its license)") }
        say("==> ready: nothing to install")
        say("next: xless run <project-dir> --build-number 1 --to finalize")
    }

    private func nativeSetup(source: XcodeSource.Identified, env: [String: String], share: URL, table: [String: String], cacheRoot: URL) throws {
        let fm = FileManager.default
        let x = source.xcode, layout = NativeLayout(env: env), store = XcodeStore(env: env), arch = Self.hostArch
        let version = XcodeVersion.canonical(x.shortVersion)
        let name = XcodePack.name(xcode: version, build: x.build, arch: arch)
        let abilities = PackPlan.abilities(env: env)
        func plan() throws -> [SetupStep] {
            try NativeSetupPlan.make(source: source, arch: arch, share: share, cacheRoot: cacheRoot, layout: layout, store: store,
                                     table: table, reexport: reexport, abilities: abilities,
                                     installed: { NativeSetupPlan.pinnedOnPath($0, version: $1, path: env["PATH"]) },
                                     existing: { fm.fileExists(atPath: $0.path) })
        }
        var steps = try plan()
        let need = Self.nativeNeeds(steps, env: env, table: table)
        let missing = NativeSetupPlan.requiredCommands.filter { Self.which($0, path: env["PATH"]) == nil }

        say("==> Xcode \(version) (\(x.build)) from \(Self.origin(source)), natively for \(arch): the pack \(name) in \(store.root.path); "
            + "tools in \(layout.root.path); SDK export in \(SetupPlan.sdkDir(source: source, cacheRoot: cacheRoot).path)")
        if dryRun {
            say("dry run: the plan, nothing runs")
            if !missing.isEmpty { say("missing commands: \(missing.joined(separator: ", ")) (\(NativeSetupPlan.aptLine))") }
            say("disk: the check asks for about \(need.cache.spoken) free under \(cacheRoot.path) (\(need.cache.key)) and \(need.store.spoken) under \(store.root.path) (\(need.store.key))")
            for (n, s) in steps.enumerated() {
                say("[\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
                say("    " + s.argv.map(ShellWord.quoted).joined(separator: " "))
            }
            if steps.isEmpty { say("nothing to do: the pack \(name) is current") }
            return
        }
        guard missing.isEmpty else {
            throw XlessError(.sdk, "a native setup needs \(missing.joined(separator: ", ")), which \(missing.count == 1 ? "is" : "are") not on PATH",
                             fix: "install them (Debian/Ubuntu: \(NativeSetupPlan.aptLine)), or build in Docker instead: xless setup --docker\(sourceArgs)")
        }
        // The docker it asks whether a running build uses the pack, as every xless command chooses it.
        try HostDocker.check()
        // Before anything is written into the store: the SDK has headers whose names differ only in case.
        try PackStore.requireCaseSensitive(store)
        // A second setup of this pack waits for the first, then finds what it left.
        let lock: PackLock
        do { lock = try PackLock(store: store, name: name, wait: false) } catch is PackLock.Busy {
            say("==> waiting for another xless setup, which is preparing the pack \(name) (it holds \(PackLock.file(store: store, name: name).path))")
            lock = try PackLock(store: store, name: name, wait: true)
        }
        try withExtendedLifetime(lock) {
            for back in try PackStore.recoverAll(store, holding: name) {
                say("==> the pack \(back) is back in place: a setup had stopped while it replaced it")
            }
            // An Xcode installed natively by an xless of before the packs: its SDK and toolchain record, and no pack.
            let old = DarwinSDKLocator.bundle(env: env)
            let olderInstall = store.packs().isEmpty && !layout.olderInstall(env: env).isEmpty
            if olderInstall {
                say("note: the Xcode that an older xless installed natively (the SDK in \(old.deletingLastPathComponent().path), the Swift toolchain under \(layout.toolchains.path)) is not used any more: this setup prepares an Xcode pack instead")
            }
            steps = try plan() // what the setup that held the lock left changes it
            let need = Self.nativeNeeds(steps, env: env, table: table)
            if need.cache.totalGB > 0 {
                try Self.checkFree(cacheRoot, need: need.cache, what: "the cache (the SDK export, which expands the .xip there)",
                                   fix: "free some space, or set XDG_CACHE_HOME to a directory on a larger disk")
            }
            if need.store.totalGB > 0 {
                try Self.checkFree(store.root, need: need.store, what: "the Xcode pack (the Swift toolchain and the SDK)",
                                   fix: "free some space, or set XLESS_XCODES to a directory on a larger disk")
            }

            if !steps.isEmpty { say("    (\(SetupPlan.estimateNote))") }
            let start = Date()
            let staging = PackPlan.staging(of: store.directory(xcode: version, build: x.build, arch: arch))
            let checks = SetupStep.inUseChecks(steps)
            do {
                for (n, s) in steps.enumerated() {
                    // Not under a running xless docker build that mounts this store (XLESS_XCODES): asked before the first step,
                    // and again right before the pack is replaced.
                    if checks.contains(n) {
                        let target = SetupStep.PackTarget(store: .directory(store.root), xcode: version, build: x.build, arch: arch)
                        do { try target.refuseInUseWhereDockerAnswers(LocalImages.hereDocker) } catch let problem as ImageProblem {
                            throw XlessError(.sdk, problem.cause, fix: problem.fix) // the staging directory is discarded below
                        }
                    }
                    say("==> [\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
                    let t0 = Date()
                    try execute(s, xcode: x, layout: layout)
                    say("    done in \(Self.minutes(since: t0))")
                }
            } catch {
                // Nothing half-prepared stays beside the pack, which is as it was.
                try? PackPlan.discard(staging: staging)
                throw error
            }
            if steps.isEmpty { say("==> nothing to do: the pack \(name) of Xcode \(version) (\(x.build)) is current" + (source.kind == .export ? "" : " (--reexport exports the SDK again)")) }
            else { say("==> done in \(Self.minutes(since: start)): the pack \(name) of Xcode \(version) (\(x.build)), in \(store.root.path) (pin it with xcode: \"\(version)\")") }
            if olderInstall { say("note: what the older xless installed is not used: xless clean --old removes it") }
        }
        say("next: xless run <project-dir> --build-number 1 --to finalize")
    }

    /// What a native plan needs on disk: the cache when it exports, the store when it prepares a pack.
    private static func nativeNeeds(_ steps: [SetupStep], env: [String: String], table: [String: String]) -> (cache: SetupDisk.Need, store: SetupDisk.Need) {
        let exporting = steps.contains { if case .export = $0.action { true } else { false } }
        let preparing = steps.contains { if case .packBegin = $0.action { true } else { false } }
        return SetupDisk.nativeNeeds(exporting: exporting, preparing: preparing, env: env, table: table)
    }

    // MARK: - Docker

    private func dockerSetup(source: XcodeSource.Identified?, archs: [String], kits: [Kit], env: [String: String], exe: URL, share: URL, home: URL, cwd: URL,
                             table: [String: String], cacheRoot: URL) throws {
        // Before docker is asked anything: the docker, as every xless command chooses it.
        try HostDocker.check()
        let fm = FileManager.default
        let host = Self.hostArch
        let work = fm.temporaryDirectory.appendingPathComponent("xless-setup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let store = PackStore(env: env)
        // A directory store is checked here, where its path is: the setup container would refuse it as /xcodes.
        if case let .directory(dir) = store, source != nil, !dryRun { try PackStore.requireCaseSensitive(XcodeStore(root: dir), docker: true) }
        let tag = try ImageName.cachedTag(ofShare: share)
        let images = archs.map { ImageName.base(version: tag, arch: $0) }

        // The disk figures are per architecture; the cache one counts only the architectures whose SDK is exported in this run
        // (none from an export). An environment variable of the same name (e.g. when most layers are already cached) wins over versions.env's.
        let exporting = source.map { s in
            let dir = SetupPlan.sdkDir(source: s, cacheRoot: cacheRoot)
            return s.kind == .export ? [] : archs.filter { reexport || !fm.fileExists(atPath: dir.appendingPathComponent("\($0)/darwin.xtoolsdk").path)
                || !fm.fileExists(atPath: dir.appendingPathComponent("toolchain-meta.json").path) }
        } ?? []
        let need = SetupDisk.needs(archs: archs.count, exporting: exporting.count, env: env, table: table)
        // Rootless Docker already writes as the calling user from the container's root; `--user` would map to a subuid.
        let rootless = dryRun ? ((try? Self.dockerInfo())?.rootless ?? false) : try Self.preflight(cacheRoot: cacheRoot, need: need)
        let missing = archs.filter { (try? LocalImages.here.base(version: tag, arch: $0)) == nil }
        var binaries: [String: URL] = [:]
        for a in missing { binaries[a] = try binary(arch: a, host: host, env: env, exe: exe, cwd: cwd, home: home, work: work, tag: tag) }

        let plan = try SetupPlan.make(source: source, archs: archs, hostArch: host, share: share, cacheRoot: cacheRoot, table: table,
                                      xlessBinaries: binaries, store: store, docker: LocalImages.hereDocker, readVolumes: !dryRun, rootless: rootless,
                                      reexport: reexport, kits: kits, builder: kits.isEmpty ? nil : LocalImages.here.builder, environment: env,
                                      existing: { fm.fileExists(atPath: $0.path) })
        let place: String
        switch store {
        case .volumes:
            let x = source.map { (SetupPlan.canonicalVersion($0.xcode.shortVersion), $0.xcode.build) }
            place = x.map { x in "the volume " + archs.map { PackVolumes.name(xcode: x.0, build: x.1, arch: $0) }.joined(separator: " and ") } ?? "a volume of its own"
        case let .directory(dir): place = "\(dir.path) (XLESS_XCODES)"
        }
        if let x = source?.xcode, let source {
            say("==> Xcode \(x.shortVersion) (\(x.build)) from \(Self.origin(source)), for \(archs.joined(separator: ", ")): the image \(images.joined(separator: " and ")), and the pack in \(place)")
        } else {
            say("==> the image \(images.joined(separator: " and "))" + (kits.isEmpty ? "" : ", and the kits \(kits.map(\.rawValue).joined(separator: ", ")) on it"))
        }
        for note in plan.notes { say("==> \(note)") }
        if !plan.steps.isEmpty { say("    (\(SetupPlan.estimateNote))") }
        let noPack = source == nil && kits.isEmpty
            ? "note: no Xcode pack is prepared (no --xcode, and no SDK export in \(cacheRoot.appendingPathComponent("sdk").path)): xless setup --docker --xcode <Xcode .xip or Xcode.app> prepares one"
            : nil
        if dryRun {
            say("dry run: the plan, nothing runs")
            say("disk: the check asks for about \(need.cache.spoken) free under \(cacheRoot.path) (\(need.cache.key))"
                + (Self.isLinux ? " and \(need.docker.spoken) under Docker's data root (\(need.docker.key))" : ""))
            list(plan.steps)
            if plan.steps.isEmpty { say("nothing to do") }
            if let noPack { say(noPack) }
            return
        }

        let start = Date()
        try run(plan.steps, share: share)
        var done = images
        if let x = source?.xcode {
            let version = SetupPlan.canonicalVersion(x.shortVersion)
            done.append("the pack of Xcode \(version) (\(x.build)) in \(place) (pin it with xcode: \"\(version)\")")
        }
        say("==> done in \(Self.minutes(since: start)): \(done.joined(separator: "; "))")
        if let noPack { say(noPack) }
        if let note = Self.oldImages() { say(note) }
        say("next: xless run --docker <project-dir> --build-number 1 --to finalize")
    }

    /// Whether `<cacheRoot>/sdk` holds anything exported (of any Xcode, supported or not).
    private static func hasExports(_ cacheRoot: URL) -> Bool {
        let sdk = cacheRoot.appendingPathComponent("sdk")
        return ((try? FileManager.default.contentsOfDirectory(atPath: sdk.path)) ?? [])
            .contains { !XcodeSource.exportedArchs(sdk.appendingPathComponent($0)).isEmpty }
    }

    private func kits() throws -> [Kit] {
        var kits: [Kit] = []
        for name in (with ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let kit = Kit(named: name) else {
                throw XlessError(.sdk, "--with does not know '\(name)'", fix: "use one or more of \(Kit.names.joined(separator: ", ")), comma separated")
            }
            if !kits.contains(kit) { kits.append(kit) }
        }
        if with != nil, kits.isEmpty { throw XlessError(.sdk, "--with names nothing", fix: "use one or more of \(Kit.names.joined(separator: ", ")), comma separated") }
        return kits
    }

    private func list(_ steps: [SetupStep]) {
        for (n, s) in steps.enumerated() {
            say("[\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            say("    " + s.argv.map(ShellWord.quoted).joined(separator: " "))
        }
    }

    private func run(_ steps: [SetupStep], share: URL) throws {
        var read: [String: [String]] = [:]
        for (n, s) in steps.enumerated() {
            say("==> [\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            let t0 = Date()
            switch s.action {
            case let .kit(kit, arch):
                try Self.build(kit, arch: arch, share: share)
            case let .packRun(job):
                if let check = job.unlessCurrent {
                    // The pack the plan could not read: read now, once, with the image this setup has built.
                    let reasons = try read[check.pack] ?? {
                        let found = try PackVolumes(LocalImages.hereDocker).manifests(arch: check.arch, image: check.image)
                            .first { XcodePack.name(xcode: $0.xcode, build: $0.build, arch: $0.arch) == check.pack }
                        let reasons = SetupPlan.staleness(found, check: check)
                        say(reasons.isEmpty ? "    the pack \(check.pack) in the volume \(check.volume) is current for this xless: nothing to prepare"
                                            : "    the pack \(check.pack) in the volume \(check.volume) is not current (\(reasons.joined(separator: "; ")))")
                        return reasons
                    }()
                    read[check.pack] = reasons
                    if reasons.isEmpty {
                        say("    skipped")
                        continue
                    }
                }
                // Not under a running build that has it (a run's, or another setup's): asked before each step that writes it.
                if let target = job.writes {
                    do { try target.refuseInUse(LocalImages.hereDocker) } catch let problem as ImageProblem { throw XlessError(.sdk, problem.cause, fix: problem.fix) }
                }
                for dir in job.directories { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
                try s.start(passthrough: true)
            default:
                try execute(s, xcode: nil)
            }
            say("    done in \(Self.minutes(since: t0))")
        }
    }

    /// The kit's image on the image of this xless, unless it is there and nothing it is made from has changed.
    private static func build(_ kit: Kit, arch: String, share: URL) throws {
        let images = LocalImages.here
        let base = try images.base(version: ImageName.cachedTag(ofShare: share), arch: arch)
        let state = { try images.state(of: kit, on: base, share: share) }
        if case .current = try state() { return say("    it is there already") }
        var env = ProcessInfo.processInfo.environment
        for name in LocalImages.builderVariables { env[name] = nil }
        do { try HostDocker.docker(kit.build(on: base, share: share, builder: images.builder), baseEnvironment: env, stage: .sdk, passthrough: true) } catch let e as XlessError {
            throw ImageProblem("\(kit.image(on: base)) was not built: \(e.cause)", fix: "its output is above: it needs buildx (docker buildx version), the network and room on Docker's disk")
        }
        guard case .current = try state() else {
            throw ImageProblem("\(kit.image(on: base)) is not what was built: it is not on \(base.name)", fix: "run xless setup again when nothing else builds it")
        }
    }

    /// The images an older xless left (one per Xcode, or the tools image), in one line.
    private static func oldImages() -> String? {
        let ls = ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]
        guard let all = try? HostDocker.docker(ls, stage: .sdk).stdout else { return nil }
        let old = all.split(whereSeparator: \.isNewline).map(String.init).filter(ImageName.isLegacy)
        return old.isEmpty ? nil : "note: \(old.count) image tag\(old.count == 1 ? "" : "s") of an older xless (as \(old[0])) \(old.count == 1 ? "is" : "are") not used any more: xless clean --old removes \(old.count == 1 ? "it" : "them")"
    }

    // MARK: - Steps

    private func execute(_ s: SetupStep, xcode: KnownXcode?, layout: NativeLayout? = nil) throws {
        let fm = FileManager.default
        switch s.action {
        case .kit, .packRun: break // run(_:share:) runs them
        case .run:
            try s.start(passthrough: true)
        case let .export(partial, final):
            // A fresh, empty directory the user owns (docker would create a missing one as root); a leftover of an
            // interrupted export is removed first and never reused.
            if fm.fileExists(atPath: partial.path) {
                do { try fm.removeItem(at: partial) } catch {
                    throw XlessError(.sdk, "cannot remove \(partial.path), left by an interrupted export: \(error)",
                                     fix: "delete it (rm -rf '\(partial.path)'), then run xless setup again")
                }
            }
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            try s.start(passthrough: true)
            guard fm.fileExists(atPath: partial.appendingPathComponent("darwin.xtoolsdk").path) else {
                throw XlessError(.sdk, "xtool did not produce \(partial.path)/darwin.xtoolsdk", fix: "see xtool's output above")
            }
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: partial, to: final)
        case let .meta(xtoolSDK, out):
            guard let xcode else { return }
            let meta = try ToolchainMetaCollector.collect(xtoolSDK: xtoolSDK, xcode: xcode)
            for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
            try meta.write(to: out)
        case let .download(d):
            try Self.install(d, layout: layout ?? NativeLayout())
        case let .packBegin(staging, from, manifest):
            try PackPlan.begin(staging: staging, from: from, manifest: manifest)
        case let .packSDK(xtoolSDK, config, toolchain, xtool):
            try PackPlan.installSDK(xtoolSDK: xtoolSDK, config: config, toolchain: toolchain, xtool: xtool.path)
        case let .packPart(part, hash, staging):
            try PackPlan.record(part, hash: hash, staging: staging)
        case let .packCommit(staging, final):
            try PackPlan.commit(staging: staging, final: final)
        }
    }

    /// A native download: fetched next to its `.partial` directory (both removed first: a leftover is never reused),
    /// checked against its pin, unpacked into `.partial`, then renamed into place and linked into the native `bin/`.
    /// A tool (xtool, rcodesign) goes into the native home every Xcode's setup shares, under its lock (`PackLock(tools:)`):
    /// one that a setup of another Xcode installed while this one waited is left as it is. `wait`: false, a test's.
    static func install(_ d: NativeDownload, layout: NativeLayout, wait: Bool = true) throws {
        guard let link = d.link else { return try unpack(d, layout: layout) }
        let lock = try PackLock(tools: layout, wait: wait)
        try withExtendedLifetime(lock) {
            let at = layout.bin.appendingPathComponent(link.name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: at.path)) == d.final.appendingPathComponent(link.target).path,
               FileManager.default.fileExists(atPath: at.path) { return }
            try unpack(d, layout: layout)
        }
    }

    private static func unpack(_ d: NativeDownload, layout: NativeLayout) throws {
        let fm = FileManager.default
        let partial = d.partial, file = URL(fileURLWithPath: partial.path + ".download")
        for u in [partial, file] where fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: file); try? fm.removeItem(at: partial) }
        do {
            try Shell.run("curl", ["-fsSL", "--retry", "3", "--proto", "=https", "-o", file.path, d.url.absoluteString], stage: .sdk)
        } catch let e as XlessError {
            throw XlessError(.sdk, "cannot download \(d.url.absoluteString): \(e.cause)", fix: "check the network, then run xless setup again")
        }
        let sum = try XcodeSource.sha256(of: file)
        guard sum == d.sha256.lowercased() else {
            throw XlessError(.sdk, "\(d.url.absoluteString) has sha256 \(sum), not versions.env's \(d.sha256): nothing was installed",
                             fix: "run xless setup again; if it persists, report it (the download changed upstream)")
        }
        let staged: URL, link = d.link
        switch d.kind {
        case .appImage:
            // The AppImage's own runtime extracts it (no FUSE needed) into squashfs-root under its working directory.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try Shell.run(file.path, ["--appimage-extract"], cwd: partial, stage: .sdk)
            staged = partial.appendingPathComponent("squashfs-root")
        case .rcodesign:
            try Shell.run("tar", ["-xzf", file.path, "-C", partial.path], stage: .sdk)
            let found = fm.enumerator(at: partial, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "rcodesign" && !$0.hasDirectoryPath }
            guard let found else { throw XlessError(.sdk, "\(d.url.lastPathComponent) holds no rcodesign", fix: "report it: the release's layout changed") }
            staged = partial.appendingPathComponent("out")
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try fm.moveItem(at: found, to: staged.appendingPathComponent("rcodesign"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent("rcodesign").path)
        case .swiftToolchain:
            try Shell.run("tar", ["-xzf", file.path, "-C", partial.path, "--strip-components=1"], stage: .sdk)
            staged = partial
            // swift.org's toolchains link against the host's libraries: a missing one is named here, not mid-build.
            do { try Shell.run(partial.appendingPathComponent("usr/bin/swiftc").path, ["--version"], stage: .sdk) } catch let e as XlessError {
                throw XlessError(.sdk, "the Swift toolchain does not run on this machine: \(e.cause)",
                                 fix: "install its libraries (Debian/Ubuntu: \(NativeSetupPlan.aptLine)), then run xless setup again")
            }
        }
        if fm.fileExists(atPath: d.final.path) { try fm.removeItem(at: d.final) }
        try fm.createDirectory(at: d.final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staged, to: d.final)
        if let link {
            try fm.createDirectory(at: layout.bin, withIntermediateDirectories: true)
            let at = layout.bin.appendingPathComponent(link.name)
            try? fm.removeItem(at: at)
            try fm.createSymbolicLink(at: at, withDestinationURL: d.final.appendingPathComponent(link.target))
        }
    }

    /// The executable `name` on `path` (a PATH value), or nil.
    static func which(_ name: String, path: String?) -> String? {
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: - Preflight

    /// Docker's data root, and whether the daemon is rootless.
    private static func dockerInfo() throws -> (root: String, rootless: Bool) {
        let info = try HostDocker.docker(["info", "--format", "{{.DockerRootDir}}|{{json .SecurityOptions}}"], stage: .sdk).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(info.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""), info.contains("name=rootless"))
    }

    /// Docker answers (the cause named: permission denied or no daemon), buildx is there, and the disks have room.
    /// Returns whether the daemon is rootless.
    private static func preflight(cacheRoot: URL, need: (cache: SetupDisk.Need, docker: SetupDisk.Need)) throws -> Bool {
        let root: String, rootless: Bool
        do {
            (root, rootless) = try dockerInfo()
        } catch let e as XlessError {
            let cause = e.cause.lowercased()
            let detail = e.cause.split(separator: "\n").dropFirst().first.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""
            if cause.contains("cannot start docker") {
                throw XlessError(.sdk, "docker is not installed (or not on PATH)",
                                 fix: "install Docker Engine with the buildx plugin: https://docs.docker.com/engine/install/")
            }
            if cause.contains("permission denied") {
                throw XlessError(.sdk, "Docker refused the connection: permission denied on its socket\(detail)",
                                 fix: "add yourself to the docker group (sudo usermod -aG docker $USER), then log out and in again (or run `newgrp docker`)")
            }
            if cause.contains("cannot connect") || cause.contains("is the docker daemon running") {
                throw XlessError(.sdk, "cannot connect to the Docker daemon\(detail)",
                                 fix: "start Docker (sudo systemctl start docker; on a Mac, Docker Desktop or colima start), then run xless setup again")
            }
            throw XlessError(.sdk, "`docker info` failed\(detail)", fix: "check that `docker info` works, then run xless setup again")
        }
        do { try HostDocker.docker(["buildx", "version"], stage: .sdk) } catch {
            throw XlessError(.sdk, "docker buildx is not available", fix: "install Docker's buildx plugin (e.g. the docker-buildx-plugin package)")
        }
        if need.cache.totalGB > 0 {
            try checkFree(cacheRoot, need: need.cache, what: "the cache (the SDK export, which expands the .xip there)",
                          fix: "free some space, or set XDG_CACHE_HOME to a directory on a larger disk")
        }
        // Docker's data root, when it is on this machine (a Linux host; a Mac's Docker keeps it inside its VM).
        #if os(Linux)
        if !root.isEmpty, FileManager.default.fileExists(atPath: root) {
            try checkFree(URL(fileURLWithPath: root), need: need.docker, what: "Docker's data root (the image, its kits, their build cache and the pack volumes)",
                          fix: "free some space (docker system prune), or move Docker's data-root to a larger disk")
        }
        #endif
        return rootless
    }

    private static func checkFree(_ url: URL, need: SetupDisk.Need, what: String, fix: String) throws {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return }
        if let cause = SetupDisk.shortfall(freeGB: free / 1_000_000_000, path: dir.path, what: what, need: need) {
            throw XlessError(.sdk, cause, fix: "\(fix); or, if you know this run needs less (e.g. the layers are already built), "
                             + "set \(need.key) to the GB per architecture to ask for (https://github.com/fmsouza/xless/blob/main/docs/troubleshooting.md#xless-setup)")
        }
    }

    // MARK: - The Linux xless for the image

    /// The linux xless of `a` for its image, copied into the work dir; nil: the image compiles the checkout `tag` names.
    private func binary(arch a: String, host: String, env: [String: String], exe: URL, cwd: URL, home: URL, work: URL, tag: String) throws -> URL? {
        let key = "XLESS_BIN_\(a.uppercased())"
        var bin: URL
        if let p = env[key], !p.isEmpty {
            bin = XcodeSource.absolute(p, cwd: cwd, home: home)
            guard FileManager.default.fileExists(atPath: bin.path) else {
                throw XlessError(.sdk, "\(key)=\(p) does not exist", fix: "point \(key) at a Linux \(a) xless binary")
            }
        } else if Self.isLinux && a == host {
            bin = exe
        } else if tag.wholeMatch(of: /[0-9a-f]{12}(-dirty)?/) != nil {
            // A checkout's image is named by its commit: the xless in it is compiled from that checkout, as the image is built.
            return nil
        } else if dryRun {
            let name = XlessRelease.tarballName(version: XlessVersion.current, dockerArch: a)
            say("(the \(a) xless would come from \(XlessRelease.url(version: XlessVersion.current, file: name).absoluteString))")
            return work.appendingPathComponent("\(a)/xless")
        } else {
            bin = try download(arch: a, key: key, into: work.appendingPathComponent(a))
        }
        if !dryRun {
            guard let got = XlessRelease.elfDockerArch(bin), got == a else {
                throw XlessError(.sdk, "\(bin.path) is not a Linux \(a) xless", fix: "set \(key) to the linux-\(a) xless binary")
            }
        }
        // docker-images.sh takes a file named xless and uses its directory as the build context, so the binary always goes
        // into a directory of its own under the work dir (never the directory it came from, e.g. ~/.local/bin).
        let dir = work.appendingPathComponent("\(a)-bin")
        let copy = dir.appendingPathComponent("xless")
        if !dryRun {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: bin, to: copy)
        }
        bin = copy
        return bin
    }

    private func download(arch a: String, key: String, into dir: URL) throws -> URL {
        let version = XlessVersion.current
        guard version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw XlessError(.sdk, "this xless is a development build (\(version)): there is no release to download the linux-\(a) xless from",
                             fix: "set \(key) to a Linux \(a) xless (e.g. one copied out of an xless image of that arch)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = XlessRelease.tarballName(version: version, dockerArch: a)
        let tarball = dir.appendingPathComponent(name), sums = dir.appendingPathComponent("SHA256SUMS")
        for (file, to) in [(name, tarball), ("SHA256SUMS", sums)] {
            let url = XlessRelease.url(version: version, file: file).absoluteString
            say("==> downloading \(url)")
            do { try Shell.run("curl", ["-fsSL", "--retry", "3", "-o", to.path, url], stage: .sdk) } catch let e as XlessError {
                throw XlessError(.sdk, "cannot download \(url): \(e.cause)", fix: "check the network, or set \(key) to a Linux \(a) xless")
            }
        }
        try XlessRelease.verify(tarball: tarball, name: name, sums: try String(contentsOf: sums, encoding: .utf8))
        return try XlessRelease.extractBinary(tarball: tarball, version: version, dockerArch: a, into: dir)
    }

    // MARK: - Helpers

    static var hostArch: String { XcodeEnvironment.hostArch }

    /// The setup there is on this system.
    static var name: String { isLinux ? "xless setup" : "xless setup --docker" }

    static var isLinux: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    /// Where the run's Xcode comes from, for the plan's first line.
    static func origin(_ source: XcodeSource.Identified) -> String {
        switch source.kind {
        case .xip: "\(source.url.path) (.xip)"
        case .app: "\(source.url.path) (.app)"
        case .export: "its SDK export \(source.url.path) (no Xcode needed)"
        }
    }

    static func minutes(since t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// Unbuffered, so the lines stay in order with the steps' own output.
private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private extension SetupStep {
    /// Runs its command: docker's are the client's, any other is a tool's.
    func start(passthrough: Bool = false) throws {
        let arguments = Array(argv.dropFirst())
        if argv[0] == "docker" { try HostDocker.docker(arguments, stage: .sdk, passthrough: passthrough) } else {
            // (docker-images.sh calls docker itself: with the same docker)
            try Shell.run(argv[0], arguments, baseEnvironment: try HostDocker.environment(), stage: .sdk, passthrough: passthrough)
        }
    }
}

extension LocalImages {
    /// This machine's docker, for what reads its images and volumes.
    static var hereDocker: LocalImages.Docker {
        { arguments in
            guard let answer = try? HostDocker.docker(arguments, stage: .sdk) else { return (1, "") }
            return (0, answer.stdout)
        }
    }

    /// Those of this machine's docker.
    static var here: LocalImages { LocalImages(hereDocker) }
}
