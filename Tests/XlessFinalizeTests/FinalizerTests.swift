import Testing
import Foundation
@testable import XlessFinalize
@testable import XlessCore
@testable import XlessMachO

func thinBinary(platform: UInt32, minos: String, sdk: String) throws -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(1); u32(24); u32(0); u32(0)
    u32(0x32); u32(24); u32(platform); u32(try MachO.encodeVersion(minos)); u32(try MachO.encodeVersion(sdk)); u32(0)
    return d
}

func iosApp(minos: String = "17.0", extraFiles: [String: Data] = [:],
            plist: [String: Any] = ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": false]) throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(plist, to: app.appendingPathComponent("Info.plist"), stage: .finalize)
    try thinBinary(platform: 2, minos: minos, sdk: minos).write(to: app.appendingPathComponent("X"))
    try Data().write(to: app.appendingPathComponent("PrivacyInfo.xcprivacy"))
    for (path, data) in extraFiles {
        let u = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
    }
    return app
}

let privacyLine = "privacyManifest: PrivacyInfo.xcprivacy"

@Test func patchesSDKAndStamps() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: app.appendingPathComponent("X")))
    #expect(bv.first?.sdk == 0x1b0000)
    #expect(bv.first?.minos == 0x110000)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["DTXcode"] as? String == "2700")
}

@Test func deploymentTargetMismatchFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    do { _ = try Finalizer.run(input: iosApp(minos: "16.0"), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.description.contains("16.0") && e.description.contains("17.0") && e.description.contains("Package.swift"))
    }
}

@Test func wrongPlatformBinaryFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Y.framework/Y": thinBinary(platform: 1, minos: "14.0", sdk: "14.0")])
    #expect(throws: XlessError.self) { try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta) }
}

@Test func looseDylibFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/libFoo.dylib": thinBinary(platform: 2, minos: "17.0", sdk: "17.0")])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("libFoo.dylib")) }
}

@Test func missingPrivacyManifestFailsForAppStore() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    #expect(throws: XlessError.self) { try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(), meta: meta) }
}

@Test func oldSDKFails() throws {
    var old = meta
    old.platforms["iphoneos"]!.sdkVersion = "18.0"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    #expect(throws: XlessError.self) { try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: old) }
}

func noBuildVersionBinary() -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(0); u32(0); u32(0); u32(0)
    return d
}

@Test func machOWithoutBuildVersionFails() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Legacy.framework/Legacy": noBuildVersionBinary()])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.description.contains("Legacy.framework/Legacy") && e.description.contains("LC_BUILD_VERSION"))
    }
}

/// An iOS dylib with LC_BUILD_VERSION and an LC_SYMTAB whose 4-byte string pool starts at `stroff`.
func binaryWithStringPool(at stroff: UInt32) throws -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(6); u32(2); u32(48); u32(0); u32(0)
    u32(0x32); u32(24); u32(2); u32(try MachO.encodeVersion("17.0")); u32(try MachO.encodeVersion("17.0")); u32(0)
    u32(0x2); u32(24); u32(0); u32(0); u32(stroff); u32(4)
    return d + Data(count: 16)
}

@Test func misalignedLinkeditIsRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/J.framework/J": binaryWithStringPool(at: 84)])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.description.hasPrefix("[finalize] Frameworks/J.framework/J has mis-aligned LINKEDIT tables (arm64: string pool at file offset 0x54 is not 8-byte aligned)"))
        #expect(e.description.contains(" — a tool rewrote this binary"))
    }
    let fine = try iosApp(extraFiles: ["Frameworks/J.framework/J": binaryWithStringPool(at: 80)])
    _ = try Finalizer.run(input: fine, outputDir: FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())"),
                          platform: .ios, config: config(privacyLine), meta: meta)
}

@Test func nestedFrameworkIsPatched() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(extraFiles: ["Frameworks/Y.framework/Y": thinBinary(platform: 2, minos: "17.0", sdk: "17.0")])
    let result = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("Frameworks/Y.framework/Y")))
    #expect(bv.first?.sdk == 0x1b0000)
}

@Test func inputBundleIsUnchanged() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp()
    _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: app.appendingPathComponent("X")))
    #expect(bv.first?.sdk == 0x110000)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["DTXcode"] == nil)
}

@Test func macOSUniversalHappyPath() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    let thin = try thinBinary(platform: 1, minos: "14.0", sdk: "14.0")
    try MachO.makeFat([thin, thin]).write(to: macos.appendingPathComponent("X"))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let cfg = try config()
    let result = try Finalizer.run(input: app, outputDir: out, platform: .macos, config: cfg, meta: meta)
    let bv = try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("Contents/MacOS/X")))
    #expect(bv.count == 2)
    #expect(bv.allSatisfy { $0.sdk == 0x1b0000 && $0.minos == 0xe0000 })
    let info = try Plist.read(result.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
}

