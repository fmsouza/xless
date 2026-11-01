import Testing
import Foundation
import XlessCore
@testable import XlessPackage

/// The mac path's version source: the signed app's `Contents/Info.plist`, read straight from the
/// tree — the plist the pkg's payload carries, so `upload` declares what is actually inside it.
@Suite struct IPAInfoAppTests {
    private func tempApp(version: String = "0.15.0", build: String = "0.15.0.2026103101") throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("xless-app-\(UUID().uuidString).app", isDirectory: false)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let body = """
        {CFBundleShortVersionString = \(version); CFBundleVersion = \(build); CFBundleIdentifier = "space.gaialab.lightcraft.mac";}
        """
        try Data(body.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test func versionsReadTheAppTree() throws {
        let app = try tempApp()
        defer { try? FileManager.default.removeItem(at: app) }
        let v = try IPAInfo.versions(app: app)
        #expect(v.version == "0.15.0")
        #expect(v.build == "0.15.0.2026103101")
    }

    @Test func overrideMustAgreeLikeTheIpa() throws {
        let app = try tempApp()
        defer { try? FileManager.default.removeItem(at: app) }
        let v = try IPAInfo.uploadVersions(app: app, buildOverride: "0.15.0.2026103101")
        #expect(v.build == "0.15.0.2026103101")
        #expect(throws: XlessError.self) { try IPAInfo.uploadVersions(app: app, buildOverride: "9.9.9.9") }
    }

    @Test func aPlistWithoutVersionsIsRefused() throws {
        let app = try tempApp()
        defer { try? FileManager.default.removeItem(at: app) }
        try Data("{}".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: XlessError.self) { try IPAInfo.versions(app: app) }
    }
}