import XCTest
@testable import XlessFIDO

/// A HID device that answers from a script, recording the reports written.
final class ScriptedHID: HIDConnection {
    let reportSize = 64
    var written: [[UInt8]] = []
    var replies: [[UInt8]] = []
    func write(_ report: [UInt8]) throws { written.append(report) }
    func read(timeout milliseconds: Int) throws -> [UInt8]? { replies.isEmpty ? nil : replies.removeFirst() }

    static func packet(_ cid: UInt32, _ head: [UInt8]) -> [UInt8] {
        let p = [UInt8(cid >> 24), UInt8(cid >> 16 & 0xFF), UInt8(cid >> 8 & 0xFF), UInt8(cid & 0xFF)] + head
        return p + [UInt8](repeating: 0, count: 64 - p.count)
    }
}

final class CTAPHIDTests: XCTestCase {
    let nonce: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

    func testInitAllocatesAChannelAndReadsCapabilities() throws {
        let key = SimulatedKey(credentials: [])
        let channel = try CTAPHIDChannel(key, nonce: nonce)
        XCTAssertEqual(channel.channel, 0x0102_0304)
        XCTAssertTrue(channel.supportsCBOR)
        XCTAssertTrue(channel.supportsMSG)

        key.ctap2 = false; key.u2f = false
        let other = try CTAPHIDChannel(key, nonce: nonce)
        XCTAssertFalse(other.supportsCBOR)
        XCTAssertFalse(other.supportsMSG)
    }

    func testInitSkipsAnswersToSomeoneElsesNonce() throws {
        let hid = ScriptedHID()
        hid.replies = [
            ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + [9, 9, 9, 9, 9, 9, 9, 9] + [0, 0, 0, 9, 2, 1, 0, 0, 0x04]),
            ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + nonce + [0, 0, 0, 7, 2, 1, 0, 0, 0x05]),
        ]
        let channel = try CTAPHIDChannel(hid, nonce: nonce)
        XCTAssertEqual(channel.channel, 7)
        XCTAssertEqual(hid.written.first.map { Array($0[0..<7]) }, [0xFF, 0xFF, 0xFF, 0xFF, 0x86, 0, 8])
    }

    func testLongMessagesUseContinuationPacketsBothWays() throws {
        let hid = ScriptedHID()
        hid.replies = [ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + nonce + [0, 0, 0, 7, 2, 1, 0, 0, 0x04])]
        let channel = try CTAPHIDChannel(hid, nonce: nonce)
        let payload = (0..<200).map { UInt8($0) }
        hid.replies = [
            ScriptedHID.packet(7, [0x81, 0, 200] + payload[0..<57]),
            ScriptedHID.packet(7, [0] + payload[57..<116]),
            ScriptedHID.packet(7, [1] + payload[116..<175]),
            ScriptedHID.packet(7, [2] + payload[175..<200]),
        ]
        hid.written = []
        XCTAssertEqual(try channel.transact(CTAPHIDChannel.Command.ping, payload, timeout: 1), payload)
        XCTAssertEqual(hid.written.count, 4)
        XCTAssertEqual(Array(hid.written[0][0..<7]), [0, 0, 0, 7, 0x81, 0, 200])
        XCTAssertEqual(Array(hid.written[1][0..<5]), [0, 0, 0, 7, 0])
        XCTAssertEqual(Array(hid.written[3][0..<5]), [0, 0, 0, 7, 2])
        XCTAssertEqual(Array(hid.written[3][5..<30]), Array(payload[175..<200]))
    }

    func testKeepalivesAreReportedAndOtherChannelsIgnored() throws {
        let hid = ScriptedHID()
        hid.replies = [ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + nonce + [0, 0, 0, 7, 2, 1, 0, 0, 0x04])]
        let channel = try CTAPHIDChannel(hid, nonce: nonce)
        hid.replies = [
            ScriptedHID.packet(7, [0xBB, 0, 1, 2]),
            ScriptedHID.packet(99, [0x90, 0, 1, 0x2E]),
            ScriptedHID.packet(99, [5, 1, 2, 3]),
            ScriptedHID.packet(7, [0xBB, 0, 1, 1]),
            ScriptedHID.packet(7, [0x90, 0, 1, 0x00]),
        ]
        var statuses: [UInt8] = []
        XCTAssertEqual(try channel.transact(0x90, [4], timeout: 1) { statuses.append($0) }, [0])
        XCTAssertEqual(statuses, [2, 1])
    }

    /// U2F_AUTHENTICATE as FIDO's raw-message format lays it out: CLA 0, INS 2, P1, P2 0, extended Lc, challenge
    /// parameter, application parameter, key handle length and handle, Le 0x0000.
    func testU2FAuthenticateBytes() throws {
        let hid = ScriptedHID()
        hid.replies = [ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + nonce + [0, 0, 0, 7, 2, 1, 0, 0, 0x01])]
        let authenticator = Authenticator(channel: try CTAPHIDChannel(hid, nonce: nonce))
        hid.written = []
        hid.replies = [ScriptedHID.packet(7, [0x83, 0, 2, 0x69, 0x85])]
        let challenge = [UInt8](repeating: 0xCC, count: 32), app = [UInt8](repeating: 0xAA, count: 32)
        XCTAssertThrowsError(try authenticator.u2fAuthenticate(appParameter: app, challenge: challenge, keyHandle: [1, 2, 3], checkOnly: true)) {
            XCTAssertEqual($0 as? FIDOError, .u2f(0x6985))
        }
        let apdu: [UInt8] = [0x00, 0x02, 0x07, 0x00, 0x00, 0x00, 68] + challenge + app + [3, 1, 2, 3] + [0x00, 0x00]
        let sent = Array(hid.written[0][7..<64]) + Array(hid.written[1][5..<5 + apdu.count - 57])
        XCTAssertEqual(Array(hid.written[0][4..<7]), [0x83, 0, UInt8(apdu.count)])
        XCTAssertEqual(sent, apdu)
    }

    func testErrorsAndBrokenSequencesThrow() throws {
        let hid = ScriptedHID()
        hid.replies = [ScriptedHID.packet(0xFFFF_FFFF, [0x86, 0, 17] + nonce + [0, 0, 0, 7, 2, 1, 0, 0, 0x04])]
        let channel = try CTAPHIDChannel(hid, nonce: nonce)
        hid.replies = [ScriptedHID.packet(7, [0xBF, 0, 1, 0x06])]
        XCTAssertThrowsError(try channel.transact(0x90, [4], timeout: 1)) { XCTAssertEqual($0 as? FIDOError, .hid(6)) }

        hid.replies = [ScriptedHID.packet(7, [0x90, 0, 100] + [UInt8](repeating: 1, count: 57)), ScriptedHID.packet(7, [1, 2])]
        XCTAssertThrowsError(try channel.transact(0x90, [4], timeout: 1)) {
            guard case .malformed = $0 as? FIDOError else { return XCTFail("\($0)") }
        }

        hid.replies = []
        XCTAssertThrowsError(try channel.transact(0x90, [4], timeout: 1)) { XCTAssertEqual($0 as? FIDOError, .timeout) }
    }
}
