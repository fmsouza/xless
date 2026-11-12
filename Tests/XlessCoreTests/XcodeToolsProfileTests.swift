import Foundation
import Testing
@testable import XlessCore

/// The tools profiles are data measured black-box (docs/research/xcode-tools-by-version.md). The values below are copied
/// verbatim from that document; a profile that drifts from it fails here.

private func meta(_ build: String) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: "2700", xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [:])
}

@Test func testMeasuredBuilds() {
    #expect(XcodeToolsProfile.all.keys.sorted() == ["17A400", "17B100", "17B55", "17C52", "17C529", "17E192", "17E202", "27A266a", "27A9275", "27B52"])
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

/// Xcode 27.2 writes what 27.1 writes bar the version strings and the CoreUI version (the 27B52 goldens equal the 27A9275 ones,
/// bar `IBTOOL_VERSION`).
@Test func test27B52() throws {
    let p = try #require(XcodeToolsProfile.all["27B52"])
    let q = try #require(XcodeToolsProfile.all["27A9275"])
    #expect(p.xcodeVersion == "27.2")
    #expect(p.actoolBundleVersion == "25408")
    #expect(p.actoolShortVersion == "27.2")
    #expect(p.ibtoolBundleVersion == "25408")
    #expect(p.ibtoolShortVersion == "27.2")
    #expect(p.carCoreUIVersion == 1011)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1011.4 [LAR]")
    #expect(p.carAssetStorageVersion == "Xcode 27.2 (27B52) via AssetCatalogAgent-AssetRuntime")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR] [IIO-2851.1.8][LAR] AppleJPEG[1][32]  CMPhoto[1][222]] [IR-120(hw)]")
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

/// Xcode 26.0.1 encodes nibs as 26.2 does (the 17A400 goldens equal the 17C52 ones, bar `IBTOOL_VERSION`); only its version strings
/// and CoreUI version differ, and ibtool refuses a document that needs Xcode 26.1.
@Test func test17A400() throws {
    let p = try #require(XcodeToolsProfile.all["17A400"])
    let q = try #require(XcodeToolsProfile.all["17C52"])
    #expect(p.xcodeVersion == "26.0.1")
    #expect(p.actoolBundleVersion == "24128")
    #expect(p.actoolShortVersion == "26.0.1")
    #expect(p.ibtoolBundleVersion == "24128")
    #expect(p.ibtoolShortVersion == "26.0.1")
    #expect(p.carCoreUIVersion == 970)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-970.1")
    #expect(p.carAssetStorageVersion == "Xcode 26.0.1 (17A400) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-652  [IIO-2773.0.1.2]")
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

/// Xcode 26.1 encodes nibs as 26.2 does (the 17B55 goldens equal the 17C52 ones, bar `IBTOOL_VERSION`); only its version strings
/// and CoreUI version differ, and ibtool refuses a document that needs Xcode 26.2.
@Test func test17B55() throws {
    let p = try #require(XcodeToolsProfile.all["17B55"])
    let q = try #require(XcodeToolsProfile.all["17C52"])
    #expect(p.xcodeVersion == "26.1")
    #expect(p.actoolBundleVersion == "24412")
    #expect(p.actoolShortVersion == "26.1")
    #expect(p.ibtoolBundleVersion == "24412")
    #expect(p.ibtoolShortVersion == "26.1")
    #expect(p.carCoreUIVersion == 971)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-971.6")
    #expect(p.carAssetStorageVersion == "Xcode 26.1 (17B55) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.2  [IIO-2784.1.3.3]")
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

/// Xcode 26.1.1 encodes nibs and cars as 26.1 does (the 17B100 goldens equal the 17B55 ones, bar `IBTOOL_VERSION`); only its short
/// version strings differ, and ibtool refuses a document that needs Xcode 26.1.2.
@Test func test17B100() throws {
    let p = try #require(XcodeToolsProfile.all["17B100"])
    let q = try #require(XcodeToolsProfile.all["17B55"])
    #expect(p.xcodeVersion == "26.1.1")
    #expect(p.actoolBundleVersion == "24412")
    #expect(p.actoolShortVersion == "26.1.1")
    #expect(p.ibtoolBundleVersion == "24412")
    #expect(p.ibtoolShortVersion == "26.1.1")
    #expect(p.carCoreUIVersion == 971)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-971.6")
    #expect(p.carAssetStorageVersion == "Xcode 26.1.1 (17B100) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.2  [IIO-2784.1.3.3]")
    #expect(p.carCoreUIVersion == q.carCoreUIVersion && p.carMainVersion == q.carMainVersion && p.carAuthoringTool == q.carAuthoringTool)
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

/// Xcode 26.3 encodes nibs and cars as 26.2 does (the 17C529 goldens equal the 17C52 ones, bar `IBTOOL_VERSION`); only its short
/// version strings differ, and ibtool refuses a document that needs Xcode 26.3.1.
@Test func test17C529() throws {
    let p = try #require(XcodeToolsProfile.all["17C529"])
    let q = try #require(XcodeToolsProfile.all["17C52"])
    #expect(p.xcodeVersion == "26.3")
    #expect(p.actoolBundleVersion == "24506")
    #expect(p.actoolShortVersion == "26.3")
    #expect(p.ibtoolBundleVersion == "24506")
    #expect(p.ibtoolShortVersion == "26.3")
    #expect(p.carCoreUIVersion == 973)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-973.1")
    #expect(p.carAssetStorageVersion == "Xcode 26.3 (17C529) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.3  [IIO-2784.3.4]")
    #expect(p.carCoreUIVersion == q.carCoreUIVersion && p.carMainVersion == q.carMainVersion && p.carAuthoringTool == q.carAuthoringTool)
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

/// Xcode 26.4 differs from 26.2 in its version strings, its CoreUI version and the CAR header strings (from the iOS 26.4 runtime), the newest
/// document ibtool accepts (26.4), and in one nib encoding: a nib of plain views writes the tint system blue as (0, 136, 255), as 27.0 does.
@Test func test17E192() throws {
    let p = try #require(XcodeToolsProfile.all["17E192"])
    let q = try #require(XcodeToolsProfile.all["17C52"])
    let r = try #require(XcodeToolsProfile.all["27A266a"])
    #expect(p.xcodeVersion == "26.4")
    #expect(p.actoolBundleVersion == "24765")
    #expect(p.actoolShortVersion == "26.4")
    #expect(p.ibtoolBundleVersion == "24765")
    #expect(p.ibtoolShortVersion == "26.4")
    #expect(p.carCoreUIVersion == 974)
    #expect(p.carStorageVersion == 17)
    #expect(p.carMainVersion == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-974.1")
    #expect(p.carAssetStorageVersion == "Xcode 26.4 (17E192) via AssetCatalogSimulatorAgent")
    #expect(p.carAuthoringTool == "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.4  [IIO-2784.4.10]")
    #expect(p.nibOtherViews == q.nibOtherViews)
    #expect(p.nibPlainViews.systemColorOverrides.isEmpty && r.nibPlainViews.systemColorOverrides.isEmpty)
    #expect(p.nibPlainViews.verifiedSystemColors == q.nibPlainViews.verifiedSystemColors)
    #expect(p.nibPlainViews.writesLNEVersionKey && p.nibPlainViews.roundsSystemColors && p.nibPlainViews.writesNilLabelText && p.nibPlainViews.uniquesCustomFonts)
    #expect(p.nibPlainViews.italicTraits == .shared)
}

/// Xcode 26.4.1 differs from 26.4 only in its version strings (the CAR header strings, from the iOS 26.4.1 runtime, are 26.4's) and the
/// newest document ibtool accepts (26.4.1); the nib encodings are 26.4's.
@Test func test17E202() throws {
    let p = try #require(XcodeToolsProfile.all["17E202"])
    let q = try #require(XcodeToolsProfile.all["17E192"])
    #expect(p.xcodeVersion == "26.4.1")
    #expect(p.actoolBundleVersion == "24765")
    #expect(p.actoolShortVersion == "26.4.1")
    #expect(p.ibtoolBundleVersion == "24765")
    #expect(p.ibtoolShortVersion == "26.4.1")
    #expect(p.carCoreUIVersion == q.carCoreUIVersion && p.carStorageVersion == q.carStorageVersion)
    #expect(p.carMainVersion == q.carMainVersion && p.carAuthoringTool == q.carAuthoringTool)
    #expect(p.carAssetStorageVersion == "Xcode 26.4.1 (17E202) via AssetCatalogSimulatorAgent")
    #expect(p.nibPlainViews == q.nibPlainViews && p.nibOtherViews == q.nibOtherViews)
}

@Test func testUnknownBuildRefuses() throws {
    let e = #expect(throws: XlessError.self) { try XcodeToolsProfile.forImage(meta: meta("99A9999"), stage: .assets) }
    #expect(e?.stage == .assets)
    #expect(e?.cause == "this image's Xcode build 99A9999 has no measured asset/storyboard tools profile")
    #expect(e?.fix.contains("xless setup --xcode") == true)
    #expect(e?.fix.contains("17A400, 17B100, 17B55, 17C52, 17C529, 17E192, 17E202, 27A266a, 27A9275, 27B52") == true)
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
