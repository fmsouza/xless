import Foundation
import XlessCore

/// One download of a native setup: checked against its versions.env sha256, unpacked into `final`'s `.partial`
/// sibling, and renamed into place only once complete (a leftover `.partial` is removed, never reused).
public struct NativeDownload: Equatable, Sendable {
    /// `appImage`: xtool's AppImage, extracted with its own runtime (`--appimage-extract`, as docker/Dockerfile does);
    /// linked as `bin/xtool`. `rcodesign`: the release tarball's binary, linked as `bin/rcodesign`. `swiftToolchain`: a
    /// swift.org toolchain tarball, unpacked without its top directory (`<final>/usr/bin/swiftc`).
    public enum Kind: Equatable, Sendable { case appImage, rcodesign, swiftToolchain }

    public let kind: Kind
    public let url: URL
    public let sha256: String
    public let final: URL

    public init(kind: Kind, url: URL, sha256: String, final: URL) {
        self.kind = kind; self.url = url; self.sha256 = sha256; self.final = final
    }

    public var partial: URL { final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial") }

    /// The link in the native `bin/` that installs a tool, and what in `final` it leads to; nil for a toolchain.
    public var link: (name: String, target: String)? {
        switch kind {
        case .appImage: ("xtool", "AppRun")
        case .rcodesign: ("rcodesign", "rcodesign")
        case .swiftToolchain: nil
        }
    }
}

/// `xless setup` without `--docker` (Linux): what the images carry, with no Docker and no sudo. In order: xtool and
/// rcodesign (versions.env's pins) into `NativeLayout`, the Darwin SDK exported by that xtool into the cache the Docker
/// path uses too, its toolchain-meta.json, and then the Xcode pack of that Xcode in the store (`PackPlan`): the
/// open-source Swift toolchain the Xcode's Swift maps to (`XCODE_SWIFT_<build>`, Ruling R10), the SDK installed for xtool
/// and SwiftPM, the metadata and the fit (scripts/fit-toolchain.sh), and Swift Build where this machine can use it. A tool
/// already installed is skipped; a pack part is prepared only when it is not current, and every other pack of the store
/// is left as it is (several Xcodes side by side).
public enum NativeSetupPlan {
    /// The host commands a native setup and a native build run (cpio: the macOS lane's .pkg payload; xless writes the XAR itself; Swift's own
    /// libraries are checked by running swiftc).
    public static let requiredCommands = ["curl", "tar", "gzip", "unzip", "zip", "git", "python3", "cpio"]

    /// The Debian/Ubuntu packages for `requiredCommands` and the swift.org toolchain's dependencies (its Ubuntu 22.04
    /// list; on a newer release apt picks the matching versions of the -dev packages), plus libncurses6: swiftc links
    /// libncurses.so.6, which ubuntu:22.04's base has and ubuntu:24.04's lacks.
    public static let aptPackages = ["curl", "ca-certificates", "tar", "gzip", "zip", "unzip", "git", "python3", "cpio", "binutils",
                                     "libc6-dev", "libcurl4-openssl-dev", "libedit2", "libgcc-11-dev", "libncurses6", "libpython3-dev",
                                     "libsqlite3-0", "libstdc++-11-dev", "libxml2-dev", "libz3-dev", "pkg-config", "tzdata", "zlib1g-dev"]
    public static var aptLine: String { "sudo apt-get install -y " + aptPackages.joined(separator: " ") }

    private static func pin(_ key: String, table: [String: String], arch: String) throws -> String {
        guard let v = table[key], !v.isEmpty else {
            throw XlessError(.sdk, "versions.env has no \(key), which a native setup on \(arch) downloads with",
                             fix: "reinstall xless (its versions.env is incomplete), or build in Docker instead: xless setup --docker …")
        }
        return v
    }

    /// rcodesign, which signs: the release for Linux, or for a Mac (the same version, by its own pin).
    public static func rcodesign(arch: String, mac: Bool, table: [String: String], layout: NativeLayout) throws -> NativeDownload {
        let a = PackRecipe.tableArch(arch), version = try pin("RCODESIGN_VERSION", table: table, arch: arch)
        let name = "apple-codesign-\(version)-\(a.lowercased())-\(mac ? "apple-darwin" : "unknown-linux-musl").tar.gz"
        return NativeDownload(kind: .rcodesign, url: URL(string: "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F\(version)/\(name)")!,
                              sha256: try pin("RCODESIGN_SHA256_\(mac ? "DARWIN_" : "")\(a)", table: table, arch: arch), final: layout.rcodesign(version: version))
    }

