import Foundation
import XlessCore

/// The steps that prepare one Xcode pack (`XcodePack`) part by part, in a staging directory beside its place
/// (`<store>/<name>.partial`) that is renamed into place last, so a pack is always whole: the one that was there, or the new
/// one. A part is prepared only when its recipe hash (`PackRecipe.hash`) is not the one the pack records; a part that is
/// still current is seeded into the staging directory from the pack that is there (hard links, a copy where linking fails).
///
/// Nothing but the staging directory is written until the last step: the toolchain is downloaded into it, the SDK installed
/// into its `config`, the metadata copied there, the toolchain fitted (scripts/fit-toolchain.sh), Swift Build compiled
/// (scripts/pack-swift-build.sh) and the pack checked (scripts/pack-check.sh) there. A part is recorded in the staging
/// `pack.json` only after every step of it succeeded.
///
/// The `swift-build` part is linked against the `sdk` part's toolchain, and its hash covers what makes that toolchain's
/// runtime: the toolchain's sha256 (the download's), and nothing of the fit. So an `sdk` part prepared again from the same
/// download keeps a current `swift-build` (the fit edits the clang drivers, `ld64.lld` and the clang resource directory,
/// never `usr/lib/swift`, which Swift Build runs on); a new toolchain changes both hashes and prepares both.
///
/// Swift Build is compiled by that fitted toolchain, not by the image's own Swift: the fit changes only what Darwin targets
/// compile and link with (the clang driver adds its definitions for Darwin targets alone), so the Linux build of Swift Build
/// is what the unfitted toolchain would make. The fit's `mode` (`PackRecipe.mode`: own or separate Swift) is in the `sdk`
/// hash and not in the `swift-build` one, though scripts/pack-swift-build.sh strips by it: the mode changes only when
/// `SWIFT_VERSION` does, and `SWB_TAG` (in the `swift-build` hash) is moved with `SWIFT_VERSION`, so that hash changes too.
///
/// Seeded files are hard links to the pack in use: no step after the seeding writes into a seeded file. A stale part is
/// never seeded, so the download, the SDK install and the fit write fresh files; `pack.json` is replaced by a rename.
public enum PackPlan {
    static let toolchainEstimate = "~2 min; a ~1.1 GB download, ~4 GB unpacked"
    static let sdkEstimate = "~1 min; ~3 GB on disk"
    static let swiftBuildEstimate = "~10 min; ~1 GB of sources and objects in a temporary directory"

    /// How long preparing `part` again takes, and what it needs, from its steps' estimates.
    public static func estimate(of part: PackPart) -> String {
        switch part {
        case .sdk: "~3 min: the Swift toolchain (\(toolchainEstimate)) and the Darwin SDK (\(sdkEstimate))"
        case .swiftBuild: "\(swiftBuildEstimate.replacingOccurrences(of: "; ", with: ": Swift Build compiled, "))"
        }
    }

    /// What this machine can prepare: Swift Build only where it can be used and compiled.
    public struct Abilities: Equatable, Sendable {
        public var swiftBuild: Bool
        public init(swiftBuild: Bool) { self.swiftBuild = swiftBuild }
    }

    /// XLESS_SHIM_DIR is set and names a directory → swiftBuild (the shims are what a build with Swift Build needs, and
    /// what the image has; a bare host has none and could not use it).
    public static func abilities(env: [String: String]) -> Abilities {
        var isDirectory: ObjCBool = false
        guard let shims = env["XLESS_SHIM_DIR"], !shims.isEmpty,
              FileManager.default.fileExists(atPath: shims, isDirectory: &isDirectory) else { return Abilities(swiftBuild: false) }
        return Abilities(swiftBuild: isDirectory.boolValue)
    }

    /// What each part holds, relative to the pack's root (`XcodePack`'s paths): what is seeded when the part is current,
    /// and what must all be there for it to count as current.
    public static func entries(of part: PackPart) -> [String] {
        switch part {
        case .sdk: ["toolchain", "config", "toolchain-meta.json", "swift-toolchain.json", "include"]
        case .swiftBuild: ["swift-build"]
        }
    }

    /// The staging directory of the pack at `final`: its sibling `<name>.partial`, on the same file system.
    public static func staging(of final: URL) -> URL {
        final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial")
    }

