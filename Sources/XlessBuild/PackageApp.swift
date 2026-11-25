import Foundation
import XlessCore

/// The .app of a Swift package, put together from what its build made: the executable, the packages' resource bundles and the
/// frameworks it loads.
enum PackageApp {
    /// What its Info.plist has before the project's own (`infoPlist` in xless.yml) and finalize: for iOS what xtool writes on Linux,
    /// so an app is the same whichever system it is built on.
    static func baseInfoPlist(config: ProjectConfig, platform: Platform) throws -> [String: Any] {
        guard platform == .ios else { return try MacBuilder.baseInfoPlist(config: config) }
        let ios = try config.platform(.ios)
        let portrait = "UIInterfaceOrientationPortrait"
        return [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": config.build,
            "CFBundleShortVersionString": config.version,
            "MinimumOSVersion": ios.minimumOS,
            "CFBundleIdentifier": config.bundleID(for: .ios),
            "CFBundleName": ios.product,
            "CFBundleExecutable": ios.product,
            "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "LSRequiresIPhoneOS": true,
            "UIRequiredDeviceCapabilities": ["arm64"],
            "UIDeviceFamily": [1, 2],
            "UISupportedInterfaceOrientations": [portrait],
            "UISupportedInterfaceOrientations~ipad": [portrait, "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
            "UILaunchScreen": [String: Any](),
        ]
    }

    /// Writes it into `directory`; its path.
    static func assemble(in directory: URL, executable: Data, resources: [URL], frameworks: [URL] = [], project: URL, config: ProjectConfig, platform: Platform) throws -> URL {
        let product = try config.platform(platform).product
        let app = directory.appendingPathComponent("\(product).app", isDirectory: true)
        let layout = BundleLayout(platform: platform)
        let fm = FileManager.default
        func at(_ dir: String) -> URL { dir.isEmpty ? app : app.appendingPathComponent(dir, isDirectory: true) }
        for dir in [layout.executableDir, layout.resourcesDir] + (frameworks.isEmpty ? [] : [layout.frameworksDir]) {
            try fm.createDirectory(at: at(dir), withIntermediateDirectories: true)
        }
        let exeURL = at(layout.executableDir).appendingPathComponent(product)
        try executable.write(to: exeURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
        try Data("APPL????".utf8).write(to: app.appendingPathComponent(layout.pkgInfo))
        for bundle in resources { try fm.copyItem(at: bundle, to: at(layout.resourcesDir).appendingPathComponent(bundle.lastPathComponent)) }
        for framework in frameworks { try fm.copyItem(at: framework, to: at(layout.frameworksDir).appendingPathComponent(framework.lastPathComponent)) }
        if let privacy = config.privacyManifest {
            guard fm.fileExists(atPath: project.appendingPathComponent(privacy).path) else {
                throw XlessError(.build, "privacyManifest \(privacy) does not exist", fix: "fix the privacyManifest path in xless.yml (relative to the project directory)")
            }
            try fm.copyItem(at: project.appendingPathComponent(privacy), to: at(layout.resourcesDir).appendingPathComponent("PrivacyInfo.xcprivacy"))
        }
        var info = try baseInfoPlist(config: config, platform: platform)
        if let userInfo = config.infoPlist {
            for (k, v) in try Plist.read(project.appendingPathComponent(userInfo), stage: .build) { info[k] = v }
        }
        try Plist.write(info, to: app.appendingPathComponent(layout.infoPlist), stage: .build)
        return app
    }
}
