import Crypto
import XCTest
import XlessCore
@testable import XlessFIDO

final class SecurityKeysTests: XCTestCase {
    let cdh = Array(SHA256.hash(data: Array("client data".utf8)))
    let registered = SimulatedKey.Credential(id: Array(repeating: 0x11, count: 64), userID: Array("user-1".utf8))
    let other = SimulatedKey.Credential(id: Array(repeating: 0x22, count: 64))

    func request(_ ids: [[UInt8]]) -> AssertionRequest { AssertionRequest(rpID: "apple.com", clientDataHash: cdh, credentials: ids) }

    func keys(_ devices: [SimulatedDevice]) -> USBSecurityKeys {
        USBSecurityKeys(devices: { devices }, touchTimeout: 2, sleep: { _ in })
    }

    func device(_ key: SimulatedKey, _ n: Int = 0) -> SimulatedDevice {
        SimulatedDevice(name: "Test Key \(n)", path: "/dev/hidraw\(n)", key: key)
    }

    /// The assertion verifies as WebAuthn does: the credential's key signed authenticatorData || clientDataHash.
    func assertVerifies(_ assertion: Assertion, with credential: SimulatedKey.Credential, file: StaticString = #filePath, line: UInt = #line) throws {
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(credential.key.publicKey.isValidSignature(signature, for: assertion.authenticatorData + cdh), file: file, line: line)
        XCTAssertEqual(Array(assertion.authenticatorData[0..<32]), Array(SHA256.hash(data: Array("apple.com".utf8))), file: file, line: line)
        XCTAssertEqual(assertion.credentialID, credential.id, file: file, line: line)
    }

    func assertFails(_ keys: USBSecurityKeys, _ request: AssertionRequest, ui: ScriptedUI = ScriptedUI(), cause: String,
                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await keys.assertion(for: request, ui: ui)
            XCTFail("expected an error", file: file, line: line)
        } catch let e as SecurityKeyError {
            XCTAssertTrue(e.cause.contains(cause), e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testSignsWithTheRegisteredCredential() async throws {
        let key = SimulatedKey(credentials: [registered])
        let ui = ScriptedUI()
        let assertion = try await keys([device(key)]).assertion(for: request([other.id, registered.id]), ui: ui)
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(assertion.authenticatorData[32] & 0x01, 1, "user present")
        XCTAssertEqual(assertion.userHandle, Array("user-1".utf8))
        XCTAssertEqual(key.log, ["init", "getInfo", "getAssertion probe", "getAssertion up"])
        XCTAssertEqual(ui.said, ["Touch your security key (Test Key 0) to sign in."])
        XCTAssertTrue(ui.prompts.isEmpty)
    }

    func testOnlyTheKeyHoldingTheCredentialIsAskedForATouch() async throws {
        let stranger = SimulatedKey(credentials: [other])
        let mine = SimulatedKey(credentials: [registered])
        let assertion = try await keys([device(stranger, 0), device(mine, 1)]).assertion(for: request([registered.id]), ui: ScriptedUI())
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(stranger.touchesAsked, 0)
        XCTAssertEqual(mine.touchesAsked, 1)
    }

    func testNoKeyHoldingTheCredential() async {
        let stranger = SimulatedKey(credentials: [other])
        await assertFails(keys([device(stranger)]), request([registered.id]), cause: "none of the connected security keys is registered")
        XCTAssertEqual(stranger.touchesAsked, 0)
        await assertFails(keys([device(stranger)]), request([]), cause: "registered")
    }

    func testWaitsForTheKeyToBePluggedIn() async throws {
        let key = SimulatedKey(credentials: [registered])
        final class Plugged: @unchecked Sendable { var devices: [SimulatedDevice] = [] }
        let plugged = Plugged()
        let ui = ScriptedUI()
        let dev = device(key)
        ui.onWaitForKey = { plugged.devices = [dev] }
        let source = USBSecurityKeys(devices: { plugged.devices }, touchTimeout: 2, sleep: { _ in })
        _ = try await source.assertion(for: request([registered.id]), ui: ui)
        XCTAssertEqual(ui.keyWaits, 1)
        XCTAssertTrue(ui.prompts.first?.contains("Plug in your security key") ?? false)

        let never = ScriptedUI()
        await assertFails(USBSecurityKeys(devices: { [] }, touchTimeout: 2), request([registered.id]), ui: never, cause: "no security key is connected")
        XCTAssertEqual(never.keyWaits, 3)
    }

    func testPermissionDeniedNamesTheDeviceAndTheUdevRule() async {
        var dev = device(SimulatedKey(credentials: [registered]), 3)
        dev.openError = .permissionDenied("/dev/hidraw3")
        do {
            _ = try await keys([dev]).assertion(for: request([registered.id]), ui: ScriptedUI())
            XCTFail("expected an error")
        } catch let e as SecurityKeyError {
            XCTAssertTrue(e.cause.contains("/dev/hidraw3"), e.cause)
            XCTAssertTrue(e.cause.contains("permission denied"), e.cause)
            XCTAssertTrue(e.fix.contains("udev rule"), e.fix)
            XCTAssertTrue(e.fix.contains("docs/apple-account.md#signing-in-with-a-security-key"), e.fix)
        } catch { XCTFail("\(error)") }
    }

    func testAKeyNobodyMayOpenIsSkippedWhenAnotherWorks() async throws {
        var locked = device(SimulatedKey(credentials: [registered]), 0)
        locked.openError = .permissionDenied("/dev/hidraw0")
        let assertion = try await keys([locked, device(SimulatedKey(credentials: [registered]), 1)])
            .assertion(for: request([registered.id]), ui: ScriptedUI())
        XCTAssertEqual(assertion.credentialID, registered.id)
    }

    func testNotTouchedAndRefused() async {
        let slow = SimulatedKey(credentials: [registered])
        slow.touch = .never
        await assertFails(keys([device(slow)]), request([registered.id]), cause: "not touched in time")
        let refusing = SimulatedKey(credentials: [registered])
        refusing.touch = .deny
        await assertFails(keys([device(refusing)]), request([registered.id]), cause: "refused")
    }

    func testThePINIsAskedOnlyWhenTheKeyWantsIt() async throws {
        let relaxed = SimulatedKey(credentials: [registered])
        relaxed.pin = "1234"
        let ui = ScriptedUI()
        _ = try await keys([device(relaxed)]).assertion(for: request([registered.id]), ui: ui)
        XCTAssertTrue(ui.prompts.isEmpty, "a key with a PIN does not need it for Apple's assertion")

        for (protocols, permissions) in [([2, 1], true), ([1], false)] {
            let strict = SimulatedKey(credentials: [registered])
            strict.pin = "1234"; strict.alwaysUV = true
            strict.pinProtocols = protocols; strict.tokenPermissions = permissions
            let asked = ScriptedUI(pins: ["1234"])
            let assertion = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: asked)
            try assertVerifies(assertion, with: registered)
            XCTAssertEqual(assertion.authenticatorData[32] & 0x04, 0x04, "user verified")
            XCTAssertEqual(asked.prompts, ["Security key PIN (8 tries left): "])
            XCTAssertEqual(asked.said.last, "Touch your security key (Test Key 0) to sign in.", "asked again once the PIN is in")
            XCTAssertTrue(strict.log.contains(permissions ? "clientPIN 9" : "clientPIN 5"), "\(strict.log)")
        }
    }

    func testAWrongPINIsAskedAgainWithTheTriesLeft() async throws {
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true
        let ui = ScriptedUI(pins: ["0000", "1234"])
        _ = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: ui)
        XCTAssertEqual(ui.prompts, ["Security key PIN (8 tries left): ", "Security key PIN (7 tries left): "])
        XCTAssertTrue(ui.said.contains("The security key did not accept that PIN."))
    }

