#if os(macOS)
import Foundation
import IOKit
import IOKit.hid

/// A HID device as IOKit's registry shows it, and the way to open it. `port` is nil when it went away meanwhile.
struct HIDService {
    let id: UInt64
    let properties: [String: Any]
    let port: () -> (any HIDPort)?
}

/// An opened HID device: reports go out with `send`, and come in to `input` (called on any thread). A fake in the tests.
protocol HIDPort: AnyObject {
    func open(input: @escaping @Sendable ([UInt8]) -> Void, removed: @escaping @Sendable () -> Void) -> IOReturn
    func send(_ report: [UInt8]) -> IOReturn
    func close()
}

/// The FIDO devices among the HID devices of a Mac, through IOKit's public HID API. Listing opens nothing.
public enum IOKitHIDDevices {
    struct Device: SecurityKeyDevice {
        let name: String
        let path: String
        let reportSize: Int
        let port: () -> (any HIDPort)?

        func open() throws -> HIDConnection {
            guard let port = port() else { throw HIDOpenError.failed(name, "it was unplugged") }
            return try HIDPortConnection(port, name: name, reportSize: reportSize)
        }
    }

    public static func list() throws -> [any SecurityKeyDevice] { try list(services: IOKitHIDPort.services) }

    /// The FIDO devices among `services`, sorted by their number.
    static func list(services: () throws -> [HIDService]) throws -> [any SecurityKeyDevice] {
        try services().sorted { $0.id < $1.id }.compactMap { service -> Device? in
            func number(_ key: String) -> Int { service.properties[key] as? Int ?? 0 }
            let size = number(kIOHIDMaxInputReportSizeKey)
            guard number(kIOHIDPrimaryUsagePageKey) == Int(HIDDescriptor.fidoUsagePage), number(kIOHIDPrimaryUsageKey) == 1,
                  HIDDescriptor.usableReportSizes.contains(size), number(kIOHIDMaxOutputReportSizeKey) == size else { return nil }
            return Device(name: name(service.properties), path: "ioreg:\(service.id)", reportSize: size, port: service.port)
        }
    }

    /// The maker and the product, as the device says, without what a terminal would act on.
    private static func name(_ properties: [String: Any]) -> String {
        func text(_ key: String) -> String {
            let said = properties[key] as? String ?? ""
            guard !said.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return "" }
            return said.trimmingCharacters(in: .whitespaces)
        }
        let maker = text(kIOHIDManufacturerKey), product = text(kIOHIDProductKey)
        let name = product.hasPrefix(maker) ? product : "\(maker) \(product)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "security key" : name
    }
}

/// The reports a device sent that nobody has read yet.
final class HIDReportQueue: @unchecked Sendable {
    /// More than the largest message has packets (129).
    static let limit = 256
    private let condition = NSCondition()
    private var reports: [[UInt8]] = []
    private var ended = false

    /// With `limit` reports unread, the oldest goes: the message it is of is lost either way.
    func push(_ report: [UInt8]) {
        condition.lock(); defer { condition.unlock() }
        if reports.count == Self.limit { reports.removeFirst() }
        reports.append(report)
        condition.signal()
    }

    func end() {
        condition.lock(); defer { condition.unlock() }
        ended = true
        condition.broadcast()
    }

    func next(timeout milliseconds: Int) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        condition.lock(); defer { condition.unlock() }
        while reports.isEmpty {
            if ended { throw FIDOError.io("the security key was unplugged") }
            guard Date() < deadline else { return nil }
            _ = condition.wait(until: deadline)
        }
        return reports.removeFirst()
    }
}

final class HIDPortConnection: HIDConnection {
    let reportSize: Int
    private let port: any HIDPort
    private let queue: HIDReportQueue

    init(_ port: any HIDPort, name: String, reportSize: Int) throws {
        self.reportSize = reportSize
        self.port = port
        let queue = HIDReportQueue()
        self.queue = queue
        switch port.open(input: { queue.push($0) }, removed: { queue.end() }) {
        case kIOReturnSuccess: return
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: throw HIDOpenError.permissionDenied(name)
        case kIOReturnExclusiveAccess: throw HIDOpenError.busy
        case let code: throw HIDOpenError.failed(name, Self.describe(code))
        }
    }

    deinit { port.close() }

    func write(_ report: [UInt8]) throws {
        let code = port.send(report)
        guard code == kIOReturnSuccess else { throw FIDOError.io("writing to the security key failed: \(Self.describe(code))") }
    }

    func read(timeout milliseconds: Int) throws -> [UInt8]? { try queue.next(timeout: milliseconds) }

    private static func describe(_ code: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }
}

/// A HID device through IOKit. It is not seized: a browser may have it open too, and CTAPHID keeps their channels apart.
final class IOKitHIDPort: HIDPort, @unchecked Sendable {
    private final class Sink {
        let input: @Sendable ([UInt8]) -> Void
        let removed: @Sendable () -> Void
        init(input: @escaping @Sendable ([UInt8]) -> Void, removed: @escaping @Sendable () -> Void) { self.input = input; self.removed = removed }
    }
    private static let bufferSize = 1024

    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "xless.hid")
    private var isOpen = false

    private init(_ device: IOHIDDevice) { self.device = device }

    /// Every HID device of the system.
    static func services() throws -> [HIDService] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [HIDService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == kIOReturnSuccess else { continue }
            var properties: [String: Any] = [:]
            for key in [kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey, kIOHIDMaxOutputReportSizeKey,
                        kIOHIDManufacturerKey, kIOHIDProductKey] {
                properties[key] = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            found.append(HIDService(id: id, properties: properties, port: { port(id) }))
        }
        return found
    }

    private static func port(_ id: UInt64) -> IOKitHIDPort? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id)) // it takes the dictionary
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IOHIDDeviceCreate(kCFAllocatorDefault, entry).map(IOKitHIDPort.init)
    }

    func open(input: @escaping @Sendable ([UInt8]) -> Void, removed: @escaping @Sendable () -> Void) -> IOReturn {
        let code = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard code == kIOReturnSuccess else { return code }
        isOpen = true
        nonisolated(unsafe) let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
        let sink = Unmanaged.passRetained(Sink(input: input, removed: removed))
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, { context, result, _, _, _, bytes, count in
            guard let context, result == kIOReturnSuccess, count > 0 else { return }
            Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().input(Array(UnsafeBufferPointer(start: bytes, count: count)))
        }, sink.toOpaque())
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().removed()
        }, sink.toOpaque())
        IOHIDDeviceSetDispatchQueue(device, queue)
        // Called once nothing calls the two above any more.
        nonisolated(unsafe) let (device, held) = (device, sink)
        IOHIDDeviceSetCancelHandler(device) {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
            held.release()
        }
        IOHIDDeviceActivate(device)
        return kIOReturnSuccess
    }

    func send(_ report: [UInt8]) -> IOReturn {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceCancel(device)
    }
}
#endif
