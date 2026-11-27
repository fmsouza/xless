import Foundation
import XlessCore
import XlessImages

/// One step of `xless setup`: what it does, the command it runs (printed by --dry-run), and roughly how long it takes.
public struct SetupStep: Equatable, Sendable {
    /// How the command runs the step. `run`: the argv, as is. `export`: the argv writes into `partial`, a fresh empty
    /// directory, which replaces `final` only once it holds `darwin.xtoolsdk` (an interrupted export never counts as one).
    /// `meta`: toolchain-meta.json is written in-process from the export; the argv is the equivalent `xless sdk meta`.
    /// Native setup only: `download`, a pinned tool or toolchain fetched, checked and unpacked in-process (the argv is its curl).
    /// Docker setup only: `kit`, the image of a kit on the image, built unless it is there already; `packRun`, the argv (a
    /// container that prepares a pack, or makes its volume the user's), after `PackRun.directories` are made on the host, and
    /// skipped when `PackRun.unlessCurrent` finds the pack current.
    /// An Xcode pack (`PackPlan`), each in-process, the argv the equivalent command: `packBegin`, the staging directory made
    /// afresh (a leftover removed), seeded from the pack at `from` with the parts `manifest` records (those still current),
    /// and its `pack.json` written from `manifest` (`PackPlan.begin`); `packSDK`, `xtool sdk install` into `config` with
    /// `toolchain` first on its PATH (`PackPlan.installSDK`); `packPart`, the part recorded in the staging `pack.json`
    /// (`PackPlan.record`); `packCommit`, the staging directory renamed to `final`, the pack that was there removed after
    /// (`PackPlan.commit`).
    public enum Action: Equatable, Sendable {
        case run
        case export(partial: URL, final: URL)
        case meta(xtoolSDK: URL, out: URL)
        case download(NativeDownload)
        case kit(Kit, arch: String)
        case packRun(PackRun)
        case packBegin(staging: URL, from: URL?, manifest: PackManifest)
        case packSDK(xtoolSDK: URL, config: URL, toolchain: URL, xtool: URL)
        case packPart(PackPart, hash: String, staging: URL)
        case packCommit(staging: URL, final: URL)
    }

    /// A pack volume that the plan could not read (its image is built by this setup, or the setup is a dry run): what it must
    /// hold to be current, checked by reading it (`PackVolumes.manifests`) when the step runs.
    public struct PackCheck: Equatable, Sendable {
        public var volume: String
        /// The pack's name, "26.2-17C52-arm64".
        public var pack: String
        public var arch: String
        /// The image that reads it.
        public var image: String
        public var build: String
        /// This xless's recipe hash of each part (`PackPart.rawValue` to `PackRecipe.hash`).
        public var expected: [String: String]

        public init(volume: String, pack: String, arch: String, image: String, build: String, expected: [String: String]) {
            self.volume = volume; self.pack = pack; self.arch = arch; self.image = image; self.build = build; self.expected = expected
        }
    }

    /// A container of a pack's preparation (`Action.packRun`).
    public struct PackRun: Equatable, Sendable {
        /// Made on the host first, as the calling user (docker would make a missing one as root): the export's directory in
        /// the cache when the SDK is exported, the store when it is a directory.
        public var directories: [URL]
        /// nil: the plan knows the pack is not current.
        public var unlessCurrent: PackCheck?
        /// The pack it writes, which no running container may be using when it runs (`PackUsers`); nil: none to ask about.
        public var writes: PackTarget?

        public init(directories: [URL], unlessCurrent: PackCheck?, writes: PackTarget? = nil) {
            self.directories = directories; self.unlessCurrent = unlessCurrent; self.writes = writes
        }
    }

