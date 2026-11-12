import Testing
import Foundation
import XlessCore
@testable import XlessIB

// Command lines are Swift Build's CompileStoryboard / LinkStoryboards (IBStoryboardCompiler.xcspec,
// IBStoryboardLinker.xcspec) with Xcode's flag order (docs/research/ib-invocation.md).

/// The image's toolchain metadata as a test injects it.
func testMeta(_ build: String) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: "2700", xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [:])
}

/// The shim in an image made from Xcode `build` (27A266a unless a test says otherwise).
private func runShim(_ args: [String], build: String = "27A266a") -> IbtoolShim.Result {
    IbtoolShim.run(args, profile: { try XcodeToolsProfile.forImage(meta: testMeta(build), stage: .ib) })
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-ibshim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func files(_ dir: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) { out[f] = try Data(contentsOf: dir.appendingPathComponent(f)) }
    return out
}

private func compileArgs(_ input: URL, tmp: URL, devices: [String] = ["iphone", "ipad"], target: String = "16.4") -> [String] {
    ["--errors", "--warnings", "--notices", "--module", "IBProbe",
     "--output-partial-info-plist", tmp.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-SBPartialInfo.plist").path,
     "--auto-activate-custom-fonts"] + devices.flatMap { ["--target-device", $0] }
        + ["--minimum-deployment-target", target, "--output-format", "human-readable-text", input.path, "--compilation-directory", tmp.path]
}

@Test(arguments: [("27A266a", "25098", "27.0"), ("27A9275", "25098", "27.1"), ("27B52", "25408", "27.2"), ("17E192", "24765", "26.4"), ("17C529", "24506", "26.3"), ("17C52", "24506", "26.2"), ("17B55", "24412", "26.1"), ("17B100", "24412", "26.1.1"), ("17A400", "24128", "26.0.1")])
func versionProbeAnswersAsTheImagesIbtool(_ build: String, _ bundle: String, _ short: String) throws {
    let r = runShim(["--version", "--output-format", "xml1"], build: build)
    #expect(r.exitCode == 0)
    let v = try PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as! [String: Any]
    #expect(v["com.apple.ibtool.version"] as? [String: String] == ["bundle-version": bundle, "short-bundle-version": short])
}

/// An image whose Xcode has no tools profile (an old local image, `XLESS_IMAGE` naming one) is refused with exit 70 and
/// `forImage`'s message, for every call: never Xcode 27.0's output under another Xcode's name.
@Test func testShimRefusesUnprofiledImage() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    for args in [["--version", "--output-format", "xml1"], compileArgs(CorpusCase(name: "real-logo-plus-label").storyboard, tmp: dir)] {
        let r = runShim(args, build: "99A9999")
        #expect(r.exitCode == 70)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("this image's Xcode build 99A9999 has no measured asset/storyboard tools profile"), "\(r.stderr)")
        #expect(r.stderr.contains("xless setup --xcode"), "\(r.stderr)")
    }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("real-logo-plus-label.storyboardc").path))
}

/// The compile follows the image: Xcode 26.2's ibtool output for the same storyboard.
@Test func compileFollowsTheImagesXcode() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let input = dir.appendingPathComponent("LaunchScreen.storyboard")
    try FileManager.default.copyItem(at: c.storyboard, to: input)
    let tmp = dir.appendingPathComponent("tmp")
    let r = runShim(compileArgs(input, tmp: tmp), build: "17C52")
    #expect(r == .init(stdout: "", stderr: "", exitCode: 0))
    #expect(try files(tmp.appendingPathComponent("LaunchScreen.storyboardc")) == c.goldenFiles(flagset: "universal-16", build: "17C52"))
}

@Test func compileThenLinkGivesTheGoldenStoryboardc() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-logo-plus-label")
    let input = dir.appendingPathComponent("LaunchScreen.storyboard")
    try FileManager.default.copyItem(at: c.storyboard, to: input)
    let tmp = dir.appendingPathComponent("tmp"), app = dir.appendingPathComponent("X.app")
    var r = runShim(compileArgs(input, tmp: tmp))
    #expect(r == .init(stdout: "", stderr: "", exitCode: 0))
    let golden = try c.goldenFiles(flagset: "universal-16")
    #expect(try files(tmp.appendingPathComponent("LaunchScreen.storyboardc")) == golden)
    let partial = try PropertyListSerialization.propertyList(from: Data(contentsOf: tmp.appendingPathComponent("LaunchScreen-SBPartialInfo.plist")), format: nil)
    #expect((partial as? [String: Any])?.isEmpty == true)

    r = runShim(["--errors", "--warnings", "--notices", "--module", "IBProbe", "--target-device", "iphone", "--target-device", "ipad",
                        "--minimum-deployment-target", "16.4", "--output-format", "human-readable-text",
                        "--link", app.path, tmp.appendingPathComponent("LaunchScreen.storyboardc").path])
    #expect(r.exitCode == 0)
    #expect(try files(app.appendingPathComponent("LaunchScreen.storyboardc")) == golden)
}

