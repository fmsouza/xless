import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessReactNative
import XlessTauri

/// `xless next-build --config <overlay>` for any overlay type: React Native and cargo overlays here, a Tauri one also
/// through `xless tauri next-build`. scripts/testflight.sh runs it in step 1, the only container with App Store Connect
/// credentials and no build code.
struct NextBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-build",
        abstract: "Print the build number the next run of an overlay would use (read-only App Store Connect query; persists nothing).",
        discussion: "For `build: dated` it asks App Store Connect for the builds of the version (credentials needed); a fixed build is printed as is. A React Native overlay is read without its work copy: the version comes from the overlay's `version:` or the app's app.json / package.json in the source, the bundle ID from `bundleIDs`. A cargo overlay gives its iOS app's number: the version from the overlay's `version:` or the package's Cargo.toml in the source, the bundle ID from ios.bundleID or bundleID. scripts/testflight.sh runs it with credentials, then builds without them using XLESS_BUILD_NUMBER.")
    @Option(name: .long, help: "Overlay file (type: react-native, type: tauri or type: cargo).") var config: String
    @Option(name: .long, help: "Use this directory as the app source instead of the overlay's `source:`.") var source: String?

    func run() async throws {
        let url = URL(fileURLWithPath: config).standardizedFileURL
        print(try await NextBuild.forOverlay(at: url, sourceOverride: source, compute: NextBuild.datedLookup(overlay: url)))
    }
}

extension NextBuild {
    /// `DatedBuildNumber.compute` with the process's credentials (the secret store's preferring the overlay's `teamID:`),
    /// as the `config` stage (`[config] …`, exit 10).
    static func datedLookup(overlay url: URL) -> Compute {
        let team = (try? OverlayPaths.read(url)).flatMap(OverlayPaths.team(of:)) ?? ""
        return { version, bundleID in
            SecretScope.enter() // reads the App Store Connect key (both next-build commands come here)
            return try await withStage(.config) {
                try await DatedBuildNumber.compute(version: version, bundleID: bundleID, secrets: Secrets().preferring(team: team))
            }
        }
    }
}
