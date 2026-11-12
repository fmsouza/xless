import Testing
import Foundation
@testable import XlessAssets
@testable import XlessCore

// Command lines are the ones Swift Build runs (docs/research/react-native-ios-contract.md, "Tool shims"); expected
// outputs come from actool 27.0 (25098) runs on the same catalogs.

/// The image's toolchain metadata as a test injects it.
func testMeta(_ build: String) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: "2700", xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [:])
}

/// A profile as the assets stage gets it in an image made from Xcode `build`.
func testProfile(_ build: String = "27A266a") -> () throws -> XcodeToolsProfile {
    { try XcodeToolsProfile.forImage(meta: testMeta(build), stage: .assets) }
}

/// The shim in an image made from Xcode `build` (27A266a unless a test says otherwise).
private func runShim(_ args: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath), build: String = "27A266a") async -> ActoolShim.Result {
    await ActoolShim.run(args, cwd: cwd, profile: testProfile(build))
}

private func tmp(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("actool-\(name)-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A catalog with a single-size app icon, an image set and a color set (the shapes an Expo app's catalog has).
private func expoLikeCatalog(icon: Bool = true, extra: [String] = []) throws -> URL {
    let root = try icon ? singleSizeCatalog(icon: solidPNG(64, r: 10, g: 20, b: 30)) : {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID()).xcassets")
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: r.appendingPathComponent("Contents.json"))
        return r
    }()
    for name in ["SplashScreenLogo"] + extra {
        let set = root.appendingPathComponent("\(name).imageset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try solidPNG(8, r: 1, g: 2, b: 3).write(to: set.appendingPathComponent("l.png"))
        try Data(#"{"images":[{"filename":"l.png","idiom":"universal","scale":"1x"}],"info":{"author":"xcode","version":1}}"#.utf8)
            .write(to: set.appendingPathComponent("Contents.json"))
    }
    let color = root.appendingPathComponent("SplashScreenBackground.colorset")
    try FileManager.default.createDirectory(at: color, withIntermediateDirectories: true)
    try Data(#"{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0.200","green":"0.400","red":"0.600"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}"#.utf8)
        .write(to: color.appendingPathComponent("Contents.json"))
    return root
}

/// `CompileAssetCatalogVariant thinned` as Swift Build runs it for HelloPIF (plus `extra`).
private func compileArgs(_ catalogs: [URL], out: URL, temp: URL, devices: [String] = ["iphone", "ipad"], target: String = "16.4", extra: [String] = [],
                         platform: String = "iphoneos") -> [String] {
    catalogs.map(\.path) + ["--compile", out.path, "--output-format", "human-readable-text", "--notices", "--warnings",
                            "--export-dependency-info", temp.appendingPathComponent("assetcatalog_dependencies_thinned").path,
                            "--output-partial-info-plist", temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned").path]
        + extra + ["--compress-pngs", "--enable-on-demand-resources", "YES", "--development-region", "en"]
        + devices.flatMap { ["--target-device", $0] } + ["--minimum-deployment-target", target, "--platform", platform]
}

private func plist(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
}

@Test(arguments: [("27A266a", "25098", "27.0"), ("27A9275", "25098", "27.1"), ("27B52", "25408", "27.2"), ("17C52", "24506", "26.2"), ("17B55", "24412", "26.1"), ("17A400", "24128", "26.0.1")])
func versionProbeAnswersAsTheImagesActool(_ build: String, _ bundle: String, _ short: String) async throws {
    let r = await runShim(["--version", "--output-format", "xml1"], build: build)
    #expect(r.exitCode == 0)
    let v = try PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as! [String: Any]
    #expect(v["com.apple.actool.version"] as? [String: String] == ["bundle-version": bundle, "short-bundle-version": short])
}

/// An image whose Xcode has no tools profile is refused with exit 70 and `forImage`'s message, for every call.
@Test func testShimRefusesUnprofiledImage() async throws {
    let out = try tmp("out"), temp = try tmp("temp")
    for args in [["--version", "--output-format", "xml1"], compileArgs([try expoLikeCatalog()], out: out, temp: temp, extra: ["--app-icon", "AppIcon"])] {
        let r = await runShim(args, build: "99A9999")
        #expect(r.exitCode == 70)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("this image's Xcode build 99A9999 has no measured asset/storyboard tools profile"), "\(r.stderr)")
        #expect(r.stderr.contains("xless setup --xcode"), "\(r.stderr)")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

/// The car and the dependency info carry the image's actool: CoreUI version and header strings as measured.
@Test(arguments: ["27A266a", "27A9275", "27B52", "17C52", "17B55", "17A400"])
func compiledCarCarriesTheImagesActool(_ build: String) async throws {
    let p = try #require(XcodeToolsProfile.all[build])
    let out = try tmp("out"), temp = try tmp("temp")
    let r = await runShim(compileArgs([try expoLikeCatalog()], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]), build: build)
    #expect(r.exitCode == 0, "\(r)")
    let car = try Data(contentsOf: out.appendingPathComponent("Assets.car"))
    let header = try #require(CARHeaderFields(car: car))
    #expect(header.coreUIVersion == p.carCoreUIVersion)
    #expect(header.storageVersion == p.carStorageVersion)
    #expect(header.mainVersion == p.carMainVersion)
    #expect(header.versionString == p.carAssetStorageVersion)
    #expect(car.range(of: Data(p.carAuthoringTool.utf8)) != nil)
    let deps = try Data(contentsOf: temp.appendingPathComponent("assetcatalog_dependencies_thinned"))
    #expect(deps.starts(with: Data([0]) + Data("actool-\(p.actoolBundleVersion)".utf8) + Data([0])))
}

@Test func assetTagProbeAnswersNoTagsOrRefusesOnDemandResources() async throws {
    let cat = try expoLikeCatalog()
    var r = await runShim(["--print-asset-tag-combinations", "--output-format", "xml1", cat.path])
    #expect(r.exitCode == 0)
    var v = try PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as! [String: Any]
    #expect((v["com.apple.actool.asset-tag-combinations"] as? [Any])?.isEmpty == true)

    try Data(#"{"images":[{"filename":"l.png","idiom":"universal","scale":"1x"}],"properties":{"on-demand-resource-tags":["level1"]}}"#.utf8)
        .write(to: cat.appendingPathComponent("SplashScreenLogo.imageset/Contents.json"))
    r = await runShim(["--print-asset-tag-combinations", "--output-format", "xml1", cat.path])
    #expect(r.exitCode == 1)
    v = try PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as! [String: Any]
    let errors = v["com.apple.actool.errors"] as? [[String: String]]
    #expect(errors?.first?["description"]?.contains("on-demand resource tags are not supported") == true)
}

@Test(arguments: [
    (["--frobnicate", "A.xcassets"], "unknown option --frobnicate"),
    (["A.xcassets", "--compile", "/o", "--output-format", "xml1", "--platform", "iphoneos", "--minimum-deployment-target", "16.4", "--target-device", "iphone"], "--output-format must be human-readable-text"),
    (["A.xcassets", "--compile", "/o", "--output-format", "human-readable-text", "--platform", "macosx", "--minimum-deployment-target", "16.4", "--target-device", "iphone"], "--platform must be iphoneos or iphonesimulator"),
    (["A.xcassets", "--compile", "/o", "--output-format", "human-readable-text", "--platform", "iphoneos", "--minimum-deployment-target", "16.4", "--target-device", "watch"], "--target-device watch"),
    (["A.xcassets", "--compile", "/o", "--output-format", "human-readable-text", "--platform", "iphoneos", "--minimum-deployment-target", "16.4", "--target-device", "iphone",
      "--bundle-identifier", "a.b", "--generate-swift-asset-symbols", "/o/S.swift"], "Swift asset symbol extensions are not supported"),
    (["Icon.icon", "--compile", "/o"], "is not an .xcassets catalog"),
    (["--version", "--compile", "/o"], "--version takes only --output-format xml1"),
])
func refusesArgvOutsideTheSwiftBuildSubset(args: [String], reason: String) async {
    let r = await runShim(args, cwd: URL(fileURLWithPath: "/"))
    #expect(r.exitCode == 70)
    #expect(r.stdout.isEmpty)
    #expect(r.stderr.contains(reason))
    #expect(r.stderr.contains("actool \(args.joined(separator: " "))"))
}

@Test func compileWritesCarIconsPartialPlistAndDependencyInfo() async throws {
    let cat = try expoLikeCatalog()
    let out = try tmp("out"), temp = try tmp("temp")
    let r = await runShim(compileArgs([cat], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 0, "\(r)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png", "Assets.car"])
    // HelloPIF's reference Info.plist icon keys (samples/HelloPIF/reference/reference.json).
    let info = try plist(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned"))
    #expect(NSDictionary(dictionary: info) == NSDictionary(dictionary: XcodeAppIcon.plistAdditions(name: "AppIcon", deviceFamily: [1, 2])))
    let deps = try Data(contentsOf: temp.appendingPathComponent("assetcatalog_dependencies_thinned"))
    let records = deps.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
    #expect(records[1] == Data("actool-25098".utf8))
    #expect(records[2] == Data([0x10]) + Data(cat.path.utf8))
    #expect(records[3] == Data([0x40]) + Data(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned").path.utf8))
    #expect(records.last(where: { !$0.isEmpty }) == Data([0x40]) + Data(out.appendingPathComponent("Assets.car").path.utf8))
    #expect(r.stdout.hasPrefix("/* com.apple.actool.compilation-results */\n\(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned").path)\n"))
}

/// A simulator build passes `--platform iphonesimulator`; Xcode 27.0's actool then writes the same Assets.car and
/// partial Info.plist as for the device (measured), and the shim writes the same files for both.
@Test func simulatorPlatformCompilesTheSameFiles() async throws {
    let cat = try expoLikeCatalog()
    var outputs: [[String: Data]] = []
    for platform in ["iphoneos", "iphonesimulator"] {
        let out = try tmp("out-\(platform)"), temp = try tmp("temp-\(platform)")
        let r = await runShim(compileArgs([cat], out: out, temp: temp, extra: ["--app-icon", "AppIcon"], platform: platform))
        #expect(r.exitCode == 0, "\(r)")
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: out.path) { files[name] = try Data(contentsOf: out.appendingPathComponent(name)) }
        files["partial.plist"] = try Data(contentsOf: temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned"))
        outputs.append(files)
    }
    #expect(outputs[0].keys.sorted() == ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png", "Assets.car", "partial.plist"])
    #expect(outputs[0] == outputs[1])
}

@Test func iphoneOnlyNamesTheIconOnlyInThePhoneDictionary() async throws {
    let out = try tmp("out"), temp = try tmp("temp")
    let r = await runShim(compileArgs([try expoLikeCatalog()], out: out, temp: temp, devices: ["iphone"], extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 0)
    let info = try plist(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned"))
    #expect(((info["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] == nil)
    #expect(((info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"] as? String == "AppIcon")
    // actool writes both loose files whatever the device family.
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("AppIcon76x76@2x~ipad.png").path))
}

@Test func withoutAppIconFlagTheIconIsLeftOutAndEmptyCatalogsWriteNoCar() async throws {
    var out = try tmp("out"), temp = try tmp("temp")
    var r = await runShim(compileArgs([try expoLikeCatalog()], out: out, temp: temp))
    #expect(r.exitCode == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Assets.car"])
    #expect(try plist(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned")).isEmpty)

    // An app-icon-only catalog without --app-icon, like an empty one, gives no Assets.car (actool: same).
    out = try tmp("out"); temp = try tmp("temp")
    r = await runShim(compileArgs([try singleSizeCatalog(icon: solidPNG(64, r: 1, g: 1, b: 1))], out: out, temp: temp))
    #expect(r.exitCode == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

@Test func missingAppIconSetAndAlphaIconsAreToolErrors() async throws {
    let out = try tmp("out"), temp = try tmp("temp")
    var r = await runShim(compileArgs([try expoLikeCatalog(icon: false)], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 1)
    #expect(r.stdout.hasPrefix("/* com.apple.actool.errors */\n"))
    // actool's wording alone on stdout; xless's fix on stderr.
    #expect(r.stdout.contains(": error: None of the input catalogs contained a matching stickers icon set, app icon set, or icon stack named  \"AppIcon\".\n"))
    #expect(r.stderr.hasPrefix("xless actool shim: [assets] None of the input catalogs"))
    #expect(r.stderr.contains(" — add AppIcon.appiconset"))

    let alpha = try singleSizeCatalog(icon: fakePNG(1024, colorType: 6))
    r = await runShim(compileArgs([alpha], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 1)
    #expect(r.stdout.contains("\(alpha.path): error: app icon 1024x1024 has an alpha channel (ITMS-90717)\n"))
}

@Test func appIconSetsInsideFoldersAreRefusedWithOrWithoutAppIconFlag() async throws {
    let cat = try expoLikeCatalog(icon: false)
    let nested = cat.appendingPathComponent("Icons/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: cat.appendingPathComponent("Icons/Contents.json"))
    try Data(#"{"images":[{"filename":"i.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.utf8)
        .write(to: nested.appendingPathComponent("Contents.json"))
    try solidPNG(64, r: 1, g: 2, b: 3).write(to: nested.appendingPathComponent("i.png"))
    for extra in [[], ["--app-icon", "AppIcon"]] {
        let out = try tmp("out"), temp = try tmp("temp")
        let r = await runShim(compileArgs([cat], out: out, temp: temp, extra: extra))
        #expect(r.exitCode == 1)
        #expect(r.stdout.contains("error: app icon set AppIcon.appiconset is inside a folder of the catalog"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }
}

@Test func outputDirectoryMustExistAsForActool() async throws {
    let temp = try tmp("temp")
    let r = await runShim(compileArgs([try expoLikeCatalog()], out: temp.appendingPathComponent("nope"), temp: temp))
    #expect(r.exitCode == 1)
    #expect(r.stdout.contains("error: The output directory"))
}

@Test func accentColorIsNamedInThePlistOrWarnedAbout() async throws {
    let cat = try expoLikeCatalog()
    var out = try tmp("out"), temp = try tmp("temp")
    var r = await runShim(compileArgs([cat], out: out, temp: temp, extra: ["--accent-color", "SplashScreenBackground"]))
    #expect(r.exitCode == 0)
    #expect(try plist(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned"))["NSAccentColorName"] as? String == "SplashScreenBackground")

    out = try tmp("out"); temp = try tmp("temp")
    r = await runShim(compileArgs([cat], out: out, temp: temp, extra: ["--accent-color", "AccentColor"]))
    #expect(r.exitCode == 0)
    #expect(r.stdout.hasPrefix("/* com.apple.actool.notices */\n\(cat.path): warning: Accent color ‘AccentColor’ is not present in any asset catalogs.\n"))
    #expect(try plist(temp.appendingPathComponent("assetcatalog_generated_info.plist_thinned"))["NSAccentColorName"] == nil)
}

@Test func catalogsOfOneTargetAreCompiledTogether() async throws {
    let a = try expoLikeCatalog()
    let b = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID()).xcassets")
    try FileManager.default.createDirectory(at: b.appendingPathComponent("Other.imageset"), withIntermediateDirectories: true)
    try solidPNG(8, r: 9, g: 9, b: 9).write(to: b.appendingPathComponent("Other.imageset/o.png"))
    try Data(#"{"images":[{"filename":"o.png","idiom":"universal","scale":"1x"}],"info":{"author":"xcode","version":1}}"#.utf8).write(to: b.appendingPathComponent("Other.imageset/Contents.json"))
    let out = try tmp("out"), temp = try tmp("temp")
    var r = await runShim(compileArgs([a, b], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 0, "\(r)")
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Assets.car").path))

    try FileManager.default.copyItem(at: a.appendingPathComponent("SplashScreenLogo.imageset"), to: b.appendingPathComponent("SplashScreenLogo.imageset"))
    r = await runShim(compileArgs([a, b], out: out, temp: temp, extra: ["--app-icon", "AppIcon"]))
    #expect(r.exitCode == 1)
    #expect(r.stdout.contains("SplashScreenLogo.imageset is in more than one asset catalog"))
}

/// `GenerateAssetSymbols`: only the three symbol files are written (no car, no partial plist), as actool does.
private func symbolsRun(_ cat: URL, target: String) async throws -> (ActoolShim.Result, URL, URL) {
    let out = try tmp("out"), temp = try tmp("temp")
    let ds = temp.appendingPathComponent("DerivedSources")
    let args = [cat.path, "--compile", out.path, "--output-format", "human-readable-text", "--notices", "--warnings",
                "--export-dependency-info", temp.appendingPathComponent("assetcatalog_dependencies").path,
                "--output-partial-info-plist", temp.appendingPathComponent("assetcatalog_generated_info.plist").path,
                "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--development-region", "en",
                "--target-device", "iphone", "--target-device", "ipad", "--minimum-deployment-target", target, "--platform", "iphoneos",
                "--bundle-identifier", "com.example.hellopif", "--generate-swift-asset-symbol-extensions", "NO",
                "--generate-swift-asset-symbols", ds.appendingPathComponent("GeneratedAssetSymbols.swift").path,
                "--generate-objc-asset-symbols", ds.appendingPathComponent("GeneratedAssetSymbols.h").path,
                "--generate-asset-symbol-index", ds.appendingPathComponent("GeneratedAssetSymbols-Index.plist").path]
    return (await runShim(args), out, temp)
}

@Test func assetSymbolsBelowIOS17ImportTheUIFrameworksAndBackDeploy() async throws {
    let (r, out, temp) = try await symbolsRun(try expoLikeCatalog(), target: "16.4")
    #expect(r.exitCode == 0, "\(r)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path) == ["DerivedSources"])
    let swift = try String(contentsOf: temp.appendingPathComponent("DerivedSources/GeneratedAssetSymbols.swift"), encoding: .utf8)
    // The imports decide which Swift overlays the app autolinks (SwiftUI brings libswiftCoreAudio, G2).
    #expect(swift.hasPrefix("""
        import Foundation
        #if canImport(AppKit)
        import AppKit
        #endif
        #if canImport(UIKit)
        import UIKit
        #endif
        #if canImport(SwiftUI)
        import SwiftUI
        #endif
        #if canImport(DeveloperToolsSupport)
        import DeveloperToolsSupport
        #endif

        """))
    #expect(swift.contains("    static let splashScreenBackground = ColorResource(name: \"SplashScreenBackground\", bundle: resourceBundle)\n"))
    #expect(swift.contains("    static let splashScreenLogo = ImageResource(name: \"SplashScreenLogo\", bundle: resourceBundle)\n"))
    #expect(swift.contains("struct ImageResource: Swift.Hashable, Swift.Sendable {"))
    #expect(swift.hasSuffix("    }\n\n}\n#endif"))
    let objc = try String(contentsOf: temp.appendingPathComponent("DerivedSources/GeneratedAssetSymbols.h"), encoding: .utf8)
    #expect(objc.contains("static NSString * const ACBundleID AC_SWIFT_PRIVATE = @\"com.example.hellopif\";\n"))
    #expect(objc.contains("static NSString * const ACImageNameSplashScreenLogo AC_SWIFT_PRIVATE = @\"SplashScreenLogo\";\n"))
    let index = try plist(temp.appendingPathComponent("DerivedSources/GeneratedAssetSymbols-Index.plist"))
    #expect((index["images"] as? [[String: String]])?.first?["relativePath"] == "./SplashScreenLogo.imageset")
    #expect((index["colors"] as? [[String: String]])?.first?["swiftSymbol"] == "splashScreenBackground")
}

@Test func assetSymbolsFromIOS17UseDeveloperToolsSupportOnly() async throws {
    let (r, _, temp) = try await symbolsRun(try expoLikeCatalog(), target: "17.0")
    #expect(r.exitCode == 0)
    let swift = try String(contentsOf: temp.appendingPathComponent("DerivedSources/GeneratedAssetSymbols.swift"), encoding: .utf8)
    #expect(swift.hasPrefix("import Foundation\n#if canImport(DeveloperToolsSupport)\nimport DeveloperToolsSupport\n#endif\n\n"))
    #expect(!swift.contains("import UIKit"))
    #expect(swift.contains("extension DeveloperToolsSupport.ImageResource {"))
    #expect(!swift.contains("Backwards Deployment"))
    #expect(swift.hasSuffix("}\n\n"))
}

@Test func emptyCatalogSymbolsHaveNoBundleIDConstant() async throws {
    let (r, _, temp) = try await symbolsRun(try singleSizeCatalog(icon: solidPNG(8, r: 1, g: 1, b: 1)), target: "16.4")
    #expect(r.exitCode == 0)
    let objc = try String(contentsOf: temp.appendingPathComponent("DerivedSources/GeneratedAssetSymbols.h"), encoding: .utf8)
    #expect(objc == """
        #import <Foundation/Foundation.h>

        #if __has_attribute(swift_private)
        #define AC_SWIFT_PRIVATE __attribute__((swift_private))
        #else
        #define AC_SWIFT_PRIVATE
        #endif

        #undef AC_SWIFT_PRIVATE

        """)
}

/// The CARHEADER block of an `Assets.car` (436 bytes from the "RATC" magic: CoreUI version, storage version, timestamp,
/// rendition count, the 128-byte main version string and the 256-byte version string).
struct CARHeaderFields {
    var coreUIVersion: UInt32, storageVersion: UInt32, mainVersion: String, versionString: String

    init?(car: Data) {
        guard let r = car.range(of: Data("RATC".utf8)), r.lowerBound + 436 <= car.count else { return nil }
        let b = [UInt8](car[r.lowerBound..<(r.lowerBound + 436)])
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func string(_ o: Int, _ n: Int) -> String { String(decoding: b[o..<(o + n)].prefix { $0 != 0 }, as: UTF8.self) }
        coreUIVersion = u32(4); storageVersion = u32(8)
        mainVersion = string(20, 128); versionString = string(148, 256)
    }
}