    /// A pack in its store: what a step that writes it names (`PackRun.writes`).
    public struct PackTarget: Equatable, Sendable {
        public var store: PackStore
        /// The canonical version.
        public var xcode: String
        public var build: String
        public var arch: String
        public var name: String { XcodePack.name(xcode: xcode, build: build, arch: arch) }
        public var place: String {
            switch store {
            case .volumes: "the volume \(PackVolumes.name(xcode: xcode, build: build, arch: arch))"
            case let .directory(dir): dir.appendingPathComponent(name).path
            }
        }

        public init(store: PackStore, xcode: String, build: String, arch: String) { self.store = store; self.xcode = xcode; self.build = build; self.arch = arch }

        /// Stops when a running container (not of the run `excludingRun`) uses it: preparing would replace it under that one.
        public func refuseInUse(_ docker: @escaping LocalImages.Docker, excludingRun: String? = nil) throws {
            let users = try PackUsers(docker).of(store, xcode: xcode, build: build, arch: arch, excludingRun: excludingRun)
            if !users.isEmpty { throw PackUsers.refusal(pack: name, place: place, users: users) }
        }

        /// A native setup's form, before it replaces the pack: docker builds may mount a directory store (`XLESS_XCODES`) of
        /// this machine. Stops when a running container uses the pack; a docker that does not answer (none installed, no
        /// daemon, or a machine without Docker at all, such as the setup container) runs nothing that could, and is no stop.
        public func refuseInUseWhereDockerAnswers(_ docker: @escaping LocalImages.Docker) throws {
            guard let users = try? PackUsers(docker).of(store, xcode: xcode, build: build, arch: arch, xlessOnly: true) else { return }
            if !users.isEmpty { throw PackUsers.refusal(pack: name, place: place, users: users) }
        }
    }

    public let title: String
    public let argv: [String]
    public let estimate: String
    public let action: Action

    /// The indexes of a native plan's steps before which the setup asks whether a running xless build uses the pack it replaces
    /// (`PackTarget.refuseInUseWhereDockerAnswers`): the first, before the downloads and Swift Build's minutes, and the commit,
    /// since a build may have started meanwhile. None when the plan replaces no pack.
    public static func inUseChecks(_ steps: [SetupStep]) -> [Int] {
        guard let commit = steps.firstIndex(where: { if case .packCommit = $0.action { true } else { false } }) else { return [] }
        return commit == 0 ? [0] : [0, commit]
    }

    public init(title: String, argv: [String], estimate: String, action: Action = .run) {
        self.title = title; self.argv = argv; self.estimate = estimate; self.action = action
    }
}

/// `xless setup --docker`, per architecture: the image of this xless (scripts/docker-images.sh; no Xcode goes into it) unless it
/// is here, then the Xcode's pack, prepared by the image's own `xless setup` in a container (`PackSetup`) into its store (a
/// volume, `PackVolumes`, or the directory `XLESS_XCODES` names), then the kits asked for, on the image. The pack's step is
/// left out when the store's pack is current: its two recipe hashes (`PackRecipe.hash`, computed here from this xless's share)
/// are the ones it records. A part that is stale is prepared by the image's setup, which prepares that part alone.
public enum SetupPlan {
    /// Printed before the steps: what the per-step times are.
    public static let estimateNote = "step times are rough: measured on an 8-core arm64 machine with a fast network; yours depend on your CPU and network"

    /// A --docker plan: its steps, and what it found that needs none, said before them.
    public struct Docker: Equatable, Sendable {
        public var steps: [SetupStep]
        public var notes: [String]
    }

