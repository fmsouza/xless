import Foundation
import XlessCore
import XlessMachO

/// Builds a macOS .app on Linux by mirroring xtool's iOS approach (generated wrapper package with an
/// executable target that links the app's library product), once per architecture, then lipo-merging.
public enum MacBuilder {
    static let archs = ["arm64", "x86_64"]

    public static func wrapperPackage(product: String, minimumOS: String, rootRelativePath: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(product)-MacBuilder",
            platforms: [.macOS("\(minimumOS)")],
            dependencies: [.package(name: "RootPackage", path: "\(rootRelativePath)")],
            targets: [
                .executableTarget(name: "\(product)Mac",
                    dependencies: [.product(name: "\(product)", package: "RootPackage")],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
                )
            ]
        )

        """
    }

    public static func baseInfoPlist(config: ProjectConfig) throws -> [String: Any] {
        let mac = try config.platform(.macos)
        return [
            "CFBundleExecutable": mac.product,
            "CFBundleIdentifier": config.bundleID(for: .macos),
            "CFBundleName": mac.product,
            "CFBundleDisplayName": mac.product,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "CFBundleShortVersionString": config.version,
            "CFBundleVersion": config.build,
            "LSMinimumSystemVersion": mac.minimumOS,
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
        ]
    }

    /// The linked executable under swiftbuild's products dir. Observed layout (Swift 6.4, xless:local-arm64):
    /// `<scratch>/out/Products/Release/<name>` next to `<name>.dSYM/Contents/Resources/DWARF/<name>`, so the
    /// dSYM companion (same file name) must be skipped.
    static func builtExecutable(named name: String, under products: URL) -> URL? {
        Files.regularFiles(under: products).first {
            $0.lastPathComponent == name && !$0.pathComponents.contains { $0.hasSuffix(".dSYM") }
        }
    }

    /// `swift build` of the wrapper package for one architecture. Another Swift than the image's own (Ruling R10: its
    /// SwiftPM, on PATH; measured with 6.2.3):
    /// - names the executable product, as `SwiftPackages.build` does: its Swift Build otherwise builds only targets and
    ///   links no executable;
    /// - selects the architecture with `--swift-sdk <arch>-apple-macosx --arch <arch>` rather than a triple: with
    ///   `--triple` its Swift Build builds every standard macOS architecture (arm64 and x86_64) and joins them with
    ///   `lipo`, which the image does not have; `--arch` is refused next to `--triple`. The deployment target is then the
    ///   wrapper package's `platforms` (`minimumOS`), which the triple's version otherwise sets.
    static func swiftBuildArguments(wrapper: URL, scratch: URL, arch: String, minimumOS: String, toolset: URL,
                                    product: String, own: SwiftToolchain?) -> [String] {
        let target = own == nil ? ["--triple", "\(arch)-apple-macosx\(minimumOS)"] : ["--swift-sdk", "\(arch)-apple-macosx", "--arch", arch]
        var args = ["build", "--package-path", wrapper.path, "--scratch-path", scratch.path,
                    "-c", "release", "--build-system", "swiftbuild"] + target + ["--toolset", toolset.path]
        if own != nil { args += ["--product", "\(product)Mac"] }
        return args
    }

    public static func build(project: URL, config: ProjectConfig, paths: StagePaths,
                             env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let mac = try config.platform(.macos)
        let sdk = DarwinSDKLocator.bundle(env: env)
        let toolset = sdk.appendingPathComponent("toolset-swb.json")
        guard FileManager.default.fileExists(atPath: toolset.path) else {
            throw XlessError(.build, "Darwin SDK not installed at \(sdk.path)", fix: "use the xless SDK image or run `xless sdk install`")
        }
        let wrapper = project.appendingPathComponent(".xless/macos-pkg", isDirectory: true)
        try? FileManager.default.removeItem(at: wrapper)
        let srcDir = wrapper.appendingPathComponent("Sources/\(mac.product)Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data().write(to: srcDir.appendingPathComponent("stub.c"))
        try wrapperPackage(product: mac.product, minimumOS: mac.minimumOS, rootRelativePath: "../..")
            .write(to: wrapper.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let buildEnv: [String: String?] = [
            "SDKROOT": nil,
            "XCODE_EXTRA_PLATFORM_FOLDERS": sdk.appendingPathComponent("Developer/Platforms").path,
            "PATH": "\(sdk.appendingPathComponent("toolset/bin").path):\(env["PATH"] ?? "/usr/bin:/bin")",
        ]
        var slices: [Data] = [], executables: [URL] = []
        var resourceBundles: [URL] = []
        // Ruling R10: another Swift than the image's own (the build stage put it on PATH) builds in its own scratch
        // directory, never reusing a previous toolchain's products; its SwiftPM may lay them out elsewhere than `out/`.
        let own = (try? SwiftToolchain.load(env: env)).flatMap { $0.isEngine ? nil : $0 }
        for arch in archs {
            let scratch = project.appendingPathComponent(".xless/macos-build-\(arch)" + (own.map { "-swift-\($0.version)" } ?? ""), isDirectory: true)
            try Shell.run("swift", swiftBuildArguments(wrapper: wrapper, scratch: scratch, arch: arch, minimumOS: mac.minimumOS,
                                                       toolset: toolset, product: mac.product, own: own),
                          cwd: project, env: buildEnv, stage: .build, passthrough: true)
            guard let exe = builtExecutable(named: "\(mac.product)Mac", under: scratch.appendingPathComponent("out/Products"))
                    ?? (own == nil ? nil : builtExecutable(named: "\(mac.product)Mac", under: scratch)) else {
                throw XlessError(.build, "no \(mac.product)Mac executable under \(scratch.path)/out/Products", fix: "check the swift build output above")
            }
            slices.append(try Data(contentsOf: exe))
            executables.append(exe)
            if resourceBundles.isEmpty {
                resourceBundles = ((try? FileManager.default.contentsOfDirectory(at: exe.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "bundle" }
            }
        }

        let built = try Files.atomicOutput(paths.app) { partial in
            let app = partial.appendingPathComponent("\(mac.product).app", isDirectory: true)
            let layout = BundleLayout(platform: .macos)
            let fm = FileManager.default
            for dir in [layout.executableDir, layout.resourcesDir] {
                try fm.createDirectory(at: app.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            let exeURL = app.appendingPathComponent("\(layout.executableDir)/\(mac.product)")
            try MachO.makeFat(slices).write(to: exeURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
            try Data("APPL????".utf8).write(to: app.appendingPathComponent(layout.pkgInfo))
            for b in resourceBundles {
                try fm.copyItem(at: b, to: app.appendingPathComponent("\(layout.resourcesDir)/\(b.lastPathComponent)"))
            }
            if let privacy = config.privacyManifest {
                guard fm.fileExists(atPath: project.appendingPathComponent(privacy).path) else {
                    throw XlessError(.build, "privacyManifest \(privacy) does not exist", fix: "fix the privacyManifest path in xless.yml (relative to the project directory)")
                }
                try fm.copyItem(at: project.appendingPathComponent(privacy),
                                to: app.appendingPathComponent("\(layout.resourcesDir)/PrivacyInfo.xcprivacy"))
            }
            var info = try baseInfoPlist(config: config)
            if let userInfo = config.infoPlist {
                for (k, v) in try Plist.read(project.appendingPathComponent(userInfo), stage: .build) { info[k] = v }
            }
            try Plist.write(info, to: app.appendingPathComponent(layout.infoPlist), stage: .build)
            return app
        }
        // Swift Build writes `<name>.dSYM` next to each architecture's executable: one universal `<Product>.app.dSYM`.
        let dSYMs = try DSYM.keep(executables: executables, app: built, into: paths.dSYMs)
        FileHandle.standardError.write(Data("xless: dSYMs: \(dSYMs.summary)\n".utf8))
        return built
    }
}
