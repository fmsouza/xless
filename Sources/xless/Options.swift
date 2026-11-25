import ArgumentParser
import Foundation
import XlessCore

extension Platform: ExpressibleByArgument {}
extension Distribution: ExpressibleByArgument {}

/// `--destination`: what a React Native overlay is built for.
enum Destination: String, ExpressibleByArgument, CaseIterable {
    /// An iOS device: the full pipeline, up to TestFlight.
    case device
    /// The iOS Simulator (arm64): an ad-hoc signed app from `build`, which is the last stage; nothing is uploaded.
    case simulator
}

/// `sign` and `ship`: `--no-provisioning-updates`. It only restricts: nothing on the command line lifts a config's
/// `provisioningUpdates: false`.
struct ProvisioningUpdatesOption: ParsableArguments {
    @Flag(name: .customLong("no-provisioning-updates"),
          help: "Change nothing on the Apple account: when signing needs a bundle ID, a capability or a profile that is not there, fail with the list (exit 24). Config: provisioningUpdates: false.")
    var flag = false

    /// What turned provisioning updates off; nil when they are on.
    static func reason(flag: Bool, config: Bool) -> String? {
        flag ? "--no-provisioning-updates" : config ? nil : "\(ProvisioningUpdates.key): false"
    }
}

struct ProjectOptions: ParsableArguments {
    @Option(help: "Project directory containing xless.yml and Package.swift.")
    var project: String = "."

    @Option(help: "Overlay file (type: tauri, type: react-native or type: cargo) instead of a project directory; cannot be combined with --project.")
    var config: String?

    @Option(help: "With --config: use this directory as the app source instead of the overlay's `source:`.")
    var source: String?

    @Option(help: "Target platform: ios or macos.")
    var platform: Platform

    @Option(help: "Override the build number from xless.yml (also XLESS_BUILD_NUMBER).")
    var buildNumber: String?

    @Option(help: "React Native overlays: device (default) or simulator (an ad-hoc signed app for the iOS Simulator in .xless/build/ios-simulator/app; build is the last stage).")
    var destination: Destination = .device

    func validate() throws {
        if config != nil, project != "." {
            throw ValidationError("--config cannot be combined with --project")
        }
        if config == nil, source != nil {
            throw ValidationError("--source requires --config")
        }
    }

    var configURL: URL? { config.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var projectURL: URL { URL(fileURLWithPath: project).standardizedFileURL }
}
