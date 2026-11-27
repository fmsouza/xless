import ArgumentParser
import Foundation
import XlessCore
import XlessImages
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
        abstract: "On the Mac: write toolchain-meta.json and build per-arch Darwin SDKs inside the xless image (xless setup --docker builds it).")

    @Option(help: "Path to Xcode.app.") var xcode: String = "/Applications/Xcode.app"
    @Option(help: "Output directory.") var out: String = "dist/sdk"
    @Option(help: "The image with xtool, when not the xless image of this xless (xless setup --docker builds it): '{arch}' in it is replaced by the architecture, else '-<arch>' is appended.") var baseImage: String?
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
            let image: String
            if let baseImage {
                image = baseImage.contains("{arch}") ? baseImage.replacingOccurrences(of: "{arch}", with: a) : "\(baseImage)-\(a)"
            } else {
                let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                do {
                    let share = try XlessShare.root(env: ProcessInfo.processInfo.environment, executable: exe)
                    image = try LocalImages.here.base(version: try ImageName.cachedTag(ofShare: share), arch: a).name
                } catch let problem as ImageProblem {
                    throw XlessError(.sdk, problem.cause, fix: problem.fix)
                }
            }
            let probe = try? Shell.docker(["run", "--rm", "--pull=never", "--platform", "linux/\(a)", "-v", "\(xcode):/xcode:ro", image,
                                           "test", "-d", "/xcode/Contents/Developer"], stage: .sdk)
            guard probe != nil else {
                throw XlessError(.sdk, "the Docker VM cannot see \(xcode)",
                                 fix: "Colima: `colima stop && colima start --mount /Applications:r --mount $HOME:w`; Docker Desktop: add /Applications to File Sharing, or clone Xcode.app under $HOME (cp -cR) and pass --xcode")
            }
            let dir = try Files.fresh(outDir.appendingPathComponent(a))
            try Shell.docker(["run", "--rm", "--pull=never", "--platform", "linux/\(a)",
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

/// Nothing remains of `xless sdk install`: it copied the SDK out of an xless image (--image, gone with the images that held an SDK), or
/// installed an export where xtool keeps it, which nothing reads any more. The command stays, so an old script is told what to run.
struct SDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "No longer installs anything: xless setup --sdk <export> prepares an Xcode pack from an SDK export.",
        discussion: """
        A native setup does not install an SDK on its own any more, and no image holds one: `xless setup --sdk <export>` prepares an Xcode pack \
        from an SDK export (the directory that holds <arch>/darwin.xtoolsdk and toolchain-meta.json), with the Swift toolchain fitted to it. \
        Every form of this command (with --xtoolsdk, --meta or --image) says so and does nothing.
        """)

    @Option(help: ArgumentHelp("No longer supported: xless setup --sdk <export> prepares an Xcode pack from the export.", visibility: .hidden)) var xtoolsdk: String?
    @Option(help: ArgumentHelp("No longer supported: see --xtoolsdk.", visibility: .hidden)) var meta: String?
    @Option(help: ArgumentHelp("No longer supported: no image holds an SDK; see --xtoolsdk.", visibility: .hidden)) var image: String?

    func run() async throws {
        let export = xtoolsdk.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().path }
            ?? meta.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent().path }
        throw XlessError(.sdk, "xless sdk install no longer installs an SDK: builds read the Xcode from an Xcode pack, which xless setup prepares"
                         + (image == nil ? "" : " (no image holds an SDK any more)"),
                         fix: "xless setup --sdk \(export.map(ShellWord.quoted) ?? "<the export directory, holding <arch>/darwin.xtoolsdk and toolchain-meta.json>")")
    }
}
