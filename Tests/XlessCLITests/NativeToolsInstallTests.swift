import Foundation
import Testing
import XlessCore
import XlessSDK
@testable import xless

/// xtool and rcodesign of a native setup go into the native home that every Xcode's setup shares; each setup holds only its
/// own pack's lock, so the tools are installed under a lock of their own (`<native home>/tools.lock`), and a setup that
/// waited for it finds them installed by the one it waited for.
@Suite struct NativeToolsInstallTests {
    let home: URL
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("native-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A download that cannot be fetched: an install that tried would fail.
    private func download(_ layout: NativeLayout) -> NativeDownload {
        NativeDownload(kind: .rcodesign, url: URL(string: "https://invalid.invalid/rcodesign.tar.gz")!, sha256: String(repeating: "0", count: 64),
                       final: layout.tools.appendingPathComponent("rcodesign-0.29.0"))
    }

    @Test func theToolsAreInstalledUnderTheNativeHomesLock() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = NativeLayout(root: home)
        let held = try PackLock(tools: layout, wait: false)
        #expect { try SetupCommand.install(download(layout), layout: layout, wait: false) } throws: { ($0 as? PackLock.Busy)?.file.path == home.appendingPathComponent("tools.lock").path }
        withExtendedLifetime(held) {}
    }

    @Test func aToolAnotherSetupInstalledMeanwhileIsNotInstalledAgain() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = NativeLayout(root: home), d = download(layout)
        let fm = FileManager.default
        try fm.createDirectory(at: d.final, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: d.final.appendingPathComponent("rcodesign"))
        try fm.createDirectory(at: layout.bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: layout.bin.appendingPathComponent("rcodesign"), withDestinationURL: d.final.appendingPathComponent("rcodesign"))
        try SetupCommand.install(d, layout: layout)
        #expect(try fm.destinationOfSymbolicLink(atPath: layout.bin.appendingPathComponent("rcodesign").path) == d.final.appendingPathComponent("rcodesign").path)
    }
}
