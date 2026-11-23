import XCTest
@testable import XlessFIDO

final class CBORTests: XCTestCase {
    func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// RFC 8949, Appendix A.
    func testEncodesTheRFCExamples() {
        let cases: [(CBOR, String)] = [
            (.int(0), "00"), (.int(23), "17"), (.int(24), "1818"), (.int(100), "1864"), (.int(1000), "1903e8"),
            (.int(1_000_000), "1a000f4240"), (.unsigned(1_000_000_000_000), "1b000000e8d4a51000"),
            (.int(-1), "20"), (.int(-1000), "3903e7"), (.bytes([1, 2, 3, 4]), "4401020304"), (.text("IETF"), "6449455446"),
            (.text("\u{00fc}"), "62c3bc"), (.array([.int(1), .array([.int(2), .int(3)])]), "8201820203"),
            (.map([(.int(1), .int(2)), (.int(3), .int(4))]), "a201020304"), (.bool(false), "f4"), (.bool(true), "f5"), (.null, "f6"),
        ]
        for (value, encoding) in cases {
            XCTAssertEqual(value.encoded(), hex(encoding), "\(value)")
            XCTAssertEqual(try CBOR.decode(hex(encoding)), value, encoding)
        }
    }

    func testDecodesFloatsAndTags() throws {
        XCTAssertEqual(try CBOR.decode(hex("f93c00")), .float(1.0))
        XCTAssertEqual(try CBOR.decode(hex("fa47c35000")), .float(100000.0))
        XCTAssertEqual(try CBOR.decode(hex("c11a514b67b0")), .tagged(1, .int(1_363_896_240)))
    }

    /// CTAP2 canonical order: shorter encoded keys first, then bytewise (so integers before text, 1 before -1).
    func testMapKeysAreSortedTheCTAP2Way() {
        let map = CBOR.map([(.text("type"), .text("public-key")), (.text("id"), .bytes([9])), (.int(-1), .int(1)), (.int(3), .int(-25)),
                            (.int(1), .int(2))])
        let encoded = map.encoded()
        XCTAssertEqual(encoded, [0xA5, 0x01, 0x02, 0x03, 0x38, 0x18, 0x20, 0x01, 0x62, 0x69, 0x64, 0x41, 0x09,
                                 0x64, 0x74, 0x79, 0x70, 0x65, 0x6A] + Array("public-key".utf8))
    }

    func testLookupByIntegerAndTextKeys() throws {
        let value = try CBOR.decode(CBOR.map([(.int(2), .bytes([1])), (.text("up"), .bool(true)), (.int(-2), .int(5))]).encoded())
        XCTAssertEqual(value[2]?.bytesValue, [1])
        XCTAssertEqual(value["up"]?.boolValue, true)
        XCTAssertEqual(value[-2]?.intValue, 5)
        XCTAssertNil(value[7])
        XCTAssertNil(CBOR.int(3)[1])
    }

    func testRefusesMalformedInput() {
        for bad in ["", "18", "4401", "8201", "a101", "5f", "0000", "62c3", "fc"] {
            XCTAssertThrowsError(try CBOR.decode(hex(bad)), bad)
        }
        // Lengths larger than the input are refused before anything is allocated.
        XCTAssertThrowsError(try CBOR.decode(hex("9bffffffffffffffff")))
        XCTAssertThrowsError(try CBOR.decode(hex("5bffffffffffffffff")))
        // Nesting is bounded.
        XCTAssertThrowsError(try CBOR.decode([UInt8](repeating: 0x81, count: 40) + [0x00]))
        XCTAssertThrowsError(try CBOR.decode(hex("62ffff")), "text that is not UTF-8")
    }
}
