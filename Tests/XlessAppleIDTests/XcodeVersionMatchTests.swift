import XCTest
import XlessCore
@testable import XlessAppleID

final class XcodeVersionMatchTests: XCTestCase {
    func file(_ name: String, size: Int64? = nil) -> AppleDownload.File {
        AppleDownload.File(filename: name, remotePath: "/Developer_Tools/\(name.replacingOccurrences(of: ".xip", with: ""))/\(name)", fileSize: size)
    }

    lazy var catalog: [AppleDownload] = [
        AppleDownload(name: "Xcode 27", files: [file("Xcode_27.xip")]),
        AppleDownload(name: "Xcode 26.2", files: [file("Xcode_26.2_Apple_silicon.xip"), file("Xcode_26.2_Universal.xip")]),
        AppleDownload(name: "Xcode 26 beta 3", files: [file("Xcode_26_beta_3.xip")]),
        AppleDownload(name: "Xcode 26", files: [file("Xcode_26.xip")]),
        AppleDownload(name: "Xcode 16.4", files: [file("Xcode_16.4.xip")]),
        AppleDownload(name: "Xcode 10.1", files: [file("Xcode_10.1.dmg")]),
    ]

    func testTokensSplitCommasAndDeduplicate() {
        XCTAssertEqual(XcodeVersionMatch.tokens(["26.2,27.0", " 16.4 ", "26.2", "", "26  beta 3"]), ["26.2", "27.0", "16.4", "26 beta 3"])
    }

    func testExactName() throws {
        let r = try XcodeVersionMatch.resolve(["16.4", "26 beta 3", "Xcode 26.2"], in: catalog)
        XCTAssertEqual(r.map(\.download.name), ["Xcode 16.4", "Xcode 26 beta 3", "Xcode 26.2"])
    }

    func testTrailingZeroEquivalence() throws {
        XCTAssertEqual(try XcodeVersionMatch.resolve(["27.0"], in: catalog).first?.download.name, "Xcode 27")
        XCTAssertEqual(try XcodeVersionMatch.resolve(["27"], in: catalog).first?.download.name, "Xcode 27")
        XCTAssertEqual(try XcodeVersionMatch.resolve(["26.0.0"], in: catalog).first?.download.name, "Xcode 26")
        XCTAssertThrowsError(try XcodeVersionMatch.resolve(["26.0.1"], in: catalog))
    }

    func testPrefersTheUniversalXip() throws {
        XCTAssertEqual(try XcodeVersionMatch.resolve(["26.2"], in: catalog).first?.file.name, "Xcode_26.2_Universal.xip")
    }

    func testResolveFailsBeforeDownloadingAndNamesEveryUnknownToken() {
        XCTAssertThrowsError(try XcodeVersionMatch.resolve(["26.2", "26.3", "99"], in: catalog)) { error in
            let e = error as! XlessError
            XCTAssertTrue(e.cause.contains("26.3") && e.cause.contains("99"), e.cause)
            XCTAssertTrue(e.cause.contains("Xcode 26.2"), "close matches: \(e.cause)")
            XCTAssertTrue(e.fix.contains("--list"))
        }
    }

    func testAReleaseWithoutAXipIsRefused() {
        XCTAssertThrowsError(try XcodeVersionMatch.resolve(["10.1"], in: catalog)) { error in
            XCTAssertTrue((error as! XlessError).cause.contains(".xip"))
        }
    }
}
