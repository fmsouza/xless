import Testing
import Foundation
@testable import XlessPackage
@testable import XlessCore
import XlessMachO

private func onPath(_ tool: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
    }
}

private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dmg-\(UUID())") }

/// A bundle with an executable, a versioned framework (`Versions/Current` and `F` are symlinks) and a name with a space.
private func makeApp(_ root: URL, name: String = "Hello Tauri") throws -> URL {
    let fm = FileManager.default
    let app = root.appendingPathComponent("\(name).app")
    let fw = app.appendingPathComponent("Contents/Frameworks/F.framework")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fw.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
    try Data("bin".utf8).write(to: app.appendingPathComponent("Contents/MacOS/x"))
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/x").path)
    try Data("fw".utf8).write(to: fw.appendingPathComponent("Versions/A/F"))
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
    return app
}

@Test func dmgFileNameMatchesTauri() throws {
    #expect(DmgBuilder.fileName(product: "HelloTauri", version: "1.0.0") == "HelloTauri_1.0.0_universal.dmg")
    let ref = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples/HelloTauri/reference/macos/dmg.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: ref)) as! [String: Any]
    #expect(DmgBuilder.fileName(product: json["volumeName"] as! String, version: "1.0.0") == json["fileName"] as? String)
}

/// Tauri's names for a single-architecture bundle: `aarch64` and `x64`; both architectures stay `universal`.
@Test func dmgFileNameFollowsTheArchitectures() {
    #expect(DmgBuilder.fileName(product: "Hello", version: "1.0.0", architectures: [.arm64]) == "Hello_1.0.0_aarch64.dmg")
    #expect(DmgBuilder.fileName(product: "Hello", version: "1.0.0", architectures: [.x86_64]) == "Hello_1.0.0_x64.dmg")
    #expect(DmgBuilder.fileName(product: "Hello", version: "1.0.0", architectures: [.arm64, .x86_64]) == "Hello_1.0.0_universal.dmg")
    #expect(DmgBuilder.fileName(product: "Hello", version: "1.0.0", architectures: [.x86_64, .arm64]) == "Hello_1.0.0_universal.dmg")
}

@Test func buildNamesAThinDMGAfterItsArchitecture() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let dmg = try DmgBuilder.build(signedApp: app, volumeName: "Hello", version: "1.0.0", architectures: [.arm64],
                                   outputDir: root.appendingPathComponent("out"), pin: { _, _ in }) { _ in }
    #expect(dmg.lastPathComponent == "Hello_1.0.0_aarch64.dmg")
}

/// A thin 64-bit Mach-O header (no load commands) for `cpu`.
private func thin(_ cpu: UInt32) -> Data {
    var d = Data()
    for v: UInt32 in [0xfeedfacf, cpu, 0, 2, 0, 0, 0, 0] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    return d
}

/// `Hello.app` whose `CFBundleExecutable` is `executable`.
private func macApp(_ root: URL, executable: Data) throws -> URL {
    let app = root.appendingPathComponent("Hello.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "Hello"], to: app.appendingPathComponent("Contents/Info.plist"), format: .xml, stage: .package)
    try executable.write(to: app.appendingPathComponent("Contents/MacOS/Hello"))
    return app
}

/// The notarized DMG is named after what the signed app holds, not after the overlay as it reads now (`--from package`).
@Test func architecturesAreReadFromTheAppsExecutable() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let arm64: UInt32 = 0x0100000c, x86_64: UInt32 = 0x01000007
    #expect(try DmgBuilder.architectures(ofApp: macApp(root.appendingPathComponent("a"), executable: thin(arm64))) == [.arm64])
    #expect(try DmgBuilder.architectures(ofApp: macApp(root.appendingPathComponent("x"), executable: thin(x86_64))) == [.x86_64])
    let fat = try MachO.makeFat([thin(x86_64), thin(arm64)])
    #expect(try DmgBuilder.architectures(ofApp: macApp(root.appendingPathComponent("u"), executable: fat)) == [.arm64, .x86_64])
    do { _ = try DmgBuilder.architectures(ofApp: macApp(root.appendingPathComponent("n"), executable: Data("bin".utf8))); Issue.record("accepted") }
    catch let e as XlessError { #expect(e.stage == .package && e.cause.contains("Hello")) }
}

@Test func commandsAreArgvWithoutAShell() {
    let work = URL(fileURLWithPath: "/w"), out = URL(fileURLWithPath: "/o/Hello Tauri é_1.0.0_universal.dmg")
    let c = DmgBuilder.commands(app: URL(fileURLWithPath: "/a/Hello Tauri é.app"), volumeName: "Hello Tauri é", work: work, out: out, sizeKB: 9000)
    #expect(c == [
        ["dd", "if=/dev/zero", "of=/w/img.hfs", "bs=1k", "count=9000", "status=none"],
        ["mkfs.hfsplus", "-v", "Hello Tauri é", "/w/img.hfs"],
        ["hfsplus", "--symlinks", "clone_link", "--special-modes", "no", "/w/img.hfs", "addall", "/w/stage"],
        ["hfsplus", "/w/img.hfs", "symlink", "/Applications", "/Applications"],
        ["dmg", "-c", "zlib", "build", "/w/img.hfs", "/o/Hello Tauri é_1.0.0_universal.dmg"],
    ])
}

