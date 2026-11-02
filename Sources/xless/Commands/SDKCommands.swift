import ArgumentParser
import Foundation
import XlessCore
import XlessSDK

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk", abstract: "Manage the Darwin SDK and toolchain metadata.",
        subcommands: {
            #if os(macOS)
            [SDKMetaCommand.self, SDKExportCommand.self, SDKInstallCommand.self]
            #else
            [SDKMetaCommand.self, SDKInstallCommand.self]
            #endif
        }())
}

/// Shared by `sdk meta` and `sdk export`: the supported-Xcode table lives in the share directory's versions.env.
private func knownXcodes() throws -> [KnownXcode] {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let share = try XlessShare.root(env: ProcessInfo.processInfo.environment, executable: exe)
    return try KnownXcodes.load(versionsEnv: share.appendingPathComponent("versions.env"))
}

private func knownXcode(build: String) throws -> KnownXcode {
    let all = try knownXcodes()
    guard let x = all.first(where: { $0.build == build }) else {
        throw XlessError(.sdk, "Xcode build \(build) is not a supported release (supported: \(all.map(\.build).joined(separator: ", ")))",
                         fix: "use a supported Xcode, or add it to versions.env's XCODE_* table")
    }
    return x
}

/// The BuildMachineOSBuild for an Xcode.app: the flag, else the table entry of its build. Never `sw_vers`.
private func buildMachineOSBuild(flag: String?, xcodeApp: URL) throws -> String {
    if let flag { return flag }
    let version = try Plist.read(xcodeApp.appendingPathComponent("Contents/version.plist"), stage: .sdk)
    guard let build = version["ProductBuildVersion"] as? String else {
        throw XlessError(.sdk, "Xcode version.plist lacks ProductBuildVersion", fix: "pass the path to a full Xcode.app")
    }
    return try knownXcode(build: build).buildMachineOSBuild
}

struct SDKMetaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta", abstract: "Write toolchain-meta.json from an Xcode.app, or from an xtool SDK (--from-xtoolsdk).")

    @Option(help: "Path to Xcode.app.") var xcode: String = "/Applications/Xcode.app"
    @Option(help: "Output file.") var out: String = "dist/sdk/toolchain-meta.json"
    @Option(help: "BuildMachineOSBuild value (default: the supported-Xcode table's).") var buildMachineOSBuild: String?
    @Option(help: "Read an xtool SDK (darwin.xtoolsdk) instead of an Xcode.app; needs --xcode-build.") var fromXtoolsdk: String?
    @Option(help: "With --from-xtoolsdk: the Xcode build the SDK was made from (a supported release).") var xcodeBuild: String?

    func run() async throws {
        let meta: ToolchainMeta
        if let fromXtoolsdk {
            guard let xcodeBuild else {
                throw XlessError(.sdk, "--from-xtoolsdk needs --xcode-build", fix: "pass the Xcode build the SDK was made from, e.g. --xcode-build 27A266a")
            }
            var known = try knownXcode(build: xcodeBuild)
            if let buildMachineOSBuild {
                known = KnownXcode(build: known.build, shortVersion: known.shortVersion, appleSwift: known.appleSwift,
                                   buildMachineOSBuild: buildMachineOSBuild, xipSHA256: known.xipSHA256)
            }
            meta = try ToolchainMetaCollector.collect(xtoolSDK: URL(fileURLWithPath: fromXtoolsdk), xcode: known)
        } else {
            let app = URL(fileURLWithPath: xcode)
            meta = try ToolchainMetaCollector.collect(
                xcodeApp: app, buildMachineOSBuild: try xless.buildMachineOSBuild(flag: buildMachineOSBuild, xcodeApp: app))
        }
        for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
        try meta.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (Xcode \(meta.xcodeVersion) \(meta.xcodeBuild))")
    }
}