    /// - source: the Xcode (nil: the image and the kits alone).
    /// - xlessBinaries: the linux xless of an arch for its image (none: the image compiles this checkout's).
    /// - docker: this machine's docker (the images and volumes that are here; `LocalImages.Docker`).
    /// - readVolumes: a pack volume may be read with a container of the image when the image is here (false for a dry run,
    ///   which starts no container): else the pack's steps check it when they run.
    /// - rootless: Docker's root is the calling user: no `--user`, and the volume is that user's already.
    /// - environment: the host's; only the disk figures go into the pack's container (`PackSetup.passed`).
    /// - existing: whether a file of the host is there.
    public static func make(source: XcodeSource.Identified?, archs: [String], hostArch: String, share: URL, cacheRoot: URL, table: [String: String],
                            xlessBinaries: [String: URL], store: PackStore, docker: @escaping LocalImages.Docker, readVolumes: Bool, rootless: Bool,
                            reexport: Bool, kits: [Kit] = [], builder: String? = nil, environment: [String: String] = [:],
                            existing: (URL) -> Bool) throws -> Docker {
        let script = share.appendingPathComponent("scripts/docker-images.sh").path
        let tag = try ImageName.cachedTag(ofShare: share)
        let user = rootless ? nil : "\(getuid()):\(getgid())"
        let images = LocalImages(docker), volumes = PackVolumes(docker)
        var steps: [SetupStep] = [], notes: [String] = []
        for a in archs {
            let est = { (s: String) in estimate(s, arch: a, hostArch: hostArch) }
            let image = ImageName.base(version: tag, arch: a)
            let found = try? images.base(version: tag, arch: a)
            if found == nil {
                var build = [script, "image", "--arch", a]
                if let bin = xlessBinaries[a] { build += ["--xless-bin", bin.path] }
                steps.append(SetupStep(title: image, argv: build, estimate: est("~3 min; longer the first time (it starts from the ~6 GB Swift image)")))
            }
            if let source {
                let (s, n) = try packSteps(source, arch: a, image: image, imageHere: found != nil, share: share, cacheRoot: cacheRoot, table: table,
                                           store: store, volumes: volumes, readVolumes: readVolumes, user: user, reexport: reexport,
                                           environment: environment, existing: existing, estimate: est)
                steps += s
                notes += n
            }
            let base = found ?? LocalImage(name: image, id: "<the ID of \(image)>", architecture: a, labels: [:], layers: [])
            steps += try kits.map { try kit($0, on: base, hostArch: hostArch, share: share, builder: builder) }
        }
        return Docker(steps: steps, notes: notes)
    }