/// Expo's template SplashScreen.storyboard (HelloRN's prebuild output, `real-expo-splash-template`) compiles and links to
/// ibtool's bytes, with the deployment target Expo uses (16.4) and the empty partial Info.plist.
@Test func expoSplashScreenCompilesLikeIbtool() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = CorpusCase(name: "real-expo-splash-template")
    let input = dir.appendingPathComponent("SplashScreen.storyboard")
    try FileManager.default.copyItem(at: c.storyboard, to: input)
    let tmp = dir.appendingPathComponent("tmp"), app = dir.appendingPathComponent("HelloRN.app")
    var r = runShim(compileArgs(input, tmp: tmp))
    #expect(r == .init(stdout: "", stderr: "", exitCode: 0))
    let golden = try c.goldenFiles(flagset: "universal-16")
    #expect(golden.keys.sorted() == ["EXPO-VIEWCONTROLLER-1-view-EXPO-ContainerView.nib", "Info.plist", "SplashScreenViewController.nib"])
    #expect(try files(tmp.appendingPathComponent("SplashScreen.storyboardc")) == golden)
    let partial = try PropertyListSerialization.propertyList(from: Data(contentsOf: tmp.appendingPathComponent("SplashScreen-SBPartialInfo.plist")), format: nil)
    #expect((partial as? [String: Any])?.isEmpty == true)
    r = runShim(["--errors", "--warnings", "--notices", "--module", "IBProbe", "--target-device", "iphone", "--target-device", "ipad",
                        "--minimum-deployment-target", "16.4", "--output-format", "human-readable-text",
                        "--link", app.path, tmp.appendingPathComponent("SplashScreen.storyboardc").path])
    #expect(r.exitCode == 0)
    #expect(try files(app.appendingPathComponent("SplashScreen.storyboardc")) == golden)
}

@Test func storyboardOutsideTheSubsetFailsWithTheCompilersRefusal() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    var xml = try String(contentsOf: CorpusCase(name: "real-logo-plus-label").storyboard, encoding: .utf8)
    xml = xml.replacingOccurrences(of: "<viewController ", with: "<viewController restorationIdentifier=\"X\" ")
    let input = dir.appendingPathComponent("SplashScreen.storyboard")
    try Data(xml.utf8).write(to: input)
    let r = runShim(compileArgs(input, tmp: dir.appendingPathComponent("tmp")))
    #expect(r.exitCode == 1)
    #expect(r.stdout.hasPrefix("/* com.apple.ibtool.errors */\n\(input.path): error: unsupported attribute restorationIdentifier=\"X\" on <viewController>"))
    #expect(r.stderr.hasPrefix("xless ibtool shim: [ib] unsupported attribute restorationIdentifier=\"X\" on <viewController>"))
    #expect(r.stderr.contains(" — "))   // the compiler's fix travels with the refusal
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tmp/SplashScreen.storyboardc").path))
}

@Test func unverifiedFlagSetsAreToolErrors() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let r = runShim(compileArgs(CorpusCase(name: "real-logo-plus-label").storyboard, tmp: dir, target: "13.0"))
    #expect(r.exitCode == 1)
    #expect(r.stderr.contains("--minimum-deployment-target 13.0 is not supported"))
}

@Test(arguments: [
    (["--flatten", "NO"], "unknown option --flatten"),
    (["--companion-strings-file", "en:/x.strings"], "unknown option --companion-strings-file"),
    (["--platform", "iphoneos"], "unknown option --platform"),
    (["--compile", "/o/x.storyboardc"], "exactly one of --compile, --compilation-directory, --link"),
])
func refusesArgvOutsideTheSwiftBuildSubset(extra: [String], reason: String) {
    let args = compileArgs(URL(fileURLWithPath: "/in/A.storyboard"), tmp: URL(fileURLWithPath: "/tmp/x")) + extra
    let r = runShim(args)
    #expect(r.exitCode == 70)
    #expect(r.stderr.contains(reason))
    #expect(r.stderr.contains("ibtool \(args.joined(separator: " "))"))
}

@Test func refusesLocalizedAndNonStoryboardInputs() {
    var r = runShim(["--output-format", "human-readable-text", "--link", "/app", "/t/Base.lproj/Main.storyboardc"])
    #expect(r.exitCode == 70)
    #expect(r.stderr.contains("(.lproj) is not supported"))
    r = runShim(["--output-format", "human-readable-text", "--minimum-deployment-target", "16.4", "--target-device", "iphone", "/in/View.xib", "--compile", "/o/View.nib"])
    #expect(r.exitCode == 70)
}
