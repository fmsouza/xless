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

    /// Whether another Swift selects the architecture by `--swift-sdk` and `--arch` (`swiftBuildArguments`): below 6.4. From
    /// 6.4 on its `--triple` builds the one architecture, and its `--swift-sdk` links the executable with the rpath
    /// `$ORIGIN` (an ELF token dyld does not expand) where the triple gives `@loader_path` (measured with 6.4.0).
    static func selectsTheArchitectureBySwiftSDK(_ swift: SwiftToolchain) -> Bool {
        guard let v = DottedVersion(swift.version) else { return true }
        return v < DottedVersion("6.4")!
    }

    /// `swift build` of the wrapper package for one architecture. Another Swift release than the image's own (Ruling R10:
    /// its SwiftPM, on PATH; measured with 6.2.3):
    /// - names the executable product, as `SwiftPackages.build` does: its Swift Build otherwise builds only targets and
    ///   links no executable;
    /// - selects the architecture with `--swift-sdk <arch>-apple-macosx --arch <arch>` rather than a triple: with
    ///   `--triple` its Swift Build builds every standard macOS architecture (arm64 and x86_64) and joins them with
    ///   `lipo`, which the image does not have; `--arch` is refused next to `--triple`. The deployment target is then the
    ///   wrapper package's `platforms` (`minimumOS`), which the triple's version otherwise sets. Below 6.4 only
    ///   (`selectsTheArchitectureBySwiftSDK`).
    /// `swiftSDKs`: where SwiftPM finds the Darwin SDK (`XcodeEnvironment.swiftSDKsArguments`: the pack is read-only, so
    /// not through `XDG_CONFIG_HOME`).
    static func swiftBuildArguments(wrapper: URL, scratch: URL, arch: String, minimumOS: String, toolset: URL,
                                    product: String, own: SwiftToolchain?, swiftSDKs: [String] = []) -> [String] {
        let target = own.map(selectsTheArchitectureBySwiftSDK) ?? false ? ["--swift-sdk", "\(arch)-apple-macosx", "--arch", arch]
            : ["--triple", "\(arch)-apple-macosx\(minimumOS)"]
        var args = ["build", "--package-path", wrapper.path, "--scratch-path", scratch.path,
                    "-c", "release", "--build-system", "swiftbuild"] + target + ["--toolset", toolset.path] + swiftSDKs
        if own != nil { args += ["--product", "\(product)Mac"] }
        return args
    }

    public static func note(_ text: String) { FileHandle.standardError.write(Data("xless: note: \(text)\n".utf8)) }

    public static func build(project: URL, config: ProjectConfig, paths: StagePaths, env: [String: String] = ProcessInfo.processInfo.environment,
                             engineRelease: String? = SwiftToolchain.engineRelease, note: (String) -> Void = Self.note) throws -> URL {
        let mac = try config.platform(.macos)
        let xcode = try XcodeEnvironment.current(env: env)
        let sdk = xcode.sdkBundle
        let toolset = sdk.appendingPathComponent("toolset-swb.json")
        guard FileManager.default.fileExists(atPath: toolset.path) else {
            throw XlessError(.build, "Darwin SDK not installed at \(sdk.path)", fix: "prepare the Xcode's pack: `xless setup --xcode <Xcode.xip>` (`--docker` for xless run --docker)")
        }
        let lock = try BuildLock(project: project, note: note)
        defer { lock.release() }
        let wrapper = project.appendingPathComponent(".xless/macos-pkg", isDirectory: true)
        try? FileManager.default.removeItem(at: wrapper)
        let srcDir = wrapper.appendingPathComponent("Sources/\(mac.product)Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data().write(to: srcDir.appendingPathComponent("stub.c"))
        try wrapperPackage(product: mac.product, minimumOS: mac.minimumOS, rootRelativePath: "../..")
            .write(to: wrapper.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try PackageResolved.copy(from: project, to: wrapper)

        let buildEnv: [String: String?] = [
            "SDKROOT": nil,
            "XCODE_EXTRA_PLATFORM_FOLDERS": sdk.appendingPathComponent("Developer/Platforms").path,
            "PATH": "\(sdk.appendingPathComponent("toolset/bin").path):\(env["PATH"] ?? "/usr/bin:/bin")",
        ]
        var slices: [Data] = [], executables: [URL] = []
        var resourceBundles: [URL] = []
        // Ruling R10: another Swift release than the image's own (the build stage put it on PATH) builds in its own
        // scratch directory, never reusing a previous toolchain's products; its SwiftPM may lay them out elsewhere than
        // `out/`. A copy of the engine's release (a pack whose Swift is the image's own) builds as the engine does.
        let own = xcode.toolchain.flatMap { $0.isEngineRelease(engineRelease) ? nil : $0 }
        for arch in archs {
            let scratch = project.appendingPathComponent(".xless/macos-build-\(arch)" + (own.map { "-swift-\($0.version)" } ?? ""), isDirectory: true)
            func executable() -> URL? {
                builtExecutable(named: "\(mac.product)Mac", under: scratch.appendingPathComponent("out/Products"))
                    ?? (own == nil ? nil : builtExecutable(named: "\(mac.product)Mac", under: scratch))
            }
            func products() -> [URL] {
                let there = own == nil ? (try? FileManager.default.contentsOfDirectory(at: scratch.appendingPathComponent("out/Products"), includingPropertiesForKeys: nil)) ?? []
                    : ResourceBundles.directories(in: scratch)
                return Set(there + [executable()?.deletingLastPathComponent()].compactMap { $0 }).sorted { $0.path < $1.path }
            }
            try ResourceBundles.fresh(scratch: scratch, products: products, note: note) {
                try Shell.run("swift", swiftBuildArguments(wrapper: wrapper, scratch: scratch, arch: arch, minimumOS: mac.minimumOS,
                                                           toolset: toolset, product: mac.product, own: own, swiftSDKs: xcode.swiftSDKsArguments),
                              cwd: project, env: buildEnv, stage: .build, passthrough: true)
            }
            guard let exe = executable() else {
                throw XlessError(.build, "no \(mac.product)Mac executable under \(scratch.path)/out/Products", fix: "check the swift build output above")
            }
            slices.append(try Data(contentsOf: exe))
            executables.append(exe)
            if resourceBundles.isEmpty {
                resourceBundles = ResourceBundles.of(exe.deletingLastPathComponent())
            }
        }

        if let unpinned = PackageResolved.unpinnedNote(project: project, wrapper: wrapper) { note(unpinned) }
        let built = try Files.atomicOutput(paths.app) { partial in
            try PackageApp.assemble(in: partial, executable: MachO.makeFat(slices), resources: resourceBundles, project: project, config: config, platform: .macos)
        }
        // Swift Build writes `<name>.dSYM` next to each architecture's executable: one universal `<Product>.app.dSYM`.
        let dSYMs = try DSYM.keep(executables: executables, app: built, into: paths.dSYMs)
        FileHandle.standardError.write(Data("xless: dSYMs: \(dSYMs.summary)\n".utf8))
        return built
    }
}
