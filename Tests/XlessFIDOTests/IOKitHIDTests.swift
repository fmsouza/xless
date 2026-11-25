#if os(macOS)
import Crypto
import Foundation
import IOKit
import XCTest
import XlessCore
@testable import XlessFIDO

/// A HID device of no hardware: what is sent to it goes to a simulated key, whose answers come as input reports.
private final class FakePort: HIDPort, @unchecked Sendable {
    let key: SimulatedKey
    var openResult = kIOReturnSuccess
    var sendResult = kIOReturnSuccess
    private(set) var opened = 0, closed = 0, sends = 0
    var beforeSend: (() -> Void)?
    private var input: (@Sendable ([UInt8]) -> Void)?
    private(set) var remove: (@Sendable () -> Void)?

    init(_ key: SimulatedKey) { self.key = key }

    func open(input: @escaping @Sendable ([UInt8]) -> Void, removed: @escaping @Sendable () -> Void) -> IOReturn {
        opened += 1
        guard openResult == kIOReturnSuccess else { return openResult }
        (self.input, remove) = (input, removed)
        return kIOReturnSuccess
    }

    func send(_ report: [UInt8]) -> IOReturn {
        sends += 1
        beforeSend?()
        guard sendResult == kIOReturnSuccess else { return sendResult }
        do {
            try key.write(report)
            while let answer = try key.read(timeout: 0) { input?(answer) }
        } catch { return kIOReturnIOError }
        return kIOReturnSuccess
    }

    func close() { closed += 1 }
}

final class IOKitHIDTests: XCTestCase {
    private let credential = SimulatedKey.Credential(id: Array(repeating: 0x11, count: 64))

    private func service(_ port: FakePort, _ properties: [String: Any] = [:], id: UInt64 = 1) -> HIDService {
        var all: [String: Any] = ["PrimaryUsagePage": 0xF1D0, "PrimaryUsage": 1, "MaxInputReportSize": 64, "MaxOutputReportSize": 64,
                                  "Manufacturer": "Yubico", "Product": "YubiKey OTP+FIDO+CCID"]
        all.merge(properties) { $1 }
        return HIDService(id: id, properties: all, port: { port })
    }

    private func port() -> FakePort { FakePort(SimulatedKey(credentials: [credential])) }

    private func sign(_ ports: [FakePort]) async throws -> Assertion {
        nonisolated(unsafe) let services = ports.enumerated().map { service($1, id: UInt64($0)) }
        return try await USBSecurityKeys(devices: { try IOKitHIDDevices.list { services } }, touchTimeout: 2, sleep: { _ in })
            .assertion(for: AssertionRequest(rpID: "apple.com", clientDataHash: Array(repeating: 7, count: 32), credentials: [credential.id]),
                       ui: ScriptedUI())
    }

    func testListsOnlyTheFIDODevices() throws {
        let p = port()
        let devices = try IOKitHIDDevices.list { [
            service(p, ["PrimaryUsagePage": 1, "PrimaryUsage": 6], id: 1),                    // a keyboard
            service(p, id: 0x2_0000_0007),
            service(p, ["PrimaryUsage": 2], id: 3),
            service(p, ["MaxInputReportSize": 4, "MaxOutputReportSize": 4], id: 4),           // no CTAPHID reports
            service(p, ["MaxOutputReportSize": 32], id: 5),
            service(p, ["Product": NSNull(), "Manufacturer": "\u{1b}[31m\n"], id: 6),
            service(p, ["Manufacturer": "SoloKeys", "Product": "SoloKeys Solo 2"], id: 7),
            HIDService(id: 8, properties: [:], port: { nil }),
        ] }
        XCTAssertEqual(devices.map(\.name), ["security key", "SoloKeys Solo 2", "Yubico YubiKey OTP+FIDO+CCID"])
        XCTAssertEqual(devices.map(\.path), ["ioreg:6", "ioreg:7", "ioreg:8589934599"])
        XCTAssertEqual(p.opened, 0)
    }

    /// A name is printed beside the question for a PIN: nothing in it changes the line, and it is short.
    func testANameIsPrintableAndShort() throws {
        func name(_ product: String, _ maker: String = "") throws -> String {
            try IOKitHIDDevices.list { [service(port(), ["Manufacturer": maker, "Product": product])] }[0].name
        }
        for bad in ["a\u{202E}b", "a\u{2028}b", "a\u{2029}b", "a\u{200B}b", "a\u{FEFF}b", "a\u{E000}b", "a\u{0378}b", "a\u{85}b", "a\u{7F}b", "a\tb", "a\u{2066}b", "a\u{A0}b"] {
            XCTAssertEqual(try name(bad), "security key", bad.debugDescription)
            XCTAssertEqual(try name("Key", bad), "Key", bad.debugDescription)
        }
        XCTAssertEqual(try name("Schlüssel №5 (日本)", "Ünïted"), "Ünïted Schlüssel №5 (日本)")
        XCTAssertEqual(try name(String(repeating: "x", count: 5000)), String(repeating: "x", count: 64))
        XCTAssertEqual(try name(String(repeating: "x", count: 60), "Maker").unicodeScalars.count, 64)
        XCTAssertEqual(try name("e" + String(repeating: "\u{301}", count: 5000)).unicodeScalars.count, 64)
    }

