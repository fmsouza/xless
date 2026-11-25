import Foundation
import XlessCore

public enum ToolchainMetaCollector {
    /// "27.0" → "2700", "16.4" → "1640", "26.0.1" → "2601" (Xcode's DTXcode encoding).
    public static func xcodeVersionCode(_ shortVersion: String) throws -> String {
        guard let v = DottedVersion(shortVersion), v.parts[1] < 10, v.parts[2] < 10 else {
            throw XlessError(.sdk, "unexpected Xcode version '\(shortVersion)'", fix: "check Xcode.app/Contents/version.plist")
        }
        return String(format: "%02d%d%d", v.parts[0], v.parts[1], v.parts[2])
    }

    /// `environment`: what its `swift` finds changed in xless's own (nil: removed).
    public static func collect(xcodeApp: URL, buildMachineOSBuild: String, environment: [String: String?] = [:]) throws -> ToolchainMeta {
        let version = try Plist.read(xcodeApp.appendingPathComponent("Contents/version.plist"), stage: .sdk)
        guard let short = version["CFBundleShortVersionString"] as? String,
              let build = version["ProductBuildVersion"] as? String else {
            throw XlessError(.sdk, "Xcode version.plist lacks version keys", fix: "pass the path to a full Xcode.app")
        }
        let platforms = try readPlatforms(under: xcodeApp.appendingPathComponent("Contents/Developer"),
                                          fix: "pass the path to a full Xcode.app with the %@ platform installed")
        return ToolchainMeta(xcodeVersion: try xcodeVersionCode(short), xcodeBuild: build,
                             buildMachineOSBuild: buildMachineOSBuild, compiler: ToolchainMeta.clangCompiler,
                             platforms: platforms, swiftVersion: try swiftVersion(xcodeApp: xcodeApp, environment: environment))
    }

    /// The same metadata from an xtool SDK (`darwin.xtoolsdk`), whose `Developer/` tree mirrors Xcode's. The Xcode's
    /// identity, Swift and BuildMachineOSBuild come from the supported-Xcode table: nothing is executed.
    public static func collect(xtoolSDK: URL, xcode: KnownXcode) throws -> ToolchainMeta {
        let platforms = try readPlatforms(under: xtoolSDK.appendingPathComponent("Developer"),
                                          fix: "pass the darwin.xtoolsdk that xtool built from the Xcode (it lacks the %@ platform)")
        return ToolchainMeta(xcodeVersion: try xcodeVersionCode(xcode.shortVersion), xcodeBuild: xcode.build,
                             buildMachineOSBuild: xcode.buildMachineOSBuild, compiler: ToolchainMeta.clangCompiler,
                             platforms: platforms, swiftVersion: xcode.appleSwift)
    }

    private static func readPlatforms(under developer: URL, fix: String) throws -> [String: PlatformSDKInfo] {
        var platforms: [String: PlatformSDKInfo] = [:]
        for (p, dirName) in [(Platform.ios, "iPhoneOS"), (Platform.macos, "MacOSX")] {
            let platformDir = developer.appendingPathComponent("Platforms/\(dirName).platform")
            let sdkDir = platformDir.appendingPathComponent("Developer/SDKs/\(dirName).sdk")
            let settingsURL = sdkDir.appendingPathComponent("SDKSettings.json")
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let canonical = settings["CanonicalName"] as? String,
                  let sdkVersion = settings["Version"] as? String else {
                throw XlessError(.sdk, "cannot read \(settingsURL.path)", fix: fix.replacingOccurrences(of: "%@", with: dirName))
            }
            let sysVersion = try Plist.read(sdkDir.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"), stage: .sdk)
            guard let sdkBuild = sysVersion["ProductBuildVersion"] as? String else {
                throw XlessError(.sdk, "\(dirName).sdk SystemVersion.plist lacks ProductBuildVersion", fix: "reinstall the \(dirName) platform in Xcode")
            }
            let platformInfo = (try? Plist.read(platformDir.appendingPathComponent("Info.plist"), stage: .sdk)) ?? [:]
            platforms[p.sdkKey] = PlatformSDKInfo(
                sdkName: canonical, sdkVersion: sdkVersion, sdkBuild: sdkBuild,
                platformName: p.sdkKey,
                platformVersion: platformInfo["DTPlatformVersion"] as? String ?? sdkVersion,
                platformBuild: platformInfo["DTPlatformBuild"] as? String ?? sdkBuild)
        }
        return platforms
    }

    /// The Swift the Xcode ships (Ruling R10), black-box: its default toolchain's `swift --version`, e.g. "Apple Swift
    /// version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)" → "6.2.3".
    public static func swiftVersion(xcodeApp: URL, environment: [String: String?] = [:]) throws -> String {
        let swift = xcodeApp.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
        let out: String
        do { out = try Shell.run(swift.path, ["--version"], env: environment, stage: .sdk).stdout } catch {
            throw XlessError(.sdk, "cannot run \(swift.path) --version: \(error)", fix: "pass the path to a full Xcode.app")
        }
        guard let v = SwiftToolchain.parseVersion(out) else {
            throw XlessError(.sdk, "no Swift version in `\(swift.path) --version`: \(out)", fix: "pass the path to a full Xcode.app")
        }
        return v
    }
}
