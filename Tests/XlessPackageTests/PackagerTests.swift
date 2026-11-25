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
    #expect(try Notary.p8Contents(Secrets(env: ["ASC_KEY_P8": mangled])) == Data((pem + "\n").utf8))
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

/// What a build leaves in the symbols is a name, not an option: `zip` runs what `--unzip-command` says.
@Test func aNameAmongTheSymbolsIsNoOptionOfZip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let dSYMs = try makeDSYMs(root, name: "A.app")
    let names = ["-T", "-@", "-", "@", "--unzip-command=touch ran;:"]
    for name in names { try Data("x".utf8).write(to: dSYMs.appendingPathComponent(name)) }
    let zip = try #require(try Packager.zipDSYMs(dSYMs, app: root.appendingPathComponent("A.app"), into: out))
    let left = try FileManager.default.contentsOfDirectory(atPath: dSYMs.path)
    #expect(!left.contains("ran"))
    let listing = try Shell.run("unzip", ["-Z1", zip.path], stage: .package).stdout.split(separator: "\n").map(String.init)
    for name in names + ["A.app.dSYM/Contents/Resources/DWARF/x"] { #expect(listing.contains(name), "\(name): \(listing)") }
}

@Test func linkedSymbolsAreNotPackaged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out"), elsewhere = root.appendingPathComponent("home"), link = root.appendingPathComponent("dSYMs")
    for dir in [out, elsewhere] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try Data("x".utf8).write(to: elsewhere.appendingPathComponent("private"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
    #expect(throws: XlessError.self) { _ = try Packager.zipDSYMs(link, app: root.appendingPathComponent("A.app"), into: out) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
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

// MARK: - The notarized zip (xless.yml's macOS app)

private let notarySecrets = Secrets(env: ["ASC_KEY_ID": "KEYID", "ASC_ISSUER_ID": "issuer", "ASC_KEY_P8": "very-secret"])

/// The zip of a macOS app, with `notary` in place of rcodesign's submission: it is given the app it would staple.
private func notarizedZip(_ root: URL, failure: XlessError? = nil, log: String = "", staple: (URL) throws -> Void) throws -> URL {
    let app = root.appendingPathComponent("signed/X.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Data("bin".utf8).write(to: app.appendingPathComponent("Contents/MacOS/X"))
    return try Packager.notarizedZip(signedApp: app, outputDir: root.appendingPathComponent("out"), secrets: notarySecrets, encodeKey: { args in
        // The key is a file of mode 0600 in a directory of mode 0700, gone with the call.
        let p8 = args[args.count - 1], json = args[2]
        let fm = FileManager.default
        #expect(try String(contentsOfFile: p8, encoding: .utf8) == "very-secret\n")
        #expect((try fm.attributesOfItem(atPath: p8)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try fm.attributesOfItem(atPath: (p8 as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((json as NSString).deletingLastPathComponent == (p8 as NSString).deletingLastPathComponent)
        // rcodesign writes into a file that is already private, not one whose mode it chooses.
        #expect(((try? fm.attributesOfItem(atPath: json))?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data(p8.utf8).write(to: root.appendingPathComponent("p8-path"))
    }, submit: { args in
        #expect(args.first == "notary-submit" && args.contains("--staple"))
        try staple(URL(fileURLWithPath: args[args.count - 1]))
        return Notary.Run(log: log, failure: failure)
    })
}

private func stapleTicket(_ app: URL) throws { try Data("ticket".utf8).write(to: app.appendingPathComponent("Contents/CodeResources")) }

@Test func theNotarizedZipHoldsTheStapledApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
    let zip = try notarizedZip(root, staple: stapleTicket)
    #expect(zip.lastPathComponent == "X-macOS.zip")
    let listing = try Shell.run("unzip", ["-Z1", zip.path], stage: .package).stdout
    #expect(listing.contains("X.app/Contents/CodeResources\n") && listing.contains("X.app/Contents/MacOS/X\n"))
    let p8 = try String(contentsOf: root.appendingPathComponent("p8-path"), encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: (p8 as NSString).deletingLastPathComponent))
}

/// The submission takes minutes, with the key in a file that rcodesign reads: it goes, however it was written, when a signal
/// ends xless meanwhile.
@Test func aSignalDuringTheSubmissionRemovesTheKeyThatRcodesignReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("directory").path
    await #expect(processExitsWith: .signal(SIGTERM)) { [note = note as String] in
        signal(SIGTERM, SIG_DFL)
        try Notary.notarize(URL(fileURLWithPath: "/x.dmg"), secrets: Secrets(env: ["ASC_KEY_ID": "KEYID", "ASC_ISSUER_ID": "issuer", "ASC_KEY_P8": "very-secret"]), encodeKey: { args in
            try Data("the whole key".utf8).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
            try Data((args[2] as NSString).deletingLastPathComponent.utf8).write(to: URL(fileURLWithPath: note))
        }, run: { _ in
            kill(getpid(), SIGTERM)
            sleep(20)
            return Notary.Run(log: "", failure: nil)
        })
    }
    let directory = try String(contentsOfFile: note, encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: directory))
}

@Test func aRejectedZipIsReportedAsTheDMGIs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
    let exit1 = XlessError(.package, "`rcodesign notary-submit` exited with 1", fix: "see the tool output above")
    do {
        _ = try notarizedZip(root, failure: exit1, log: "poll state after 10s: Invalid\n") { _ in }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.exitCode == 16)
        #expect(e.description == "[package] notarization of X.app was rejected (Invalid) — read the notary log printed above, fix the reported binaries, then re-run from package")
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out/X-macOS.zip").path))
    let p8 = try String(contentsOf: root.appendingPathComponent("p8-path"), encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: (p8 as NSString).deletingLastPathComponent))
}

