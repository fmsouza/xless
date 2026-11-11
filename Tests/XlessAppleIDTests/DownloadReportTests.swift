import XCTest
import XlessCore
@testable import XlessAppleID

final class DownloadReportTests: XCTestCase {
    let known = [KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: ["abc123"])]

    func testSupportedXipIsNamed() {
        XCTAssertEqual(DownloadReport.identity(sha256: "ABC123", known: known), "supported: Xcode 27.0 (27A266a)")
    }

    func testUnknownXipPrintsItsHashForVersionsEnv() {
        let line = DownloadReport.identity(sha256: "ffee", known: known)
        XCTAssertTrue(line.contains("not in xless's supported table"))
        XCTAssertTrue(line.contains("XCODE_XIP_SHA256_<build>"))
        XCTAssertTrue(line.contains("ffee"))
    }

    func testBytesStillNeededCountsPartsAndSkipsFinishedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-need-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = AppleDownload.File(filename: "A.xip", remotePath: "/x/A.xip", fileSize: 1000)
        let b = AppleDownload.File(filename: "B.xip", remotePath: "/x/B.xip", fileSize: 500)
        let c = AppleDownload.File(filename: "C.xip", remotePath: "/x/C.xip", fileSize: nil)
        try Data(count: 300).write(to: dir.appendingPathComponent("A.xip.part"))
        try Data("xar!".utf8).write(to: dir.appendingPathComponent("B.xip"))
        XCTAssertEqual(DownloadReport.bytesStillNeeded([a, b, c], in: dir), 700)
    }

    func testHumanSizes() {
        XCTAssertEqual(DownloadReport.size(3_210_000_000), "3.2 GB")
        XCTAssertEqual(DownloadReport.size(850_000_000), "850 MB")
    }
}