    /// The steps that bring `store`'s pack of `xcode` up to this xless's recipes, for the parts `abilities` allows. Empty:
    /// nothing to do.
    /// - export: the SDK export of that Xcode (`SetupPlan.sdkDir`): `<arch>/darwin.xtoolsdk` and `toolchain-meta.json`.
    /// - current: the pack at the destination (`store.directory(…)`), when there is one.
    /// - existing: whether a file is there (each entry of a part the pack records is checked: a part that lacks one is
    ///   prepared again).
    /// A part the machine cannot prepare (`swift-build` without `abilities.swiftBuild`) is kept when it is current, and left
    /// out when the pack is prepared again around it while it is stale.
    public static func make(xcode: KnownXcode, arch: String, export: URL, store: XcodeStore, share: URL, table: [String: String],
                            abilities: Abilities, current: XcodePack?, xtool: URL, existing: (URL) -> Bool) throws -> [SetupStep] {
        let version = XcodeVersion.canonical(xcode.shortVersion)
        let name = XcodePack.name(xcode: version, build: xcode.build, arch: arch)
        let final = store.directory(xcode: version, build: xcode.build, arch: arch), staging = staging(of: final)
        let swift = try PackRecipe.swiftVersion(build: xcode.build, table: table)
        let mode = PackRecipe.mode(swift: swift, table: table)
        let sdkHash = try PackRecipe.hash(.sdk, build: xcode.build, arch: arch, table: table, share: share)
        // Without the ability the hash only decides whether a present part is kept; a table that cannot make it keeps none.
        let swiftBuildHash = abilities.swiftBuild
            ? try PackRecipe.hash(.swiftBuild, build: xcode.build, arch: arch, table: table, share: share)
            : try? PackRecipe.hash(.swiftBuild, build: xcode.build, arch: arch, table: table, share: share)

        func isCurrent(_ part: PackPart, _ hash: String?) -> Bool {
            guard let current, let hash, current.manifest.format == PackRecipe.format, current.manifest.build == xcode.build,
                  current.manifest.arch == arch, current.manifest.parts[part.rawValue] == hash else { return false }
            return entries(of: part).allSatisfy { existing(current.root.appendingPathComponent($0)) }
        }
        let sdkCurrent = isCurrent(.sdk, sdkHash), swiftBuildCurrent = isCurrent(.swiftBuild, swiftBuildHash)
        let prepareSDK = !sdkCurrent, prepareSwiftBuild = abilities.swiftBuild && !swiftBuildCurrent
        guard prepareSDK || prepareSwiftBuild else { return [] }

        var seeded: [String: String] = [:]
        if sdkCurrent { seeded[PackPart.sdk.rawValue] = sdkHash }
        if swiftBuildCurrent, let swiftBuildHash { seeded[PackPart.swiftBuild.rawValue] = swiftBuildHash }
        let manifest = PackManifest(format: PackRecipe.format, xcode: version, build: xcode.build, arch: arch, swift: swift,
                                    mode: mode, parts: seeded)
        let from = seeded.isEmpty ? nil : current?.root
        let pack = XcodePack(root: staging, manifest: manifest)

        var steps: [SetupStep] = []
        let kept = seeded.keys.sorted()
        steps.append(SetupStep(
            title: "a staging directory for the pack \(name), beside it in \(store.root.path)"
                + (kept.isEmpty ? "" : ", holding the pack's current \(kept.joined(separator: " and ")) (hard links)"),
            argv: beginArgv(staging: staging, from: from, manifest: manifest),
            estimate: "seconds", action: .packBegin(staging: staging, from: from, manifest: manifest)))

        if prepareSDK {
            let a = PackRecipe.tableArch(arch), key = "SWIFT_TOOLCHAIN_\(swift.replacingOccurrences(of: ".", with: "_"))"
            func pin(_ k: String) throws -> String {
                guard let v = table[k], !v.isEmpty else {
                    throw XlessError(.sdk, "versions.env has no \(k), which the pack of Xcode \(version) on \(arch) is prepared with",
                                     fix: "reinstall xless (its versions.env is incomplete), or use a supported Xcode")
                }
                return v
            }
            let urlString = try pin("\(key)_URL_\(a)")
            guard let url = URL(string: urlString) else {
                throw XlessError(.sdk, "versions.env's \(key)_URL_\(a) (\(urlString)) is not a URL", fix: "reinstall xless (its versions.env is damaged)")
            }
            let download = NativeDownload(kind: .swiftToolchain, url: url, sha256: try pin("\(key)_SHA256_\(a)"), final: pack.toolchain)
            steps.append(SetupStep(title: "download the Swift \(swift) toolchain (the open-source release of Xcode \(xcode.shortVersion)'s Swift) into \(pack.toolchain.path)",
                                   argv: ["curl", "-fsSL", "-o", download.partial.path + ".download", url.absoluteString],
                                   estimate: Self.toolchainEstimate, action: .download(download)))
            let xtoolSDK = export.appendingPathComponent("\(arch)/darwin.xtoolsdk")
            steps.append(SetupStep(title: "install the Darwin SDK for xtool and SwiftPM into \(pack.configHome.path)",
                                   argv: sdkArgv(xtoolSDK: xtoolSDK, config: pack.configHome, toolchain: pack.toolchain, xtool: xtool),
                                   estimate: Self.sdkEstimate,
                                   action: .packSDK(xtoolSDK: xtoolSDK, config: pack.configHome, toolchain: pack.toolchain, xtool: xtool)))
            steps.append(SetupStep(title: "toolchain-meta.json of Xcode \(xcode.shortVersion) (\(xcode.build)) into the pack",
                                   argv: ["cp", export.appendingPathComponent("toolchain-meta.json").path, pack.meta.path], estimate: "seconds"))
            steps.append(SetupStep(title: "fit the Swift \(swift) toolchain to the SDK (\(mode.rawValue)) and record it in \(pack.record.path)",
                                   argv: [script("fit-toolchain", share), staging.path, mode.rawValue, share.appendingPathComponent("docker/toolchain").path],
                                   estimate: "seconds"))
            steps.append(part(.sdk, hash: sdkHash, staging: staging))
        }
        if prepareSwiftBuild, let swiftBuildHash {
            // The SWB_* pins reach the script through its environment (every one of them is in the part's hash).
            let pins = table.keys.filter { $0.hasPrefix("SWB_") }.sorted().map { "\($0)=\(table[$0] ?? "")" }
            steps.append(SetupStep(title: "compile Swift Build \(table["SWB_TAG"] ?? "") with the pack's Swift \(swift) into \(pack.swiftBuild.path)",
                                   argv: ["env"] + pins + [script("pack-swift-build", share), staging.path, arch, mode.rawValue],
                                   estimate: Self.swiftBuildEstimate))
            steps.append(part(.swiftBuild, hash: swiftBuildHash, staging: staging))
        }
        if abilities.swiftBuild {
            steps.append(SetupStep(title: "check the pack: the SDK, Xcode's tools, the iOS stub dylib link, Swift Build",
                                   argv: [script("pack-check", share), staging.path], estimate: "seconds"))
        }
        steps.append(SetupStep(title: "put the pack in place: \(final.path)" + (current == nil ? "" : " (the one there is removed after)"),
                               argv: commitArgv(staging: staging, final: final), estimate: "seconds",
                               action: .packCommit(staging: staging, final: final)))
        return steps
    }

