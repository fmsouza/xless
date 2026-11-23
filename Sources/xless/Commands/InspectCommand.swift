import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessFinalize
import XlessReactNative
import XlessTauri

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print Info.plist and Mach-O build versions of a bundle as JSON, or (--config) what an overlay's build would do.",
        discussion: "With --config: a read-only report (writes nothing, runs no build tool). A React Native overlay reports its scheme, targets, bundle IDs, Swift packages and contract versions (the Xcode project is read from the work copy once `xless prepare` has generated it); a Tauri overlay prints `xless tauri inspect`'s report. Cargo overlays are not supported yet.")
    @Argument(help: "The .app or .appex to describe (without --config).") var bundle: String?
    @Option(help: "Platform of the bundle (without --config); ios or macos.") var platform: Platform?
    @Option(name: .long, help: "Overlay file (type: react-native or type: tauri; type: cargo is refused).") var config: String?
    @Option(name: .long, help: "With --config: use this directory as the app source instead of the overlay's `source:`.") var source: String?

    func validate() throws {
        if config == nil {
            guard bundle != nil, platform != nil else { throw ValidationError("give a bundle and --platform, or --config <overlay>") }
            if source != nil { throw ValidationError("--source requires --config") }
        } else if bundle != nil {
            throw ValidationError("--config describes an overlay; it cannot be combined with a bundle")
        }
    }

    func run() async throws {
        guard let config else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(Inspector.report(bundle: URL(fileURLWithPath: bundle!), platform: platform!)), as: UTF8.self))
            return
        }
        let url = URL(fileURLWithPath: config).standardizedFileURL
        let kind = try OverlayKind.of(url)
        try kind.requireInspectable()
        guard kind == .reactNative else {
            var args = ["--config", config] + (source.map { ["--source", $0] } ?? [])
            if let platform { args += ["--platform", platform.rawValue] }
            let tauri = try TauriInspectCommand.parse(args)
            try await tauri.run()
            return
        }
        if let platform, platform != .ios { throw XlessError(.config, "React Native overlays build iOS apps only", fix: "use --platform ios") }
        let (overlay, sourceRoot, workRoot) = try ReactNativeOverlay.load(from: url, sourceOverride: source)
        let resolved = try ReactNativeProject.resolve(overlay: overlay, source: sourceRoot, work: workRoot)
        // The next build number is a read-only App Store Connect query, made only when credentials are present.
        let nextBuild = try await InspectNextBuild.query(dated: overlay.build == "dated", team: resolved.config.teamID) { secrets in
            try await DatedBuildNumber.compute(version: resolved.config.version, bundleID: resolved.config.bundleID, secrets: secrets)
        }
        print(ReactNativeInspectReport.make(resolved: resolved, overlay: overlay,
                                            contract: ReactNativeContract.detect(appDir: overlay.appDir, source: sourceRoot, work: workRoot),
                                            native: ReactNativeInspectReport.native(overlay: overlay, work: workRoot), nextBuild: nextBuild),
              terminator: "")
    }
}

/// `inspect`'s next build number: a read-only App Store Connect query, made only for a dated build and only when the
/// project's team has credentials (the store's lookups prefer that team, like every stage of a run); a failed query is
/// reported in its place.
enum InspectNextBuild {
    /// Ctrl-C (`CancellationError`) is rethrown, not reported as a failed query.
    static func query(dated: Bool, team: String, secrets: Secrets = Secrets(),
                      compute: @escaping (Secrets) async throws -> String) async throws -> String? {
        guard dated else { return nil }
        let secrets = secrets.preferring(team: team)
        guard (try? ASCCredentials.fromSecrets(secrets, stage: .config)) != nil else { return nil }
        do {
            return try await compute(secrets)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "(App Store Connect query failed: \(XlessError.wrapping(error, stage: .config).cause))"
        }
    }
}