@Test func buildRunsNormalisedStageThenCommandsInOrder() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    nonisolated(unsafe) var ran: [[String]] = []
    let dmg = try DmgBuilder.build(signedApp: app, volumeName: "Hello Tauri é", version: "1.0.0", outputDir: root.appendingPathComponent("out"),
                                   pin: { image, pinned in ran.append(["pin", image.lastPathComponent, pinned.path]) }) { ran.append($0) }
    #expect(dmg.lastPathComponent == "Hello Tauri é_1.0.0_universal.dmg")
    // The volume's dates are pinned once every tool that stamps one has run, before it is compressed.
    #expect(ran.map { $0[0] } == ["chmod", "dd", "mkfs.hfsplus", "hfsplus", "hfsplus", "pin", "dmg"])
    #expect(ran[5] == ["pin", "img.hfs", app.path])
    #expect(ran[0].prefix(3) == ["chmod", "-R", "u=rwX,go=rX"])
    #expect(ran[2][2] == "Hello Tauri é")
    #expect(ran.last?.last == dmg.path.replacingOccurrences(of: "/out/", with: "/out.partial/"))
}

/// The tree `hfsplus addall` copies modes from is normalised whatever the builder's umask: the stage is loosened here as a
/// umask of 002 creates it (775 directories, 664 files) before the real chmod runs, and read back when addall would run.
@Test func theStageIsNormalisedWhateverTheUmask() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    nonisolated(unsafe) var modes: [String: UInt16] = [:]
    _ = try DmgBuilder.build(signedApp: app, volumeName: "Hello", version: "1.0.0", outputDir: root.appendingPathComponent("out"),
                             pin: { _, _ in }) { argv in
        if argv[0] == "chmod", let stage = argv.last {
            let fm = FileManager.default
            _ = chmod(stage, 0o775)
            for rel in try fm.subpathsOfDirectory(atPath: stage) {
                let path = "\(stage)/\(rel)", info = try PkgBuilder.lstatInfo(path)
                if !info.isSymlink { _ = chmod(path, info.isDirectory || info.mode & 0o100 != 0 ? 0o775 : 0o664) }
            }
            try Shell.run(argv[0], Array(argv.dropFirst()), stage: .package)
        }
        if argv.contains("addall"), let stage = argv.last {
            modes["."] = try PkgBuilder.lstatInfo(stage).mode
            for rel in try FileManager.default.subpathsOfDirectory(atPath: stage) {
                let info = try PkgBuilder.lstatInfo("\(stage)/\(rel)")
                if !info.isSymlink { modes[rel] = info.mode }
            }
        }
    }
    let base = "Hello Tauri.app/Contents"
    #expect(modes == [".": 0o755, "Hello Tauri.app": 0o755, base: 0o755, "\(base)/MacOS": 0o755, "\(base)/MacOS/x": 0o755,
                      "\(base)/Frameworks": 0o755, "\(base)/Frameworks/F.framework": 0o755,
                      "\(base)/Frameworks/F.framework/Versions": 0o755, "\(base)/Frameworks/F.framework/Versions/A": 0o755,
                      "\(base)/Frameworks/F.framework/Versions/A/F": 0o644])
}