/// Developer ID (Tauri macOS): a loose dylib in Contents/Frameworks (bundle.macOS.frameworks) is allowed, and Mach-Os in
/// Contents/Resources (bundle.resources, universal after the per-target merge) are stamped like the executable.
@Test func macOSDeveloperIDStampsLooseDylibs() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    let contents = app.appendingPathComponent("Contents")
    for d in ["MacOS", "Frameworks", "Resources/lib"] { try FileManager.default.createDirectory(at: contents.appendingPathComponent(d), withIntermediateDirectories: true) }
    try Plist.write(["CFBundleExecutable": "X"], to: contents.appendingPathComponent("Info.plist"), stage: .finalize)
    let thin = try thinBinary(platform: 1, minos: "14.0", sdk: "14.0")
    try MachO.makeFat([thin, thin]).write(to: contents.appendingPathComponent("MacOS/X"))
    try thinBinary(platform: 1, minos: "13.0", sdk: "14.0").write(to: contents.appendingPathComponent("Frameworks/libx.dylib"))
    try MachO.makeFat([thin, thin]).write(to: contents.appendingPathComponent("Resources/lib/liby.dylib"))
    let cfg = try config()
    #expect(cfg.distribution(for: .macos) == .developerID)
    let result = try Finalizer.run(input: app, outputDir: FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())"), platform: .macos, config: cfg, meta: meta)
    for path in ["Contents/Frameworks/libx.dylib", "Contents/Resources/lib/liby.dylib"] {
        let bv = try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent(path)))
        #expect(!bv.isEmpty && bv.allSatisfy { $0.sdk == 0x1b0000 })
    }
}

@Test func writesPkgInfoLikeXcode() throws {
    // Xcode 27.0 puts PkgInfo ("APPL????") in iOS app bundles too; xtool does not.
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    #expect(try Data(contentsOf: app.appendingPathComponent("PkgInfo")) == Data("APPL????".utf8))
}

@Test func finalizeFailureLeavesNoBundleInFinal() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())/final")
    try FileManager.default.createDirectory(at: out.appendingPathComponent("X.app"), withIntermediateDirectories: true)   // stale output
    #expect(throws: XlessError.self) {
        try Finalizer.run(input: iosApp(minos: "16.0"), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    }
    #expect(throws: XlessError.self) { try StagePaths(project: out, platform: .ios).bundle(in: out, stage: .sign) }
    #expect(!FileManager.default.fileExists(atPath: out.path + ".partial"))
}

// MARK: export compliance (ITSAppUsesNonExemptEncryption)

@Test func appStoreBuildWithoutComplianceKeyIsRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X"])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("ITSAppUsesNonExemptEncryption"))
        #expect(e.fix.contains("usesNonExemptEncryption: false") && e.fix.contains("infoPlist"))
    }
}

@Test func configKeyStampsComplianceKey() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X"]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: false"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == false)
}

@Test func configKeyTrueIsStampedToo() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X"]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: true"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == true)
}

@Test func userPlistValueIsKeptWhenConfigAgrees() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try Finalizer.run(input: iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true]), outputDir: out, platform: .ios,
                                config: config(privacyLine + "\nusesNonExemptEncryption: true"), meta: meta)
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["ITSAppUsesNonExemptEncryption"] as? Bool == true)
}

@Test func conflictingPlistAndConfigValuesAreRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine + "\nusesNonExemptEncryption: false"), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("ITSAppUsesNonExemptEncryption") && e.cause.contains("usesNonExemptEncryption"))
    }
}

@Test func macOSDeveloperIDDoesNotNeedComplianceKey() throws {
    // macos fixture in macOSUniversalHappyPath has no key and must keep passing.
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID())/X.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"], to: app.appendingPathComponent("Contents/Info.plist"), stage: .finalize)
    try thinBinary(platform: 1, minos: "14.0", sdk: "14.0").write(to: macos.appendingPathComponent("X"))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    _ = try Finalizer.run(input: app, outputDir: out, platform: .macos, config: config(), meta: meta)
}

@Test func nonBooleanComplianceKeyInUserPlistIsRefused() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let app = try iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": "NO"])
    do { _ = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .finalize && e.cause.contains("not a boolean")) }
}

