import Testing
import Foundation
@testable import XlessCore

func sdkInfo(_ v: String) -> PlatformSDKInfo {
    .init(sdkName: "iphoneos\(v)", sdkVersion: v, sdkBuild: "23A1", platformName: "iphoneos", platformVersion: v, platformBuild: "23A1")
}

@Test func rejectsOldSDK() {
    #expect(throws: XlessError.self) { try Requirements.checkSDK(sdkInfo("18.5"), platform: .ios) }
    #expect(throws: Never.self) { try Requirements.checkSDK(sdkInfo("27.0"), platform: .ios) }
}

@Test func rejectsLowIOSDeployment() {
    #expect(throws: XlessError.self) { try Requirements.checkDeployment("12.4", platform: .ios) }
    #expect(throws: Never.self) { try Requirements.checkDeployment("13.0", platform: .ios) }
    #expect(throws: Never.self) { try Requirements.checkDeployment("11.0", platform: .macos) }
}

@Test func metaRoundTripsAndLooksUpPlatform() throws {
    let meta = ToolchainMeta(xcodeVersion: "2700", xcodeBuild: "27A266a", buildMachineOSBuild: "26A100",
                             compiler: ToolchainMeta.clangCompiler, platforms: ["iphoneos": sdkInfo("27.0")])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID()).json")
    try meta.write(to: url)
    #expect(try ToolchainMeta.load(from: url) == meta)
    #expect(try meta.sdk(for: .ios).sdkVersion == "27.0")
    #expect(throws: XlessError.self) { try meta.sdk(for: .macos) }
}

@Test func olderLocationIgnoresTheOverride() {
    // XLESS_TOOLCHAIN_META names a file in use, never an older install's.
    #expect(ToolchainMeta.olderLocation(env: ["XLESS_TOOLCHAIN_META": "/x/m.json", "HOME": "/home/u"]).path == "/home/u/.config/xless/toolchain-meta.json")
    #expect(ToolchainMeta.olderLocation(env: ["XDG_CONFIG_HOME": "/c", "HOME": "/home/u"]).path == "/c/xless/toolchain-meta.json")
}

@Test func sdkLocatorHonoursXDG() {
    #expect(DarwinSDKLocator.bundle(env: ["XDG_CONFIG_HOME": "/opt/xless/config"]).path
            == "/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle")
    #expect(DarwinSDKLocator.bundle(env: ["HOME": "/home/u"]).path
            == "/home/u/.swiftpm/swift-sdks/darwin.artifactbundle")
}
