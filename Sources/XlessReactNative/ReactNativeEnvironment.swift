import Foundation
import XlessCore
import XlessTauri

/// The environment of the React Native steps (contract doc, "Env-only fixes" and "Overrides and environment Task 8 sets").
public enum ReactNativeEnvironment {
    /// The image's `hermesc` (built from the Hermes source React Native pins; React Native's npm `hermesc` is macOS / x86_64).
    public static let hermesc = KitTools.hermesc

    /// What GNU tar needs to read macOS-made tarballs as bsdtar does: no warning on stderr for the Apple pax headers
    /// (Expo reads tar's merged output as a plist), no AppleDouble `._*` files (they would be embedded in the app).
    static let tarOptions = "--warning=no-unknown-keyword --exclude=._*"

    /// Changes to the environment of `prepare`'s commands (JS install, the overlay's commands, Expo prebuild,
    /// Bundler, CocoaPods). nil removes a variable.
    /// - `SWIFT_*` removed: the Swift image exports `SWIFT_VERSION=swift-6.4.0-RELEASE`, and Xcodeproj resolves a build
    ///   setting from the environment before the project, so CocoaPods would read the app target's `SWIFT_VERSION` as
    ///   that string and fail;
    /// - `PATH` starts with `<shims>/prepare`: `command` (Ruby runs `command -v` as an executable, which macOS has) and
    ///   the `clang` that retargets Expo's stub-framework compile to iOS (`PrepareClangShim`);
    /// - `TAR_OPTIONS`, and no telemetry or corepack prompt;
    /// - the overlay's `env` last.
    public static func prepare(overlay: ReactNativeOverlay, shimDirectory: URL, base: [String: String]) -> [String: String?] {
        var env: [String: String?] = [:]
        for key in base.keys where key.hasPrefix("SWIFT_") { env[key] = .some(nil) }
        env["PATH"] = shimDirectory.appendingPathComponent("prepare").path + ":" + (base["PATH"] ?? "/usr/bin:/bin")
        env["TAR_OPTIONS"] = tarOptions
        env["EXPO_NO_TELEMETRY"] = "1"
        env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        for (k, v) in overlay.env { env[k] = v }
        return env
    }

    /// `prepare` for a Mac, and the environment of `xcodebuild`: xless's stand-ins first on PATH (`XcodeBuild.writeTools`), and the gems
    /// in a directory of the build's own (Ruby's is the user's, which the sandbox does not let it write).
    public static func native(overlay: ReactNativeOverlay, work: URL, base: [String: String]) -> [String: String?] {
        var env = build(overlay: overlay)
        env["PATH"] = RustApple.wrapperDirectory(workRoot: work).path + ":" + (base["PATH"] ?? "/usr/bin:/bin")
        env["SWIFT_EXEC"] = XcodeBuild.compiler(work: work).path
        if overlay.env["BUNDLE_PATH"] == nil { env["BUNDLE_PATH"] = (base["HOME"] ?? NSHomeDirectory()) + "/.bundle/xless" }
        return env
    }

    /// Additions to `swbuild`'s environment (`SwiftBuildEnvironment.processEnvironment` comes first), inherited by every
    /// script phase: the overlay's `env` (the app's config is evaluated again by Expo's phases: the JS bundle, the
    /// Constants manifest), no telemetry, no corepack prompt.
    public static func build(overlay: ReactNativeOverlay) -> [String: String?] {
        var env: [String: String?] = ["EXPO_NO_TELEMETRY": "1", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0"]
        for (k, v) in overlay.env { env[k] = v }
        return env
    }

    /// Command-line build settings on top of `SwiftBuildEnvironment.overrides` (which already has
    /// `CODE_SIGNING_ALLOWED = NO`): the signing team, and Hermes. `HERMES_CLI_PATH` must be a build setting: React
    /// Native's post-install writes the npm macOS `hermesc` into the project, and build settings beat the environment
    /// in script phases. Per-target settings (bundle IDs, versions) are not here: a command-line value would apply
    /// to every target and win over them.
    public static func buildSettings(overlay: ReactNativeOverlay) -> [String: String] {
        ["DEVELOPMENT_TEAM": overlay.teamID, "HERMES_CLI_PATH": hermesc]
    }

    /// Per-target settings of the app and each bundle it embeds: the overlay's bundle ID and the run's version, for
    /// Info.plists that use `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`.
    public static func targetSettings(bundleID: String, version: String, build: String) -> [String: String] {
        ["PRODUCT_BUNDLE_IDENTIFIER": bundleID, "MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build]
    }
}