    func testThreeWrongPINsStopBeforeTheKeyLocks() async {
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true
        await assertFails(keys([device(strict)]), request([registered.id]), ui: ScriptedUI(pins: ["0000", "1111", "2222"]),
                          cause: "stopped accepting PINs")
        XCTAssertEqual(strict.pinRetries, 5)
    }

    func testAShortPINIsRefusedWithoutSpendingATry() async throws {
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true
        let ui = ScriptedUI(pins: ["12", "1234"])
        _ = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: ui)
        XCTAssertTrue(ui.said.contains("A security key PIN has 4 to 63 characters."))
        XCTAssertEqual(strict.pinRetries, 8)

        let again = SimulatedKey(credentials: [registered])
        again.pin = "1234"; again.alwaysUV = true
        await assertFails(keys([device(again)]), request([registered.id]), ui: ScriptedUI(pins: ["1", "22", "333"]),
                          cause: "no PIN of 4 to 63 characters")
        XCTAssertEqual(again.pinRetries, 8)
    }

    func testAKeyCloseToLockingSaysSoBeforeThePIN() async throws {
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true; strict.pinRetries = 2
        let ui = ScriptedUI(pins: ["1234"])
        _ = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: ui)
        XCTAssertTrue(ui.said.contains { $0.hasPrefix("Careful: 2 wrong PINs and the key locks itself") }, "\(ui.said)")
        XCTAssertEqual(ui.prompts, ["Security key PIN (2 tries left): "])
    }

    func testTheTerminalGoingAwayIsNotBlamedOnTheKey() async {
        struct TerminalGone: Error {}
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true
        let ui = ScriptedUI()
        ui.pinError = TerminalGone()
        do {
            _ = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: ui)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is TerminalGone, "\(error)")
        }
    }

    func testAFailedFingerprintFallsBackToThePIN() async throws {
        let key = SimulatedKey(credentials: [registered])
        key.alwaysUV = true; key.builtInUV = true; key.uvFails = true; key.pin = "1234"
        let ui = ScriptedUI(pins: ["1234"])
        let assertion = try await keys([device(key)]).assertion(for: request([registered.id]), ui: ui)
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(ui.prompts.count, 1)
    }

    func testKeysThatCannotSayAreTriedInTurn() async throws {
        let first = SimulatedKey(credentials: [other]), second = SimulatedKey(credentials: [registered])
        for k in [first, second] { k.alwaysUV = true; k.builtInUV = true }
        let assertion = try await keys([device(first, 0), device(second, 1)]).assertion(for: request([registered.id]), ui: ScriptedUI())
        try assertVerifies(assertion, with: registered)
    }

    func testBlockedAndMissingPINs() async {
        let blocked = SimulatedKey(credentials: [registered])
        blocked.pin = "1234"; blocked.alwaysUV = true; blocked.pinRetries = 0
        await assertFails(keys([device(blocked)]), request([registered.id]), cause: "PIN is blocked")

        let noPIN = SimulatedKey(credentials: [registered])
        noPIN.alwaysUV = true
        await assertFails(keys([device(noPIN)]), request([registered.id]), cause: "has no PIN")
    }

    func testBuiltInVerificationIsUsedBeforeThePIN() async throws {
        let fingerprint = SimulatedKey(credentials: [registered])
        fingerprint.alwaysUV = true; fingerprint.builtInUV = true; fingerprint.pin = "1234"
        let ui = ScriptedUI()
        let assertion = try await keys([device(fingerprint)]).assertion(for: request([registered.id]), ui: ui)
        XCTAssertEqual(assertion.authenticatorData[32] & 0x04, 0x04)
        XCTAssertTrue(ui.prompts.isEmpty)
    }

    func testU2FOnlyKeys() async throws {
        let old = SimulatedKey(credentials: [registered])
        old.ctap2 = false
        let assertion = try await keys([device(old)]).assertion(for: request([other.id, registered.id]), ui: ScriptedUI())
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(assertion.authenticatorData.count, 37)
        XCTAssertNil(assertion.userHandle)
        XCTAssertEqual(old.log.filter { $0 == "u2f sign" }.count, 3, "asked again until touched")
        XCTAssertEqual(old.log.filter { $0 == "u2f wrong" }.count, 1, "the other credential was checked without a touch")

        let untouched = SimulatedKey(credentials: [registered])
        untouched.ctap2 = false; untouched.u2fWaits = .max
        let slowDevice = device(untouched)
        let slow = USBSecurityKeys(devices: { [slowDevice] }, touchTimeout: 0.05, sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
        await assertFails(slow, request([registered.id]), cause: "not touched in time")
    }

    func testLongAllowListsAreSentInPiecesTheKeyAccepts() async throws {
        let small = SimulatedKey(credentials: [registered])
        small.maxCredentialCountInList = 1
        let ids = [Array(repeating: UInt8(1), count: 32), Array(repeating: UInt8(2), count: 32), registered.id]
        let assertion = try await keys([device(small)]).assertion(for: request(ids), ui: ScriptedUI())
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(small.log.filter { $0 == "getAssertion probe" }.count, 3)
        XCTAssertEqual(small.touchesAsked, 1)
    }

    func testALeftOutCredentialIDIsTheOneAskedFor() async throws {
        let terse = SimulatedKey(credentials: [registered])
        terse.omitCredentialForOneItemList = true
        let assertion = try await keys([device(terse)]).assertion(for: request([other.id, registered.id]), ui: ScriptedUI())
        XCTAssertEqual(assertion.credentialID, registered.id)
    }

    func testAnAssertionForAnotherRelyingPartyIsRefused() async {
        let liar = SimulatedKey(credentials: [registered])
        liar.signRPOverride = "evil.example"
        await assertFails(keys([device(liar)]), request([registered.id]), cause: "does not match")
    }

    func testAnswersOnOtherChannelsDoNotConfuseTheExchange() async throws {
        let shared = SimulatedKey(credentials: [registered])
        shared.noise = true
        let assertion = try await keys([device(shared)]).assertion(for: request([registered.id]), ui: ScriptedUI())
        try assertVerifies(assertion, with: registered)
    }

    func testAKeyWithAPINAndAlwaysUVIsStillProbedThenAskedForThePIN() async throws {
        // alwaysUv keys refuse even the silent check: the key is used anyway, and the real request asks for the PIN.
        let strict = SimulatedKey(credentials: [registered])
        strict.pin = "1234"; strict.alwaysUV = true
        let assertion = try await keys([device(strict)]).assertion(for: request([registered.id]), ui: ScriptedUI(pins: ["1234"]))
        try assertVerifies(assertion, with: registered)
        XCTAssertEqual(strict.log.first { $0.hasPrefix("getAssertion") }, "getAssertion probe")
    }
}
