import Testing
import Foundation
@testable import XlessCore

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func tempEnv(_ text: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("known-xcodes-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("versions.env")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func parseEnvHandlesQuotesCommentsAndBlankLines() {
    let env = KnownXcodes.parseEnv("""
    # a comment

    A=1
    B="two words"
      C = 3
    D=
    E="x" # trailing
    not a line
    """)
    #expect(env["A"] == "1")
    #expect(env["B"] == "two words")
    #expect(env["D"] == "")
    #expect(env["E"] == "x")
    #expect(env["not a line"] == nil)
}

@Test func loadsTheRepositorysTable() throws {
    let xcodes = try KnownXcodes.load(versionsEnv: repoRoot.appendingPathComponent("versions.env"))
    #expect(xcodes.map(\.build) == ["17A400", "17B55", "17B100", "17C52", "27A266a", "27A9275", "27B52"])
    #expect(xcodes.map(\.appleSwift) == ["6.2", "6.2.1", "6.2.1", "6.2.3", "6.4", "6.4", "6.4.2"])
    #expect(xcodes.map(\.shortVersion) == ["26.0.1", "26.1", "26.1.1", "26.2", "27.0", "27.1", "27.2"])
    #expect(xcodes.map(\.buildMachineOSBuild) == ["26B123", "26B123", "26B123", "26A434", "26A434", "26B123", "26B123"])
    // 17C52: the Universal and the Apple silicon download; 17A400, 17B55, 17B100, 27A266a, 27A9275 and 27B52: one download each.
    #expect(xcodes.map(\.xipSHA256.count) == [1, 1, 1, 2, 1, 1, 1])
    #expect(xcodes.allSatisfy { $0.xipSHA256.allSatisfy { $0.wholeMatch(of: /[0-9a-f]{64}/) != nil } })
}

@Test func loadParsesSpaceSeparatedHashes() throws {
    let url = try tempEnv("""
    XCODE_RELEASES="AAA"
    XCODE_SHORT_AAA=1.0
    XCODE_APPLE_SWIFT_AAA=6.0
    XCODE_BUILD_MACHINE_OS_AAA=1B1
    XCODE_XIP_SHA256_AAA="aa bb"
    """)
    let x = try KnownXcodes.load(versionsEnv: url)
    #expect(x == [KnownXcode(build: "AAA", shortVersion: "1.0", appleSwift: "6.0", buildMachineOSBuild: "1B1", xipSHA256: ["aa", "bb"])])
}

@Test(arguments: ["XCODE_SHORT_AAA", "XCODE_APPLE_SWIFT_AAA", "XCODE_BUILD_MACHINE_OS_AAA"])
func loadThrowsWhenAKeyIsMissing(missing: String) throws {
    let all = ["XCODE_SHORT_AAA": "1.0", "XCODE_APPLE_SWIFT_AAA": "6.0", "XCODE_BUILD_MACHINE_OS_AAA": "1B1"]
    let body = all.filter { $0.key != missing }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    let url = try tempEnv("XCODE_RELEASES=\"AAA\"\n\(body)\n")
    #expect(throws: XlessError.self) { try KnownXcodes.load(versionsEnv: url) }
}

@Test func everyKnownXcodeIsSupportedEverywhere() throws {
    let envURL = repoRoot.appendingPathComponent("versions.env")
    let xcodes = try KnownXcodes.load(versionsEnv: envURL)
    let env = KnownXcodes.parseEnv(try String(contentsOf: envURL, encoding: .utf8))
    #expect(!xcodes.isEmpty)
    for x in xcodes {
        #expect(XcodeToolsProfile.all[x.build] != nil, "no XcodeToolsProfile for \(x.build)")
        let targetOS = repoRoot.appendingPathComponent("docker/toolchain/target-os/\(x.build).txt")
        #expect(FileManager.default.fileExists(atPath: targetOS.path), "no \(targetOS.lastPathComponent)")
        #expect((env["XCODE_SWIFT_\(x.build)"] ?? "").isEmpty == false, "no XCODE_SWIFT_\(x.build)")
    }
}