    private static func script(_ name: String, _ share: URL) -> String { share.appendingPathComponent("scripts/\(name).sh").path }

    private static func part(_ part: PackPart, hash: String, staging: URL) -> SetupStep {
        SetupStep(title: "record the \(part.rawValue) part in \(staging.appendingPathComponent("pack.json").path)",
                  argv: recordArgv(part, hash: hash, staging: staging), estimate: "seconds",
                  action: .packPart(part, hash: hash, staging: staging))
    }

    // MARK: - The commands --dry-run prints for the in-process steps

    /// `begin`, as a command: the leftover removed, the directory made, the current parts linked into it (GNU `cp -al`; the
    /// step itself copies where linking fails), the manifest written.
    static func beginArgv(staging: URL, from: URL?, manifest: PackManifest) -> [String] {
        let parts = manifest.parts.keys.sorted().compactMap(PackPart.init(rawValue:))
        let sources = from.map { f in parts.flatMap(entries(of:)).map { f.appendingPathComponent($0).path } } ?? []
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let seed = sources.isEmpty ? "" : " && cp -al \"$@\" \"$d\"/"
        return ["sh", "-c", "d=$1; j=$2; shift 2; { [ ! -e \"$d\" ] || find \"$d\" -type d -exec chmod u+w {} +; } && rm -rf \"$d\" && mkdir -p \"$d\"\(seed) && printf '%s\\n' \"$j\" > \"$d/pack.json\"",
                "sh", staging.path, json] + sources
    }

