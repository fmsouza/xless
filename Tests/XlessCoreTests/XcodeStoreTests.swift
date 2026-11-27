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

// A broken pack of the other architecture is not this machine's: it neither stops nor hides the pack this one uses.
@Test func aBrokenPackOfTheOtherArchitectureIsNotThisMachines() throws {
    let store = try tempDir()
    defer { try? FileManager.default.removeItem(at: store) }
    try makePack(in: store, xcode: "26.2", build: "17C52")
    let bad = store.appendingPathComponent("27.0-27A266a-amd64")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try "{ nope".write(to: bad.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
    #expect(try resolve(store).manifest.build == "17C52")
    #expect(try resolve(store, pin: "26.2").manifest.build == "17C52")
}

// A pin and a pack's own version are compared as versions: a pack.json that spells 26.2 as 26.2.0 is the pin's.
@Test func aPinFindsAPackWhoseVersionIsSpelledOtherwise() throws {
    let store = try tempDir()
    defer { try? FileManager.default.removeItem(at: store) }
    try makePack(in: store, xcode: "26.2.0", build: "17C52")
    #expect(try resolve(store, pin: "26.2").manifest.build == "17C52")
    #expect(try resolve(store, pin: "26.2.0").manifest.build == "17C52")
}

@Test func onlyTheOtherArchitecture() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52", arch: "amd64")
    let e = problem { try resolve(store, pin: "26.2", arch: "arm64") }
    #expect(e?.cause.contains("amd64") == true)
    #expect(e?.cause.contains("arm64") == true)
    #expect(e?.fix.contains("on this arm64 machine") == true && e?.fix.contains("--arch") == false)
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
    #expect(e?.fix.contains("xless setup --sdk ") == true)
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

@Test func aPackBeingPreparedOrSwappedIsNoPackOfTheStore() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    for leftover in ["26.2-17C52-arm64.partial", "27.0-27A266a-arm64.partial", "26.2-17C52-arm64.old"] {
        try PackManifest(format: 1, xcode: "27.0", build: "27A266a", arch: "arm64", swift: "6.4.0", mode: .own, parts: ["sdk": "h"])
            .write(to: store.appendingPathComponent(leftover).appendingPathComponent("pack.json"))
    }
    #expect(XcodeStore(root: store).packs().map(\.root.lastPathComponent) == ["26.2-17C52-arm64"])
    #expect(try resolve(store).manifest.xcode == "26.2")
}

// The fixes are commands to run: the setup that prepares from the cached export, else from the .xip; for a missing or stale
// part, the export of that pack's Xcode by its path, and what to do where the pack is read-only (a container); for a missing
// Swift Build part, the setup of the image (a native setup prepares none).
@Test func theFixesAreCommands() throws {
    let store = try tempDir()
    let none = problem { try resolve(store, pin: "26.2") }
    #expect(none?.fix == "xless setup (it prepares the pack from the SDK export in the cache when there is one), else xless setup --xcode <path to Xcode 26.2's .app or .xip>")
    try makePack(in: store, xcode: "26.2", build: "17C52")
    let env = ["HOME": "/home/me"]
    let missing = problem { try resolve(store, needs: [.swiftBuild], extra: env) }
    let stale = problem { try resolve(store, extra: env, expected: { _, _ in "other" }) }
    let fix = "xless setup --sdk /home/me/.cache/xless/sdk/xcode26.2-17C52 prepares it (without that SDK export: xless setup --xcode <path to Xcode 26.2's .app or .xip>); "
        + "in a container, whose pack is read-only, run xless setup --docker --sdk <that export> on the host instead, then start the container again"
    #expect(stale?.fix == fix)
    // a missing Swift Build part: a native setup prepares none, only a setup of the image does
    #expect(missing?.fix == "only a pack prepared in xless's image has Swift Build: xless setup --docker --sdk /home/me/.cache/xless/sdk/xcode26.2-17C52 prepares it; "
        + "then build with xless run --docker, or in a container of that image (docs/images.md#using-the-image-directly)")
    let cached = problem { try resolve(store, extra: ["HOME": "/home/me", "XDG_CACHE_HOME": "/c"], expected: { _, _ in "other" }) }
    #expect(cached?.fix.hasPrefix("xless setup --sdk /c/xless/sdk/xcode26.2-17C52 prepares it") == true)
    let cachedSwiftBuild = problem { try resolve(store, needs: [.swiftBuild], extra: ["HOME": "/home/me", "XDG_CACHE_HOME": "/c"]) }
    #expect(cachedSwiftBuild?.fix.contains("xless setup --docker --sdk /c/xless/sdk/xcode26.2-17C52 prepares it") == true)
}

// XLESS_XCODE's pack is checked as a store's is: of this machine's architecture, and of this xless's pack format.
@Test func anExplicitPackOfAnotherArchitectureOrFormatIsRefused() throws {
    let store = try tempDir(), other = try tempDir()
    let amd = try makePack(in: other, xcode: "26.2", build: "17C52", arch: "amd64")
    let e = problem { try resolve(store, arch: "arm64", extra: ["XLESS_XCODE": amd.path]) }
    #expect(e?.cause == "XLESS_XCODE names \(amd.path), a pack for amd64, which this arm64 machine cannot use")
    let old = other.appendingPathComponent("26.2-17C52-arm64")
    try PackManifest(format: PackRecipe.format + 1, xcode: "26.2", build: "17C52", arch: "arm64", swift: "6.2.3", mode: .own, parts: ["sdk": "h"])
        .write(to: old.appendingPathComponent("pack.json"))
    let f = problem { try resolve(store, extra: ["XLESS_XCODE": old.path]) }
    #expect(f?.cause == "the pack 26.2-17C52-arm64 is of pack format \(PackRecipe.format + 1), and this xless uses format \(PackRecipe.format)")
    // In the store too.
    let g = problem { try resolve(other, pin: "26.2") }
    #expect(g?.cause.contains("pack format") == true)
}

// A pack.json that is there but cannot be read is said to be unreadable, not missing.
@Test func anUnreadableManifestIsSaidToBeUnreadable() throws {
    let other = try tempDir()
    let root = try makePack(in: other, xcode: "26.2", build: "17C52")
    let file = root.appendingPathComponent("pack.json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
    guard (try? Data(contentsOf: file)) == nil else { return } // root reads it anyway
    let e = problem { try resolve(try tempDir(), extra: ["XLESS_XCODE": root.path]) }
    #expect(e?.cause.contains("cannot be read") == true && e?.cause.contains("not found") == false, "\(String(describing: e))")
    do { _ = try PackManifest.load(from: file); Issue.record("expected a throw") } catch let x as XlessError {
        #expect(x.cause.contains("cannot be read") && !x.cause.contains("not found"), "\(x.cause)")
    }
}
