import XCTest
import BigInt
import Crypto
@testable import XlessAppleID

final class AppleSRPTests: XCTestCase {
    // RFC 5054 Appendix B (SHA-1, 1024-bit group, I = "alice", P = "password123").
    let salt = bytes(hex: "BEB25379D1A8581EB5A727673A2441EE")
    let a = BigUInt("60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393", radix: 16)!
    let b = BigUInt("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20", radix: 16)!

    func testRFC5054Vectors() throws {
        let client = AppleSRPClient<Insecure.SHA1>(group: .rfc5054_1024, privateKey: a)
        let x = AppleSRPClient<Insecure.SHA1>.x(salt: salt, message: Array("alice:password123".utf8))
        XCTAssertEqual(client.k.hexUpper, "7556AA045AEF2CDD07ABAF0F665C3E818913186F")
        XCTAssertEqual(x.hexUpper, "94B7555AABE9127CC58CCF4993DB6CF84D16C124")
        XCTAssertEqual(hex(client.publicKey).uppercased(),
                       "61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358A2CF1B6E"
                       + "0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261"
                       + "EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B")
        let B = BigUInt("BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9"
                        + "B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A"
                        + "00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58", radix: 16)!
        XCTAssertEqual(client.u(serverPublicKey: B).hexUpper, "CE38B9593487DA98554ED47D70A7AE5F462EF019")
        XCTAssertEqual(try client.premasterSecret(x: x, serverPublicKey: B).hexUpper,
                       "B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A6F67809F"
                       + "0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB3394"
                       + "3CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A")
    }

    /// M1/M2 from an independent Python implementation of Apple's variant (2048-bit group, SHA-256, x = H(s | H(":" | key))).
    func testAppleProofsMatchReference() throws {
        let client = AppleSRP(privateKey: a)
        let B = bytes(hex: """
            421ecda90c4a4f9570d2b7b4baee301ed34383851f6701e6a79313afb0c7fdf3a301a3eeb036044d258f69bcf0b499cfbd361d7acba6208c
            89842ab4d28c7369dbc495020988aaebf1e775ebcbe8f0bd12f3db3a287b39289a2550b789ea41b4638b763a6c7b3319bf89e028174983e3
            654a7eb9b3b265646eb72b112cd40a96a749837846aea0c32e373b36b377a8c1e4004a1ceda644151195d89386b6eb5d36cf8e322c7312f4
            e4c8ab51eaefac298213a8980ca428f161ff030e826f3c612b07d8bc0c55d0037557c008bed9b730edf8461abb6e0f7cfd3b853b27fef5bd
            f170aebb4fa2e6452828ed6edeb988b9ea22e1fbe6b794762a67301eda280984
            """)
        XCTAssertEqual(hex(client.publicKey), """
            4b700f8d48e69c9aae40c684ac7c7c03121e2b7602eb4c3514804ccada0ed4019193a351ecc65a6f854ede91eb096e721b22d701c7adc64e\
            9cedacd75f2e26bb2f5e45dd53dc8dbeafffe82aa49fca0573444691212537a73cf80e25039258205a7edf4749b30adaf25877c62fcd09d6\
            613598bcd4baf2a9727a53706a278148992b2abb23ad5d512d269e16ca11bc0895b5a3b5ec4721cde40a8c39c796e94f0be86dbbeb33da70\
            37018983921aba3f5053195d5ac1da4e567e3c0e75d9e0609f92e850657b2be4771f415b9cacc5c1ecedc30133bf6474f5022c6519d78076\
            0ca4d8d3b966b034bd73877c1b3b33f474b9c3c5299a1968f3e6cd3bfe84445a
            """)
        let proofs = try client.proofs(accountName: "user@example.com", passwordKey: Array(0..<32), salt: salt, serverPublicKey: B)
        XCTAssertEqual(hex(proofs.m1), "f48fe306429d2e239212130b743f627e6c7e658543740cad0a9c48ce7075106b")
        XCTAssertEqual(hex(proofs.m2), "b84524d6d3f77b5248b7b12313e0ac9dfaeecd92502524c7ea9e54f22ea003b4")
    }

    func testRejectsAServerKeyThatIsAMultipleOfN() {
        let client = AppleSRP(privateKey: a)
        XCTAssertThrowsError(try client.proofs(accountName: "u", passwordKey: [1], salt: salt,
                                               serverPublicKey: Array(SRPGroup.rfc5054_2048.N.serialize())))
        XCTAssertThrowsError(try client.proofs(accountName: "u", passwordKey: [1], salt: salt, serverPublicKey: [0]))
    }

    func testRandomPrivateKeysDiffer() {
        XCTAssertNotEqual(AppleSRP().publicKey, AppleSRP().publicKey)
    }
}

extension BigUInt {
    var hexUpper: String { String(self, radix: 16, uppercase: true) }
}
