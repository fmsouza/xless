import Foundation
import XlessCore

/// One download of a native setup: checked against its versions.env sha256, unpacked into `final`'s `.partial`
/// sibling, and renamed into place only once complete (a leftover `.partial` is removed, never reused).
public struct NativeDownload: Equatable, Sendable {
    /// `appImage`: xtool's AppImage, extracted with its own runtime (`--appimage-extract`, as docker/Dockerfile.base does);
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
}

/// `xless setup` without `--docker` (Linux): installs into `NativeLayout` what the images carry, with no Docker and no
/// sudo. In order: xtool and rcodesign (versions.env's pins), the open-source Swift toolchain the Xcode's Swift maps to
/// (`XCODE_SWIFT_<build>`, Ruling R10), the Darwin SDK exported by that xtool into the cache the Docker path uses too,
/// its toolchain-meta.json, the SDK installed for xtool/SwiftPM (`xless sdk install`), and last the image's toolchain
/// fix-ups (scripts/native-toolchain.sh), which write the toolchain record. A tool already installed is skipped; the SDK
/// install and the fix-ups are skipped only when the install already holds this Xcode with this toolchain.
public enum NativeSetupPlan {
    /// The current native install, from its toolchain-meta.json and toolchain record.
    public struct Installed: Equatable, Sendable {
        public let xcodeBuild: String
        public let swiftVersion: String
        public init(xcodeBuild: String, swiftVersion: String) { self.xcodeBuild = xcodeBuild; self.swiftVersion = swiftVersion }
    }

    /// The host commands a native setup and a native build run (cpio: the macOS lane's .pkg payload; xless writes the XAR itself; Swift's own
    /// libraries are checked by running swiftc).
    public static let requiredCommands = ["curl", "tar", "gzip", "unzip", "zip", "git", "python3", "cpio"]

    /// The Debian/Ubuntu packages for `requiredCommands` and the swift.org toolchain's dependencies (its Ubuntu 22.04
    /// list; on a newer release apt picks the matching versions of the -dev packages).
    public static let aptPackages = ["curl", "ca-certificates", "tar", "gzip", "zip", "unzip", "git", "python3", "cpio", "binutils",
                                     "libc6-dev", "libcurl4-openssl-dev", "libedit2", "libgcc-11-dev", "libpython3-dev",
                                     "libsqlite3-0", "libstdc++-11-dev", "libxml2-dev", "libz3-dev", "pkg-config", "tzdata", "zlib1g-dev"]
    public static var aptLine: String { "sudo apt-get install -y " + aptPackages.joined(separator: " ") }

    /// versions.env's spelling of an architecture: AARCH64 / X86_64 (and the downloads' aarch64 / x86_64).
    static func tableArch(_ arch: String) -> String { arch == "arm64" ? "AARCH64" : "X86_64" }

    /// The toolchain release Ruling R10 maps the Xcode to.
    public static func swiftVersion(for xcode: KnownXcode, table: [String: String]) throws -> String {
        guard let v = table["XCODE_SWIFT_\(xcode.build)"], !v.isEmpty else {
            throw XlessError(.sdk, "versions.env maps Xcode \(xcode.shortVersion) (\(xcode.build)) to no Swift toolchain (XCODE_SWIFT_\(xcode.build))",
                             fix: "use a supported Xcode, or build the images instead: xless setup --docker --xcode …")
        }
        return v
    }

