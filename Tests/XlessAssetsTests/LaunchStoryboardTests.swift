import Testing
import Foundation
@testable import XlessAssets
@testable import XlessCore

private let ibCorpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IBCorpus")

/// Runs the iOS `assets` stage on a fake app whose Info.plist has `UIDeviceFamily` = `family` (absent when nil) and a
/// `UILaunchScreen` dictionary, with `launchStoryboard` pointing at `storyboard`.
private func runLaunchStoryboard(_ storyboard: URL, family: [Int]?, minimumOS: String,
                                 profile: @escaping () throws -> XcodeToolsProfile = testProfile()) async throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/X.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleExecutable": "X", "UILaunchScreen": [String: Any]()]
    if let family { info["UIDeviceFamily"] = family }
    try Plist.write(info, to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let yaml = """
    bundleID: a.b
    teamID: ABCDE12345
    version: "1"
    build: 1
    platforms:
      ios: { minimumOS: "\(minimumOS)", product: X }
    assets: \(try helloShipLikeCatalog().path)
    launchStoryboard: \(storyboard.path)
    """
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    return try await AssetsStage.run(input: app, outputDir: out, platform: .ios, config: ProjectConfig.parse(yaml: yaml), project: URL(fileURLWithPath: "/"), profile: profile)
}

private func files(in dir: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
}

@Test(arguments: [([1, 2], "17.0", "universal-17"), ([1], "16.0", "iphone-16"), ([1, 2], "16.0", "universal-16")])
func launchStoryboardCompiledIntoBundleRoot(family: [Int], minimumOS: String, flagset: String) async throws {
    let app = try await runLaunchStoryboard(ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), family: family, minimumOS: minimumOS)
    // docs/research/ib-invocation.md: the linked .storyboardc lands at the bundle root.
    let compiled = app.appendingPathComponent("real-logo-plus-label.storyboardc")
    let golden = ibCorpus.appendingPathComponent("golden/27A266a/real-logo-plus-label/\(flagset).storyboardc")
    let got = try files(in: compiled), want = try files(in: golden)
    #expect(got.keys.sorted() == want.keys.sorted())
    for (name, data) in want { #expect(got[name] == data, "\(name) differs from golden \(flagset)") }

    let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .assets)
    #expect(info["UILaunchStoryboardName"] as? String == "real-logo-plus-label")
    #expect(info["UILaunchScreen"] == nil)
    #expect(info["CFBundleExecutable"] as? String == "X")
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets.car").path))
}

@Test func launchStoryboardWithoutDeviceFamilyUsesIPhoneAndIPad() async throws {
    // xtool's Info.plist may lack UIDeviceFamily; the iOS default (and the app icon code's) is [1, 2].
    let app = try await runLaunchStoryboard(ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), family: nil, minimumOS: "17.0")
    let golden = ibCorpus.appendingPathComponent("golden/27A266a/real-logo-plus-label/universal-17.storyboardc")
    #expect(try files(in: app.appendingPathComponent("real-logo-plus-label.storyboardc")) == files(in: golden))
}

@Test func unsupportedElementInLaunchStoryboardIsAnAssetsError() async throws {
    let src = try String(contentsOf: ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), encoding: .utf8)
    let lines = src.components(separatedBy: "\n")
    let index = try #require(lines.firstIndex { $0.contains("<subviews>") })
    var bad = lines
    bad.insert("                            <button id=\"Btn-00-001\"/>", at: index + 1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Launch.storyboard")
    try bad.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let out: URL
    do {
        out = try await runLaunchStoryboard(url, family: [1, 2], minimumOS: "17.0")
        Issue.record("expected throw, got \(out.path)")
    } catch let e as XlessError {
        #expect(e.stage == .assets)
        #expect(e.description.hasPrefix("[assets] "))
        #expect(e.cause.contains("button"))
        #expect(e.cause.contains("line \(index + 2)"), "\(e.cause)")
        #expect(e.cause.contains("Launch.storyboard"))
    }
}

@Test func missingLaunchStoryboardIsAnAssetsError() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())/Launch.storyboard")
    do { _ = try await runLaunchStoryboard(missing, family: [1, 2], minimumOS: "17.0"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .assets); #expect(e.cause.contains("Launch.storyboard")) }
}

