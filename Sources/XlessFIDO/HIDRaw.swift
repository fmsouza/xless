import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What a HID report descriptor says, as far as FIDO cares: whether the device's top-level usage is the FIDO
/// authenticator (usage page 0xF1D0, usage 0x01), and its input and output report sizes in bytes.
public struct HIDDescriptor: Equatable, Sendable {
    public static let fidoUsagePage: UInt32 = 0xF1D0
    public let isFIDO: Bool
    public let inputSize: Int
    public let outputSize: Int

    /// Parses the short items of a report descriptor (HID 1.11, section 6.2.2). Long items are skipped.
    public static func parse(_ bytes: [UInt8]) -> HIDDescriptor {
        var usagePage: UInt32?, firstUsage: UInt32?, firstUsagePage: UInt32?
        var reportSize: UInt32 = 0, reportCount: UInt32 = 0
        var input = 0, output = 0
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item: size in the next byte, then a tag
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            guard i + size < bytes.count else { break }
            var value: UInt32 = 0
            for k in 0..<size { value |= UInt32(bytes[i + 1 + k]) << (8 * UInt32(k)) }
            let type = (prefix >> 2) & 0x03, tag = prefix >> 4
            switch (type, tag) {
            case (1, 0x0): usagePage = value
            case (1, 0x7): reportSize = value
            case (1, 0x9): reportCount = value
            case (2, 0x0):
                if firstUsage == nil { firstUsage = value; firstUsagePage = usagePage }
            case (0, 0x8): input += Int(reportSize * reportCount)
            case (0, 0x9): output += Int(reportSize * reportCount)
            default: break
            }
            i += 1 + size
        }
        return HIDDescriptor(isFIDO: firstUsagePage == fidoUsagePage && firstUsage == 0x01, inputSize: input / 8, outputSize: output / 8)
    }
}

/// The FIDO devices among the Linux hidraw devices: /sys/class/hidraw/hidrawN (report descriptor and name, readable by
/// anyone) and /dev/hidrawN (opened read-write, which needs a udev rule on some systems).
public struct HIDRawDevices {
    public struct Device: SecurityKeyDevice {
        public let name: String
        public let path: String
        public let reportSize: Int
        public func open() throws -> HIDConnection {
            #if os(Linux)
            try HIDRawConnection(path: path, reportSize: reportSize)
            #else
            throw SecurityKeyError.notLinux
            #endif
        }
    }

    /// The FIDO devices, sorted by path. `sysfs` and `dev` are for tests.
    public static func list(sysfs: String = "/sys/class/hidraw", dev: String = "/dev") throws -> [any SecurityKeyDevice] {
        #if os(Linux)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sysfs)) ?? []
        var found: [Device] = []
        for entry in names.sorted() where entry.hasPrefix("hidraw") {
            let base = "\(sysfs)/\(entry)/device"
            guard let descriptor = FileManager.default.contents(atPath: "\(base)/report_descriptor") else { continue }
            let parsed = HIDDescriptor.parse(Array(descriptor))
            guard parsed.isFIDO else { continue }
            let size = parsed.inputSize > 0 ? parsed.inputSize : 64
            found.append(Device(name: name(uevent: "\(base)/uevent") ?? entry, path: "\(dev)/\(entry)", reportSize: size))
        }
        return found
        #else
        throw SecurityKeyError.notLinux
        #endif
    }

    /// HID_NAME from a uevent file.
    static func name(uevent path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("HID_NAME=") {
            let value = line.dropFirst("HID_NAME=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

#if os(Linux)
/// /dev/hidrawN: one write per output report (with report ID 0 in front, as hidraw wants for devices without report
/// IDs), one read per input report.
final class HIDRawConnection: HIDConnection {
    let reportSize: Int
    private let fd: Int32

    init(path: String, reportSize: Int) throws {
        self.reportSize = reportSize
        fd = open(path, O_RDWR | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM { throw HIDOpenError.permissionDenied(path) }
            throw HIDOpenError.failed(path, String(cString: strerror(code)))
        }
    }

    deinit { close(fd) }

    func write(_ report: [UInt8]) throws {
        let packet = [0] + report
        while true {
            let n = packet.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n == packet.count { return }
            if n < 0 && errno == EINTR { continue }
            throw FIDOError.io("writing to the security key failed: \(n < 0 ? String(cString: strerror(errno)) : "short write")")
        }
    }

    func read(timeout milliseconds: Int) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        var buffer = [UInt8](repeating: 0, count: reportSize + 1)
        while true {
            let left = Int32(clamping: max(0, Int(deadline.timeIntervalSinceNow * 1000)))
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, left)
            if ready < 0 {
                if errno == EINTR { continue }
                throw FIDOError.io("waiting for the security key failed: \(String(cString: strerror(errno)))")
            }
            if ready == 0 { return nil }
            if poller.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && poller.revents & Int16(POLLIN) == 0 {
                throw FIDOError.io("the security key was unplugged")
            }
            let n = buffer.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FIDOError.io("reading from the security key failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw FIDOError.io("the security key was unplugged") }
            return Array(buffer[0..<n])
        }
    }
}
#endif
