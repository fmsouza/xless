import Foundation
import Testing
@testable import XlessCore

/// The tools profiles are data measured black-box (docs/research/xcode-tools-by-version.md). The values below are copied
/// verbatim from that document; a profile that drifts from it fails here.

private func meta(_ build: String) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: "2700", xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [:])
}

@Test func testMeasuredBuilds() {
    #expect(XcodeToolsProfile.all.keys.sorted() == ["17C52", "27A266a", "27A9275"])
    for (build, p) in XcodeToolsProfile.all { #expect(p.xcodeBuild == build) }
}

@Test func test27A266aMatchesM3() throws {
    let p = try #require(XcodeToolsProfile.all["27A266a"])
    #expect(p.xcodeVersion == "27.0")
    #expect(p.actoolBundleVersion == "25098")
    #expect(p.actoolShortVersion == "27.0")
    #expect(p.ibtoolBundleVersion == "25098")
    #expect(p.ibtoolShortVersion == "27.0")
    #expect(p.carCoreUIVersion == 1010)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1010 [LAR]")
    #expect(p.carAssetStorageVersion == "Xcode 27.0 (27A266a) via AssetCatalogAgent-AssetRuntime")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR] [IIO-2851][LAR] AppleJPEG[1][32]  CMPhoto[1][219]] [IR-120(hw)]")
    // One nib encoder for every view nib: m3's output (the LNE key everywhere, decimals rounded to 10 digits).
    #expect(p.nibPlainViews == p.nibOtherViews)
    #expect(p.nibOtherViews.writesLNEVersionKey)
    #expect(p.nibOtherViews.roundsSystemColors)
    #expect(p.nibOtherViews.systemColorOverrides.isEmpty)
    #expect(p.nibOtherViews.verifiedSystemColors == nil)
    #expect(p.nibOtherViews.writesNilLabelText)
    #expect(p.nibOtherViews.uniquesCustomFonts)
    #expect(p.nibOtherViews.italicTraits == .shared)
}

/// Xcode 27.1 writes what 27.0 writes (the 27A9275 goldens equal the 27A266a ones, bar the version strings).
@Test func test27A9275() throws {
    let p = try #require(XcodeToolsProfile.all["27A9275"])
    let q = try #require(XcodeToolsProfile.all["27A266a"])
    #expect(p.xcodeVersion == "27.1")
    #expect(p.actoolBundleVersion == "25098")
    #expect(p.actoolShortVersion == "27.1")
    #expect(p.ibtoolBundleVersion == "25098")
    #expect(p.ibtoolShortVersion == "27.1")
    #expect(p.carCoreUIVersion == 1010)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == q.carMainVersion)
    #expect(p.carAssetStorageVersion == "Xcode 27.1 (27A9275) via AssetCatalogAgent-AssetRuntime")
    #expect(p.carAuthoringTool == q.carAuthoringTool)
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

@Test func test17C52() throws {
    let p = try #require(XcodeToolsProfile.all["17C52"])
    #expect(p.xcodeVersion == "26.2")
    #expect(p.actoolBundleVersion == "24506")
    #expect(p.actoolShortVersion == "26.2")
    #expect(p.ibtoolBundleVersion == "24506")
    #expect(p.ibtoolShortVersion == "26.2")
    #expect(p.carCoreUIVersion == 973)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-973.1")
    #expect(p.carAssetStorageVersion == "Xcode 26.2 (17C52) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.3  [IIO-2784.3.4]")
    // View nibs of plain UIViews only: the LNE key, decimals rounded, system blue 0 122 255 (`0 0.478 1`).
    #expect(p.nibPlainViews.writesLNEVersionKey)
    #expect(p.nibPlainViews.roundsSystemColors)
    #expect(p.nibPlainViews.systemColorOverrides == ["systemBlueColor": [0, 122, 255]])
    #expect(p.nibPlainViews.verifiedSystemColors == ["labelColor", "systemBackgroundColor", "systemBlueColor", "systemGroupedBackgroundColor"])
    // View nibs with a label, an image view or the legacy layout guides: no LNE key, the nearest double, no `UIText`
    // for a label without text, custom fonts not shared, the italic traits dictionary per optical size.
    #expect(!p.nibOtherViews.writesLNEVersionKey)
    #expect(!p.nibOtherViews.roundsSystemColors)
    #expect(p.nibOtherViews.systemColorOverrides.isEmpty)
    #expect(p.nibOtherViews.verifiedSystemColors == nil)
    #expect(!p.nibOtherViews.writesNilLabelText)
    #expect(!p.nibOtherViews.uniquesCustomFonts)
    #expect(p.nibOtherViews.italicTraits == .opticalSizeBands(low: 13, high: 28, between: [20]))
}

@Test func testUnknownBuildRefuses() throws {
    let e = #expect(throws: XlessError.self) { try XcodeToolsProfile.forImage(meta: meta("99A9999"), stage: .assets) }
    #expect(e?.stage == .assets)
    #expect(e?.cause == "this image's Xcode build 99A9999 has no measured asset/storyboard tools profile")
    #expect(e?.fix.contains("xless setup --xcode") == true)
    #expect(e?.fix.contains("17C52, 27A266a, 27A9275") == true)
    #expect(try XcodeToolsProfile.forImage(meta: meta("17C52"), stage: .ib) == XcodeToolsProfile.all["17C52"])
}

@Test func testImageMetadataIsReadFromTheToolchainFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("toolchain-meta.json")
    try meta("17C52").write(to: url)
    #expect(try XcodeToolsProfile.forImage(env: ["XLESS_TOOLCHAIN_META": url.path], stage: .ib).xcodeBuild == "17C52")
    // No metadata: refused in the asking stage, never a default profile.
    let missing = #expect(throws: XlessError.self) {
        try XcodeToolsProfile.forImage(env: ["XLESS_TOOLCHAIN_META": dir.appendingPathComponent("none.json").path], stage: .assets)
    }
    #expect(missing?.stage == .assets)
    #expect(missing?.cause.contains("toolchain metadata not found") == true)
}

/// Task 4's `scripts/xcode-tools.sh` learns the profiled builds by grepping this file for `xcodeBuild: "<B>"`.
@Test func testEachProfileHasOneGreppableBuildLiteral() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/XlessCore/XcodeToolsProfile.swift")
    let text = try String(contentsOf: file, encoding: .utf8)
    let regex = try NSRegularExpression(pattern: #"xcodeBuild: "([^"]+)""#)
    let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) }
    #expect(found.sorted() == XcodeToolsProfile.all.keys.sorted())
}
