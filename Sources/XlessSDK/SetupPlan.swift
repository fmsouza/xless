import Foundation
import XlessCore

/// One step of `xless setup`: what it does, the command it runs (printed by --dry-run), and roughly how long it takes.
public struct SetupStep: Equatable, Sendable {
    /// How the command runs the step. `run`: the argv, as is. `export`: the argv writes into `partial`, a fresh empty
    /// directory, which replaces `final` only once it holds `darwin.xtoolsdk` (an interrupted export never counts as one).
    /// `meta`: toolchain-meta.json is written in-process from the export; the argv is the equivalent `xless sdk meta`.
    /// Native setup only: `download`, a pinned tool fetched, checked and unpacked in-process (the argv is its curl);
    /// `sdkInstall`, the SDK installed in-process with `toolchain` (the Swift toolchain the setup installs) first on xtool's PATH (the
    /// argv is the equivalent `xless sdk install`).
    public enum Action: Equatable, Sendable {
        case run
        case export(partial: URL, final: URL)
        case meta(xtoolSDK: URL, out: URL)
        case download(NativeDownload)
        case sdkInstall(xtoolSDK: URL, meta: URL, toolchain: URL)
    }

    public let title: String
    public let argv: [String]
    public let estimate: String
    public let action: Action

    public init(title: String, argv: [String], estimate: String, action: Action = .run) {
        self.title = title; self.argv = argv; self.estimate = estimate; self.action = action
    }
}

/// The image chain `xless setup` builds from one Xcode, as scripts/build-images.sh does on the Mac: per arch, xless-base
/// (with that arch's Linux xless), the Darwin SDK export (xtool in xless-base, the Xcode mounted read-only), xless,
/// xless-tauri and xless-rn, all tagged `-xcode<V>-<B>`; then the `-xcode<V>` tags, and the plain `local-<arch>` tags
/// when the Xcode is versions.env's default (XCODE_VERSION / XCODE_BUILD).
public enum SetupPlan {
    public static let images = ["xless-base", "xless", "xless-tauri", "xless-rn"]

    /// Printed before the steps: what the per-step times are.
    public static let estimateNote = "step times are rough: measured on an 8-core arm64 machine with a fast network; yours depend on your CPU and network"

    public static func make(source: XcodeSource.Identified, archs: [String], hostArch: String, share: URL, cacheRoot: URL,
                            xlessBinaries: [String: URL], reexport: Bool, existing: (URL) -> Bool) -> [SetupStep] {
        let x = source.xcode
        let version = canonicalVersion(x.shortVersion)
        let suffix = "-xcode\(version)", bsuffix = "\(suffix)-\(x.build)"
        let sdkDir = self.sdkDir(source: source, cacheRoot: cacheRoot)
        let script = share.appendingPathComponent("scripts/docker-images.sh").path
        let env = (try? String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8)).map(KnownXcodes.parseEnv) ?? [:]
        let isDefault = env["XCODE_BUILD"] == x.build && env["XCODE_VERSION"] == version
        let ext = source.kind == .xip ? ".xip" : ".app"
        let name = source.url.lastPathComponent.hasSuffix(ext) ? source.url.lastPathComponent : source.url.lastPathComponent + ext
        let inContainer = "/xcode/\(name)"

        var steps: [SetupStep] = []
        var wroteMeta = false
        for a in archs {
            let emulated = a != hostArch
            // Measured on an 8-core arm64 Linux machine with a fast network (docs/acceptance-m5.md); `estimateNote` says so.
            func est(_ s: String, disk: String = "") -> String { (emulated ? "\(s) natively; emulated: 2-3x slower under Rosetta, slower still under QEMU" : s) + disk }
            var base = [script, "base", "--arch", a, "--suffix", bsuffix]
            if let bin = xlessBinaries[a] { base += ["--xless-bin", bin.path] }
            steps.append(SetupStep(title: "xless-base:local-\(a)\(bsuffix)", argv: base, estimate: est("~3 min")))

            let final = sdkDir.appendingPathComponent(a), partial = sdkDir.appendingPathComponent("\(a).partial")
            let xtoolSDK = final.appendingPathComponent("darwin.xtoolsdk")
            // An export source has no Xcode to export from (setup refuses an export that lacks this arch).
            if source.kind != .export, reexport || !existing(xtoolSDK) {
                steps.append(SetupStep(
                    title: "export the Darwin SDK for \(a) from Xcode \(x.shortVersion) (\(x.build)) into \(final.path)",
                    argv: ["docker", "run", "--rm", "--platform", "linux/\(a)", "--user", "\(getuid()):\(getgid())",
                           "-e", "HOME=/tmp", "-w", "/tmp",
                           "-v", "\(source.url.path):\(inContainer):ro", "-v", "\(partial.path):/out",
                           "xless-base:local-\(a)\(bsuffix)", "xtool", "sdk", "build", inContainer, "/out"],
                    estimate: est("~2 min", disk: source.kind == .xip ? "; up to ~15 GB in the cache while the .xip is unpacked, ~3.5 GB stays" : "; ~3 GB on disk"),
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
            steps.append(SetupStep(title: "xless:local-\(a)\(bsuffix)",
                                   argv: [script, "sdk", "--arch", a, "--suffix", bsuffix, "--sdk-dir", sdkDir.path, "--xcode-build", x.build],
                                   estimate: est("~5 min")))
            steps.append(SetupStep(title: "xless-tauri:local-\(a)\(bsuffix)", argv: [script, "tauri", "--arch", a, "--suffix", bsuffix],
                                   estimate: est("~1 min")))
            steps.append(SetupStep(title: "xless-rn:local-\(a)\(bsuffix)", argv: [script, "rn", "--arch", a, "--suffix", bsuffix],
                                   estimate: est("~6 min")))
        }
        for a in archs {
            for i in images {
                var tags = ["\(i):local-\(a)\(suffix)"]
                if isDefault { tags.append("\(i):local-\(a)") }
                for t in tags {
                    steps.append(SetupStep(title: "tag \(t)", argv: ["docker", "tag", "\(i):local-\(a)\(bsuffix)", t], estimate: "seconds"))
                }
            }
        }
        return steps
    }

    /// `$XDG_CACHE_HOME/xless`, else `~/.cache/xless`.
    public static func cacheRoot(env: [String: String], home: URL) -> URL {
        if let x = env["XDG_CACHE_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("xless") }
        return home.appendingPathComponent(".cache/xless")
    }

    /// Where the SDK exported from `xcode` lives: `<arch>/darwin.xtoolsdk` and toolchain-meta.json, the build context
    /// docker/Dockerfile.sdk reads.
    public static func sdkDir(cacheRoot: URL, xcode: KnownXcode) -> URL {
        cacheRoot.appendingPathComponent("sdk/xcode\(canonicalVersion(xcode.shortVersion))-\(xcode.build)")
    }

    /// The SDK export a setup from `source` reads: the export itself when the source is one, else the cache's.
    public static func sdkDir(source: XcodeSource.Identified, cacheRoot: URL) -> URL {
        source.kind == .export ? source.url : sdkDir(cacheRoot: cacheRoot, xcode: source.xcode)
    }

    /// As scripts/build-images.sh and a project's pin spell it: major.minor, plus the patch when it is not 0.
    public static func canonicalVersion(_ v: String) -> String {
        let p = v.split(separator: ".").map { Int($0) ?? 0 }
        var s = "\(p.first ?? 0).\(p.count > 1 ? p[1] : 0)"
        if p.count > 2, p[2] != 0 { s += ".\(p[2])" }
        return s
    }
}