    /// `installSDK`, as a command.
    static func sdkArgv(xtoolSDK: URL, config: URL, toolchain: URL, xtool: URL) -> [String] {
        ["sh", "-c", "PATH=\"$1/usr/bin:$PATH\" XDG_CONFIG_HOME=\"$2\" exec \"$4\" sdk install \"$3\"", "sh",
         toolchain.path, config.path, xtoolSDK.path, xtool.path]
    }

    /// `record`, as a command.
    static func recordArgv(_ part: PackPart, hash: String, staging: URL) -> [String] {
        ["python3", "-c", "import json, os, sys; p = sys.argv[1]; m = json.load(open(p)); m['parts'][sys.argv[2]] = sys.argv[3]; "
            + "json.dump(m, open(p + '.tmp', 'w'), indent=2, sort_keys=True); os.replace(p + '.tmp', p)",
         staging.appendingPathComponent("pack.json").path, part.rawValue, hash]
    }

    /// `commit`, as a command: a staging directory without `pack.json` refused, the old pack put back when the rename into
    /// place fails.
    static func commitArgv(staging: URL, final: URL) -> [String] {
        ["sh", "-c", "set -e; rm_tree() { [ ! -e \"$1\" ] || { find \"$1\" -type d -exec chmod u+w {} + && rm -rf \"$1\"; }; }; "
            + "[ -f \"$1/pack.json\" ] || { echo \"$1 has no pack.json: it is not a prepared pack\" >&2; exit 1; }; "
            + "rm_tree \"$2.old\"; had=; if [ -e \"$2\" ]; then mv \"$2\" \"$2.old\"; had=1; fi; "
            + "if ! mv \"$1\" \"$2\"; then [ -z \"$had\" ] || mv \"$2.old\" \"$2\"; exit 1; fi; rm_tree \"$2.old\"", "sh",
         staging.path, final.path]
    }

    // MARK: - The in-process steps

    /// `.packBegin`: removes a leftover `staging` (never reused), makes it, links into it from `from` the entries of the parts
    /// `manifest` records (those are current), and writes `manifest` as its `pack.json`.
    public static func begin(staging: URL, from: URL?, manifest: PackManifest) throws {
        try begin(staging: staging, from: from, manifest: manifest, link: { link($0, $1) == 0 })
    }

