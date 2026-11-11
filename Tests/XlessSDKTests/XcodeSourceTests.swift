import Testing
import Foundation
import Crypto
@testable import XlessSDK
@testable import XlessCore

private func tempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-source-\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

/// Bytes standing in for an Xcode .xip (not Apple's file); the table entry is their own SHA-256.
private let fakeXipBytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
private let fakeXipHash = SHA256.hash(data: fakeXipBytes).map { String(format: "%02x", $0) }.joined()

private let known = [
    KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: []),
    KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: ["00ff", fakeXipHash]),
]

private func fakeApp(_ dir: URL, name: String, build: String) throws -> URL {
    let app = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": "27.0", "ProductBuildVersion": build]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/version.plist"))
    return app
}

@Test func xipIsIdentifiedByContentWhateverItsNameAndPathSpelling() throws {
    let dir = try tempDir("xip with spaces")
    let xip = dir.appendingPathComponent("My Xcode copy.xip")
    try fakeXipBytes.write(to: xip)

    // Absolute path with spaces.
    let a = try XcodeSource.identify(path: xip.path, known: known, cwd: URL(fileURLWithPath: "/"), home: URL(fileURLWithPath: "/nonexistent"))
    #expect(a.xcode.build == "27A266a")
    #expect(a.kind == .xip)
    #expect(a.url.resolvingSymlinksInPath().path == xip.path)

    // ~/…: the home is the temp dir's parent.
    let home = dir.deletingLastPathComponent()
    let b = try XcodeSource.identify(path: "~/\(dir.lastPathComponent)/My Xcode copy.xip", known: known,
                                     cwd: URL(fileURLWithPath: "/"), home: home)
    #expect(b.xcode.build == "27A266a")
    #expect(b.url.resolvingSymlinksInPath().path == xip.path)

    // Relative to the working directory.
    let c = try XcodeSource.identify(path: "./My Xcode copy.xip", known: known, cwd: dir, home: home)
    #expect(c.xcode.build == "27A266a")
    #expect(c.url.resolvingSymlinksInPath().path == xip.path)
    let d = try XcodeSource.identify(path: "My Xcode copy.xip", known: known, cwd: dir, home: home)
    #expect(d.url.path == c.url.path)

    // A renamed .xip, no extension at all.
    let renamed = dir.appendingPathComponent("Xcode_27")
    try fakeXipBytes.write(to: renamed)
    #expect(try XcodeSource.identify(path: renamed.path, known: known, cwd: dir, home: home).kind == .xip)
}

@Test func aOneByteDifferentXipIsNotSupportedAndTheErrorListsBothReleases() throws {
    let dir = try tempDir("bad-xip")
    var bytes = fakeXipBytes
    bytes[bytes.count / 2] ^= 1
    let xip = dir.appendingPathComponent("Xcode_27.0.xip")
    try bytes.write(to: xip)
    do {
        _ = try XcodeSource.identify(path: xip.path, known: known, cwd: dir, home: dir)
        Issue.record("a one-byte-different .xip was accepted")
    } catch let e as XlessError {
        #expect(e.stage == .sdk)
        #expect(e.cause == "\(xip.path) is not a supported Xcode (supported: Xcode 26.2 (17C52), Xcode 27.0 (27A266a))")
        #expect(e.fix == "download the Universal Xcode 26.2 or 27.0 .xip from https://developer.apple.com/download/all/ (free Apple ID)")
    }
}

@Test func appIsIdentifiedByItsVersionPlist() throws {
    let dir = try tempDir("app")
    let app = try fakeApp(dir, name: "Xcode-beta.app", build: "27A266a")
    let id = try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir)
    #expect(id.xcode.build == "27A266a")
    #expect(id.kind == .app)
}

@Test func anUnsupportedAppBuildThrows() throws {
    let dir = try tempDir("app-27.1")
    let app = try fakeApp(dir, name: "Xcode.app", build: "27A9275")
    #expect(throws: XlessError.self) { try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir) }
    do { _ = try XcodeSource.identify(path: app.path, known: known, cwd: dir, home: dir) } catch let e as XlessError {
        #expect(e.cause.contains("Xcode 26.2 (17C52), Xcode 27.0 (27A266a)"))
    }
}

