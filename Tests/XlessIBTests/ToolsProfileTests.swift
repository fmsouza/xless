import Testing
import Foundation
@testable import XlessIB
@testable import XlessCore

// What follows the image's Xcode in the storyboard compiler (docs/research/xcode-tools-by-version.md, "ibtool").

private let p27 = XcodeToolsProfile.all["27A266a"]!
private let p26 = XcodeToolsProfile.all["17C52"]!
private let p2601 = XcodeToolsProfile.all["17A400"]!
private let p261 = XcodeToolsProfile.all["17B55"]!
private let p2611 = XcodeToolsProfile.all["17B100"]!
private let p263 = XcodeToolsProfile.all["17C529"]!

private func compile(_ xml: String, _ profile: XcodeToolsProfile) throws -> IBCompileResult {
    try StoryboardCompiler.compile(StoryboardParser.parse(Data(xml.utf8)), options: .flagset(named: "universal-16", root: corpusRoot), profile: profile)
}

private func corpus(_ name: String) throws -> String {
    try String(contentsOf: CorpusCase(name: name).storyboard, encoding: .utf8)
}

/// ibtool does not check `toolsVersion`; it refuses a document whose capability needs a newer Xcode than its own short
/// version (27.0, 26.3, 26.2, 26.1.1, 26.1, 26.0.1), with "This document requires at least Xcode X.". The compiler refuses it the same way under that
/// profile, naming the image's limit.
@Test func testStoryboardNewerThanPinRefused() throws {
    let base = try corpus("view-plain-default")
    let marker = #"<capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>"#
    #expect(base.contains(marker))
    func needing(_ v: String) -> String {
        base.replacingOccurrences(of: marker, with: #"<capability name="documents saved in the Xcode 8 format" minToolsVersion="\#(v)"/>"#)
    }
    _ = try compile(needing("27.0"), p27)
    _ = try compile(needing("26.2"), p26)
    _ = try compile(needing("26.0"), p2601)
    _ = try compile(needing("26.0.1"), p2601)
    _ = try compile(needing("26.1"), p261)
    _ = try compile(needing("26.1"), p2611)
    _ = try compile(needing("26.1.1"), p2611)
    _ = try compile(needing("26.2"), p263)
    _ = try compile(needing("26.3"), p263)
    for (v, profile) in [("27.0", p26), ("26.3", p26), ("26.3.1", p263), ("27.0", p263), ("27.1", p27), ("26.1", p2601), ("26.2", p2601), ("26.2", p261), ("27.0", p261), ("26.1.2", p2611), ("26.2", p2611), ("27.0", p2611)] {
        let e = try #require(throws: XlessError.self) { try compile(needing(v), profile) }
        #expect(e.stage == .ib)
        #expect(e.cause.hasPrefix("This document requires at least Xcode \(v)."), "\(e)")
        #expect(e.cause.contains("ibtool \(profile.ibtoolShortVersion)"), "\(e)")
        #expect(e.cause.contains(profile.xcodeBuild), "\(e)")
    }
    // A stale toolsVersion is not what ibtool refuses: 25098 (Xcode 27.0's) compiles under 26.2.
    _ = try compile(base.replacingOccurrences(of: #"toolsVersion="23727""#, with: #"toolsVersion="25098""#), p26)
    // A capability version that is not a version is refused, not ignored.
    let e = try #require(throws: XlessError.self) { try compile(needing("next"), p27) }
    #expect(e.cause.contains(#"minToolsVersion="next""#), "\(e)")
}

/// 17C52 writes a view nib of plain views with its own system color table, measured only for these colors
/// (`systemBlueColor` 0 122 255 there); another system color in such a nib is refused under that profile.
@Test func plainViewNibSystemColorsOutsideThe17C52MeasurementsAreRefused() throws {
    let red = try corpus("color-system-systemBlueColor").replacingOccurrences(of: "systemBlueColor", with: "systemRedColor")
    _ = try compile(red, p27)
    let e = try #require(throws: XlessError.self) { try compile(red, p26) }
    #expect(e.cause.contains(#"system color "systemRedColor""#), "\(e)")
    #expect(e.cause.contains("17C52"), "\(e)")
}

/// 17C52 shares the italic traits dictionary between italic system fonts only within a measured optical-size band
/// (≤ 13, 20, ≥ 28; `label-font-grid`). Two italic sizes where one is outside them are refused under that profile.
@Test func italicSizesOutsideThe17C52BandsAreRefusedWhenTheyMeet() throws {
    let one = try corpus("label-italic")
    _ = try compile(one, p26)  // a single italic font: nothing is shared, any size works
    let label = #"<fontDescription key="fontDescription" type="italicSystem" pointSize="17"/>"#
    #expect(one.contains(label))
    // Add a second italic label at 9 pt.
    guard let start = one.range(of: "<label "), let end = one.range(of: "</label>", range: start.upperBound..<one.endIndex) else {
        Issue.record("label-italic has no label"); return
    }
    var second = String(one[start.lowerBound..<end.upperBound]).replacingOccurrences(of: #"pointSize="17""#, with: #"pointSize="9""#)
    second = second.replacingOccurrences(of: #"id="([^"]+)""#, with: #"id="$1x""#, options: .regularExpression)
    let two = one.replacingCharacters(in: end.upperBound..<end.upperBound, with: "\n" + second)
    _ = try compile(two, p27)
    let e = try #require(throws: XlessError.self) { try compile(two, p26) }
    #expect(e.cause.contains("italic system fonts of 9 and 17 pt"), "\(e)")
}