    static func begin(staging: URL, from: URL?, manifest: PackManifest, link: (String, String) -> Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) || (try? fm.destinationOfSymbolicLink(atPath: staging.path)) != nil {
            do { try removeTree(staging) } catch {
                throw XlessError(.sdk, "cannot remove \(staging.path), left by an interrupted setup: \(error)",
                                 fix: "delete it (rm -rf '\(staging.path)'), then run xless setup again")
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let parts = manifest.parts.keys.sorted().compactMap(PackPart.init(rawValue:))
        if !parts.isEmpty {
            guard let from else {
                throw XlessError(.sdk, "the pack to seed \(staging.path) from is not named", fix: "report it: the setup's plan is inconsistent")
            }
            for entry in parts.flatMap(entries(of:)) {
                let source = from.appendingPathComponent(entry)
                guard fm.fileExists(atPath: source.path) || (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil else {
                    throw XlessError(.sdk, "\(source.path) is gone, and the pack's current parts are taken from there",
                                     fix: "run xless setup again (it prepares that part again)")
                }
                try seed(source.path, into: staging.appendingPathComponent(entry).path, link: link)
            }
        }
        try manifest.write(to: staging.appendingPathComponent("pack.json"))
    }

    /// `source` at `destination`: directories made again, symbolic links made again (their targets unchanged), files hard
    /// linked, or copied where linking fails (another file system, a file system without hard links).
    static func seed(_ source: String, into destination: String, link: (String, String) -> Bool) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source)
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            try fm.createSymbolicLink(atPath: destination, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: source))
        case .typeDirectory?:
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(atPath: source) {
                try seed(source + "/" + child, into: destination + "/" + child, link: link)
            }
            // Last, so a directory without write permission is filled first.
            if let mode = attributes[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination) }
        default:
            if !link(source, destination) { try fm.copyItem(atPath: source, toPath: destination) }
        }
    }

    /// `.packSDK`: `xtool sdk install <xtoolSDK>` with `XDG_CONFIG_HOME=<config>` and the pack's toolchain first on PATH
    /// (xtool runs `swiftc` from PATH). xtool also writes lock files under `$HOME/.cache/xtool`: `env` needs a writable
    /// HOME. `xtool`: the xtool to run, by path (the one the plan's export runs: `NativeSetupPlan`).
    public static func installSDK(xtoolSDK: URL, config: URL, toolchain: URL, xtool: String,
                                  env: [String: String] = ProcessInfo.processInfo.environment) throws {
        try Shell.run(xtool, ["sdk", "install", xtoolSDK.path],
                      env: ["XDG_CONFIG_HOME": config.path, "PATH": SDKInstaller.path(toolchain: toolchain, env: env)],
                      baseEnvironment: env, stage: .sdk, passthrough: true)
        let bundle = config.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw XlessError(.sdk, "xtool installed no SDK at \(bundle.path)", fix: "see xtool's output above, then run xless setup again")
        }
    }

    /// `.packPart`: `part`, made with `hash`, recorded in the staging `pack.json` (replaced by a rename).
    public static func record(_ part: PackPart, hash: String, staging: URL) throws {
        let file = staging.appendingPathComponent("pack.json")
        var manifest = try PackManifest.load(from: file)
        manifest.parts[part.rawValue] = hash
        try manifest.write(to: file)
    }

    /// `.packCommit`: `staging` renamed to `final`; the pack that was there is renamed aside first (`<name>.old`, a leftover
    /// of which is removed) and removed after. A failed rename puts the old pack back. `move`: the rename (a test's).
    public static func commit(staging: URL, final: URL, move: ((URL, URL) throws -> Void)? = nil) throws {
        let fm = FileManager.default, move = move ?? { try Self.move($0, to: $1) }
        guard fm.fileExists(atPath: staging.appendingPathComponent("pack.json").path) else {
            throw XlessError(.sdk, "\(staging.path) has no pack.json: it is not a prepared pack", fix: "run xless setup again")
        }
        let old = final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".old")
        if fm.fileExists(atPath: old.path) { try removeTree(old) }
        let hadOne = fm.fileExists(atPath: final.path)
        if hadOne { try move(final, old) }
        do { try move(staging, final) } catch {
            if hadOne { try? move(old, final) }
            throw error
        }
        if hadOne { try? removeTree(old) }
    }

    /// The pack a setup left at `<final>.old` with no `final` (stopped between the two renames of `commit`), renamed back
    /// to `final`. Returns whether it did. Called under the pack's lock (`PackLock`), by setup alone: a build never renames.
    public static func recover(_ final: URL) throws -> Bool {
        let fm = FileManager.default
        let old = final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".old")
        guard !fm.fileExists(atPath: final.path), (try? fm.destinationOfSymbolicLink(atPath: final.path)) == nil,
              fm.fileExists(atPath: old.appendingPathComponent("pack.json").path) else { return false }
        try move(old, to: final)
        return true
    }

    /// A staging directory a failed setup leaves (`<name>.partial`): removed, so nothing half-prepared stays beside the pack.
    public static func discard(staging: URL) throws {
        guard FileManager.default.fileExists(atPath: staging.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: staging.path)) != nil else { return }
        try removeTree(staging)
    }

    /// Removes `url`, its directories made writable first (a directory without write permission keeps its entries). Files
    /// are left as they are: they may be hard links of the pack in use. Only directories are made writable, each looked at
    /// (without following a link) right before: a symbolic link, the tree itself or in it, never has its target changed.
    public static func removeTree(_ url: URL) throws {
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory }
        do { try fm.removeItem(at: url) } catch {
            var directories = [url.path]
            if isDirectory(url.path), let e = fm.enumerator(atPath: url.path) {
                for case let p as String in e where isDirectory(url.path + "/" + p) { directories.append(url.path + "/" + p) }
            }
            for d in directories where isDirectory(d) {
                let mode = (try? fm.attributesOfItem(atPath: d)[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
                try? fm.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: d)
            }
            try fm.removeItem(at: url)
        }
    }

    private static func move(_ from: URL, to: URL) throws {
        guard rename(from.path, to.path) == 0 else {
            let error = errno
            throw XlessError(.sdk, "cannot rename \(from.path) to \(to.path): \(String(cString: strerror(error)))",
                             fix: "check that \(to.deletingLastPathComponent().path) is writable, then run xless setup again")
        }
    }
}
