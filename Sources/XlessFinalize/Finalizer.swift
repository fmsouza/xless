import Foundation
import XlessCore
import XlessMachO

public enum Finalizer {
    /// `kind` only words the fix texts (`ProjectKind`). The app is stamped from `meta`, the image's SDK: it must be the
    /// SDK the build used (`built`, the build's `BuildSDKRecord`, when it wrote one) and the project's `xcode:` pin.
    /// `identifiers` (a React Native overlay's `identifiers.replace`) rewrites the app's own Info.plists' string values
    /// first; each replaced key path goes to `log`.
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, meta: ToolchainMeta,
                           kind: ProjectKind = .xlessYML, built: BuildSDKRecord? = nil, identifiers: IdentifierReplacement = .none,
                           log: (String) -> Void = { FileHandle.standardError.write(Data("xless: \($0)\n".utf8)) }) throws -> URL {
        try Files.atomicOutput(outputDir) { partial in
            let pc = try config.platform(platform)
            let sdk = try meta.sdk(for: platform)
            try Requirements.checkSDK(sdk, platform: platform)
            try Requirements.checkDeployment(pc.minimumOS, platform: platform)
            try checkSameSDK(built: built, meta: meta, pin: config.xcode, platform: platform, kind: kind)
            let app = try Files.copyBundle(input, intoFreshDir: partial)
            let replaced = try identifiers.rewriteInfoPlists(in: app, stage: .finalize)
            try identifiers.record(in: partial)   // sign refuses another map (IdentifierReplacement.checkFinalized)
            if !identifiers.isEmpty {
                log("identifiers.replace: \(replaced.count) Info.plist value(s) replaced\(replaced.isEmpty ? "" : ": " + replaced.joined(separator: ", "))")
            }
            log("stamping from Xcode \(XcodePin.xcodeVersion(meta)) (\(meta.xcodeBuild)), \(sdk.sdkName) SDK (\(sdk.sdkBuild))")
            return try finalize(app, pc: pc, sdk: sdk, platform: platform, config: config, meta: meta, kind: kind)
        }
    }

    /// The image's SDK (`meta`) must be the one the app was built with: finalize stamps the app's DT* keys and every
    /// Mach-O's SDK version from it. Refused: an image change since the build, or an image other than the pin's.
    static func checkSameSDK(built: BuildSDKRecord?, meta: ToolchainMeta, pin: String?, platform: Platform, kind: ProjectKind) throws {
        try XcodePin.check(pin: pin, meta: meta, platform: platform, file: kind.pinFile, stage: .finalize)
        guard let built, built.toolchain != meta else { return }
        throw XlessError(.finalize, "the app was built with \(built.summary(platform: platform)), but this image has \(BuildSDKRecord(pin: nil, toolchain: meta).summary(platform: platform)); its metadata would not describe the SDK the app was built with",
                         fix: "finalize in the image that built the app, or build again in this one (`xless ship --from build`)")
    }

    static func finalize(_ app: URL, pc: PlatformConfig, sdk: PlatformSDKInfo, platform: Platform, config: ProjectConfig, meta: ToolchainMeta,
                         kind: ProjectKind) throws -> URL {
        let layout = BundleLayout(platform: platform)

        let plistURL = app.appendingPathComponent(layout.infoPlist)
        var info = try Plist.read(plistURL, stage: .finalize)
        try InfoPlistStamper.stamp(&info, meta: meta, sdk: sdk, platform: platform, config: config, kind: kind)
        if platform == .ios, config.distribution(for: .ios) == .appStore, info[InfoPlistStamper.encryptionKey] == nil {
            throw XlessError(.finalize, "Info.plist has no ITSAppUsesNonExemptEncryption (export compliance); every upload would stall at \"Missing Compliance\" in TestFlight",
                             fix: kind.encryptionMissingFix())
        }
        if platform == .ios, config.distribution(for: .ios) == .appStore, let v = info[InfoPlistStamper.encryptionKey], !(v is Bool) {
            throw XlessError(.finalize, "ITSAppUsesNonExemptEncryption in the Info.plist is not a boolean (\(v))",
                             fix: kind.encryptionNotBooleanFix())
        }
        try BuiltTree.write(try Plist.data(info, format: .binary, named: plistURL.path, stage: .finalize), at: layout.infoPlist, in: app, stage: .finalize)
        if !FileManager.default.fileExists(atPath: app.appendingPathComponent(layout.pkgInfo).path) {
            try BuiltTree.write(Data("APPL????".utf8), at: layout.pkgInfo, in: app, stage: .finalize)   // Xcode writes it for every app; xtool omits it on iOS
        }

        let frameworks = app.appendingPathComponent(layout.frameworksDir).standardizedFileURL.path
        let exeName = info["CFBundleExecutable"] as? String ?? pc.product
        let mainExe = (layout.executableDir.isEmpty ? app.appendingPathComponent(exeName) : app.appendingPathComponent("\(layout.executableDir)/\(exeName)"))
            .standardizedFileURL.path
        let sdkValue = try MachO.encodeVersion(sdk.sdkVersion)
        let wantedMinOS = try MachO.encodeVersion(pc.minimumOS)
        var sawMain = false

        for file in Files.regularFiles(under: app) {
            let path = file.standardizedFileURL.path
            let rel = String(path.dropFirst(app.standardizedFileURL.path.count + 1))
            // Developer ID apps may ship loose dylibs in Frameworks (Tauri's bundle.macOS.frameworks); the App Store may not.
            if config.distribution(for: platform) == .appStore, file.pathExtension == "dylib",
               file.deletingLastPathComponent().standardizedFileURL.path == frameworks {
                throw XlessError(.finalize, "loose dynamic library \(rel) in the bundle (App Store rejects these)",
                                 fix: "make the library static (remove `type: .dynamic`) — dylib→framework wrapping is not supported in milestone 1")
            }
            var data: Data
            do { data = try Data(contentsOf: file) } catch {
                throw XlessError(.finalize, "cannot read \(rel): \(error)", fix: "check file permissions and disk state")
            }
            let isImage: Bool
            do { isImage = try MachO.containsLoadableImage(data) } catch {
                throw XlessError(.finalize, "cannot parse Mach-O \(rel): \(error)", fix: "report this binary to the xless maintainers")
            }
            guard isImage else { continue }   // static archives (also fat-wrapped) carry no LC_BUILD_VERSION
            let misaligned: [String]
            do { misaligned = try MachO.linkeditAlignmentProblems(in: data) } catch {
                throw XlessError(.finalize, "cannot parse Mach-O \(rel): \(error)", fix: "report this binary to the xless maintainers")
            }
            if !misaligned.isEmpty {   // dyld refuses the image ("mis-aligned LINKEDIT …"): the app would crash at launch
                throw XlessError(.finalize, "\(rel) has mis-aligned LINKEDIT tables (\(misaligned.joined(separator: "; "))); dyld refuses to load it, so the app would crash at launch",
                                 fix: "a tool rewrote this binary after linking without keeping its LINKEDIT tables 8-byte aligned: rebuild with the current xless image (its strip shim re-aligns llvm-strip's output); for a prebuilt vendor binary, update it, else report it to the xless maintainers")
            }
            let versions: [BuildVersion]
            do { versions = try MachO.buildVersions(in: data) } catch {
                throw XlessError(.finalize, "cannot parse Mach-O \(rel): \(error)", fix: "report this binary to the xless maintainers")
            }
            if versions.isEmpty {
                throw XlessError(.finalize, "\(rel) has no LC_BUILD_VERSION (legacy or malformed Mach-O); its SDK version cannot be patched",
                                 fix: "rebuild the dependency that ships \(rel) with a modern toolchain so it carries LC_BUILD_VERSION")
            }
            for v in versions where v.platform != platform.machOPlatform {
                throw XlessError(.finalize, "\(rel) was built for Mach-O platform \(v.platform), expected \(platform.machOPlatform) (\(platform.rawValue))",
                                 fix: "remove prebuilt binaries for other platforms from the package")
            }
            if path == mainExe {
                sawMain = true
                for v in versions where v.minos != wantedMinOS {
                    let text = kind.deploymentTarget(binary: MachO.decodeVersion(v.minos), wanted: pc.minimumOS, platform: platform)
                    throw XlessError(.finalize, text.cause, fix: text.fix)
                }
            }
            try MachO.patchSDK(in: &data, to: sdkValue)
            try data.write(to: file)
        }
        if !sawMain {
            throw XlessError(.finalize, "main executable not found at \(mainExe)", fix: "check CFBundleExecutable and the build output")
        }

        let privacy = app.appendingPathComponent(layout.resourcesDir.isEmpty ? "PrivacyInfo.xcprivacy" : "\(layout.resourcesDir)/PrivacyInfo.xcprivacy")
        if config.distribution(for: platform) == .appStore, config.privacyManifest == nil || !FileManager.default.fileExists(atPath: privacy.path) {
            throw XlessError(.finalize, "no PrivacyInfo.xcprivacy in the bundle (required for App Store uploads)",
                             fix: kind.privacyManifestFix())
        }
        return app
    }
}