/// Fat (cafebabe) wrapper with one arm64 slice that is an `ar` static archive, as shipped by the onnxruntime-c pod.
func fatWrappedArchive() -> Data {
    var slice = Data("!<arch>\n".utf8)
    slice.append(Data("x.o/            0           0     0     100644  4         `\nabcd".utf8))
    var d = Data()
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    be(0xcafebabe); be(1); be(0x0100000c); be(0); be(0x4000); be(UInt32(slice.count)); be(14)
    d.append(Data(count: 0x4000 - d.count)); d.append(slice)
    return d
}

@Test func staticArchiveFrameworkBinaryIsLeftAlone() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let archive = fatWrappedArchive()
    let app = try iosApp(extraFiles: ["Frameworks/x.framework/x": archive])
    let result = try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta)
    #expect(try Data(contentsOf: result.appendingPathComponent("Frameworks/x.framework/x")) == archive)
    #expect(try MachO.buildVersions(in: Data(contentsOf: result.appendingPathComponent("X"))).first?.sdk == 0x1b0000)
}

@Test func reactNativeFixTextsNameTheOverlayAndTheXcodeSettings() throws {
    func failure(_ app: URL, _ config: ProjectConfig, _ kind: ProjectKind) throws -> XlessError? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
        return #expect(throws: XlessError.self) { try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config, meta: meta, kind: kind) }
    }
    // The deployment target comes from the app target's IPHONEOS_DEPLOYMENT_TARGET, not from Package.swift / xless.yml.
    let rnTarget = try failure(iosApp(minos: "16.0"), config(privacyLine), .reactNative)
    #expect(rnTarget?.cause == "binary deployment target 16.0 ≠ the app target's IPHONEOS_DEPLOYMENT_TARGET 17.0")
    #expect(rnTarget?.fix.contains("expo-build-properties") == true && rnTarget?.fix.contains("Package.swift") == false)
    // The privacy manifest and the export-compliance key: the React Native overlay or the Expo config, never xless.yml.
    let rnPrivacy = try failure(iosApp(), config(), .reactNative)
    #expect(rnPrivacy?.fix.contains("the React Native overlay") == true && rnPrivacy?.fix.contains("xless.yml") == false)
    let rnEncryption = try failure(iosApp(plist: ["CFBundleExecutable": "X"]), config(privacyLine), .reactNative)
    #expect(rnEncryption?.fix.contains("the React Native overlay") == true && rnEncryption?.fix.contains("infoPlist") == false)
    let rnDisagree = try failure(iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true]),
                                 config(privacyLine + "\nusesNonExemptEncryption: false"), .reactNative)
    #expect(rnDisagree?.cause.contains("in the React Native overlay is false") == true)
    // xless.yml (the default) keeps its texts.
    #expect(try failure(iosApp(minos: "16.0"), config(privacyLine), .xlessYML)?.fix.contains("Package.swift") == true)
    #expect(try failure(iosApp(plist: ["CFBundleExecutable": "X"]), config(privacyLine), .xlessYML)?.fix.contains("xless.yml") == true)
}

@Test func cargoFixTextsNameTheCargoOverlay() throws {
    func failure(_ app: URL, _ config: ProjectConfig) throws -> XlessError? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
        return #expect(throws: XlessError.self) { try Finalizer.run(input: app, outputDir: out, platform: .ios, config: config, meta: meta, kind: .cargo) }
    }
    // The deployment target comes from the overlay's minimumOS (cargo's deployment-target variables), not Package.swift.
    let target = try failure(iosApp(minos: "16.0"), config(privacyLine))
    #expect(target?.cause == "binary deployment target 16.0 ≠ the cargo overlay's ios.minimumOS 17.0")
    #expect(target?.fix.contains("Package.swift") == false)
    let privacy = try failure(iosApp(), config())
    #expect(privacy?.fix.contains("the cargo overlay") == true && privacy?.fix.contains("xless.yml") == false)
    let encryption = try failure(iosApp(plist: ["CFBundleExecutable": "X"]), config(privacyLine))
    #expect(encryption?.fix.contains("the cargo overlay") == true && encryption?.fix.contains("xless.yml") == false)
    let disagree = try failure(iosApp(plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": true]),
                               config(privacyLine + "\nusesNonExemptEncryption: false"))
    #expect(disagree?.cause.contains("in the cargo overlay is false") == true)
}

// MARK: Ruling R8: stamped from the SDK actually used; R9: identifiers in Info.plist

let meta262 = ToolchainMeta(
    xcodeVersion: "2620", xcodeBuild: "17C52", buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler,
    platforms: [
        "iphoneos": .init(sdkName: "iphoneos26.2", sdkVersion: "26.2", sdkBuild: "23C53", platformName: "iphoneos", platformVersion: "26.2", platformBuild: "23C53"),
        "macosx": .init(sdkName: "macosx26.2", sdkVersion: "26.2", sdkBuild: "25C56", platformName: "macosx", platformVersion: "26.2", platformBuild: "25C56"),
    ])

