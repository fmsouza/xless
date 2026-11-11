import Testing
import Foundation
@testable import XlessCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
private func touch(_ url: URL) throws { try write("x", url) }

// MARK: - Finding the share directory

@Test func xlessShareEnvWins() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("bin/../share/xless/versions.env"))
    let root = try XlessShare.locate(env: ["XLESS_SHARE": "/somewhere/else"], executable: t.appendingPathComponent("bin/xless"))
    #expect(root.path == "/somewhere/else")
}

@Test func installedLayout() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("share/xless/versions.env"))
    let root = try XlessShare.locate(env: [:], executable: t.appendingPathComponent("bin/xless"))
    #expect(root.resolvingSymlinksInPath().path == t.appendingPathComponent("share/xless").path)
}

@Test func sourceCheckout() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("versions.env"))
    try touch(t.appendingPathComponent("docker/Dockerfile.base"))
    let root = try XlessShare.locate(env: [:], executable: t.appendingPathComponent(".build/release/xless"))
    #expect(root.resolvingSymlinksInPath().path == t.path)
}

@Test func sourceCheckoutNeedsTheDockerfileToo() throws {
    let t = try tempDir()
    try touch(t.appendingPathComponent("versions.env"))
    #expect(throws: XlessError.self) { try XlessShare.locate(env: [:], executable: t.appendingPathComponent(".build/release/xless")) }
}

@Test func nothingFound() throws {
    let t = try tempDir()
    do {
        _ = try XlessShare.locate(env: [:], executable: t.appendingPathComponent("bin/xless"))
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.stage == .sdk)
        #expect(e.cause == "cannot find xless's share directory")
        #expect(e.fix == "reinstall xless (see README) or set XLESS_SHARE")
    }
}

// MARK: - The share's release against the binary's

@Test func releaseReadsTheVersionFile() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    try write("XLESS_VERSION=0.0.0-dev\n", t.appendingPathComponent("versions.env"))
    #expect(XlessShare.release(of: t) == "0.3.1")
}

@Test func releaseFallsBackToVersionsEnv() throws {
    let t = try tempDir()   // a source checkout: no VERSION file
    try write("SWIFT_VERSION=6.4.0\nXLESS_VERSION=0.0.0-dev\n", t.appendingPathComponent("versions.env"))
    #expect(XlessShare.release(of: t) == "0.0.0-dev")
}

@Test func releaseIsNilWithoutARecord() throws {
    let t = try tempDir()
    try write("SWIFT_VERSION=6.4.0\n", t.appendingPathComponent("versions.env"))
    try write("  \n", t.appendingPathComponent("VERSION"))
    #expect(XlessShare.release(of: t) == nil)
}

@Test func theSameReleasePasses() throws {
    let t = try tempDir()
    try write("0.4.0\n", t.appendingPathComponent("VERSION"))
    #expect(try XlessShare.checkRelease(share: t, binary: "0.4.0", env: [:]) == nil)
}

@Test func anotherReleaseIsRefused() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    do {
        _ = try XlessShare.checkRelease(share: t, binary: "0.4.0", env: [:])
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.stage == .sdk)
        #expect(e.cause == "this xless is 0.4.0, but its share directory \(t.path) is from xless 0.3.1")
        #expect(e.fix.contains("curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | XLESS_VERSION=0.4.0 sh"))
        #expect(e.fix.contains("XLESS_ALLOW_SHARE_MISMATCH=1"))
    }
}

@Test func aSourceBuildIsToldToUseItsCheckout() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    do {
        _ = try XlessShare.checkRelease(share: t, binary: "0.0.0-dev", env: [:])
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.cause == "this xless is 0.0.0-dev, but its share directory \(t.path) is from xless 0.3.1")
        #expect(e.fix.contains("XLESS_SHARE=<the checkout it was built from>"))
        #expect(!e.fix.contains("install.sh"))
    }
}

@Test func aShareWithoutARecordIsRefused() throws {
    let t = try tempDir()
    try write("SWIFT_VERSION=6.4.0\n", t.appendingPathComponent("versions.env"))
    do {
        _ = try XlessShare.checkRelease(share: t, binary: "0.4.0", env: [:])
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.cause == "this xless is 0.4.0, but its share directory \(t.path) records no release (no VERSION file, no XLESS_VERSION in versions.env)")
    }
}

@Test func theEscapeHatchTurnsTheRefusalIntoAWarning() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    let warning = try XlessShare.checkRelease(share: t, binary: "0.4.0", env: ["XLESS_ALLOW_SHARE_MISMATCH": "1"])
    #expect(warning == "warning: this xless is 0.4.0, but its share directory \(t.path) is from xless 0.3.1; "
            + "going on because XLESS_ALLOW_SHARE_MISMATCH=1 (its scripts, Dockerfiles and pins may not match this binary)")
}

@Test func onlyOneOpensTheEscapeHatch() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    for v in ["0", "", "yes"] {
        #expect(throws: XlessError.self) { try XlessShare.checkRelease(share: t, binary: "0.4.0", env: ["XLESS_ALLOW_SHARE_MISMATCH": v]) }
    }
}

@Test func rootChecksTheInstalledShare() throws {
    let t = try tempDir()
    try write("XLESS_VERSION=0.3.1\n", t.appendingPathComponent("share/xless/versions.env"))
    try write("0.3.1\n", t.appendingPathComponent("share/xless/VERSION"))
    let exe = t.appendingPathComponent("bin/xless")
    #expect(throws: XlessError.self) { try XlessShare.root(env: [:], executable: exe, binary: "0.4.0") }
    var warnings: [String] = []
    let root = try XlessShare.root(env: ["XLESS_ALLOW_SHARE_MISMATCH": "1"], executable: exe, binary: "0.4.0") { warnings.append($0) }
    #expect(root.resolvingSymlinksInPath().path == t.appendingPathComponent("share/xless").path)
    #expect(warnings.count == 1)
    _ = try XlessShare.root(env: [:], executable: exe, binary: "0.3.1") { warnings.append($0) }
    #expect(warnings.count == 1)
}

@Test func rootChecksAnExplicitShareToo() throws {
    let t = try tempDir()
    try write("0.3.1\n", t.appendingPathComponent("VERSION"))
    #expect(throws: XlessError.self) {
        try XlessShare.root(env: ["XLESS_SHARE": t.path], executable: t.appendingPathComponent("bin/xless"), binary: "0.4.0")
    }
}

@Test func thisCheckoutMatchesThisBinary() throws {
    // The repository is the share of a source build: its versions.env and the source tree's version agree.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(try XlessShare.checkRelease(share: repo, binary: XlessVersion.current, env: [:]) == nil)
}
