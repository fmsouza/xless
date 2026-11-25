import Foundation
import XlessCore

/// Xcode's `actool` and `ibtool` on a Mac, for what AssetKit and `XlessIB` do elsewhere. A tool that is nil is not used: xless's own
/// does its work.
public struct XcodeAssets: Sendable {
    public var actool: URL?
    public var ibtool: URL?
    /// What their environment has changed (`InstalledXcode.environment`).
    public var environment: [String: String?]
    public var simulator: Bool

    public init(actool: URL?, ibtool: URL?, environment: [String: String?], simulator: Bool = false) {
        self.actool = actool; self.ibtool = ibtool; self.environment = environment; self.simulator = simulator
    }

    static func targetDevices(_ info: [String: Any]) throws -> [String] { try LaunchStoryboard.targetDevices(info).reversed() }

    /// The arguments that compile `catalog` into `output`.
    func actoolArguments(_ catalog: URL, appIcon: String?, output: URL, partial: URL, platform: Platform, minimumOS: String, devices: [String]) -> [String] {
        [catalog.path, "--compile", output.path, "--platform", platform == .macos ? "macosx" : simulator ? "iphonesimulator" : "iphoneos",
         "--minimum-deployment-target", minimumOS] + devices.flatMap { ["--target-device", $0] } + (appIcon.map { ["--app-icon", $0] } ?? [])
            + ["--output-partial-info-plist", partial.path, "--output-format", "human-readable-text", "--errors", "--warnings"]
    }

    /// Compiles `catalog` into the app's resources; what goes into its Info.plist.
    func compile(_ catalog: URL, with actool: URL, into resources: URL, platform: Platform, minimumOS: String, info: [String: Any]) throws -> [String: Any] {
        let icon = AssetsStage.appIconSet(catalog: catalog)?.deletingPathExtension().lastPathComponent
        let scratch = Files.temporary.appendingPathComponent("xless-actool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent("partial.plist")
        let devices = platform == .macos ? ["mac"] : try Self.targetDevices(info)
        do {
            try Shell.run(actool.path, actoolArguments(catalog, appIcon: icon, output: resources, partial: partial, platform: platform, minimumOS: minimumOS, devices: devices),
                          env: environment, stage: .assets, passthrough: true)
        } catch let e as XlessError {
            throw XlessError(.assets, "\(catalog.path): \(e.cause)", fix: "see actool's output above; if it lacks a simulator, install the iOS platform (Xcode's Settings, Components), or use xless's own compiler: XLESS_TOOLS=actool=xless")
        }
        return (try? Plist.read(partial, stage: .assets)) ?? [:]
    }

    /// Compiles `storyboard` to `output` (a `.storyboardc`).
    func compile(_ storyboard: URL, with ibtool: URL, to output: URL, minimumOS: String, info: [String: Any]) throws {
        let devices = try Self.targetDevices(info).flatMap { ["--target-device", $0] }
        do {
            try Shell.run(ibtool.path, ["--compile", output.path, storyboard.path, "--minimum-deployment-target", minimumOS] + devices
                + ["--output-format", "human-readable-text", "--errors", "--warnings"], env: environment, stage: .assets, passthrough: true)
        } catch let e as XlessError {
            throw XlessError(.assets, "launch storyboard \(storyboard.path): \(e.cause)", fix: "see ibtool's output above, or use xless's own compiler: XLESS_TOOLS=ibtool=xless")
        }
    }
}