@Test func stampsFromTheImagesSDKNotFromAFixedXcode() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    var lines: [String] = []
    let app = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine + "\nxcode: \"26.2\""), meta: meta262,
                                built: BuildSDKRecord(pin: "26.2", toolchain: meta262), log: { lines.append($0) })
    let p = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)
    #expect(p["DTXcode"] as? String == "2620" && p["DTXcodeBuild"] as? String == "17C52")
    #expect(p["DTSDKName"] as? String == "iphoneos26.2" && p["DTSDKBuild"] as? String == "23C53")
    #expect(p["DTPlatformVersion"] as? String == "26.2" && p["DTPlatformBuild"] as? String == "23C53")
    #expect(try MachO.buildVersions(in: Data(contentsOf: app.appendingPathComponent("X"))).first?.sdk == 0x1a0200)
    #expect(lines == ["stamping from Xcode 26.2 (17C52), iphoneos26.2 SDK (23C53)"])
}

@Test func refusesAnImageOtherThanTheOneThatBuiltTheApp() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let e = #expect(throws: XlessError.self) {
        try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta,
                          built: BuildSDKRecord(pin: nil, toolchain: meta262), log: { _ in })
    }
    #expect(e?.stage == .finalize && e?.cause.contains("built with Xcode 26.2 (17C52)") == true && e?.cause.contains("but the Xcode here now is Xcode 27.0 (27A266a)") == true)
    #expect(!FileManager.default.fileExists(atPath: out.path))
    // The same SDK, or no record (a build before records existed): stamped.
    _ = try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine), meta: meta,
                          built: BuildSDKRecord(pin: nil, toolchain: meta), log: { _ in })
}

@Test func refusesAnImageThatIsNotThePinnedXcode() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let e = #expect(throws: XlessError.self) {
        try Finalizer.run(input: iosApp(), outputDir: out, platform: .ios, config: config(privacyLine + "\nxcode: \"26.2\""), meta: meta, log: { _ in })
    }
    #expect(e?.stage == .finalize && e?.cause.hasPrefix("xless.yml pins xcode: \"26.2\", but the Xcode pack it would build with has the iphoneos27.0 SDK from Xcode 27.0") == true)
}

@Test func identifiersAreReplacedInEveryBundlesInfoPlistBeforeSigning() throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    let ext = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.example.x.Ext",
                                                                    "Groups": ["group.com.other.app"]], format: .xml, options: 0)
    let input = try iosApp(extraFiles: ["PlugIns/Ext.appex/Info.plist": ext],
                           plist: ["CFBundleExecutable": "X", "ITSAppUsesNonExemptEncryption": false, "SharedContainerGroup": "group.com.other.app"])
    var lines: [String] = []
    let app = try Finalizer.run(input: input, outputDir: out, platform: .ios, config: config(privacyLine), meta: meta,
                                identifiers: IdentifierReplacement(["com.other.app": "app.example.x"]), log: { lines.append($0) })
    #expect(try Plist.read(app.appendingPathComponent("Info.plist"), stage: .finalize)["SharedContainerGroup"] as? String == "group.app.example.x")
    #expect(try Plist.read(app.appendingPathComponent("PlugIns/Ext.appex/Info.plist"), stage: .finalize)["Groups"] as? [String] == ["group.app.example.x"])
    #expect(lines.first == "identifiers.replace: 2 Info.plist value(s) replaced: Info.plist: SharedContainerGroup, PlugIns/Ext.appex/Info.plist: Groups[0]")
    // The input is never changed.
    #expect(try Plist.read(input.appendingPathComponent("Info.plist"), stage: .finalize)["SharedContainerGroup"] as? String == "group.com.other.app")
    // The map is recorded next to the app for sign (fix wave M4), which refuses another one.
    #expect(try IdentifierReplacement.recorded(in: out) == IdentifierReplacement(["com.other.app": "app.example.x"]))
    try IdentifierReplacement(["com.other.app": "app.example.x"]).checkFinalized(in: out)
    #expect(throws: XlessError.self) { try IdentifierReplacement.none.checkFinalized(in: out) }
    // Without a map nothing is recorded.
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("fo-\(UUID())")
    _ = try Finalizer.run(input: input, outputDir: plain, platform: .ios, config: config(privacyLine), meta: meta, log: { _ in })
    #expect(!FileManager.default.fileExists(atPath: plain.appendingPathComponent(IdentifierReplacement.recordName).path))
}