    /// The executable `tool` on `path` (a PATH value), when it is the pinned `version`: it is run (`<tool> --version`), and
    /// one word of what it prints must be `version` exactly (xtool prints `xtool 1.21.0`, rcodesign `apple-codesign
    /// 0.29.0`). nil: not on PATH, another version, or it does not run. An image has both installed; a native setup there
    /// downloads neither (`make`'s `installed`).
    public static func pinnedOnPath(_ tool: String, version: String, path: String?) -> URL? {
        guard let found = XcodeEnvironment.which(tool, path: path),
              let out = try? Shell.run(found.path, ["--version"], stage: .sdk).stdout else { return nil }
        return out.split(whereSeparator: \.isWhitespace).contains { $0 == version } ? found : nil
    }

    /// `store`: where the pack goes (`XcodeStore`); the pack there now, if any, is read to tell which of its parts are current.
    /// `abilities`: what this machine can prepare (`PackPlan.abilities`). `existing`: whether a file is there.
    /// `installed`: a tool (`xtool`, `rcodesign`) of the pinned version already on this machine (`pinnedOnPath`), which is
    /// then not downloaded into `layout`, and the export runs that xtool.
    public static func make(source: XcodeSource.Identified, arch: String, share: URL, cacheRoot: URL, layout: NativeLayout,
                            store: XcodeStore, table: [String: String], reexport: Bool, abilities: PackPlan.Abilities,
                            installed: (_ tool: String, _ version: String) -> URL? = { _, _ in nil },
                            existing: (URL) -> Bool) throws -> [SetupStep] {
        let x = source.xcode, a = PackRecipe.tableArch(arch), lower = a.lowercased()
        func pin(_ key: String) throws -> String { try Self.pin(key, table: table, arch: arch) }
        let xtoolV = try pin("XTOOL_VERSION"), rcV = try pin("RCODESIGN_VERSION")
        let downloads = [
            ("xtool", xtoolV, NativeDownload(kind: .appImage, url: URL(string: "https://github.com/xtool-org/xtool/releases/download/\(xtoolV)/xtool-\(lower).AppImage")!,
                                             sha256: try pin("XTOOL_SHA256_\(a)"), final: layout.xtool(version: xtoolV)), "~10 s"),
            ("rcodesign", rcV, try rcodesign(arch: arch, mac: false, table: table, layout: layout), "seconds"),
        ]
        var steps: [SetupStep] = []
        // Installed when its marker is there: a tool's link in bin/ (which a run stopped after the move lacks); or when the
        // pinned version is on PATH already (the image's), which is then the one that runs.
        var xtool = layout.bin.appendingPathComponent("xtool")
        for (tool, version, d, estimate) in downloads {
            let marker = layout.bin.appendingPathComponent(tool)
            if existing(marker) { continue }
            if let found = installed(tool, version) {
                if tool == "xtool" { xtool = found }
                continue
            }
            let what = "\(tool) \(version)"
            steps.append(SetupStep(title: "install \(what) into \(d.final.path)",
                                   argv: ["curl", "-fsSL", "-o", d.partial.path + ".download", d.url.absoluteString],
                                   estimate: estimate, action: .download(d)))
        }

        let sdkDir = SetupPlan.sdkDir(source: source, cacheRoot: cacheRoot)
        let final = sdkDir.appendingPathComponent(arch), partial = sdkDir.appendingPathComponent("\(arch).partial")
        let xtoolSDK = final.appendingPathComponent("darwin.xtoolsdk"), meta = sdkDir.appendingPathComponent("toolchain-meta.json")
        // An export source has no Xcode to export from (setup refuses an export that lacks this arch).
        let exporting = source.kind != .export && (reexport || !existing(xtoolSDK))
        if exporting {
            steps.append(SetupStep(
                title: "export the Darwin SDK for \(arch) from Xcode \(x.shortVersion) (\(x.build)) into \(final.path)",
                argv: [xtool.path, "sdk", "build", source.url.path, partial.path],
                estimate: "~2 min" + (source.kind == .xip ? "; up to ~15 GB in the cache while the .xip is unpacked, ~3.5 GB stays" : "; ~3 GB on disk"),
                action: .export(partial: partial, final: final)))
        }
        if exporting || !existing(meta) {
            steps.append(SetupStep(title: "toolchain-meta.json for Xcode \(x.shortVersion) (\(x.build))",
                                   argv: ["xless", "sdk", "meta", "--from-xtoolsdk", xtoolSDK.path, "--xcode-build", x.build, "--out", meta.path],
                                   estimate: "seconds", action: .meta(xtoolSDK: xtoolSDK, out: meta)))
        }
        let place = store.directory(xcode: XcodeVersion.canonical(x.shortVersion), build: x.build, arch: arch)
        // A pack.json that cannot be read is no pack: it is prepared whole.
        let current = (try? XcodePack.open(place)) ?? nil
        return steps + (try PackPlan.make(xcode: x, arch: arch, export: sdkDir, store: store, share: share, table: table,
                                          abilities: abilities, current: current, existing: existing))
    }
}
