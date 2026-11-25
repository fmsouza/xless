import Foundation
import Testing
@testable import XlessBuild
@testable import XlessCore

private let yaml = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.2.3
build: 7
platforms:
  ios: { minimumOS: "17.0", product: HelloShip }
  macos: { minimumOS: "14.0", product: HelloShip, distribution: developer-id }
"""

/// A thin arm64 Mach-O executable that loads `libraries`.
private func image(loading libraries: [String]) -> Data {
    func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var commands = Data()
    for name in libraries {
        var text = Data(name.utf8) + [0]
        while (24 + text.count) % 8 != 0 { text.append(0) }
        commands += u32(0xc) + u32(UInt32(24 + text.count)) + u32(24) + u32(0) + u32(0) + u32(0) + text
    }
    return u32(0xfeedfacf) + u32(0x0100000c) + u32(0) + u32(2) + u32(UInt32(libraries.count)) + u32(UInt32(commands.count)) + u32(0) + u32(0) + commands
}

private func temporary() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-xcpkg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func theXcodeWrapperPackageLinksTheAppsLibrary() {
    let ios = XcodePackageBuilder.wrapperPackage(product: "HelloShip", minimumOS: "17.0", platform: .ios)
    #expect(ios.contains(#"platforms: [.iOS("17.0")]"#) && ios.contains(#".executableTarget(name: "HelloShipApp""#))
    #expect(ios.contains(#".package(name: "RootPackage", path: "../..")"#) && ios.contains(#""@executable_path/Frameworks""#))
    let mac = XcodePackageBuilder.wrapperPackage(product: "HelloShip", minimumOS: "14.0", platform: .macos)
    #expect(mac.contains(#"platforms: [.macOS("14.0")]"#) && mac.contains(#""@executable_path/../Frameworks""#))
}

@Test func swiftBuildOfXcodesKeepsItsSandboxAndLeavesTheKeychain() {
    let w = URL(fileURLWithPath: "/p/w"), s = URL(fileURLWithPath: "/p/s")
    let base = ["build", "--package-path", "/p/w", "--scratch-path", "/p/s", "-c", "release", "--build-system", "swiftbuild", "--disable-keychain", "--product", "XApp"]
    func arguments(_ d: XcodePackageBuilder.Destination) -> [String] { XcodePackageBuilder.arguments(d, wrapper: w, scratch: s, product: "X", minimumOS: "17.0") }
    #expect(arguments(.device) == base + ["--triple", "arm64-apple-ios17.0"])
    #expect(arguments(.simulator) == base + ["--triple", "arm64-apple-ios17.0-simulator"])
    #expect(arguments(.mac) == base + ["--arch", "arm64", "--arch", "x86_64"])
    for d in [XcodePackageBuilder.Destination.device, .simulator, .mac] { #expect(!arguments(d).contains("--disable-sandbox")) }
}

@Test func onlyTheSystemsAndTheAppsOwnRunPathsStay() {
    #expect(XcodePackageBuilder.isForeign("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/iphoneos"))
    #expect(XcodePackageBuilder.isForeign("/var/run/com.apple.security.cryptexd/mnt/x"))
    for path in ["/usr/lib/swift", "@loader_path", "@executable_path/Frameworks"] { #expect(!XcodePackageBuilder.isForeign(path)) }
}

@Test func theFrameworksAnAppLoadsAreEmbeddedWithWhatTheyLoad() throws {
    let products = try temporary()
    defer { try? FileManager.default.removeItem(at: products) }
    func write(_ path: String, _ libraries: [String]) throws -> URL {
        let url = products.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image(loading: libraries).write(to: url)
        return url
    }
    let exe = try write("XApp", ["/usr/lib/libSystem.B.dylib", "@rpath/A.framework/A", "@rpath/libC.dylib"])
    _ = try write("A.framework/A", ["@rpath/B.framework/Versions/A/B", "@rpath/A.framework/A"])
    _ = try write("PackageFrameworks/B.framework/Versions/A/B", [])
    _ = try write("libC.dylib", [])
    _ = try write("Unused.framework/Unused", [])
    #expect(try XcodePackageBuilder.embedded(exe, products: products).map(\.lastPathComponent).sorted() == ["A.framework", "B.framework", "libC.dylib"])

    for (library, fix) in [("libswift_Concurrency.dylib", "minimumOS"), ("Gone.framework/Gone", "binaryTarget")] {
        let bad = try write("Bad", ["@rpath/\(library)"])
        do {
            _ = try XcodePackageBuilder.embedded(bad, products: products)
            Issue.record("not refused")
        } catch let e as XlessError { #expect(e.cause.contains("@rpath/\(library)") && e.fix.contains(fix)) }
    }
}

@Test func anIOSAppIsAssembledFlat() throws {
    let dir = try temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = try ProjectConfig.parse(yaml: yaml + "\nprivacyManifest: P.xcprivacy\ninfoPlist: I.plist\n")
    try Data("<plist/>".utf8).write(to: dir.appendingPathComponent("P.xcprivacy"))
    try Plist.write(["UIDeviceFamily": [1], "Own": "x"], to: dir.appendingPathComponent("I.plist"), stage: .build)
    let resources = dir.appendingPathComponent("Pkg_Target.bundle"), framework = dir.appendingPathComponent("A.framework")
    for made in [resources, framework] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
    let app = try PackageApp.assemble(in: dir.appendingPathComponent("out"), executable: Data("exe".utf8), resources: [resources], frameworks: [framework],
                                      project: dir, config: config, platform: .ios)
    #expect(app.lastPathComponent == "HelloShip.app")
    #expect(try FileManager.default.contentsOfDirectory(atPath: app.path).sorted() == ["Frameworks", "HelloShip", "Info.plist", "PkgInfo", "Pkg_Target.bundle", "PrivacyInfo.xcprivacy"])
    #expect(FileManager.default.isExecutableFile(atPath: app.path + "/HelloShip"))
    let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .build)
    #expect(info["CFBundleIdentifier"] as? String == "app.example.helloship" && info["CFBundleExecutable"] as? String == "HelloShip")
    #expect(info["LSRequiresIPhoneOS"] as? Bool == true && info["MinimumOSVersion"] as? String == "17.0" && info["UILaunchScreen"] != nil)
    #expect(info["UIDeviceFamily"] as? [Int] == [1] && info["Own"] as? String == "x")
}

@Test func aMacAppIsAssembledInContents() throws {
    let dir = try temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = try PackageApp.assemble(in: dir, executable: Data("exe".utf8), resources: [], project: dir, config: ProjectConfig.parse(yaml: yaml), platform: .macos)
    #expect(try FileManager.default.contentsOfDirectory(atPath: app.path + "/Contents").sorted() == ["Info.plist", "MacOS", "PkgInfo", "Resources"])
    #expect(FileManager.default.isExecutableFile(atPath: app.path + "/Contents/MacOS/HelloShip"))
}
