import Testing
import Foundation
@testable import XlessPackage
@testable import XlessCore

private func makeApp(_ root: URL) throws -> URL {
    let app = root.appendingPathComponent("signed/X.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks/F.framework/Versions/A"), withIntermediateDirectories: true)
    try Data("bin".utf8).write(to: app.appendingPathComponent("X"))
    try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Frameworks/F.framework/Current").path, withDestinationPath: "Versions/A")
    return app
}

@Test func ipaHasPayloadLayoutAndKeepsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let ipa = try Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("out"))
    #expect(ipa.lastPathComponent == "X.ipa")
    let listing = try Shell.run("unzip", ["-Z1", ipa.path], stage: .package).stdout
    #expect(listing.contains("Payload/X.app/X"))
    let verbose = try Shell.run("zipinfo", [ipa.path], stage: .package).stdout
    #expect(verbose.contains("lrwx"))   // symlink preserved
}

@Test func ipaExcludesFinderAndAppleDoubleJunk() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    try Data("x".utf8).write(to: app.appendingPathComponent(".DS_Store"))
    try Data("x".utf8).write(to: app.appendingPathComponent("._X"))
    try Data("x".utf8).write(to: app.appendingPathComponent("Frameworks/F.framework/Versions/A/._F"))
    try Data("x".utf8).write(to: app.appendingPathComponent("Frameworks/.DS_Store"))
    let ipa = try Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("out"))
    let listing = try Shell.run("unzip", ["-Z1", ipa.path], stage: .package).stdout
    #expect(listing.contains("Payload/X.app/X"))
    #expect(!listing.contains(".DS_Store"))
    #expect(!listing.contains("._"))
}

/// The same app zips to the same .ipa bytes two seconds and more later (zip dates in 2 s steps): every entry carries the
/// app's own date, never the time of the copy, and `Payload/` is 755 whatever the umask (run under umask 002 locally).
@Test func ipaIsTheSameBytesLaterAndCarriesTheAppsDates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let date = Date(timeIntervalSince1970: 1_767_225_600)          // 2026-01-01 00:00:00 UTC, an even second
    for rel in try FileManager.default.subpathsOfDirectory(atPath: app.path).sorted(by: >) + [""] {
        try PkgBuilder.setLinkDate(rel.isEmpty ? app.path : app.appendingPathComponent(rel).path, date)
    }
    let first = try Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("a"))
    Thread.sleep(forTimeInterval: 2.1)
    let second = try Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("b"))
    #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    // zipinfo -T prints each entry's date as yyyymmdd.hhmmss in the local time zone, as zip stored it.
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = .current; format.dateFormat = "yyyyMMdd.HHmmss"
    let lines = try Shell.run("zipinfo", ["-T", first.path], stage: .package).stdout.split(separator: "\n").filter { $0.contains("Payload") }
    #expect(lines.count == 8, "\(lines)")   // Payload, X.app, X, Frameworks, F.framework, Current, Versions, A
    for line in lines { #expect(line.contains(" \(format.string(from: date)) "), "\(line)") }
    #expect(lines.contains { $0.hasPrefix("drwxr-xr-x") && $0.hasSuffix(" Payload/") })
}

private func ipaWithVersions(_ version: String, _ build: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    let app = try makeApp(root)
    try Plist.write(["CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleExecutable": "X"],
                    to: app.appendingPathComponent("Info.plist"), stage: .package)
    try Plist.write(["CFBundleVersion": "999"], to: app.appendingPathComponent("Frameworks/F.framework/Versions/A/Info.plist"), stage: .package)
    return try Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("out"))
}

@Test func uploadVersionsComeFromTheIPA() throws {
    let ipa = try ipaWithVersions("1.2.3", "29000000")
    let v = try IPAInfo.uploadVersions(ipa: ipa, buildOverride: nil)
    #expect(v.version == "1.2.3" && v.build == "29000000")
    #expect(try IPAInfo.uploadVersions(ipa: ipa, buildOverride: "29000000").build == "29000000")
}

@Test func uploadOverrideDisagreeingWithIPAFails() throws {
    let ipa = try ipaWithVersions("1.0.0", "41")
    do { _ = try IPAInfo.uploadVersions(ipa: ipa, buildOverride: "42"); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.description == "[upload] the .ipa has build 41 but --build-number/XLESS_BUILD_NUMBER is 42 — re-run from finalize or drop the override")
    }
}

@Test func notarizationKeyFileIsNormalizedPEM() throws {
    let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
    let mangled = pem.replacingOccurrences(of: "\n", with: "\\n") + "\r\n"
    #expect(try Packager.p8Contents(Secrets(env: ["ASC_KEY_P8": mangled])) == Data((pem + "\n").utf8))
}

@Test func ipaZipsTheBuildsDSYMsNextToIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let dSYMs = root.appendingPathComponent("dSYMs")
    for rel in ["X.app.dSYM/Contents/Resources/DWARF/X", "Pod/Pod.framework.dSYM/Contents/Resources/DWARF/Pod"] {
        let f = dSYMs.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dwarf".utf8).write(to: f)
    }
    let out = root.appendingPathComponent("out")
    _ = try Packager.ipa(signedApp: app, outputDir: out, dSYMs: dSYMs)
    let listing = try Shell.run("unzip", ["-Z1", out.appendingPathComponent("X.app.dSYM.zip").path], stage: .package).stdout
    #expect(listing.contains("X.app.dSYM/Contents/Resources/DWARF/X\n") && listing.contains("Pod/Pod.framework.dSYM/Contents/Resources/DWARF/Pod\n"))

    try FileManager.default.removeItem(at: dSYMs)
    _ = try Packager.ipa(signedApp: app, outputDir: out, dSYMs: dSYMs)
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("X.app.dSYM.zip").path))
}

/// A `dSYMs` directory holding `<name>.dSYM` with one DWARF file.
func makeDSYMs(_ root: URL, name: String) throws -> URL {
    let dSYMs = root.appendingPathComponent("dSYMs")
    let dwarf = dSYMs.appendingPathComponent("\(name).dSYM/Contents/Resources/DWARF/x")
    try FileManager.default.createDirectory(at: dwarf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("dwarf".utf8).write(to: dwarf)
    return dSYMs
}

@Test func zipDSYMsNamesTheZipAfterTheApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let app = root.appendingPathComponent("signed/Hello World.app")
    let dSYMs = try makeDSYMs(root, name: "Hello World.app")
    let zip = try #require(try Packager.zipDSYMs(dSYMs, app: app, into: out))
    #expect(zip.lastPathComponent == "Hello World.app.dSYM.zip")
    let listing = try Shell.run("unzip", ["-Z1", zip.path], stage: .package).stdout
    #expect(listing.contains("Hello World.app.dSYM/Contents/Resources/DWARF/x\n"))

    try FileManager.default.removeItem(at: zip)
    #expect(try Packager.zipDSYMs(nil, app: app, into: out) == nil)
    #expect(try Packager.zipDSYMs(root.appendingPathComponent("missing"), app: app, into: out) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}