#if os(macOS)
struct SDKExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "On the Mac: write toolchain-meta.json and build per-arch Darwin SDKs inside the Linux base image.")

    @Option(help: "Path to Xcode.app.") var xcode: String = "/Applications/Xcode.app"
    @Option(help: "Output directory.") var out: String = "dist/sdk"
    @Option(help: "Base image: '{arch}' in it is replaced by the architecture, else '-<arch>' is appended.") var baseImage: String = "xless-base:local"
    @Option(parsing: .upToNextOption, help: "Docker architectures.") var arch: [String] = ["arm64", "amd64"]
    @Option(help: "BuildMachineOSBuild value (default: the supported-Xcode table's).") var buildMachineOSBuild: String?

    func run() async throws {
        let outDir = URL(fileURLWithPath: out).standardizedFileURL
        let app = URL(fileURLWithPath: xcode)
        let osBuild = try xless.buildMachineOSBuild(flag: buildMachineOSBuild, xcodeApp: app)
        let meta = try ToolchainMetaCollector.collect(xcodeApp: app, buildMachineOSBuild: osBuild)
        for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
        try meta.write(to: outDir.appendingPathComponent("toolchain-meta.json"))

        for a in arch {
            let image = baseImage.contains("{arch}") ? baseImage.replacingOccurrences(of: "{arch}", with: a) : "\(baseImage)-\(a)"
            let probe = try? Shell.run("docker", ["run", "--rm", "--platform", "linux/\(a)", "-v", "\(xcode):/xcode:ro", image,
                                                  "test", "-d", "/xcode/Contents/Developer"], stage: .sdk)
            guard probe != nil else {
                throw XlessError(.sdk, "the Docker VM cannot see \(xcode)",
                                 fix: "Colima: `colima stop && colima start --mount /Applications:r --mount $HOME:w`; Docker Desktop: add /Applications to File Sharing, or clone Xcode.app under $HOME (cp -cR) and pass --xcode")
            }
            let dir = try Files.fresh(outDir.appendingPathComponent(a))
            try Shell.run("docker", ["run", "--rm", "--platform", "linux/\(a)",
                                     "-v", "\(xcode):/xcode:ro", "-v", "\(dir.path):/out", image,
                                     "xtool", "sdk", "build", "/xcode", "/out"], stage: .sdk, passthrough: true)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("darwin.xtoolsdk").path) else {
                throw XlessError(.sdk, "xtool did not produce \(dir.path)/darwin.xtoolsdk", fix: "see xtool output above")
            }
        }
        print("exported SDK for \(arch.joined(separator: ", ")) to \(outDir.path)")
    }
}
#endif

struct SDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install the Darwin SDK + toolchain metadata on this Linux machine.")

    @Option(help: "darwin.xtoolsdk produced by `xless sdk export` for this machine's architecture.") var xtoolsdk: String?
    @Option(help: "toolchain-meta.json from the same export.") var meta: String?
    @Option(help: "Copy both from an xless SDK image instead (needs docker).") var image: String?

    func run() async throws {
        let installed: (sdk: URL, meta: URL)
        if let image {
            guard xtoolsdk == nil, meta == nil else {
                throw XlessError(.sdk, "--image cannot be combined with --xtoolsdk/--meta", fix: "pass either --image, or --xtoolsdk with --meta")
            }
            installed = try SDKInstaller.install { sdkStage, metaStage in
                let cid = try Shell.run("docker", ["create", image], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                defer { _ = try? Shell.run("docker", ["rm", cid], stage: .sdk) }
                try Shell.run("docker", ["cp", "\(cid):/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle", sdkStage.path], stage: .sdk)
                try Shell.run("docker", ["cp", "\(cid):/opt/xless/toolchain-meta.json", metaStage.path], stage: .sdk)
                return sdkStage
            }
        } else {
            guard let xtoolsdk, let meta else {
                throw XlessError(.sdk, "pass --xtoolsdk and --meta, or --image", fix: "see docs/native-install.md")
            }
            for (name, path) in [("--xtoolsdk", xtoolsdk), ("--meta", meta)] where !FileManager.default.fileExists(atPath: path) {
                throw XlessError(.sdk, "\(name) \(path) does not exist", fix: "pass the files produced by `xless sdk export`")
            }
            installed = try SDKInstaller.install(xtoolsdk: URL(fileURLWithPath: xtoolsdk), meta: URL(fileURLWithPath: meta))
        }
        print("SDK at \(installed.sdk.path); metadata at \(installed.meta.path)")
    }
}
