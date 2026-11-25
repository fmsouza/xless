import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

@Test(arguments: [("27.0", "2700"), ("16.4", "1640"), ("26.0.1", "2601"), ("15.0", "1500")])
func xcodeVersionCode(input: String, expected: String) throws {
    #expect(try ToolchainMetaCollector.xcodeVersionCode(input) == expected)
}

func makeFakeXcode() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeXcode-\(UUID()).app")
    let fm = FileManager.default
    func plist(_ dict: [String: Any], _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }
    func json(_ dict: [String: Any], _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
    }
    try plist(["CFBundleShortVersionString": "27.0", "ProductBuildVersion": "27A266a"], "Contents/version.plist")
    for (plat, canon, build) in [("iPhoneOS", "iphoneos27.0", "23A340"), ("MacOSX", "macosx27.0", "26A120")] {
        let base = "Contents/Developer/Platforms/\(plat).platform"
        try plist(["DTPlatformBuild": build, "DTPlatformVersion": "27.0"], "\(base)/Info.plist")
        try json(["CanonicalName": canon, "Version": "27.0"], "\(base)/Developer/SDKs/\(plat).sdk/SDKSettings.json")
        try plist(["ProductBuildVersion": build], "\(base)/Developer/SDKs/\(plat).sdk/System/Library/CoreServices/SystemVersion.plist")
    }
    let swift = root.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    try fm.createDirectory(at: swift.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ExecutableFile.write("#!/bin/sh\necho 'swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)'\necho 'Target: arm64-apple-macosx27.0'\n",
                             to: swift, stage: .sdk)
    return root
}

@Test func collectsMetaFromXcodeTree() throws {
    let meta = try ToolchainMetaCollector.collect(xcodeApp: try makeFakeXcode(), buildMachineOSBuild: "26A100")
    #expect(meta.xcodeVersion == "2700")
    #expect(meta.xcodeBuild == "27A266a")
    #expect(meta.buildMachineOSBuild == "26A100")
    let ios = try meta.sdk(for: .ios)
    #expect(ios == PlatformSDKInfo(sdkName: "iphoneos27.0", sdkVersion: "27.0", sdkBuild: "23A340",
                                   platformName: "iphoneos", platformVersion: "27.0", platformBuild: "23A340"))
    #expect(try meta.sdk(for: .macos).sdkName == "macosx27.0")
    #expect(meta.swiftVersion == "6.4")
}

@Test func metadataWithoutSwiftVersionStillDecodes() throws {
    // Exported before Ruling R10.
    let json = #"{"buildMachineOSBuild":"26A100","compiler":"c","platforms":{},"xcodeBuild":"17C52","xcodeVersion":"2620"}"#
    let meta = try JSONDecoder().decode(ToolchainMeta.self, from: Data(json.utf8))
    #expect(meta.swiftVersion == nil)
}

@Test func swiftIsAskedWithTheEnvironmentThatIsGiven() throws {
    let app = try makeFakeXcode(), key = "XLESS_TEST_OF_SWIFT_\(UUID().uuidString.prefix(8))"
    try ExecutableFile.write("#!/bin/sh\necho \"Apple Swift version 6.4.$\(key)\"\n",
                             to: app.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"), stage: .sdk)
    #expect(try ToolchainMetaCollector.collect(xcodeApp: app, buildMachineOSBuild: "x", environment: [key: "7"]).swiftVersion == "6.4.7")
}

@Test func missingXcodeIsSDKError() {
    do { _ = try ToolchainMetaCollector.collect(xcodeApp: URL(fileURLWithPath: "/nope.app"), buildMachineOSBuild: "x"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sdk) } catch { Issue.record("\(error)") }
}