    /// A device that never takes a report does not hold the sign-in.
    func testAKeyThatTakesNoReportIsGivenUp() throws {
        let p = port()
        let stuck = DispatchSemaphore(value: 0)
        p.beforeSend = { stuck.wait() }
        let connection = try HIDPortConnection(p, name: "key", reportSize: 64, writeTimeout: 0.2)
        for _ in 0..<2 { // the second one waits for nothing
            let start = Date()
            XCTAssertThrowsError(try connection.write(Array(repeating: 0, count: 64))) {
                XCTAssertEqual($0 as? FIDOError, .io("the security key does not take what it is sent"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        }
        XCTAssertEqual(p.sends, 1)
        stuck.signal()
    }

    /// The real listing opens nothing, so it asks the person for no permission, and works where no key is plugged in.
    func testTheListingOfThisMac() throws { _ = try IOKitHIDDevices.list() }

    func testSignsThroughIOKit() async throws {
        let p = port()
        let assertion = try await sign([p])
        XCTAssertEqual(assertion.credentialID, credential.id)
        XCTAssertEqual(p.opened, 1)
        XCTAssertEqual(p.closed, 1)
    }

    func testNotPermittedNamesTheSettingAndOtherWays() async {
        for code in [kIOReturnNotPermitted, kIOReturnNotPrivileged] {
            let p = port()
            p.openResult = code
            do {
                _ = try await sign([p])
                XCTFail("expected an error")
            } catch let e as SecurityKeyError {
                XCTAssertTrue(e.cause.contains("macOS does not let xless open the security key (Yubico YubiKey OTP+FIDO+CCID)"), e.cause)
                XCTAssertTrue(e.fix.contains("Input Monitoring"), e.fix)
                XCTAssertTrue(e.fix.contains("two-factor codes"), e.fix)
                XCTAssertTrue(e.fix.contains("docs/apple-account.md#signing-in-with-a-security-key"), e.fix)
            } catch { XCTFail("\(error)") }
        }
    }

    func testAKeyAnotherProgramHolds() async {
        let p = port()
        p.openResult = kIOReturnExclusiveAccess
        do { _ = try await sign([p]); XCTFail("expected an error") } catch { XCTAssertEqual(error as? SecurityKeyError, USBSecurityKeys.busy) }
        // ... does not keep another one from signing
        let free = port()
        let assertion = try? await sign([p, free])
        XCTAssertEqual(assertion?.credentialID, credential.id)
    }

    func testOtherFailuresToOpenAndToSend() async {
        let p = port()
        p.openResult = kIOReturnNoDevice
        do { _ = try await sign([p]); XCTFail("expected an error") } catch {
            XCTAssertTrue("\(error)".contains("cannot open the security key") && "\(error)".contains("0xe00002c0"), "\(error)")
        }
        let q = port()
        q.sendResult = kIOReturnAborted
        do { _ = try await sign([q]); XCTFail("expected an error") } catch {
            XCTAssertTrue("\(error)".contains("lost the security key (writing to the security key failed: 0xe00002eb)"), "\(error)")
        }
        XCTAssertEqual(q.closed, 1)
    }

    func testReadsInOrderTimesOutAndEndsWithAnUnpluggedKey() throws {
        let queue = HIDReportQueue()
        XCTAssertNil(try queue.next(timeout: 20))
        queue.push([1, 2, 3, 4]); queue.push([5, 6, 7, 8])
        XCTAssertEqual(try queue.next(timeout: 0), [1, 2, 3, 4])
        XCTAssertEqual(try queue.next(timeout: 1000), [5, 6, 7, 8])
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.05); queue.push([9, 9, 9, 9]) }
        XCTAssertEqual(try queue.next(timeout: 10_000), [9, 9, 9, 9])
        queue.push([1, 1, 1, 1]); queue.end()
        XCTAssertEqual(try queue.next(timeout: 0), [1, 1, 1, 1])
        XCTAssertThrowsError(try queue.next(timeout: 10_000)) { XCTAssertEqual($0 as? FIDOError, .io("the security key was unplugged")) }
    }

    /// A key that floods it while nobody reads takes a bounded amount of memory.
    func testKeepsABoundedNumberOfReports() throws {
        let queue = HIDReportQueue()
        for i in 0..<10_000 { queue.push([UInt8(truncatingIfNeeded: i)]) }
        var n = 0
        while try queue.next(timeout: 0) != nil { n += 1 }
        XCTAssertEqual(n, HIDReportQueue.limit)
    }
}
#endif
