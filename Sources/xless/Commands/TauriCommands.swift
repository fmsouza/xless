import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessReactNative
import XlessTauri

struct TauriCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tauri", abstract: "Tauri v2 helpers (iOS and macOS).",
                                                    subcommands: [TauriReportCommand.self, TauriCompareCommand.self, TauriInspectCommand.self, TauriNextBuildCommand.self])
}

struct TauriReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Describe a built .app as deterministic JSON (for black-box comparison).")
    @Argument var app: String
    @Option(name: .long, help: "Write the JSON here instead of stdout.") var json: String?
    func run() throws {
        let data = try BundleReport.make(app: URL(fileURLWithPath: app)).json()
        if let json {
            do { try data.write(to: URL(fileURLWithPath: json)) }
            catch { throw XlessError(.build, "cannot write \(json): \(error.localizedDescription)", fix: "check the output path") }
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

struct TauriCompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compare", abstract: "Diff a built .app against a reference report; exits 1 on differences.")
    @Argument var reference: String
    @Argument var app: String
    @Option(name: .customLong("allow-file"), help: "File of known-gap keys (one per line, # comments) to ignore.") var allowFile: String?
    @Flag(name: .customLong("assets-only"), help: "Compare only the asset catalogs (`car:` keys), read with xcrun assetutil (macOS); <app> may be any directory holding the bundle's .car files at their bundle paths.") var assetsOnly = false
    func run() throws {
        let ref: BundleReport
        do { ref = try JSONDecoder().decode(BundleReport.self, from: Data(contentsOf: URL(fileURLWithPath: reference))) }
        catch { throw XlessError(.build, "cannot read reference report \(reference): \(error.localizedDescription)", fix: "generate it with `xless tauri report <app> --json <file>`") }
        var allowed: Set<String> = []
        if let allowFile {
            guard let text = try? String(contentsOfFile: allowFile, encoding: .utf8) else {
                throw XlessError(.build, "cannot read allow file \(allowFile)", fix: "check the path")
            }
            allowed = BundleReport.parseAllow(text)
        }
        let diffs: [String]
        if assetsOnly {
            guard AssetCatalogReport.isAvailable else {
                throw XlessError(.build, "--assets-only needs xcrun assetutil", fix: "run it on a Mac with Xcode")
            }
            guard let refCatalogs = ref.assetCatalogs else {
                throw XlessError(.build, "reference report \(reference) has no asset catalogs", fix: "record it on a Mac (`xless tauri report` reads them with assetutil)")
            }
            let dir = URL(fileURLWithPath: app)
            let actual = try AssetCatalogReport.catalogs(in: dir, files: AssetCatalogReport.carFiles(under: dir))
            diffs = AssetCatalogReport.diff(reference: refCatalogs, actual: actual, allowed: allowed)
        } else {
            let actual = try BundleReport.make(app: URL(fileURLWithPath: app))
            if ref.assetCatalogs != nil, actual.assetCatalogs == nil {
                FileHandle.standardError.write(Data("note: asset catalogs not compared (no xcrun assetutil here); on a Mac: xless tauri compare --assets-only\n".utf8))
            }
            diffs = BundleReport.diff(reference: ref, actual: actual, allowed: allowed)
        }
        guard diffs.isEmpty else {
            print(diffs.joined(separator: "\n"))
            throw ExitCode(1)
        }
    }
}

struct TauriInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Print what a Tauri build would do (read-only; writes nothing, runs no cargo).")
    @Option(name: .long, help: "Tauri overlay file (type: tauri).") var config: String
    @Option(name: .long, help: "Use this directory as the app source instead of the overlay's `source:`.") var source: String?
    @Option(name: .long, help: "Target platform: ios (default) or macos (Developer ID DMG; never contacts App Store Connect).") var platform: Platform = .ios
    func run() async throws {
        let loc = try OverlayLocation.load(from: URL(fileURLWithPath: config).standardizedFileURL, sourceOverride: source)
        if platform == .macos {
            let mac = try TauriProject.resolveMac(overlay: loc.overlay, source: loc.sourceRoot)
            print(InspectReport.makeMac(resolved: mac, overlay: loc.overlay,
                                        contract: TauriContract.detect(source: loc.sourceRoot, tauriDir: mac.tauriDir), source: loc.sourceRoot), terminator: "")
            return
        }
        let resolved = try TauriProject.resolve(overlay: loc.overlay, source: loc.sourceRoot)
        // Swift packages come from `cargo metadata`, which inspect never runs. The next build number is a read-only App Store
        // Connect query, made only when credentials are present; nothing is persisted.
        let nextBuild = try await InspectNextBuild.query(dated: loc.overlay.build == "dated", team: resolved.config.teamID) { secrets in
            try await DatedBuildNumber.compute(version: resolved.config.version, bundleID: resolved.config.bundleID(for: .ios), secrets: secrets)
        }
        print(InspectReport.make(resolved: resolved, overlay: loc.overlay,
                                 contract: TauriContract.detect(source: loc.sourceRoot, tauriDir: resolved.tauriDir),
                                 scripts: InspectReport.scripts(target: resolved.target, overlay: loc.overlay),
                                 scriptTexts: InspectReport.builtInScripts(target: resolved.target, overlay: loc.overlay),
                                 swiftPackages: nil, nextBuild: nextBuild), terminator: "")
    }
}

struct TauriNextBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-build",
        abstract: "Print the build number the next run of an overlay would use (read-only App Store Connect query; persists nothing).",
        discussion: "For `build: dated` it asks App Store Connect for the builds of the version (credentials needed); a fixed build is printed as is. xless run starts it with credentials, then builds without them using XLESS_BUILD_NUMBER.")
    @Option(name: .long, help: "Tauri overlay file (type: tauri).") var config: String
    @Option(name: .long, help: "Use this directory as the app source instead of the overlay's `source:`.") var source: String?
    func run() async throws {
        let url = URL(fileURLWithPath: config).standardizedFileURL
        print(try await NextBuild.tauri(at: url, sourceOverride: source, compute: NextBuild.datedLookup(overlay: url)))
    }
}