    /// The steps of the pack of `source` on `arch`, and what is said of it.
    private static func packSteps(_ source: XcodeSource.Identified, arch a: String, image: String, imageHere: Bool, share: URL, cacheRoot: URL,
                                  table: [String: String], store: PackStore, volumes: PackVolumes, readVolumes: Bool, user: String?, reexport: Bool,
                                  environment: [String: String], existing: (URL) -> Bool, estimate est: (String) -> String) throws -> ([SetupStep], [String]) {
        let x = source.xcode, version = canonicalVersion(x.shortVersion)
        let pack = XcodePack.name(xcode: version, build: x.build, arch: a), volume = PackVolumes.name(xcode: version, build: x.build, arch: a)
        var expected: [String: String] = [:]
        for part in PackPart.allCases { expected[part.rawValue] = try PackRecipe.hash(part, build: x.build, arch: a, table: table, share: share) }
        let check = SetupStep.PackCheck(volume: volume, pack: pack, arch: a, image: image, build: x.build, expected: expected)

        // What the store holds of it: nothing (no volume), a pack read (or none in it), or a volume that cannot be read now.
        enum Found { case nothing, read(PackManifest?), unread(String) }
        let found: Found, place: String
        switch store {
        case .volumes:
            place = "the volume \(volume)"
            let here = readVolumes ? try volumes.names(arch: a) : ((try? volumes.names(arch: a)) ?? [])
            if !here.contains(volume) { found = .nothing }
            else if !imageHere { found = .unread("read once the image \(image) is built") }
            else if !readVolumes { found = .unread("read when the setup runs") }
            else { found = .read(try volumes.manifest(of: pack, arch: a, image: image)) }
        case let .directory(dir):
            place = dir.path
            let root = dir.appendingPathComponent(pack)
            found = .read((try? XcodePack.open(root))??.manifest)
        }
        var reasons: [String]
        switch found {
        case .nothing: reasons = ["it holds no pack yet"]
        case let .read(m):
            reasons = staleness(m, check: check)
            if reasons.isEmpty, case let .directory(dir) = store { reasons = lacking(dir.appendingPathComponent(pack), existing: existing) }
        case .unread: reasons = []
        }
        var notes: [String] = []
        if case let .unread(when) = found {
            notes.append("\(place) is there: what it holds is \(when), and the pack's steps are skipped then if it holds a current pack")
        } else if reasons.isEmpty {
            notes.append("the pack \(pack) in \(place) is current for this xless" + (reexport ? "; its SDK is exported again (--reexport)" : ": nothing to prepare"))
            if !reexport { return ([], notes) }
        } else if case .read(.some) = found {
            notes.append("the pack \(pack) in \(place) is not current (\(reasons.joined(separator: "; "))): the image's xless setup prepares what is stale")
        }
        let unless: SetupStep.PackCheck? = { if case .unread = found, !reexport { return check } else { return nil } }()

        // The SDK export: written into the host's cache when the Xcode is given and the cache has no whole export of it.
        let exportDir = sdkDir(source: source, cacheRoot: cacheRoot)
        let exporting = source.kind != .export
            && (reexport || !existing(exportDir.appendingPathComponent("\(a)/darwin.xtoolsdk")) || !existing(exportDir.appendingPathComponent("toolchain-meta.json")))
        let from: PackSetup.Source
        if exporting {
            let ext = source.kind == .xip ? ".xip" : ".app"
            let name = source.url.lastPathComponent.hasSuffix(ext) ? source.url.lastPathComponent : source.url.lastPathComponent + ext
            from = .xcode(source.url, name: name, export: exportDir)
        } else {
            from = .export(exportDir)
        }
        var directories = exporting ? [exportDir] : []
        var steps: [SetupStep] = []
        let suffix = unless == nil ? "" : ", skipped when the pack is current (it is read first)"
        let target = SetupStep.PackTarget(store: store, xcode: version, build: x.build, arch: a)
        switch store {
        case .volumes:
            if case .nothing = found {
                steps.append(SetupStep(title: "the volume \(volume), the store of the pack \(pack)", argv: PackVolumes.create(volume), estimate: "seconds"))
            }
            // A new volume is root's: made the calling user's, unless it is writable for them already (the image's /xcodes,
            // which docker copies into an empty volume, is). Rootless Docker's root is that user.
            if let user {
                let ids = user.split(separator: ":").map(String.init)
                steps.append(SetupStep(
                    title: "the volume \(volume) writable for the calling user (\(user)), when it is not" + suffix,
                    argv: ["docker", "run", "--rm", "--pull=never", "--platform", "linux/\(a)", "--network", "none"]
                        + store.mount(xcode: version, build: x.build, arch: a, writable: true)
                        + [image, "sh", "-c", ownerScript, "sh", ids[0], ids.count > 1 ? ids[1] : ids[0]],
                    estimate: "seconds", action: .packRun(SetupStep.PackRun(directories: [], unlessCurrent: unless, writes: target))))
            }
        case let .directory(dir):
            directories.append(dir)
        }
        let what = exporting
            ? "exporting the SDK from \(source.url.lastPathComponent) into \(exportDir.path)"
            : "from the SDK export \(exportDir.path)"
        steps.append(SetupStep(
            title: "the pack \(pack) of Xcode \(x.shortVersion) (\(x.build)) in \(place), by the xless setup of \(image), \(what)" + suffix,
            argv: PackSetup.argv(image: image, arch: a, xcode: version, build: x.build, store: store, source: from, reexport: reexport,
                                 user: user, environment: environment),
            estimate: est("~6 min; ~7 GB in the store" + (exporting ? ", and ~2 min more to export the SDK" + (source.kind == .xip ? " (up to ~15 GB in the cache while the .xip is unpacked, ~3.5 GB stays)" : " (~3 GB in the cache)") : "")),
            action: .packRun(SetupStep.PackRun(directories: directories, unlessCurrent: unless, writes: target))))
        return (steps, notes)
    }

