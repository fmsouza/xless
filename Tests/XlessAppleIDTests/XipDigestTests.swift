import XCTest
@testable import XlessAppleID

final class XipDigestTests: XCTestCase {
    var dir: URL!
    var xip: URL { dir.appendingPathComponent("Xcode_27.xip") }
    var sidecar: URL { dir.appendingPathComponent("Xcode_27.xip.sha256") }
    let sum = String(repeating: "ab", count: 32)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try testXip.write(to: xip)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func digest(_ calls: ByteCounter) throws -> String {
        try XipDigest.sha256(of: xip) { _ in _ = calls.add(1); return self.sum }
    }

    func testFirstHashIsRecordedInSha256sumFormat() throws {
        let calls = ByteCounter(0)
        XCTAssertEqual(try digest(calls), sum)
        XCTAssertEqual(calls.add(0), 1)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "\(sum)  Xcode_27.xip\n")
    }

    func testRecordedHashIsReusedWithoutReadingTheXip() throws {
        let calls = ByteCounter(0)
        _ = try digest(calls)
        XCTAssertEqual(try digest(calls), sum)
        XCTAssertEqual(calls.add(0), 1)
    }

    func testXipNewerThanTheRecordIsHashedAgain() throws {
        let calls = ByteCounter(0)
        _ = try digest(calls)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: xip.path)
        _ = try digest(calls)
        XCTAssertEqual(calls.add(0), 2)
    }

    func testGarbageRecordIsIgnored() throws {
        let calls = ByteCounter(0)
        try Data("not a hash  Xcode_27.xip\n".utf8).write(to: sidecar)
        XCTAssertEqual(try digest(calls), sum)
        XCTAssertEqual(calls.add(0), 1)
    }
}