@Test func aFailedSubmissionOfAZipNamesItsID() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
    let id = "12345678-1234-1234-1234-123456789abc"
    let exit1 = XlessError(.package, "`rcodesign notary-submit` exited with 1", fix: "see the tool output above")
    do {
        _ = try notarizedZip(root, failure: exit1, log: "created submission ID: \(id)\nerror sending request\n") { _ in }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause == "`rcodesign notary-submit` exited with 1 (notary submission \(id))")
    }
}

@Test func anAppWithoutATicketIsNotZipped() throws {
    for staple: (URL) throws -> Void in [{ _ in }, { app in
        // an old layout's link to the signature's own CodeResources is no ticket
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/CodeResources").path, withDestinationPath: "MacOS/X")
    }, { app in try Data().write(to: app.appendingPathComponent("Contents/CodeResources")) }] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try notarizedZip(root, staple: staple)
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.exitCode == 16 && e.cause == "X.app has no stapled notarization ticket after notary-submit --staple")
        }
    }
}

// MARK: - What a build may leave

/// Names are a file's, and no pattern of `unzip`.
@Test(arguments: ["X [beta].app", "X*?.app", "X\\a.app", "-x.app", "\u{dc}x.app", "X[\u{301}b]\u{301}*\u{301}.app"])
func theVersionsOfAnIPAAreThoseOfItsAppWhateverItsName(_ name: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("signed/\(name)")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Plist.write(["CFBundleShortVersionString": "1.2", "CFBundleVersion": "3"], to: app.appendingPathComponent("Info.plist"), stage: .package)
    let versions = try IPAInfo.versions(ipa: Packager.ipa(signedApp: app, outputDir: root.appendingPathComponent("out")))
    #expect(versions.version == "1.2" && versions.build == "3")
}

/// A thin arm64 Mach-O of `filetype` (MH_EXECUTE 2, MH_DSYM 0xa) whose LC_UUID is 16 bytes of `uuid`.
private func machO(uuid: UInt8, filetype: UInt32) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(filetype); u32(1); u32(24); u32(0); u32(0)
    u32(0x1b); u32(24); d.append(Data(repeating: uuid, count: 16))
    return d
}

/// A signed app with one executable, and the directory of its build's dSYMs, with the executable's.
private func appWithDSYMs() throws -> (root: URL, app: URL, dSYMs: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID())"), app = root.appendingPathComponent("signed/X.app"), dSYMs = root.appendingPathComponent("dSYMs")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try machO(uuid: 0x11, filetype: 2).write(to: app.appendingPathComponent("X"))
    try addDSYM("X.app.dSYM", 0x11, to: dSYMs)
    return (root, app, dSYMs)
}

private func addDSYM(_ path: String, _ uuid: UInt8, to dSYMs: URL) throws {
    let dwarf = dSYMs.appendingPathComponent("\(path)/Contents/Resources/DWARF/X")
    try FileManager.default.createDirectory(at: dwarf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try machO(uuid: uuid, filetype: 0xa).write(to: dwarf)
}

@Test func onlyTheDSYMsOfTheAppAreShipped() throws {
    let (root, app, dSYMs) = try appWithDSYMs(), fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    try addDSYM("Pods/Y.framework.dSYM", 0x11, to: dSYMs)
    try addDSYM("Other.app.dSYM", 0x22, to: dSYMs)
    try Data("x".utf8).write(to: dSYMs.appendingPathComponent("loose"))
    try Data("x".utf8).write(to: dSYMs.appendingPathComponent("Pods/loose"))
    let shipped = try #require(try Packager.shippedDSYMs(dSYMs, of: app))
    defer { try? fm.removeItem(at: shipped) }
    #expect(try fm.subpathsOfDirectory(atPath: shipped.path).filter { !$0.hasSuffix("/Contents") && !$0.contains("/Contents/") }.sorted() == ["Pods", "Pods/Y.framework.dSYM", "X.app.dSYM"])
    #expect(try Data(contentsOf: shipped.appendingPathComponent("X.app.dSYM/Contents/Resources/DWARF/X")) == machO(uuid: 0x11, filetype: 0xa))
    #expect(fm.fileExists(atPath: dSYMs.appendingPathComponent("loose").path)) // the build's own are left as they are
    #expect(try Packager.shippedDSYMs(root.appendingPathComponent("none"), of: app) == nil)
    try fm.removeItem(at: dSYMs.appendingPathComponent("X.app.dSYM"))
    try fm.removeItem(at: dSYMs.appendingPathComponent("Pods"))
    #expect(try Packager.shippedDSYMs(dSYMs, of: app) == nil)
}

@Test(arguments: ["link", "linked", "pipe", "newline"])
func dSYMsThatAreNoPlainTreeAreRefused(_ what: String) throws {
    let (root, app, dSYMs) = try appWithDSYMs(), fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    try Data("mine".utf8).write(to: root.appendingPathComponent("own"))
    var given = dSYMs
    switch what {
    case "link": try fm.createSymbolicLink(at: dSYMs.appendingPathComponent("X.app.dSYM/Contents/own"), withDestinationURL: root.appendingPathComponent("own"))
    case "linked":
        given = root.appendingPathComponent("other")
        try fm.createSymbolicLink(at: given, withDestinationURL: dSYMs)
    case "pipe": try #require(mkfifo(dSYMs.appendingPathComponent("X.app.dSYM/Contents/Resources/DWARF/pipe").path, 0o600) == 0)
    default: try Data().write(to: dSYMs.appendingPathComponent("X.app.dSYM/a\nb"))
    }
    #expect(throws: XlessError.self) { try Packager.shippedDSYMs(given, of: app) }
}