@Test func aMissingPathThrows() throws {
    let dir = try tempDir("missing")
    #expect(throws: XlessError.self) { try XcodeSource.identify(path: "nope.xip", known: known, cwd: dir, home: dir) }
}

@Test func streamingSHA256MatchesOneShot() throws {
    let dir = try tempDir("sha")
    let f = dir.appendingPathComponent("f")
    try fakeXipBytes.write(to: f)
    #expect(try XcodeSource.sha256(of: f, chunkSize: 4096) == fakeXipHash)
}

/// The process's peak resident set size in bytes: getrusage's ru_maxrss (bytes) on Darwin, /proc's VmHWM (kB) on Linux.
private func peakRSS() -> Int64 {
    #if canImport(Darwin)
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Int64(u.ru_maxrss)
    #else
    let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
    let line = status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") } ?? ""
    return (Int64(line.split(separator: " ").dropFirst().first ?? "") ?? 0) * 1024
    #endif
}

/// An Xcode .xip is several GB: hashing it must not hold the file in memory (on Darwin, autoreleased chunks pile up
/// unless they are drained). A sparse 2 GB file (no disk used) is hashed and the peak RSS may grow by 256 MB at most.
@Test func hashingAMultiGBFileKeepsMemoryFlat() throws {
    let dir = try tempDir("big")
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("sparse.xip")
    guard FileManager.default.createFile(atPath: f.path, contents: nil),
          let h = try? FileHandle(forWritingTo: f), (try? h.truncate(atOffset: 2 << 30)) != nil else { return }  // skip: no sparse file
    try h.close()
    let before = peakRSS()
    _ = try XcodeSource.sha256(of: f)
    let grew = peakRSS() - before
    #expect(grew < 256 << 20, "hashing 2 GB raised the peak RSS by \(grew >> 20) MB")
}

// MARK: - An SDK export reused in place of the Xcode (issue #51)

/// A fake SDK export as `xless setup` leaves it: `<arch>/darwin.xtoolsdk` per architecture, and toolchain-meta.json
/// naming the Xcode build (`metaBuild` nil: no metadata, as after a run stopped between the export and the metadata).
private func fakeExport(_ parent: URL, name: String = "xcode27.0-27A266a", archs: [String] = ["arm64"],
                        metaBuild: String? = "27A266a") throws -> URL {
    let dir = parent.appendingPathComponent(name)
    for a in archs {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("\(a)/darwin.xtoolsdk/Developer"), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let metaBuild {
        try ToolchainMeta(xcodeVersion: "2700", xcodeBuild: metaBuild, buildMachineOSBuild: "26A434", compiler: ToolchainMeta.clangCompiler,
                          platforms: [:]).write(to: dir.appendingPathComponent("toolchain-meta.json"))
    }
    return dir
}

@Test func anExportIsIdentifiedByItsToolchainMetaWhateverItsName() throws {
    let dir = try tempDir("export-meta")
    let export = try fakeExport(dir, name: "my export")
    let id = try XcodeSource.identifyExport(path: "my export", known: known, cwd: dir, home: dir)
    #expect(id.xcode.build == "27A266a")
    #expect(id.kind == .export)
    #expect(id.url.path == export.path)
}

@Test func anExportWithoutMetadataIsIdentifiedByItsDirectoryName() throws {
    let dir = try tempDir("export-name")
    _ = try fakeExport(dir, name: "xcode26.2-17C52", metaBuild: nil)
    #expect(try XcodeSource.identifyExport(path: "xcode26.2-17C52", known: known, cwd: dir, home: dir).xcode.build == "17C52")
}

@Test func anExportOfAnUnsupportedXcodeIsRefusedWithTheSupportedReleases() throws {
    let dir = try tempDir("export-unsupported")
    let export = try fakeExport(dir, name: "xcode27.1-27A9275", metaBuild: "27A9275")
    #expect { try XcodeSource.identifyExport(path: export.path, known: known, cwd: dir, home: dir) } throws: {
        ($0 as? XlessError)?.cause == "\(export.path) is an SDK export of Xcode build 27A9275, not a supported Xcode (supported: Xcode 26.2 (17C52), Xcode 27.0 (27A266a))"
    }
}

