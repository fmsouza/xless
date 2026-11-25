import ArgumentParser
import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// `xless setup`: on Linux, by default, a native install of what the images carry (`NativeSetupPlan`: xtool, rcodesign,
/// the Xcode's open-source Swift, the Darwin SDK exported from the Xcode), with no Docker and no sudo. With `--docker`,
/// the image xless:local-<arch>-xcode<version> from an Xcode .xip or Xcode.app, with Docker and nothing else: no Mac, no Apple
/// binary executed (xtool reads the Xcode in a container), no checkout. `--with` adds the kits: what Tauri, Cargo, React Native
/// and Expo apps need on top of it, which `xless run --docker` otherwise builds when it needs them.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install xless's toolchain and Apple's SDK natively from an Xcode .xip (or, with --docker, build the xless image).",
        discussion: """
        The Xcode is identified by its content (a .xip's SHA-256, an Xcode.app's version.plist), never by its name. The Darwin \
        SDK is exported into $XDG_CACHE_HOME/xless/sdk/xcode<V>-<B>/ (default ~/.cache/xless) and reused by later runs \
        (--reexport exports again).

        Once exported, the Xcode is no longer needed: --sdk <dir> sets up from that export instead (its toolchain-meta.json \
        names the Xcode, which must be one versions.env supports), and with neither --xcode nor --sdk setup reuses the \
        cache's export when exactly one holds the architectures it sets up. Nothing is exported then, so the cache's \
        free-space check is skipped.

        Native (the default, Linux only): xtool, rcodesign and the open-source Swift toolchain of that Xcode's Swift are \
        downloaded (each checked against versions.env's sha256) into $XLESS_NATIVE_HOME (default \
        $XDG_DATA_HOME/xless-native, else ~/.local/share/xless-native), the SDK is installed for xtool and SwiftPM, and the \
        toolchain is fitted to it. No Docker and no sudo; the host commands it needs (\(NativeSetupPlan.requiredCommands.joined(separator: ", "))) \
        are checked first, and free space: XLESS_SETUP_CACHE_GB under the cache (only when the SDK is exported) and \
        XLESS_SETUP_NATIVE_GB under the native home. One Xcode at a time: the last setup wins.

        --docker: the image xless:local-<arch>-xcode<version>, one per Xcode and architecture. --with adds the kits on top of \
        it: tauri (Tauri and Cargo apps) and react-native (React Native and Expo apps), comma separated; xless run --docker builds \
        the one it needs by itself. --with without --xcode and --sdk adds them to the image that is already there (the newest \
        Xcode's). The Linux xless that goes into the image: \
        XLESS_BIN_ARM64 / XLESS_BIN_AMD64 when set, else this xless on a Linux host of that arch, else the release's linux \
        tarball, checked against its SHA256SUMS. Before any step it checks that Docker answers, that buildx is installed, \
        and that there is free space, per architecture: XLESS_SETUP_CACHE_GB under the cache (only when the SDK is \
        exported) and, on Linux, XLESS_SETUP_DOCKER_GB under Docker's data root.

        Each figure is versions.env's; an environment variable of the same name wins. --dry-run prints the plan and what \
        the disk check asks for, and runs nothing.
        """)

    @Option(help: "The Xcode: a downloaded Xcode .xip (any name) or an Xcode.app. Not needed once its SDK is exported (see --sdk).") var xcode: String?
    @Option(help: ArgumentHelp("Set up from this SDK export instead of an Xcode: a directory an earlier setup exported into (e.g. ~/.cache/xless/sdk/xcode27.0-27A266a). Without --xcode or --sdk: the cache's one export.",
                               valueName: "dir")) var sdk: String?
    @Flag(help: "Build the xless Docker image instead of installing natively.") var docker = false
    @Option(parsing: .upToNextOption, help: "With --docker: architectures arm64 and/or amd64 (default: this machine's).") var arch: [String] = []
    @Option(help: ArgumentHelp("With --docker: also build the kits for these kinds of app, comma separated (\(Kit.names.joined(separator: ", "))).", valueName: "kinds")) var with: String?
    @Flag(help: "Export the SDK again even when an export of this Xcode exists (needs --xcode).") var reexport = false
    @Flag(help: "Print the plan (each step's command) and run nothing.") var dryRun = false

    func run() async throws {
        do { try setup() } catch let e as XlessError { throw e } catch {
            throw XlessError(.sdk, "\(error.localizedDescription)", fix: "see the output above, then run xless setup again")
        }
    }

    /// What this run sets up from, as its arguments spell it: for a fix that names the same setup with other flags.
    private var sourceArgs: String {
        if let xcode { return " --xcode \(Self.quote(xcode))" }
        if let sdk { return " --sdk \(Self.quote(sdk))" }
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
                                 fix: "drop --arch, or add --docker to build the images for those architectures")
            }
            guard Self.isLinux else {
                throw XlessError(.sdk, "a native setup runs on Linux only", fix: "build the images instead: xless setup --docker\(sourceArgs)")
            }
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
        // --with alone: on the images that are here, when there is one for each architecture.
        if !kits.isEmpty, xcode == nil, sdk == nil, let bases = try? archs.map({ try LocalImages.here.base(arch: $0, pin: nil).image }) {
            return try runKits(kits, on: bases, share: share)
        }
        let source: XcodeSource.Identified
        if let xcode {
            if !dryRun { say("==> identifying \(xcode)") }
            source = try XcodeSource.identify(path: xcode, known: known, cwd: cwd, home: home)
        } else if let sdk {
            source = try XcodeSource.identifyExport(path: sdk, known: known, cwd: cwd, home: home)
        } else {
            source = try XcodeSource.findExport(cacheRoot: cacheRoot, known: known, archs: archs)
        }
        // An export is reused as it is: every architecture this run sets up must already be in it.
        if source.kind == .export { try XcodeSource.checkExport(source.url, holds: archs) }
        if docker {
            try dockerSetup(source: source, archs: archs, kits: kits, env: env, exe: exe, share: share, home: home, cwd: cwd, table: table, cacheRoot: cacheRoot)
        } else {
            try nativeSetup(source: source, env: env, share: share, table: table, cacheRoot: cacheRoot)
        }
    }

    // MARK: - Native

    private func nativeSetup(source: XcodeSource.Identified, env: [String: String], share: URL, table: [String: String], cacheRoot: URL) throws {
        let fm = FileManager.default
        let x = source.xcode, layout = NativeLayout(env: env)
        let sdkBundle = DarwinSDKLocator.bundle(env: env), metaDest = ToolchainMeta.defaultLocation(env: env)
        let installed: NativeSetupPlan.Installed? = {
            guard fm.fileExists(atPath: sdkBundle.path), let meta = try? ToolchainMeta.load(from: metaDest),
                  let data = fm.contents(atPath: layout.record.path), let swift = try? JSONDecoder().decode(SwiftToolchain.self, from: data)
            else { return nil }
            return .init(xcodeBuild: meta.xcodeBuild, swiftVersion: swift.version)
        }()
        let steps = try NativeSetupPlan.make(source: source, arch: Self.hostArch, share: share, cacheRoot: cacheRoot, layout: layout,
                                             sdkBundle: sdkBundle, metaDest: metaDest, table: table, reexport: reexport,
                                             installed: installed, existing: { fm.fileExists(atPath: $0.path) })
        let exporting = steps.contains { if case .export = $0.action { true } else { false } }
        let need = SetupDisk.nativeNeeds(exporting: exporting, env: env, table: table)
        let missing = NativeSetupPlan.requiredCommands.filter { Self.which($0, path: env["PATH"]) == nil }

        say("==> Xcode \(x.shortVersion) (\(x.build)) from \(Self.origin(source)), natively for \(Self.hostArch) into \(layout.root.path); SDK in \(SetupPlan.sdkDir(source: source, cacheRoot: cacheRoot).path)")
        if dryRun {
            say("dry run: the plan, nothing runs")
            if !missing.isEmpty { say("missing commands: \(missing.joined(separator: ", ")) (\(NativeSetupPlan.aptLine))") }
            say("disk: the check asks for about \(need.cache.spoken) free under \(cacheRoot.path) (\(need.cache.key)) and \(need.native.spoken) under \(layout.root.path) (\(need.native.key))")
            for (n, s) in steps.enumerated() {
                say("[\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
                say("    " + s.argv.map(Self.quote).joined(separator: " "))
            }
            if steps.isEmpty { say("nothing to do: Xcode \(x.shortVersion) is installed") }
            return
        }
        guard missing.isEmpty else {
            throw XlessError(.sdk, "a native setup needs \(missing.joined(separator: ", ")), which \(missing.count == 1 ? "is" : "are") not on PATH",
                             fix: "install them (Debian/Ubuntu: \(NativeSetupPlan.aptLine)), or build the images instead: xless setup --docker\(sourceArgs)")
        }
        if need.cache.totalGB > 0 {
            try Self.checkFree(cacheRoot, need: need.cache, what: "the cache (the SDK export, which expands the .xip there)",
                               fix: "free some space, or set XDG_CACHE_HOME to a directory on a larger disk")
        }
        if !steps.isEmpty {
            try Self.checkFree(layout.root, need: need.native, what: "the native install (the Swift toolchain, xtool, rcodesign and the SDK)",
                               fix: "free some space, or set XLESS_NATIVE_HOME to a directory on a larger disk")
        }

        say("    (\(SetupPlan.estimateNote))")
        let start = Date()
        for (n, s) in steps.enumerated() {
            say("==> [\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            let t0 = Date()
            try execute(s, xcode: x, layout: layout)
            say("    done in \(Self.minutes(since: t0))")
        }
        if steps.isEmpty { say("==> nothing to do: Xcode \(x.shortVersion) (\(x.build)) is installed natively" + (source.kind == .export ? "" : " (--reexport exports the SDK again)")) }
        else { say("==> done in \(Self.minutes(since: start)): Xcode \(x.shortVersion) (\(x.build))'s SDK and its Swift are installed natively") }
        say("next: xless run <project-dir> --build-number 1 --to finalize")
    }

    // MARK: - Docker

    private func dockerSetup(source: XcodeSource.Identified, archs: [String], kits: [Kit], env: [String: String], exe: URL, share: URL, home: URL, cwd: URL,
                             table: [String: String], cacheRoot: URL) throws {
        let fm = FileManager.default
        let host = Self.hostArch

        // The .xip or .app is mounted with -v (an export is a build context instead).
        guard source.kind == .export || !source.url.path.contains(":") else {
            throw XlessError(.sdk, "\(source.url.path) contains ':', which docker cannot mount", fix: "move or rename it, then run xless setup again")
        }
        let x = source.xcode
        let work = fm.temporaryDirectory.appendingPathComponent("xless-setup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        // The disk figures are per architecture; the cache one counts only the architectures exported in this run (none
        // from an export). An environment variable of the same name (e.g. when most layers are already cached) wins over versions.env's.
        let sdkDir = SetupPlan.sdkDir(source: source, cacheRoot: cacheRoot)
        let exporting = source.kind == .export ? []
            : archs.filter { reexport || !fm.fileExists(atPath: sdkDir.appendingPathComponent("\($0)/darwin.xtoolsdk").path) }
        let need = SetupDisk.needs(archs: archs.count, exporting: exporting.count, env: env, table: table)
        var rootless = false
        if !dryRun { rootless = try Self.preflight(cacheRoot: cacheRoot, need: need) }
        var binaries: [String: URL] = [:]
        for a in archs { binaries[a] = try binary(arch: a, host: host, env: env, exe: exe, cwd: cwd, home: home, work: work) }

        var steps = dryRun ? [] : try Self.retagSteps(xcode: x, archs: archs, env: env)
        steps += SetupPlan.make(source: source, archs: archs, hostArch: host, share: share, cacheRoot: cacheRoot,
                                xlessBinaries: binaries, reexport: reexport, kits: kits, existing: { fm.fileExists(atPath: $0.path) })
            // Rootless Docker already writes as the calling user from the container's root; `--user` would map to a subuid.
            .map { rootless ? Self.withoutUser($0) : $0 }

        say("==> Xcode \(x.shortVersion) (\(x.build)) from \(Self.origin(source)), for \(archs.joined(separator: ", ")); SDK in \(sdkDir.path)")
        say("    (\(SetupPlan.estimateNote))")
        if dryRun {
            say("dry run: the plan, nothing runs")
            say("disk: the check asks for about \(need.cache.spoken) free under \(cacheRoot.path) (\(need.cache.key))"
                + (Self.isLinux ? " and \(need.docker.spoken) under Docker's data root (\(need.docker.key))" : ""))
            list(steps)
            return
        }

        let start = Date()
        try run(steps, xcode: x, share: share)
        let version = SetupPlan.canonicalVersion(x.shortVersion)
        let built = archs.map { ImageName.base(arch: $0, xcode: version) }
        say("==> done in \(Self.minutes(since: start)): \(built.joined(separator: " and ")) (pin it with xcode: \"\(version)\")")
        if let note = Self.oldImages() { say(note) }
        say("next: xless run --docker <project-dir> --build-number 1 --to finalize")
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

    /// `--with` alone: the kits, on the images that are here.
    private func runKits(_ kits: [Kit], on bases: [LocalImage], share: URL) throws {
        let steps = bases.flatMap { base in
            kits.map { SetupPlan.kit($0, arch: base.architecture, xcode: base.xcode ?? "", hostArch: Self.hostArch, share: share) }
        }
        say("==> on \(bases.map(\.name).joined(separator: " and "))")
        if dryRun {
            say("dry run: the plan, nothing runs")
            return list(steps)
        }
        try run(steps, xcode: nil, share: share)
    }

    private func list(_ steps: [SetupStep]) {
        for (n, s) in steps.enumerated() {
            say("[\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            say("    " + s.argv.map(Self.quote).joined(separator: " "))
        }
    }

    private func run(_ steps: [SetupStep], xcode: KnownXcode?, share: URL) throws {
        for (n, s) in steps.enumerated() {
            say("==> [\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            let t0 = Date()
            if case let .kit(kit, arch, version) = s.action {
                do { try Self.build(kit, arch: arch, xcode: version, share: share) } catch let problem as ImageProblem {
                    throw XlessError(.sdk, problem.cause, fix: problem.fix)
                }
            } else { try execute(s, xcode: xcode) }
            say("    done in \(Self.minutes(since: t0))")
        }
    }

    /// The kit's image on that Xcode's, unless it is there and nothing it is made from has changed.
    private static func build(_ kit: Kit, arch: String, xcode: String, share: URL) throws {
        let images = LocalImages.here
        let base = try images.base(arch: arch, pin: xcode).image
        let state = { try images.state(of: kit, on: base, share: share) }
        if case .current = try state() { return say("    it is there already") }
        // `docker build` is docker's own builder unless this names another, which could not see the local image.
        var env = ProcessInfo.processInfo.environment
        env["BUILDX_BUILDER"] = nil
        try Shell.run("docker", kit.build(on: base, share: share), baseEnvironment: env, stage: .sdk, passthrough: true)
        guard case .current = try state() else {
            throw ImageProblem("\(kit.image(on: base)) is not what was built: it is not on \(base.name)", fix: "run xless setup again when nothing else builds it")
        }
    }

    /// What an older xless left, in one line.
    private static func oldImages() -> String? {
        let ls = ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]
        guard let all = try? Shell.run("docker", ls, stage: .sdk).stdout,
              let labelled = try? Shell.run("docker", ls + ["--filter", "label=\(ImageLabel.sdk)"], stage: .sdk).stdout else { return nil }
        let old = CleanPlan.old(fromListing: all, labelled: labelled)
        return old.isEmpty ? nil : "note: \(old.count) image tag\(old.count == 1 ? "" : "s") of an older xless (as \(old[0])) \(old.count == 1 ? "is" : "are") not used any more: xless clean --old removes \(old.count == 1 ? "it" : "them")"
    }

    // MARK: - Steps

    private func execute(_ s: SetupStep, xcode: KnownXcode?, layout: NativeLayout? = nil) throws {
        let fm = FileManager.default
        switch s.action {
        case .kit: break // run(_:xcode:share:) builds it
        case .tidy:
            _ = try? Shell.run(s.argv[0], Array(s.argv.dropFirst()), stage: .sdk)
        case .run:
            try Shell.run(s.argv[0], Array(s.argv.dropFirst()), stage: .sdk, passthrough: true)
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
            try Shell.run(s.argv[0], Array(s.argv.dropFirst()), stage: .sdk, passthrough: true)
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
        case let .sdkInstall(xtoolSDK, meta, toolchain):
            let layout = layout ?? NativeLayout()
            // The record says the toolchain is fitted to the installed SDK: gone until the fit-up after this rewrites it,
            // so a run stopped in between plans the fit-up again.
            if FileManager.default.fileExists(atPath: layout.record.path) { try FileManager.default.removeItem(at: layout.record) }
            let xtool = layout.bin.appendingPathComponent("xtool").path
            let at = try SDKInstaller.install(xtoolsdk: xtoolSDK, meta: meta, xtool: xtool, toolchain: toolchain)
            say("    SDK at \(at.sdk.path); metadata at \(at.meta.path)")
        }
    }

    /// A native download: fetched next to its `.partial` directory (both removed first: a leftover is never reused),
    /// checked against its pin, unpacked into `.partial`, then renamed into place and linked into the native `bin/`.
    static func install(_ d: NativeDownload, layout: NativeLayout) throws {
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
        let staged: URL, link: (name: String, target: String)?
        switch d.kind {
        case .appImage:
            // The AppImage's own runtime extracts it (no FUSE needed) into squashfs-root under its working directory.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try Shell.run(file.path, ["--appimage-extract"], cwd: partial, stage: .sdk)
            staged = partial.appendingPathComponent("squashfs-root")
            link = ("xtool", "AppRun")
        case .rcodesign:
            try Shell.run("tar", ["-xzf", file.path, "-C", partial.path], stage: .sdk)
            let found = fm.enumerator(at: partial, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "rcodesign" && !$0.hasDirectoryPath }
            guard let found else { throw XlessError(.sdk, "\(d.url.lastPathComponent) holds no rcodesign", fix: "report it: the release's layout changed") }
            staged = partial.appendingPathComponent("out")
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try fm.moveItem(at: found, to: staged.appendingPathComponent("rcodesign"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent("rcodesign").path)
            link = ("rcodesign", "rcodesign")
        case .swiftToolchain:
            try Shell.run("tar", ["-xzf", file.path, "-C", partial.path, "--strip-components=1"], stage: .sdk)
            staged = partial
            link = nil
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

    /// Two builds of one Xcode version (a beta and the release): `-xcode<V>` names one of them. As scripts/build-images.sh:
    /// refused when it names another build, unless XLESS_XCODE_RETAG=1, which keeps that build's image as `-xcode<V>-<B>`.
    private static func retagSteps(xcode: KnownXcode, archs: [String], env: [String: String]) throws -> [SetupStep] {
        let version = SetupPlan.canonicalVersion(xcode.shortVersion)
        var steps: [SetupStep] = []
        for a in archs {
            let name = ImageName.base(arch: a, xcode: version)
            guard let old = LocalImages.here.image(name)?.sdk, old != xcode.build else { continue }
            guard env["XLESS_XCODE_RETAG"] == "1" else {
                throw XlessError(.sdk, "\(name) is another build of Xcode \(version) (\(old), this is \(xcode.build)); a pin xcode: \"\(version)\" selects it",
                                 fix: "to point it at this build: XLESS_XCODE_RETAG=1 xless setup … (the \(old) image stays as \(ImageName.base(arch: a, xcode: version, build: old)))")
            }
            let kept = ImageName.base(arch: a, xcode: version, build: old)
            steps.append(SetupStep(title: "XLESS_XCODE_RETAG=1: keep \(name) (Xcode \(old)) as \(kept)", argv: ["docker", "tag", name, kept], estimate: "seconds"))
        }
        return steps
    }

    // MARK: - Preflight

    /// Docker answers (the cause named: permission denied or no daemon), buildx is there, and the disks have room.
    /// Returns whether the daemon is rootless.
    private static func preflight(cacheRoot: URL, need: (cache: SetupDisk.Need, docker: SetupDisk.Need)) throws -> Bool {
        let root: String, rootless: Bool
        do {
            let info = try Shell.run("docker", ["info", "--format", "{{.DockerRootDir}}|{{json .SecurityOptions}}"], stage: .sdk).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            root = String(info.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            rootless = info.contains("name=rootless")
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
        do { try Shell.run("docker", ["buildx", "version"], stage: .sdk) } catch {
            throw XlessError(.sdk, "docker buildx is not available", fix: "install Docker's buildx plugin (e.g. the docker-buildx-plugin package)")
        }
        if need.cache.totalGB > 0 {
            try checkFree(cacheRoot, need: need.cache, what: "the cache (the SDK export, which expands the .xip there)",
                          fix: "free some space, or set XDG_CACHE_HOME to a directory on a larger disk")
        }
        // Docker's data root, when it is on this machine (a Linux host; a Mac's Docker keeps it inside its VM).
        #if os(Linux)
        if !root.isEmpty, FileManager.default.fileExists(atPath: root) {
            try checkFree(URL(fileURLWithPath: root), need: need.docker, what: "Docker's data root (the images and their build cache)",
                          fix: "free some space (docker system prune), or move Docker's data-root to a larger disk")
        }
        #endif
        return rootless
    }

    static func withoutUser(_ s: SetupStep) -> SetupStep {
        guard let i = s.argv.firstIndex(of: "--user"), i + 1 < s.argv.count else { return s }
        var argv = s.argv
        argv.removeSubrange(i...(i + 1))
        return SetupStep(title: s.title, argv: argv, estimate: s.estimate, action: s.action)
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

    private func binary(arch a: String, host: String, env: [String: String], exe: URL, cwd: URL, home: URL, work: URL) throws -> URL {
        let key = "XLESS_BIN_\(a.uppercased())"
        var bin: URL
        if let p = env[key], !p.isEmpty {
            bin = XcodeSource.absolute(p, cwd: cwd, home: home)
            guard FileManager.default.fileExists(atPath: bin.path) else {
                throw XlessError(.sdk, "\(key)=\(p) does not exist", fix: "point \(key) at a Linux \(a) xless binary")
            }
        } else if Self.isLinux && a == host {
            bin = exe
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

    static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

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

    static func quote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@,+%{}".contains($0) }) && !s.isEmpty
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

extension LocalImages {
    /// Those of this machine's docker.
    static var here: LocalImages {
        LocalImages { arguments in
            guard let answer = try? Shell.run("docker", arguments, stage: .sdk) else { return (1, "") }
            return (0, answer.stdout)
        }
    }
}
