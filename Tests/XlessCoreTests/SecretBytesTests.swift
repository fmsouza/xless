import Foundation
import Testing
@testable import XlessCore

/// Records what the buffer held at the moment it was handed back for deallocation.
private final class ReleaseProbe: @unchecked Sendable {
    var seen: [UInt8]?
    func release(_ buffer: UnsafeMutableRawBufferPointer) {
        seen = Array(buffer)
        buffer.deallocate()
    }
}

@Test func secretBytesAreZeroedBeforeTheirMemoryIsReleased() {
    let probe = ReleaseProbe()
    do {
        let secret = SecretBytes(count: 8, release: probe.release)
        secret.withUnsafeMutableBytes { $0.copyBytes(from: Array("hunter2!".utf8)) }
        #expect(secret.utf8String() == "hunter2!")
    }
    #expect(probe.seen == [UInt8](repeating: 0, count: 8))
}

@Test func wipeZeroesTheBytesAndKeepsTheSize() {
    let secret = SecretBytes(utf8: "correct horse")
    secret.wipe()
    #expect(secret.count == 13)
    secret.withUnsafeBytes { #expect($0.allSatisfy { $0 == 0 }) }
}

@Test func wipingInitialisersZeroTheirSource() {
    var array = Array("p8-private-key".utf8)
    let fromArray = SecretBytes(wiping: &array)
    #expect(array == [UInt8](repeating: 0, count: 14))
    #expect(fromArray.utf8String() == "p8-private-key")

    var data = Data("cookie-value".utf8)
    let fromData = SecretBytes(wiping: &data)
    #expect(data == Data(count: 12))
    #expect(fromData.utf8String() == "cookie-value")
}

@Test func secretBytesNeverPrintTheirContent() {
    let secret = SecretBytes(utf8: "FAKE-SECRET-VALUE")
    var dumped = ""
    dump(secret, to: &dumped)
    for text in ["\(secret)", String(describing: secret), String(reflecting: secret), dumped, "\([secret])"] {
        #expect(!text.contains("FAKE"), "printed: \(text)")
        #expect(!text.contains("70"), "printed bytes: \(text)") // 0x46 'F' as a decimal byte
    }
    #expect("\(secret)" == "SecretBytes(17 bytes, redacted)")
}

@Test func secretBytesCompareByContentAndPrefix() {
    #expect(SecretBytes(utf8: "abc") == SecretBytes(copying: [0x61, 0x62, 0x63]))
    #expect(SecretBytes(utf8: "abc") != SecretBytes(utf8: "abd"))
    #expect(SecretBytes(utf8: "abc") != SecretBytes(utf8: "ab"))
    #expect(SecretBytes(utf8: "abcdef").prefix(3) == SecretBytes(utf8: "abc"))
    #expect(SecretBytes(utf8: "ab").prefix(9).count == 2)
    #expect(SecretBytes(count: 0).isEmpty)
}
