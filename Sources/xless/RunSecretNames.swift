import Foundation
import XlessCargo
import XlessCore
import XlessReactNative
import XlessTauri

/// The secrets a run's upload reads under names its configuration gives (`xless secrets named-by`, for
/// scripts/testflight.sh): the TestFlight demo account's password, when the configuration's
/// `testflight.external.review.demoAccount` may need it sent (`TestFlightConfig.demoPasswordSecret`). The script gives
/// it, from its `_FILE` variable or the secret store, to the container that uploads, and to no other.
/// The configuration is only parsed: its source is not read, no tool runs and the secret store is not opened.
enum RunSecretNames {
    /// For an overlay (`config`) or a project directory's xless.yml (`project`), shipped for `platform`.
    static func upload(config: URL?, project: URL?, platform: Platform) throws -> [String] {
        [try testFlight(config: config, project: project, platform: platform)?.demoPasswordSecret].compactMap { $0 }
    }

    /// The `testflight:` block the run's upload publishes with, as each loader resolves it for `platform`: a Tauri app's
    /// DMG and React Native (iOS only) have none on macOS; a cargo app's macOS upload is its App-Store lane's.
    static func testFlight(config: URL?, project: URL?, platform: Platform) throws -> TestFlightConfig? {
        if let project { return try ProjectConfig.load(from: project.appendingPathComponent("xless.yml")).testflight }
        guard let config else { return nil }
        let text = try OverlayPaths.read(config)
        let name = OverlayPaths(overlay: config).name
        switch try OverlayKind.of(config) {
        case .reactNative: return platform == .ios ? try ReactNativeOverlay.parse(yaml: text, name: name).testflight : nil
        case .cargo: return try CargoOverlay.parse(yaml: text, name: name).testflight
        case .tauri: return platform == .ios ? try TauriOverlay.parse(yaml: text, name: name).testflight : nil
        }
    }
}