/// `sourceDate` reads each entry's date from the signed app itself (a symlink's own), the app's date for what the app
/// does not hold; a path outside the app (`Applications` next to it) is never read.
@Test func sourceDateReadsOnlyInsideTheSignedApp() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let appDate = Date(timeIntervalSince1970: 1_767_225_600), exeDate = Date(timeIntervalSince1970: 1_748_779_200)
    let linkDate = Date(timeIntervalSince1970: 1_740_787_200)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                          ofItemAtPath: root.appendingPathComponent("Applications").path)
    try FileManager.default.setAttributes([.modificationDate: exeDate], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/x").path)
    try PkgBuilder.setLinkDate(app.appendingPathComponent("Contents/Frameworks/F.framework/Versions/Current").path, linkDate)
    try FileManager.default.setAttributes([.modificationDate: appDate], ofItemAtPath: app.path)
    var asked: [String: Date?] = [:]
    for rel in ["Hello Tauri.app", "Hello Tauri.app/Contents/MacOS/x", "Hello Tauri.app/Contents/Frameworks/F.framework/Versions/Current",
                "Hello Tauri.app/Contents/Nope", "Applications", "Hello Tauri.appx"] {
        asked.updateValue(DmgBuilder.sourceDate(rel, app: app), forKey: rel)
    }
    #expect(asked["Hello Tauri.app"] == appDate)
    #expect(asked["Hello Tauri.app/Contents/MacOS/x"] == exeDate)
    #expect(asked["Hello Tauri.app/Contents/Frameworks/F.framework/Versions/Current"] == linkDate)
    #expect(asked["Hello Tauri.app/Contents/Nope"] == .some(nil))
    #expect(asked["Applications"] == .some(nil))
    #expect(asked["Hello Tauri.appx"] == .some(nil))
}

@Test func missingToolPointsAtTheTauriImage() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    do {
        _ = try DmgBuilder.build(signedApp: app, volumeName: "X", version: "1", outputDir: root.appendingPathComponent("out"), pin: { _, _ in }) { argv in
            if argv[0] == "dmg" { throw XlessError(.package, "cannot start dmg: nope", fix: "install dmg or check PATH") }
        }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.description == "[package] cannot start dmg to build the DMG — install libdmg-hfsplus and hfsprogs (use the xless-tauri image)")
    }
}

private let notaryID = "12345678-1234-1234-1234-123456789abc"
private let longIssues = "notary log> {\n  \"status\": \"Invalid\",\n  \"issues\": [{\"message\": \"The binary is not signed. Accepted\\nStatus: Accepted by nobody\"}]\n}\n"
private func notary(_ log: String, failure: XlessError? = nil) throws {
    try Notary.submit(URL(fileURLWithPath: "/x/X.dmg"), apiKeyJSON: URL(fileURLWithPath: "/k.json")) { _ in
        Notary.Run(log: log, failure: failure)
    }
}
private let exit1 = XlessError(.package, "`rcodesign notary-submit` exited with 1:\nlast line", fix: "see the tool output above")

@Test func notaryRejectionAfterLongIssuesLogIsReportedWithTheStatusFromPollLines() {
    let log = "created submission ID: \(notaryID)\n" + String(repeating: "waiting\n", count: 50)
        + "poll state after 10s: Invalid\n" + longIssues
    #expect(Notary.submissionID(in: log) == notaryID)
    #expect(Notary.status(in: log) == "Invalid")
    do { try notary(log, failure: exit1); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.description == "[package] notarization of X.dmg was rejected (Invalid) — read the notary log printed above, fix the reported binaries, then re-run from package")
    } catch { Issue.record("\(error)") }
}

@Test func networkFailureIsNotCalledARejection() {
    do { try notary("created submission ID: \(notaryID)\nerror sending request\n", failure: exit1); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(!e.cause.contains("rejected"))
        #expect(e.cause.hasPrefix("`rcodesign notary-submit` exited with 1") && e.cause.hasSuffix("(notary submission \(notaryID))"))
    } catch { Issue.record("\(error)") }
}

