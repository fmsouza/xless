import Foundation
import XlessCore

/// The app an appstore/ manifest belongs to when app.yml does not say: the bundle IDs (by platform) and the team of
/// the project configuration, an overlay given with `--config` (Tauri, cargo, React Native) or the xless.yml next to
/// the manifest directory. Overlays are only parsed: the app source is not read.
struct StoreProject: Equatable {
    var bundleIDs: [Platform: String]
    var team: String?
    /// How messages name the configuration: `xless.yml`, `overlay tauri.yml`.
    var name: String

    /// The bundle ID for App Store Connect's `platform` (MAC_OS is the macOS app, anything else the iOS one); with no
    /// platform, the iOS app, else the only one.
    func bundleID(for platform: String?) -> String? {
        guard let platform else { return bundleIDs[.ios] ?? (bundleIDs.count == 1 ? bundleIDs.values.first : nil) }
        return bundleIDs[platform == "MAC_OS" ? .macos : .ios]
    }

    /// xless.yml in the manifest directory's parent; nil when there is none or it cannot be read (as before overlays).
    static func nextTo(manifestDir: URL) -> StoreProject? {
        let file = manifestDir.deletingLastPathComponent().appendingPathComponent("xless.yml")
        guard FileManager.default.fileExists(atPath: file.path), let config = try? ProjectConfig.load(from: file) else { return nil }
        // A platform xless.yml does not build still has the project's bundle ID (one app record for both).
        let ids = Dictionary(uniqueKeysWithValues: Platform.allCasesOrdered.map { ($0, config.bundleID(for: $0)) })
        return StoreProject(bundleIDs: ids, team: config.teamID, name: "xless.yml")
    }
}