    /// Run as root in the image, with the volume at /xcodes: `chown <uid>:<gid> /xcodes` unless its owner is that user or anyone
    /// may write there.
    static let ownerScript = "[ \"$(stat -c %u /xcodes)\" = \"$1\" ] || [ $(( 0$(stat -c %a /xcodes) & 2 )) -ne 0 ] || chown \"$1:$2\" /xcodes"

    /// Why `manifest` is not the current pack that `check` names (empty: it is): this xless's format, that Xcode build and
    /// architecture, and each part made by this xless's recipe.
    public static func staleness(_ manifest: PackManifest?, check: SetupStep.PackCheck) -> [String] {
        guard let m = manifest else { return ["it holds no pack yet"] }
        guard m.format == PackRecipe.format else { return ["it is of the pack format \(m.format), and this xless's is \(PackRecipe.format)"] }
        guard m.build == check.build, m.arch == check.arch else { return ["it is a pack of Xcode build \(m.build) for \(m.arch)"] }
        var reasons: [String] = []
        for part in PackPart.allCases {
            guard let want = check.expected[part.rawValue] else { continue }
            guard let have = m.parts[part.rawValue] else { reasons.append("it has no \(part.rawValue) part"); continue }
            if have != want { reasons.append("its \(part.rawValue) part was prepared by another recipe (\(have.prefix(12)), this xless's is \(want.prefix(12)))") }
        }
        return reasons
    }

    /// What a pack of a directory store (at `root`, on this machine) lacks of its parts' entries (`PackPlan.entries`): its
    /// `pack.json` may record a part whose files are gone. Empty: nothing.
    public static func lacking(_ root: URL, existing: (URL) -> Bool) -> [String] {
        PackPart.allCases.flatMap { part in
            PackPlan.entries(of: part).filter { !existing(root.appendingPathComponent($0)) }.map { "its \(part.rawValue) part lacks \($0)" }
        }
    }

    /// A kit's image on `base`. (The command is the one that runs, where `base` is built already.)
    public static func kit(_ kit: Kit, on base: LocalImage, hostArch: String, share: URL, builder: String?) throws -> SetupStep {
        let arch = base.architecture
        return SetupStep(title: "\(kit.image(on: base)): \(kit.holds), for \(kit.apps)", argv: ["docker"] + (try kit.build(on: base, share: share, builder: builder)),
                         estimate: estimate(kit.estimate, arch: arch, hostArch: hostArch), action: .kit(kit, arch: arch))
    }

    private static func estimate(_ s: String, arch: String, hostArch: String) -> String {
        arch == hostArch ? s : "\(s) natively; emulated: 2-3x slower under Rosetta, slower still under QEMU"
    }

    /// `$XDG_CACHE_HOME/xless`, else `~/.cache/xless`.
    public static func cacheRoot(env: [String: String], home: URL) -> URL {
        if let x = env["XDG_CACHE_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("xless") }
        return home.appendingPathComponent(".cache/xless")
    }

    /// Where the SDK exported from `xcode` lives: `<arch>/darwin.xtoolsdk` and toolchain-meta.json, which a pack is prepared from.
    public static func sdkDir(cacheRoot: URL, xcode: KnownXcode) -> URL {
        cacheRoot.appendingPathComponent("sdk/xcode\(canonicalVersion(xcode.shortVersion))-\(xcode.build)")
    }

    /// The SDK export a setup from `source` reads: the export itself when the source is one, else the cache's.
    public static func sdkDir(source: XcodeSource.Identified, cacheRoot: URL) -> URL {
        source.kind == .export ? source.url : sdkDir(cacheRoot: cacheRoot, xcode: source.xcode)
    }

    /// As scripts/build-images.sh and a project's pin spell it: major.minor, plus the patch when it is not 0.
    public static func canonicalVersion(_ v: String) -> String { XcodeVersion.canonical(v) }
}