@Test func stapleFailureAfterAcceptedIsTheStapleError() {
    let staple = XlessError(.package, "`rcodesign notary-submit` exited with 1:\ncannot staple", fix: "see the tool output above")
    do { try notary("submission ID: \(notaryID)\npoll state after 20s: Accepted\nattempting to staple /x/X.dmg\n", failure: staple); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("cannot staple") && !e.cause.contains("rejected")) } catch { Issue.record("\(error)") }
}

@Test func acceptedAndUnknownStatusSucceed() throws {
    try notary("submission ID: \(notaryID)\npoll state after 20s: Accepted\nstapling DMG with 1695 byte notarization ticket\n")
    try notary("stapling DMG with 1695 byte notarization ticket\n")   // exit 0, no status: logged as unknown
}

/// Runs only where the DMG tools exist (the xless-tauri image): a real volume, listed back with `dmg extract` + `hfsplus ls`.
@Test(.enabled(if: onPath("dmg") && onPath("hfsplus") && onPath("mkfs.hfsplus")))
func realDmgKeepsFrameworkSymlinksAndHasApplicationsLink() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let dmg = try DmgBuilder.build(signedApp: app, volumeName: "Hello Tauri é", version: "1.0.0", outputDir: root.appendingPathComponent("out"))
    #expect(FileManager.default.fileExists(atPath: dmg.path))
    let img = root.appendingPathComponent("extracted.hfs")
    try Shell.run("dmg", ["extract", dmg.path, img.path], stage: .package)
    let top = try Shell.run("hfsplus", [img.path, "ls", "/"], stage: .package).stdout
    #expect(top.contains("Hello Tauri.app") && top.contains("Applications"))
    let fw = try Shell.run("hfsplus", [img.path, "ls", "/Hello Tauri.app/Contents/Frameworks/F.framework"], stage: .package).stdout
    // ls prints the octal mode first: 12xxxx is a symlink, 04xxxx a directory.
    #expect(fw.split(separator: "\n").contains { $0.hasPrefix("12") && $0.hasSuffix(" F") })
    let versions = try Shell.run("hfsplus", [img.path, "ls", "/Hello Tauri.app/Contents/Frameworks/F.framework/Versions"], stage: .package).stdout
    #expect(versions.split(separator: "\n").contains { $0.hasPrefix("12") && $0.hasSuffix(" Current") })
    #expect(top.split(separator: "\n").contains { $0.hasPrefix("12") && $0.hasSuffix(" Applications") })
    let macos = try Shell.run("hfsplus", [img.path, "ls", "/Hello Tauri.app/Contents/MacOS"], stage: .package).stdout
    #expect(macos.split(separator: "\n").contains { $0.contains("100755") && $0.hasSuffix(" x") })   // 0700 source normalised
}

/// Runs only where the DMG tools exist: the same app gives the same DMG bytes built a second and more later, the stage
/// loosened the way a umask of 002 creates it, and the volume carries the app's own dates.
@Test(.enabled(if: onPath("dmg") && onPath("hfsplus") && onPath("mkfs.hfsplus")))
func realDmgIsTheSameBytesLaterAndUnderAnotherUmask() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let date = Date(timeIntervalSince1970: 1_767_225_600)
    for rel in try FileManager.default.subpathsOfDirectory(atPath: app.path).reversed() + [""] {
        try PkgBuilder.setLinkDate(rel.isEmpty ? app.path : app.appendingPathComponent(rel).path, date)
    }
    let first = try DmgBuilder.build(signedApp: app, volumeName: "Hello Tauri é", version: "1.0.0", outputDir: root.appendingPathComponent("a"))
    Thread.sleep(forTimeInterval: 1.1)
    let second = try DmgBuilder.build(signedApp: app, volumeName: "Hello Tauri é", version: "1.0.0", outputDir: root.appendingPathComponent("b"),
                                      run: { argv in
        if argv[0] == "chmod", let stage = argv.last { try Shell.run("chmod", ["-R", "g+w", stage], stage: .package) }
        try DmgBuilder.shell(argv)
    })
    #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    let img = root.appendingPathComponent("extracted.hfs")
    try Shell.run("dmg", ["extract", first.path, img.path], stage: .package)
    let snapshot = try HFSPlusDates.read(image: img)
    #expect(snapshot.entries["Hello Tauri.app/Contents/MacOS/x"]?[1] == HFSPlusDates.hfsDate(date))
    #expect(snapshot.volumeDates[0] == HFSPlusDates.hfsDate(date))
}

