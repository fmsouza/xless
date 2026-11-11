import XCTest
import Crypto
@testable import XlessAppleID

final class PBKDF2Tests: XCTestCase {
    // RFC 7914 §11: PBKDF2-HMAC-SHA256 test vectors.
    func testRFC7914SingleIteration() {
        let key = PBKDF2.sha256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, length: 64)
        XCTAssertEqual(hex(key), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                       + "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    func testManyIterations() {
        let key = PBKDF2.sha256(password: Array("password".utf8), salt: Array("salt".utf8), iterations: 4096, length: 32)
        XCTAssertEqual(hex(key), "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testS2KDerivesFromTheRawDigest() {
        let digest = Array(SHA256.hash(data: Array("secret".utf8)))
        let salt: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(ApplePasswordKey.derive(passwordSHA256: digest, salt: salt, iterations: 10, protocol: .s2k),
                       PBKDF2.sha256(password: digest, salt: salt, iterations: 10, length: 32))
    }

    func testS2KFODerivesFromTheLowercaseHexDigest() {
        let digest = Array(SHA256.hash(data: Array("secret".utf8)))
        let salt: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(ApplePasswordKey.derive(passwordSHA256: digest, salt: salt, iterations: 10, protocol: .s2k_fo),
                       PBKDF2.sha256(password: Array(hex(digest).utf8), salt: salt, iterations: 10, length: 32))
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func bytes(hex: String) -> [UInt8] {
    let s = hex.filter { !$0.isWhitespace }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
