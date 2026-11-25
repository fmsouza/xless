import Foundation
import XlessCore
import XlessIB

/// `launchStoryboard` in the iOS `assets` stage: compiles the storyboard like Xcode's CompileStoryboard + LinkStoryboards
/// steps and points Info.plist at it (docs/research/ib-invocation.md).
enum LaunchStoryboard {
    /// Compiles `storyboard` into `<app>/<name>.storyboardc` (the bundle root, where Xcode links it), sets
    /// `UILaunchStoryboardName` to `<name>` and removes `UILaunchScreen`. Every failure is an `[assets]` error.
    static func compile(_ storyboard: URL, into app: URL, minimumOS: String, xcode: XcodeAssets? = nil, profile: () throws -> XcodeToolsProfile) throws {
        let name = storyboard.deletingPathExtension().lastPathComponent
        guard FileManager.default.fileExists(atPath: storyboard.path) else {
            throw XlessError(.assets, "launch storyboard \(storyboard.path) does not exist", fix: "check `launchStoryboard` in xless.yml (relative to the project)")
        }
        let plistURL = app.appendingPathComponent(BundleLayout(platform: .ios).infoPlist)
        var info = try Plist.read(plistURL, stage: .assets)
        let out = app.appendingPathComponent("\(name).storyboardc", isDirectory: true)
        if let xcode, let ibtool = xcode.ibtool {
            try? FileManager.default.removeItem(at: out)
            try xcode.compile(storyboard, with: ibtool, to: out, minimumOS: minimumOS, info: info)
        } else { try compileOwn(storyboard, to: out, minimumOS: minimumOS, info: info, profile: profile()) }
        info["UILaunchStoryboardName"] = name
        info.removeValue(forKey: "UILaunchScreen")
        try Plist.write(info, to: plistURL, stage: .assets)
    }

    private static func compileOwn(_ storyboard: URL, to out: URL, minimumOS: String, info: [String: Any], profile: XcodeToolsProfile) throws {
        let options = IBCompileOptions(targetDevices: try targetDevices(info), minimumDeploymentTarget: minimumOS)

        let result: IBCompileResult
        do { result = try StoryboardCompiler.compile(url: storyboard, options: options, profile: profile) } catch {
            throw assetsError(error, storyboard: storyboard)
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: out)
            try fm.createDirectory(at: out, withIntermediateDirectories: false)
            for (file, data) in result.files.sorted(by: { $0.key < $1.key }) { try data.write(to: out.appendingPathComponent(file)) }
        } catch {
            throw XlessError(.assets, "cannot write \(out.path): \(error.localizedDescription)", fix: "check disk space and permissions")
        }
    }

    /// Any compiler failure as an `[assets]` error naming the storyboard (the compiler throws `XlessError`s; anything
    /// else is reported with its description).
    static func assetsError(_ error: Error, storyboard: URL) -> XlessError {
        if let e = error as? XlessError { return XlessError(.assets, "launch storyboard \(storyboard.path): \(e.cause)", fix: e.fix) }
        return XlessError(.assets, "launch storyboard \(storyboard.path): \(error.localizedDescription)",
                          fix: "check the storyboard file; re-save it in Xcode if needed")
    }

    /// ibtool's `--target-device` values from `UIDeviceFamily` (1 = iPhone, 2 = iPad), as Xcode derives them from
    /// `TARGETED_DEVICE_FAMILY`. Absent means iPhone + iPad, the default the app icon code also assumes.
    static func targetDevices(_ info: [String: Any]) throws -> [String] {
        guard let raw = info["UIDeviceFamily"] else { return ["ipad", "iphone"] }
        let family = (raw as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
        guard let family, !family.isEmpty, family.count == (raw as? [Any])?.count, family.allSatisfy({ $0 == 1 || $0 == 2 }) else {
            throw XlessError(.assets, "launch storyboards need UIDeviceFamily to be [1] or [1, 2], got \(raw)",
                             fix: "target iPhone (1), or iPhone and iPad (1, 2)")
        }
        return Set(family).map { $0 == 1 ? "iphone" : "ipad" }.sorted()
    }
}