@Test func captureToKeepsTheFullOutputPastTheErrorTail() throws {
    let log = scratch()
    defer { try? FileManager.default.removeItem(at: log) }
    do {
        try Shell.run("sh", ["-c", "echo fir\"\"st; i=0; while [ $i -lt 40 ]; do echo li\"\"ne$i >&2; i=$((i+1)); done; exit 3"], stage: .package, captureTo: log)
        Issue.record("expected throw")
    } catch let e as XlessError { #expect(!e.cause.contains("first")) }
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("first") && text.contains("line0") && text.contains("line39"))
}

/// `rcodesign print-signature-info` blob lists (rcodesign 0.29.0) of a signed DMG before and after `notary-submit --staple`.
private let unstapledInfo = """
- path: /d/X_1.0.0_universal.dmg
  entity:
    dmg:
      signature:
        blob_count: 3
        blobs:
        - slot: CodeDirectory (0)
          magic: fade0c02
        - slot: RequirementSet (2)
          magic: fade0c01
        - slot: CMS Signature (65536)
          magic: fade0b01
"""
private let stapledInfo = unstapledInfo.replacingOccurrences(of: "blob_count: 3", with: "blob_count: 4")
    + "\n        - slot: Ticket (65538)\n          magic: fade0b01\n          length: 1703\n"

@Test func stapledTicketIsDetectedInTheSignatureBlobs() throws {
    #expect(Notary.hasStapledTicket(signatureInfo: stapledInfo))
    #expect(!Notary.hasStapledTicket(signatureInfo: unstapledInfo))
    #expect(!Notary.hasStapledTicket(signatureInfo: "identifier: Ticket (65538)\n"))   // only a blob slot line counts
    let dmg = URL(fileURLWithPath: "/x/X_1.0.0_universal.dmg")
    try Notary.checkStapled(dmg: dmg) { _ in stapledInfo }
    do { try Notary.checkStapled(dmg: dmg) { _ in unstapledInfo }; Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.stage == .package && e.cause == "X_1.0.0_universal.dmg has no stapled notarization ticket after notary-submit --staple")
    }
}

/// In the xless-tauri image: a real DMG signed by rcodesign (self-signed certificate, nothing sent anywhere) has no ticket.
@Test(.enabled(if: onPath("dmg") && onPath("hfsplus") && onPath("mkfs.hfsplus") && onPath("rcodesign")))
func signedButUnstapledRealDmgFailsTheStapleCheck() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let dmg = try DmgBuilder.build(signedApp: try makeApp(root), volumeName: "X", version: "1.0.0", outputDir: root.appendingPathComponent("out"))
    let pem = root.appendingPathComponent("self.pem")
    try Shell.run("rcodesign", ["generate-self-signed-certificate", "--person-name", "xless test", "--pem-unified-file", pem.path], stage: .package)
    try Shell.run("rcodesign", ["sign", "--pem-file", pem.path, dmg.path], stage: .package)
    let info = try Shell.run("rcodesign", ["print-signature-info", dmg.path], stage: .package).stdout
    #expect(info.contains("slot: CodeDirectory (0)"))   // the format the check reads
    #expect(!Notary.hasStapledTicket(signatureInfo: info))
    #expect(throws: XlessError.self) { try Notary.checkStapled(dmg: dmg) }
}

@Test func buildZipsTheDSYMsNextToTheDMG() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeApp(root)
    let dSYMs = try makeDSYMs(root, name: "Hello Tauri.app")
    let out = root.appendingPathComponent("out")
    _ = try DmgBuilder.build(signedApp: app, volumeName: "Hello", version: "1.0.0", architectures: [.arm64], outputDir: out, dSYMs: dSYMs, pin: { _, _ in }) { _ in }
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Hello Tauri.app.dSYM.zip").path))
}