    /// `sdkBundle` and `metaDest`: where the SDK install puts them (`DarwinSDKLocator.bundle()`,
    /// `ToolchainMeta.defaultLocation()`), which the fix-ups edit and read.
    public static func make(source: XcodeSource.Identified, arch: String, share: URL, cacheRoot: URL, layout: NativeLayout,
                            sdkBundle: URL, metaDest: URL, table: [String: String], reexport: Bool, installed: Installed?,
                            existing: (URL) -> Bool) throws -> [SetupStep] {
        let x = source.xcode, a = tableArch(arch), lower = a.lowercased()
        func pin(_ key: String) throws -> String {
            guard let v = table[key], !v.isEmpty else {
                throw XlessError(.sdk, "versions.env has no \(key), which a native setup on \(arch) downloads with",
                                 fix: "reinstall xless (its versions.env is incomplete), or build the images instead: xless setup --docker --xcode …")
            }
            return v
        }
        let swift = try swiftVersion(for: x, table: table)
        let swiftKey = "SWIFT_TOOLCHAIN_\(swift.replacingOccurrences(of: ".", with: "_"))"
        let xtoolV = try pin("XTOOL_VERSION"), rcV = try pin("RCODESIGN_VERSION")
        let rc = "apple-codesign-\(rcV)-\(lower)-unknown-linux-musl"
        let downloads = [
            ("xtool \(xtoolV)", NativeDownload(kind: .appImage, url: URL(string: "https://github.com/xtool-org/xtool/releases/download/\(xtoolV)/xtool-\(lower).AppImage")!,
                                              sha256: try pin("XTOOL_SHA256_\(a)"), final: layout.xtool(version: xtoolV)), layout.bin.appendingPathComponent("xtool"), "~10 s"),
            ("rcodesign \(rcV)", NativeDownload(kind: .rcodesign, url: URL(string: "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F\(rcV)/\(rc).tar.gz")!,
                                                sha256: try pin("RCODESIGN_SHA256_\(a)"), final: layout.rcodesign(version: rcV)), layout.bin.appendingPathComponent("rcodesign"), "seconds"),
            ("the Swift \(swift) toolchain (Xcode \(x.shortVersion)'s Swift, Ruling R10)",
             NativeDownload(kind: .swiftToolchain, url: URL(string: try pin("\(swiftKey)_URL_\(a)"))!, sha256: try pin("\(swiftKey)_SHA256_\(a)"),
                            final: layout.toolchain(version: swift)), layout.toolchain(version: swift).appendingPathComponent("usr/bin/swiftc"), "~2 min; a ~1.1 GB download, ~4 GB unpacked"),
        ]
        var steps: [SetupStep] = []
        // Installed when its marker is there: a tool's link in bin/ (which a run stopped after the move lacks), the toolchain's swiftc.
        for (what, d, marker, estimate) in downloads where !existing(marker) {
            steps.append(SetupStep(title: "install \(what) into \(d.final.path)",
                                   argv: ["curl", "-fsSL", "-o", d.partial.path + ".download", d.url.absoluteString],
                                   estimate: estimate, action: .download(d)))
        }

        let sdkDir = SetupPlan.sdkDir(cacheRoot: cacheRoot, xcode: x)
        let final = sdkDir.appendingPathComponent(arch), partial = sdkDir.appendingPathComponent("\(arch).partial")
        let xtoolSDK = final.appendingPathComponent("darwin.xtoolsdk"), meta = sdkDir.appendingPathComponent("toolchain-meta.json")
        let exporting = reexport || !existing(xtoolSDK)
        if exporting {
            steps.append(SetupStep(
                title: "export the Darwin SDK for \(arch) from Xcode \(x.shortVersion) (\(x.build)) into \(final.path)",
                argv: [layout.bin.appendingPathComponent("xtool").path, "sdk", "build", source.url.path, partial.path],
                estimate: "~2 min" + (source.kind == .xip ? "; up to ~15 GB in the cache while the .xip is unpacked, ~3.5 GB stays" : "; ~3 GB on disk"),
                action: .export(partial: partial, final: final)))
        }
        if exporting || !existing(meta) {
            steps.append(SetupStep(title: "toolchain-meta.json for Xcode \(x.shortVersion) (\(x.build))",
                                   argv: ["xless", "sdk", "meta", "--from-xtoolsdk", xtoolSDK.path, "--xcode-build", x.build, "--out", meta.path],
                                   estimate: "seconds", action: .meta(xtoolSDK: xtoolSDK, out: meta)))
        }
        let current = installed.map { $0.xcodeBuild == x.build && DottedVersion($0.swiftVersion) == DottedVersion(swift) } ?? false
        if !steps.isEmpty || !current || !existing(layout.record) {
            steps.append(SetupStep(title: "install the SDK and toolchain-meta.json for xtool and SwiftPM",
                                   argv: ["xless", "sdk", "install", "--xtoolsdk", xtoolSDK.path, "--meta", meta.path],
                                   estimate: "~1 min", action: .sdkInstall(xtoolSDK: xtoolSDK, meta: meta)))
            // The image's own Swift (SWIFT_VERSION) keeps the Xcode's clang resource directory; another release gets
            // its own, with the Xcode's runtimes (docker/Dockerfile.sdk's two cases).
            let mode = swift == table["SWIFT_VERSION"] ? "own" : "separate"
            steps.append(SetupStep(title: "fit the Swift \(swift) toolchain to the SDK and record it in \(layout.record.path)",
                                   argv: [share.appendingPathComponent("scripts/native-toolchain.sh").path, layout.toolchain(version: swift).path, mode,
                                          sdkBundle.path, metaDest.path, share.appendingPathComponent("docker/toolchain").path,
                                          layout.record.path],
                                   estimate: "seconds"))
        }
        return steps
    }
}