@Test func unsupportedDeviceFamilyIsAnAssetsError() async throws {
    do {
        _ = try await runLaunchStoryboard(ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), family: [2], minimumOS: "17.0")
        Issue.record("expected throw")
    } catch let e as XlessError { #expect(e.stage == .assets) }
}

@Test func launchStoryboardMustEndInStoryboard() throws {
    let yaml = "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  ios: { minimumOS: \"17.0\", product: X }\nlaunchStoryboard: Resources/Launch.xib\n"
    do { _ = try ProjectConfig.parse(yaml: yaml); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .config); #expect(e.cause.contains("launchStoryboard")) }
    let ok = yaml.replacingOccurrences(of: "Launch.xib", with: "Launch.storyboard")
    #expect(try ProjectConfig.parse(yaml: ok).launchStoryboard == "Resources/Launch.storyboard")
}

@Test func helloShipLaunchSampleRunsThroughAssetsStage() async throws {
    let project = ibCorpus.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples/HelloShipLaunch")
    let config = try ProjectConfig.load(from: project.appendingPathComponent("xless.yml"))
    #expect(config.bundleID == "com.example.helloshiplaunch" && config.teamID == "ABCDE12345")
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID())/HelloShipLaunch.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "HelloShipLaunch", "UIDeviceFamily": [1, 2]], to: app.appendingPathComponent("Info.plist"), stage: .assets)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
    let result = try await AssetsStage.run(input: app, outputDir: out, platform: .ios, config: config, project: project, profile: testProfile())
    let names = try FileManager.default.contentsOfDirectory(atPath: result.appendingPathComponent("LaunchScreen.storyboardc").path)
    #expect(names.contains("Info.plist") && names.filter { $0.hasSuffix(".nib") }.count == 2)
    #expect(try Plist.read(result.appendingPathComponent("Info.plist"), stage: .assets)["UILaunchStoryboardName"] as? String == "LaunchScreen")
    let car = try Data(contentsOf: result.appendingPathComponent("Assets.car"))
    #expect(car.range(of: Data("Logo".utf8)) != nil, "the storyboard's Logo image must be in Assets.car")
}

/// Final review M2: any compiler failure is an `[assets]` error, not only an `XlessError`.
@Test func everyCompilerFailureMapsToAnAssetsError() throws {
    let url = URL(fileURLWithPath: "/p/Launch.storyboard")
    let ib = LaunchStoryboard.assetsError(XlessError(.ib, "unsupported x at line 3", fix: "do y"), storyboard: url)
    #expect(ib.stage == .assets && ib.cause == "launch storyboard /p/Launch.storyboard: unsupported x at line 3" && ib.fix == "do y")
    let other = LaunchStoryboard.assetsError(CocoaError(.fileReadCorruptFile), storyboard: url)
    #expect(other.stage == .assets)
    #expect(other.cause.hasPrefix("launch storyboard /p/Launch.storyboard: "), "\(other.cause)")
}

/// The assets stage writes the image's Xcode's formats: Xcode 26.2's storyboard and car under a 17C52 image.
@Test func assetsStageFollowsTheImagesXcode() async throws {
    let app = try await runLaunchStoryboard(ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), family: [1, 2], minimumOS: "16.0",
                                            profile: testProfile("17C52"))
    let golden = ibCorpus.appendingPathComponent("golden/17C52/real-logo-plus-label/universal-16.storyboardc")
    #expect(try files(in: app.appendingPathComponent("real-logo-plus-label.storyboardc")) == files(in: golden))
    let header = try #require(CARHeaderFields(car: Data(contentsOf: app.appendingPathComponent("Assets.car"))))
    #expect(header.coreUIVersion == 973)
    #expect(header.versionString == "Xcode 26.2 (17C52) via AssetCatalogSimulatorAgent")
}

/// An image whose Xcode has no tools profile: the iOS assets stage refuses (exit 13), never writes 27.0's formats.
@Test func assetsStageRefusesAnUnprofiledImage() async throws {
    let e = try await #require(throws: XlessError.self) {
        _ = try await runLaunchStoryboard(ibCorpus.appendingPathComponent("real-logo-plus-label.storyboard"), family: [1, 2], minimumOS: "16.0",
                                          profile: testProfile("99A9999"))
    }
    #expect(e.stage == .assets)
    #expect(e.cause == "this image's Xcode build 99A9999 has no measured asset/storyboard tools profile")
    #expect(e.fix.contains("xless setup --xcode"))
}
