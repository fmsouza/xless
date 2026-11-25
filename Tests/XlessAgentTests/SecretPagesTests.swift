import CXlessProcess
import Foundation
import Testing
@testable import XlessAgent

/// What the kernel says of the mapping at `address`.
#if os(macOS)
private func isCopiedOnFork(_ address: UnsafeRawPointer) throws -> Bool {
    var at = vm_address_t(UInt(bitPattern: address)), size = vm_size_t(0), object = mach_port_t(0)
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
            vm_region_64(mach_task_self_, &at, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
        }
    }
    try #require(result == KERN_SUCCESS)
    try #require(at <= UInt(bitPattern: address))
    return info.inheritance != VM_INHERIT_NONE
}
#else
private func isCopiedOnFork(_ address: UnsafeRawPointer) throws -> Bool {
    var here = false
    for line in try String(contentsOfFile: "/proc/self/smaps", encoding: .utf8).split(separator: "\n") {
        if let m = line.wholeMatch(of: /([0-9a-f]+)-([0-9a-f]+) .*/), let from = UInt(m.1, radix: 16), let to = UInt(m.2, radix: 16) {
            here = (from..<to).contains(UInt(bitPattern: address))
        }
        if here, line.hasPrefix("VmFlags:") { return !line.split(separator: " ").contains("dc") }
    }
    throw CancellationError()
}
#endif

@Test func secretPagesAreNotInAForkedChild() throws {
    let pages = SecretPages(count: 100)
    let address = pages.withUnsafeBytes { $0.baseAddress! }
    do {
        #expect(try !isCopiedOnFork(address))
    } catch is CancellationError {} // a kernel that does not say (no smaps)
    withExtendedLifetime(pages) {}
}
