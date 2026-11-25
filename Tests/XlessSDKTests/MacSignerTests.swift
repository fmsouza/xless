#if os(macOS)
import Foundation
import Testing
@testable import XlessSDK
import XlessCore

@Suite struct MacSignerTests {
    let root: URL
    let layout: NativeLayout
    /// A release as it is downloaded, with a stand-in for rcodesign.
    let release: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("signer-\(UUID())")
        layout = NativeLayout(root: root.appendingPathComponent("data/xless-native"))
        let directory = root.appendingPathComponent("apple-codesign-0.29.0-aarch64-apple-darwin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
        try ExecutableFile.write("#!/bin/sh\necho genuine\n", to: directory.appendingPathComponent("rcodesign"), stage: .sdk)
        try Data("text".utf8).write(to: directory.appendingPathComponent("COPYING"))
        release = root.appendingPathComponent("release.tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", release.path, "-C", root.path, directory.lastPathComponent], stage: .sdk)
    }

    private func signer(pin: String? = nil) throws -> MacSigner {
        let download = NativeDownload(kind: .rcodesign, url: URL(string: "https://example.com/rcodesign.tar.gz")!, sha256: try pin ?? XcodeSource.sha256(of: release),
                                      final: layout.rcodesign(version: "0.29.0"))
        return MacSigner(download: download)
    }

    private final class Fetches: @unchecked Sendable { var count = 0 }

    private func prepare(_ signer: MacSigner, _ fetches: Fetches = Fetches(), from: URL? = nil) throws -> URL {
        try signer.prepare { _, file in
            fetches.count += 1
            try FileManager.default.copyItem(at: from ?? release, to: file)
        }
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func said(_ program: URL) throws -> String { try Shell.run(program.path, [], stage: .sdk).stdout }

    @Test func itIsFetchedOnceIntoADirectoryOfThisUserAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Fetches(), signer = try signer()
        #expect(!signer.isInstalled)
        let program = try prepare(signer, fetches)
        #expect(program == layout.rcodesign(version: "0.29.0").appendingPathComponent("rcodesign") && signer.isInstalled)
        #expect(try said(program) == "genuine\n")
        #expect(try prepare(signer, fetches) == program && fetches.count == 1)
        for directory in [layout.root, layout.tools, program.deletingLastPathComponent()] { #expect(try mode(directory) == 0o700, "\(directory.path)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: program.deletingLastPathComponent().path).sorted() == ["rcodesign", "rcodesign.tar.gz"])
    }

    @Test func whatIsNotOfThePinnedArchiveIsNotUsed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default, fetches = Fetches(), signer = try signer(), program = try prepare(signer, fetches)
        let archive = program.deletingLastPathComponent().appendingPathComponent("rcodesign.tar.gz")
        // another program in its place, or a link to one: the archive's again, without a fetch
        try ExecutableFile.write("#!/bin/sh\necho forged\n", to: program, stage: .sdk)
        #expect(try said(prepare(signer, fetches)) == "genuine\n" && fetches.count == 1)
        let other = root.appendingPathComponent("other")
        try fm.copyItem(at: program, to: other)
        try fm.removeItem(at: program)
        try fm.createSymbolicLink(at: program, withDestinationURL: other)
        _ = try prepare(signer, fetches)
        #expect(try fm.attributesOfItem(atPath: program.path)[.type] as? FileAttributeType == .typeRegular && fetches.count == 1)
        // another archive: fetched again
        try Data("another".utf8).write(to: archive)
        #expect(try said(prepare(signer, fetches)) == "genuine\n" && fetches.count == 2)
        try fm.removeItem(at: archive)
        #expect(try said(prepare(signer, fetches)) == "genuine\n" && fetches.count == 3)
    }

    @Test func aDownloadThatIsNotThePinnedOneLeavesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = try signer(pin: String(repeating: "0", count: 64))
        do {
            _ = try prepare(signer)
            Issue.record("expected throw")
        } catch let e as XlessError { #expect(e.stage == .sdk && e.cause.contains("not versions.env's") && e.cause.contains("nothing was installed")) }
        #expect(!signer.isInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: signer.download.final.path).isEmpty)
        struct NoNetwork: Error {}
        #expect(throws: NoNetwork.self) { try signer.prepare { _, _ in throw NoNetwork() } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: signer.download.final.path).isEmpty)
    }

    @Test func aPlaceThatOthersCanWriteIsRefusedBeforeAnythingIsFetched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for shared in [layout.tools, root.appendingPathComponent("data")] {
            for directory in [root.appendingPathComponent("data"), layout.root, layout.tools] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                chmod(directory.path, directory.path == shared.path ? 0o777 : 0o700) // whatever the umask
            }
            let fetches = Fetches()
            do {
                _ = try prepare(signer(), fetches)
                Issue.record("expected throw")
            } catch let e as XlessError { #expect(e.cause.contains("\(shared.path) can be written by other users"), "\(e.cause)") }
            #expect(fetches.count == 0)
            chmod(shared.path, 0o700)
        }
        #expect(try said(prepare(signer())) == "genuine\n")
    }

    @Test func aRelativePlaceIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let table = ["RCODESIGN_VERSION": "0.29.0", "RCODESIGN_SHA256_DARWIN_AARCH64": "da"]
        for name in ["XLESS_NATIVE_HOME", "XDG_DATA_HOME"] {
            #expect(throws: XlessError.self) { try MacSigner(env: [name: "native", "HOME": root.path], arch: "arm64", table: table) }
        }
        #expect(throws: XlessError.self) { try MacSigner(env: ["HOME": "home"], arch: "arm64", table: table) }
        #expect(try MacSigner(env: ["HOME": root.path], arch: "arm64", table: table).program.path == "\(root.path)/.local/share/xless-native/tools/rcodesign-0.29.0/rcodesign")
    }
}
#endif
