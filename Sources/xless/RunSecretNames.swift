import Foundation
import XlessCore

/// The secrets a run's upload reads under names its configuration gives (`xless secrets named-by`, for
/// `xless run`): the TestFlight demo account's password, when the configuration's
/// `testflight.external.review.demoAccount` may need it sent (`TestFlightConfig.demoPasswordSecret`). The script gives
/// it, from its `_FILE` variable or the secret store, to the container that uploads, and to no other.
/// The configuration is only parsed: its source is not read, no tool runs and the secret store is not opened.
enum RunSecretNames {
    /// For an overlay (`config`) or a project directory's xless.yml (`project`), shipped for `platform`.
    static func upload(config: URL?, project: URL?, platform: Platform) throws -> [String] {
        let names = [try testFlight(config: config, project: project, platform: platform)?.demoPasswordSecret].compactMap { $0 }
        // An overlay is only parsed here (its loader validates later): refuse what that validation would.
        for name in names {
            if let problem = SecretEnvironment.passwordNameProblem(name) {
                throw XlessError(.config, "testflight.external.review.demoAccount.passwordSecret \(name) \(problem)",
                                 fix: "keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD (`xless secrets import XLESS_DEMO_PASSWORD --file <file> --kind password`)")
            }
        }
        return names
    }

    /// The `testflight:` block the run's upload publishes with, as each loader resolves it for `platform`: a Tauri app's
    /// DMG and React Native (iOS only) have none on macOS; a cargo app's macOS upload is its App-Store lane's.
    static func testFlight(config: URL?, project: URL?, platform: Platform) throws -> TestFlightConfig? {
        if let project { return try ProjectConfig.load(from: project.appendingPathComponent("xless.yml")).testflight }
        return try config.flatMap { try overlay($0, platform: platform) }
    }
}
