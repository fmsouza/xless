import XCTest
@testable import XlessFIDO

final class HIDRawTests: XCTestCase {
    /// A YubiKey 5's FIDO interface: usage page 0xF1D0, usage 1, 64-byte input and output reports.
    static let fido: [UInt8] = [
        0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01, 0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02,
        0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, 0xC0,
    ]
    /// A boot keyboard.
    static let keyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0xC0,
    ]

    func testRecognizesTheFIDOUsageAndReportSizes() {
        XCTAssertEqual(HIDDescriptor.parse(Self.fido), HIDDescriptor(isFIDO: true, inputSize: 64, outputSize: 64))
        XCTAssertFalse(HIDDescriptor.parse(Self.keyboard).isFIDO)
        // The FIDO usage page must be the top-level one, not an inner usage.
        XCTAssertFalse(HIDDescriptor.parse(Self.keyboard + [0x06, 0xD0, 0xF1, 0x09, 0x01]).isFIDO)
        // Truncated or empty descriptors are not FIDO, and do not crash.
        XCTAssertFalse(HIDDescriptor.parse(Array(Self.fido[0..<2])).isFIDO)
        XCTAssertFalse(HIDDescriptor.parse([]).isFIDO)
        XCTAssertFalse(HIDDescriptor.parse([0xFE, 0x05]).isFIDO)
    }

    #if os(Linux)
    func testListsOnlyTheFIDODevicesOfSysfs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-hidraw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func add(_ name: String, _ descriptor: [UInt8], uevent: String?) throws {
            let dir = root.appendingPathComponent("\(name)/device")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(descriptor).write(to: dir.appendingPathComponent("report_descriptor"))
            if let uevent { try Data(uevent.utf8).write(to: dir.appendingPathComponent("uevent")) }
        }
        try add("hidraw0", Self.keyboard, uevent: "HID_NAME=Some Keyboard\n")
        try add("hidraw3", Self.fido, uevent: "DRIVER=hid-generic\nHID_ID=0003:00001050:00000407\nHID_NAME=Yubico YubiKey OTP+FIDO+CCID\n")
        try add("hidraw7", Self.fido, uevent: nil)
        try add("hidraw12", Self.fido, uevent: "HID_NAME=Later Key\n")
        var tiny = Self.fido
        tiny[17] = 0x04; tiny[30] = 0x04 // four-byte reports: no CTAPHID device
        try add("hidraw9", tiny, uevent: nil)
        let devices = try HIDRawDevices.list(sysfs: root.path, dev: "/dev")
        XCTAssertEqual(devices.map(\.path), ["/dev/hidraw3", "/dev/hidraw7", "/dev/hidraw12"])
        XCTAssertEqual(devices.map(\.name), ["Yubico YubiKey OTP+FIDO+CCID", "hidraw7", "Later Key"])
        XCTAssertTrue(try HIDRawDevices.list(sysfs: root.appendingPathComponent("missing").path).isEmpty)
    }

    func testOpeningAPathItMayNotOpenSaysPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0, "root opens anything")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xless-hidraw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertThrowsError(try HIDRawDevices.Device(name: "k", path: file.path, reportSize: 64).open()) {
            XCTAssertEqual($0 as? HIDOpenError, .permissionDenied(file.path))
        }
    }
    #endif
}
