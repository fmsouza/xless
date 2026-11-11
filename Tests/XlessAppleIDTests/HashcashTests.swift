import XCTest
import Crypto
@testable import XlessAppleID

final class HashcashTests: XCTestCase {
    // The stamp fastlane's hashcash spec documents (X-Apple-HC for bits 11 and challenge 4d74fb15…).
    func testKnownStamp() {
        XCTAssertEqual(Hashcash.mint(challenge: "4d74fb15eb23f465f1f6fcbf534e5877", bits: 11, date: "20230223170600"),
                       "1:11:20230223170600:4d74fb15eb23f465f1f6fcbf534e5877::6373")
    }

    func testMintedStampHasEnoughLeadingZeroBits() {
        let stamp = Hashcash.mint(challenge: "abc", bits: 12, date: "261111120000")
        let digest = Array(Insecure.SHA1.hash(data: Array(stamp.utf8)))
        let leading = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }.leadingZeroBitCount
        XCTAssertGreaterThanOrEqual(leading, 12)
        XCTAssertTrue(stamp.hasPrefix("1:12:261111120000:abc::"))
    }

    func testTimestampIsUTCyyMMddHHmmss() {
        XCTAssertEqual(Hashcash.timestamp(Date(timeIntervalSince1970: 1_762_862_400)), "251111120000")
    }
}
