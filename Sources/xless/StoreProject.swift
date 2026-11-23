import Foundation
import XlessCargo
import XlessCore
import XlessReactNative
import XlessTauri

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
        var ids: [Platform: String] = [:]
        for p in Platform.allCasesOrdered where config.platforms[p] != nil { ids[p] = config.bundleID(for: p) }
        if ids.isEmpty { ids[.ios] = config.bundleID }
        return StoreProject(bundleIDs: ids, team: config.teamID, name: "xless.yml")
    }

    /// The overlay at `url`; its errors are the configuration's.
    static func overlay(_ url: URL) throws -> StoreProject {
        let text = try OverlayPaths.read(url)
        let name = OverlayPaths(overlay: url).name
        let label = "overlay \(url.lastPathComponent)"
        switch try OverlayKind.of(url) {
        case .tauri:
            let o = try TauriOverlay.parse(yaml: text, name: name)
            var ids: [Platform: String] = [:]
            if o.ios != nil || o.macos == nil { ids[.ios] = o.bundleID }
            if o.macos != nil { ids[.macos] = o.bundleID }
            return StoreProject(bundleIDs: ids, team: o.teamID, name: label)
        case .cargo:
            let o = try CargoOverlay.parse(yaml: text, name: name)
            var ids: [Platform: String] = [:]
            if let ios = o.ios { ids[.ios] = ios.bundleID ?? o.bundleID }
            if let mac = o.macos { ids[.macos] = mac.bundleID ?? o.bundleID }
            return StoreProject(bundleIDs: ids, team: o.teamID, name: label)
        case .reactNative:
            let o = try ReactNativeOverlay.parse(yaml: text, name: name)
            return StoreProject(bundleIDs: o.appTargetGuess.flatMap { o.bundleIDs[$0] }.map { [.ios: $0] } ?? [:], team: o.teamID, name: label)
        }
    }
}
