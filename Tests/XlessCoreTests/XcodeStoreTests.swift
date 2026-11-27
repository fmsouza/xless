import Testing
import Foundation
@testable import XlessCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-store-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makePack(in store: URL, xcode: String, build: String, arch: String = "arm64", parts: [String: String] = ["sdk": "h"]) throws -> URL {
    let dir = store.appendingPathComponent(XcodePack.name(xcode: xcode, build: build, arch: arch))
    try PackManifest(format: 1, xcode: xcode, build: build, arch: arch, swift: "6.2.3", mode: .own, parts: parts)
        .write(to: dir.appendingPathComponent("pack.json"))
    return dir
}

private func resolve(_ store: URL, pin: String? = nil, arch: String = "arm64", order: [String] = [], needs: Set<XcodeResolver.Need> = [.sdk],
                     extra: [String: String] = [:], expected: @escaping (XcodePack, PackPart) -> String? = { _, _ in nil }) throws -> XcodePack {
    try XcodeResolver.resolve(env: ["XLESS_XCODES": store.path].merging(extra) { $1 }, pin: pin, arch: arch, order: order, needs: needs, expected: expected)
}

private func problem(_ body: () throws -> Any) -> XcodeProblem? {
    do { _ = try body(); return nil } catch { return error as? XcodeProblem }
}

@Test func explicitPackWins() throws {
    let store = try tempDir(), other = try tempDir()
    try makePack(in: store, xcode: "27.0", build: "18A1")
    let explicit = try makePack(in: other, xcode: "26.2", build: "17C52")
    let p = try resolve(store, extra: ["XLESS_XCODE": explicit.path])
    #expect(p.root.path == explicit.path)
}

@Test func explicitPathThatIsNoPackIsRefused() throws {
    let store = try tempDir(), empty = try tempDir()
    let e = problem { try resolve(store, extra: ["XLESS_XCODE": empty.path]) }
    #expect(e?.cause.contains("XLESS_XCODE names \(empty.path), which is no Xcode pack") == true)
}

@Test func explicitPackIsStillChecked() throws {
    let other = try tempDir()
    let explicit = try makePack(in: other, xcode: "26.2", build: "17C52")
    let e = problem { try resolve(other, needs: [.swiftBuild], extra: ["XLESS_XCODE": explicit.path]) }
    #expect(e?.cause.contains("no Swift Build") == true)
}

@Test func pinChoosesThatVersion() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    try makePack(in: store, xcode: "27.0", build: "18A1")
    #expect(try resolve(store, pin: "26.2").manifest.build == "17C52")
    #expect(try resolve(store, pin: "26.2.0").manifest.build == "17C52")
}

@Test func twoBuildsOfOneVersionTakeTheLaterInTheTable() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.1", build: "17B55")
    try makePack(in: store, xcode: "26.1", build: "17B100")
    #expect(try resolve(store, pin: "26.1", order: ["17B55", "17B100"]).manifest.build == "17B100")
    #expect(try resolve(store, pin: "26.1", order: ["17B100", "17B55"]).manifest.build == "17B55")
}

@Test func noPinTakesTheNewestXcode() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    try makePack(in: store, xcode: "27.0", build: "18A1")
    #expect(try resolve(store).manifest.xcode == "27.0")
    let numeric = try tempDir()
    try makePack(in: numeric, xcode: "26.9", build: "A")
    try makePack(in: numeric, xcode: "26.10", build: "B")
    #expect(try resolve(numeric).manifest.xcode == "26.10")
}

@Test func directoryWithoutManifestIsSkipped() throws {
    let store = try tempDir()
    let dir = store.appendingPathComponent("26.2-17C52-arm64")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("config"), withIntermediateDirectories: true)
    #expect(XcodeStore(root: store).packs().isEmpty)
    let e = problem { try resolve(store, pin: "26.2") }
    #expect(e?.cause.contains("no pack") == true)
    #expect(e?.fix.contains("xless setup --xcode") == true)
}

@Test func brokenManifestIsSkippedButNamedWhenItWouldHaveBeenChosen() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.1", build: "17B55")
    let bad = store.appendingPathComponent("26.2-17C52-arm64")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try "{ nope".write(to: bad.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
    #expect(XcodeStore(root: store).packs().count == 1)
    let e = problem { try resolve(store, pin: "26.2") }
    #expect(e?.cause.contains("26.2-17C52-arm64") == true)
    #expect(e?.cause.contains("pack.json") == true)
    // The pack of another version is not touched by it.
    #expect(try resolve(store, pin: "26.1").manifest.build == "17B55")
    // Without a pin the broken one is the newest.
    #expect(problem { try resolve(store) }?.cause.contains("26.2-17C52-arm64") == true)
}

@Test func onlyTheOtherArchitecture() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52", arch: "amd64")
    let e = problem { try resolve(store, pin: "26.2", arch: "arm64") }
    #expect(e?.cause.contains("amd64") == true)
    #expect(e?.cause.contains("arm64") == true)
    #expect(e?.fix.contains("--arch arm64") == true)
}

@Test func emptyStoreIsNoPack() throws {
    let e = problem { try resolve(try tempDir().appendingPathComponent("none")) }
    #expect(e?.cause.contains("no pack") == true)
}

@Test func stalePartIsRefused() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    let e = problem { try resolve(store, expected: { _, _ in "other" }) }
    #expect(e?.cause.contains("another recipe") == true)
    #expect(e?.fix.contains("SDK export in the cache") == true)
}

@Test func missingNeededPartIsRefused() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    let e = problem { try resolve(store, needs: [.swiftBuild]) }
    #expect(e?.cause.contains("no Swift Build") == true)
}

@Test func unknownExpectedHashIsNotStale() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    #expect(try resolve(store, expected: { _, _ in nil }).manifest.build == "17C52")
}

@Test func defaultRootIsUnderTheNativeLayout() {
    #expect(XcodeStore(env: ["XLESS_NATIVE_HOME": "/n"]).root.path == "/n/xcodes")
    #expect(XcodeStore(env: ["XLESS_NATIVE_HOME": "/n", "XLESS_XCODES": "/x"]).root.path == "/x")
}

@Test func canonicalVersionDropsAZeroPatch() {
    #expect(XcodeVersion.canonical("26.2.0") == "26.2")
    #expect(XcodeVersion.canonical("26") == "26.0")
    #expect(XcodeVersion.canonical("26.2.1") == "26.2.1")
}