@Test func aDirectoryThatIsNotAnExportIsRefusedNamingTheLayout() throws {
    let dir = try tempDir("export-not")
    let export = try fakeExport(dir)
    // The architecture's directory, not the export's: the fix names the export (its parent).
    #expect { try XcodeSource.identifyExport(path: export.appendingPathComponent("arm64").path, known: known, cwd: dir, home: dir) } throws: {
        let e = $0 as? XlessError
        return e?.cause == "\(export.path)/arm64 holds no SDK export (<arch>/darwin.xtoolsdk)" && e?.fix.contains("--sdk \(export.path)") == true
    }
    #expect { try XcodeSource.identifyExport(path: "nope", known: known, cwd: dir, home: dir) } throws: {
        ($0 as? XlessError)?.cause == "\(dir.path)/nope does not exist"
    }
}

@Test func onlyCompleteArchitecturesCountAsExported() throws {
    let dir = try tempDir("export-archs")
    let export = try fakeExport(dir, archs: ["arm64"])
    // A leftover of an interrupted export is never one.
    try FileManager.default.createDirectory(at: export.appendingPathComponent("amd64.partial/darwin.xtoolsdk"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: export.appendingPathComponent("amd64"), withIntermediateDirectories: true)
    #expect(XcodeSource.exportedArchs(export) == ["arm64"])
    #expect(throws: Never.self) { try XcodeSource.checkExport(export, holds: ["arm64"]) }
    #expect { try XcodeSource.checkExport(export, holds: ["arm64", "amd64"]) } throws: {
        let e = $0 as? XlessError
        return e?.cause == "the SDK export \(export.path) holds no amd64 SDK (it holds arm64)" && e?.fix.contains("--xcode") == true
    }
}

@Test func theCachesOneExportIsFoundWhenNoXcodeIsGiven() throws {
    let cache = try tempDir("export-cache")
    // No cache at all, then an empty one: refused, naming --xcode.
    for _ in 0..<2 {
        #expect { try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["arm64"]) } throws: {
            let e = $0 as? XlessError
            return e?.cause == "no --xcode, and no SDK export under \(cache.path)/sdk to reuse" && e?.fix.contains("xless setup --xcode") == true
        }
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("sdk"), withIntermediateDirectories: true)
    }
    let sdk = cache.appendingPathComponent("sdk")
    // An export of an Xcode no longer supported is not a candidate; the refusal says it was skipped.
    _ = try fakeExport(sdk, name: "xcode25.0-16A242d", metaBuild: "16A242d")
    #expect { try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["arm64"]) } throws: {
        ($0 as? XlessError)?.cause == "no --xcode, and no SDK export under \(sdk.path) to reuse (skipped xcode25.0-16A242d: not a supported Xcode)"
    }
    let x27 = try fakeExport(sdk, name: "xcode27.0-27A266a", archs: ["arm64"])
    let found = try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["arm64"])
    #expect(found.xcode.build == "27A266a" && found.kind == .export && found.url.path == x27.path)
    // None holds amd64: refused, naming what each one holds.
    #expect { try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["amd64"]) } throws: {
        let e = $0 as? XlessError
        return e?.cause == "no SDK export under \(sdk.path) holds amd64 (xcode27.0-27A266a holds arm64)" && e?.fix.contains("--xcode") == true
    }
    // Two exports of supported Xcodes: the one holding the architectures wins; when both do, refused, listing both.
    _ = try fakeExport(sdk, name: "xcode26.2-17C52", archs: ["amd64"], metaBuild: "17C52")
    #expect(try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["amd64"]).xcode.build == "17C52")
    _ = try fakeExport(sdk, name: "xcode26.2-17C52", archs: ["arm64"], metaBuild: "17C52")
    #expect { try XcodeSource.findExport(cacheRoot: cache, known: known, archs: ["arm64"]) } throws: {
        let e = $0 as? XlessError
        return e?.cause == "\(sdk.path) holds 2 SDK exports for arm64 (xcode26.2-17C52, xcode27.0-27A266a)"
            && e?.fix == "pick one: xless setup --sdk \(sdk.path)/xcode27.0-27A266a (or --xcode <Xcode .xip or Xcode.app>)"
    }
}
