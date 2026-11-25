import Testing
import Foundation
@testable import XlessBuild
@testable import XlessCore

let macYAML = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 3
platforms:
  macos: { minimumOS: "14.0", product: HelloShip, distribution: developer-id }
"""

@Test func wrapperPackageMirrorsXtool() {
    let s = MacBuilder.wrapperPackage(product: "HelloShip", minimumOS: "14.0", rootRelativePath: "../..")
    #expect(s.contains(".macOS(\"14.0\")"))
    #expect(s.contains(".package(name: \"RootPackage\", path: \"../..\")"))
    #expect(s.contains(".executableTarget(name: \"HelloShipMac\""))
    #expect(s.contains("@executable_path/../Frameworks"))
}

@Test func baseInfoPlist() throws {
    let p = try MacBuilder.baseInfoPlist(config: ProjectConfig.parse(yaml: macYAML))
    #expect(p["CFBundleExecutable"] as? String == "HelloShip")
    #expect(p["CFBundleIdentifier"] as? String == "app.example.helloship")
    #expect(p["CFBundlePackageType"] as? String == "APPL")
    #expect(p["LSMinimumSystemVersion"] as? String == "14.0")
    #expect(p["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"])
    #expect(p["NSPrincipalClass"] as? String == "NSApplication")
}

@Test func builtExecutableSkipsDSYMCompanion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-macbuilder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dwarf = root.appendingPathComponent("Release/HelloShipMac.dSYM/Contents/Resources/DWARF")
    try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
    try Data("dwarf".utf8).write(to: dwarf.appendingPathComponent("HelloShipMac"))
    #expect(MacBuilder.builtExecutable(named: "HelloShipMac", under: root) == nil)
    try Data("exe".utf8).write(to: root.appendingPathComponent("Release/HelloShipMac"))
    #expect(MacBuilder.builtExecutable(named: "HelloShipMac", under: root)?.resolvingSymlinksInPath().path
        == root.appendingPathComponent("Release/HelloShipMac").resolvingSymlinksInPath().path)
}

@Test func swiftBuildNamesTheProductWithTheAppSwiftToolchain() {
    // Ruling R10: SwiftPM 6.2's Swift Build builds only targets unless --product names the executable (as for Tauri's
    // Swift aggregate); the image's own SwiftPM keeps the invocation it always had.
    let w = URL(fileURLWithPath: "/p/.xless/macos-pkg"), t = URL(fileURLWithPath: "/sdk/toolset-swb.json")
    // It also selects one architecture by --swift-sdk and --arch: with --triple it builds arm64 and x86_64 and needs lipo.
    let base = ["build", "--package-path", "/p/.xless/macos-pkg", "--scratch-path", "/p/.xless/macos-build-x86_64-swift-6.2.3",
                "-c", "release", "--build-system", "swiftbuild"]
    let scratch = URL(fileURLWithPath: "/p/.xless/macos-build-x86_64-swift-6.2.3")
    #expect(MacBuilder.swiftBuildArguments(wrapper: w, scratch: scratch, arch: "x86_64", minimumOS: "14.0", toolset: t, product: "HelloShip",
                                           own: SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3"))
            == base + ["--swift-sdk", "x86_64-apple-macosx", "--arch", "x86_64", "--toolset", "/sdk/toolset-swb.json", "--product", "HelloShipMac"])
    #expect(MacBuilder.swiftBuildArguments(wrapper: w, scratch: scratch, arch: "x86_64", minimumOS: "14.0", toolset: t, product: "HelloShip",
                                           own: nil) == base + ["--triple", "x86_64-apple-macosx14.0", "--toolset", "/sdk/toolset-swb.json"])
}

/// A build on Linux, with a stand-in for `swift` that leaves an executable and the bundle of the one package that the app has.
@Test func aMacAppIsBuiltWithTheProjectsPackageResolvedAndOnlyWithTheBundlesOfThisBuild() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-macbuilder-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let project = root.appendingPathComponent("p"), home = root.appendingPathComponent("home")
    let env = ["PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": home.path, "XLESS_SWIFT_TOOLCHAIN": root.path + "/none"]
    let sdk = DarwinSDKLocator.bundle(env: env), bin = sdk.appendingPathComponent("toolset/bin")
    for directory in [project, bin] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    try Data("{}".utf8).write(to: sdk.appendingPathComponent("toolset-swb.json"))
    for (name, cpu) in [("arm64", 0x0100000c), ("x86_64", 0x01000007)] as [(String, UInt32)] {
        let words: [UInt32] = [0xfeedfacf, cpu, 0, 2, 0, 0, 0, 0]
        try Data(words.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }).write(to: root.appendingPathComponent(name))
    }
    try ExecutableFile.write("""
        #!/bin/sh
        while [ $# -gt 0 ]; do case "$1" in --package-path) w="$2" ;; --scratch-path) s="$2" ;; --triple) a="${2%%-*}" ;; esac; shift; done
        mkdir -p "$s/out/Products/Release/Now_Now.bundle"
        cp '\(root.path)'/"$a" "$s/out/Products/Release/DemoMac"
        cp "$w/Package.resolved" '\(root.path)/used-'"$a" 2>/dev/null || true
        echo '{"pins":[{"identity":"dep","state":{"version":"9.0.0"}}],"version":3}' > "$w/Package.resolved"

        """, to: bin.appendingPathComponent("swift"), stage: .build)
    let config = try ProjectConfig.parse(yaml: macYAML.replacingOccurrences(of: "HelloShip", with: "Demo"))
    let own = project.appendingPathComponent("Package.resolved"), text = #"{"pins":[{"identity":"dep","state":{"version":"1.0.0"}}],"version":3}"#
    try Data(text.utf8).write(to: own)
    // what another build left, of a package that the app had then
    for arch in ["arm64", "x86_64"] {
        try fm.createDirectory(at: project.appendingPathComponent(".xless/macos-build-\(arch)/out/Products/Release/Gone_Gone.bundle"), withIntermediateDirectories: true)
    }
    let app = try MacBuilder.build(project: project, config: config, paths: StagePaths(project: project, platform: .macos), env: env)
    #expect(try fm.contentsOfDirectory(atPath: app.path + "/Contents/Resources") == ["Now_Now.bundle"])
    #expect(try String(contentsOf: root.appendingPathComponent("used-arm64"), encoding: .utf8) == text)
    #expect(try String(contentsOf: root.appendingPathComponent("used-x86_64"), encoding: .utf8).contains("9.0.0"), "the other architecture: the versions of the first")
    #expect(try String(contentsOf: own, encoding: .utf8) == text)

    // one that a project no longer has is not built with
    try fm.removeItem(at: own)
    try fm.removeItem(at: root.appendingPathComponent("used-arm64"))
    _ = try MacBuilder.build(project: project, config: config, paths: StagePaths(project: project, platform: .macos), env: env)
    #expect(!fm.fileExists(atPath: root.path + "/used-arm64"))
}
