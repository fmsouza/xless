import Foundation
import XlessCore
import XlessImages

/// One step of `xless setup`: what it does, the command it runs (printed by --dry-run), and roughly how long it takes.
public struct SetupStep: Equatable, Sendable {
    /// How the command runs the step. `run`: the argv, as is. `export`: the argv writes into `partial`, a fresh empty
    /// directory, which replaces `final` only once it holds `darwin.xtoolsdk` (an interrupted export never counts as one).
    /// `meta`: toolchain-meta.json is written in-process from the export; the argv is the equivalent `xless sdk meta`.
    /// Native setup only: `download`, a pinned tool or toolchain fetched, checked and unpacked in-process (the argv is its curl).
    /// Docker setup only: `kit`, the image of a kit on that Xcode's, built unless it is there already; `tidy`, the argv, whose
    /// failure is none of the setup's.
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
        case kit(Kit, arch: String, xcode: String)
        case tidy
        case packBegin(staging: URL, from: URL?, manifest: PackManifest)
        case packSDK(xtoolSDK: URL, config: URL, toolchain: URL)
        case packPart(PackPart, hash: String, staging: URL)
        case packCommit(staging: URL, final: URL)
    }

    public let title: String
    public let argv: [String]
    public let estimate: String
    public let action: Action

    public init(title: String, argv: [String], estimate: String, action: Action = .run) {
        self.title = title; self.argv = argv; self.estimate = estimate; self.action = action
    }
}

/// The image `xless setup --docker` builds from one Xcode, as scripts/build-images.sh does on the Mac: per arch, the Darwin SDK
/// export (xtool, in an image without an SDK that is removed again; the Xcode mounted read-only), the image
/// `xless:local-<arch>-xcode<V>`, with that arch's Linux xless, and the kits asked for on top of it.
public enum SetupPlan {
    /// Printed before the steps: what the per-step times are.
    public static let estimateNote = "step times are rough: measured on an 8-core arm64 machine with a fast network; yours depend on your CPU and network"

    public static func make(source: XcodeSource.Identified, archs: [String], hostArch: String, share: URL, cacheRoot: URL,
                            xlessBinaries: [String: URL], reexport: Bool, kits: [Kit] = [], builder: String? = nil, existing: (URL) -> Bool) throws -> [SetupStep] {
        let x = source.xcode
        let version = canonicalVersion(x.shortVersion)
        let sdkDir = self.sdkDir(source: source, cacheRoot: cacheRoot)
        let script = share.appendingPathComponent("scripts/docker-images.sh").path
        let ext = source.kind == .xip ? ".xip" : ".app"
        let name = source.url.lastPathComponent.hasSuffix(ext) ? source.url.lastPathComponent : source.url.lastPathComponent + ext
        let inContainer = "/xcode/\(name)"

        var steps: [SetupStep] = []
        var wroteMeta = false
        for a in archs {
            let est = { (s: String, disk: String) in estimate(s, arch: a, hostArch: hostArch) + disk }
            let final = sdkDir.appendingPathComponent(a), partial = sdkDir.appendingPathComponent("\(a).partial")
            let xtoolSDK = final.appendingPathComponent("darwin.xtoolsdk")
            let tools = ImageName.tools(arch: a), image = ImageName.base(arch: a, xcode: version)
            // An export source has no Xcode to export from (setup refuses an export that lacks this arch).
            let exports = source.kind != .export && (reexport || !existing(xtoolSDK))
            if exports {
                steps.append(SetupStep(title: "\(tools), to export the SDK with", argv: [script, "tools", "--arch", a], estimate: est("~3 min", "")))
                steps.append(SetupStep(
                    title: "export the Darwin SDK for \(a) from Xcode \(x.shortVersion) (\(x.build)) into \(final.path)",
                    argv: ["docker", "run", "--rm", "--pull=never", "--platform", "linux/\(a)", "--user", "\(getuid()):\(getgid())",
                           "-e", "HOME=/tmp", "-w", "/tmp",
                           "-v", "\(source.url.path):\(inContainer):ro", "-v", "\(partial.path):/out",
                           tools, "xtool", "sdk", "build", inContainer, "/out"],
                    estimate: est("~2 min", source.kind == .xip ? "; up to ~15 GB in the cache while the .xip is unpacked, ~3.5 GB stays" : "; ~3 GB on disk"),
                    action: .export(partial: partial, final: final)))
            }
            // An export source is read, not written (it may be read-only): its metadata is written only when it has none.
            let out = sdkDir.appendingPathComponent("toolchain-meta.json")
            if !wroteMeta, source.kind != .export || !existing(out) {
                wroteMeta = true
                steps.append(SetupStep(
                    title: "toolchain-meta.json for Xcode \(x.shortVersion) (\(x.build))",
                    argv: ["xless", "sdk", "meta", "--from-xtoolsdk", xtoolSDK.path, "--xcode-build", x.build, "--out", out.path],
                    estimate: "seconds", action: .meta(xtoolSDK: xtoolSDK, out: out)))
            }
            var build = [script, "image", "--arch", a, "--xcode", version, "--xcode-build", x.build, "--sdk-dir", sdkDir.path]
            if let bin = xlessBinaries[a] { build += ["--xless-bin", bin.path] }
            steps.append(SetupStep(title: image, argv: build, estimate: est("~7 min", "")))
            if exports { steps.append(SetupStep(title: "remove \(tools)", argv: ["docker", "image", "rm", tools], estimate: "seconds", action: .tidy)) }
            let built = LocalImage(name: image, id: "<the ID of \(image)>", architecture: a, labels: [ImageLabel.xcode: version], layers: [])
            steps += try kits.map { try kit($0, on: built, hostArch: hostArch, share: share, builder: builder) }
        }
        return steps
    }

    /// A kit's image on `base`. (The command is the one that runs, where `base` is built already.)
    public static func kit(_ kit: Kit, on base: LocalImage, hostArch: String, share: URL, builder: String?) throws -> SetupStep {
        let arch = base.architecture
        return SetupStep(title: "\(kit.image(on: base)): \(kit.holds), for \(kit.apps)", argv: ["docker"] + (try kit.build(on: base, share: share, builder: builder)),
                         estimate: estimate(kit.estimate, arch: arch, hostArch: hostArch), action: .kit(kit, arch: arch, xcode: base.xcode ?? ""))
    }

    private static func estimate(_ s: String, arch: String, hostArch: String) -> String {
        arch == hostArch ? s : "\(s) natively; emulated: 2-3x slower under Rosetta, slower still under QEMU"
    }

    /// `$XDG_CACHE_HOME/xless`, else `~/.cache/xless`.
    public static func cacheRoot(env: [String: String], home: URL) -> URL {
        if let x = env["XDG_CACHE_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("xless") }
        return home.appendingPathComponent(".cache/xless")
    }

    /// Where the SDK exported from `xcode` lives: `<arch>/darwin.xtoolsdk` and toolchain-meta.json, the build context
    /// docker/Dockerfile reads.
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
