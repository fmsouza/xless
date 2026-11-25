import CXlessProcess
import Foundation
import XlessCore

/// Bytes in pages of their own: locked against swap where the limits allow, kept out of core dumps and of forked
/// children, zeroed when wiped or released. What the agent keeps and what it sends and receives secrets in.
final class SecretPages: @unchecked Sendable {
    private let base: UnsafeMutableRawPointer
    let count: Int
    /// Whether the pages cannot be swapped out (the limit on locked memory was not reached).
    let isLocked: Bool

    init(count: Int) {
        var locked: Int32 = 0
        guard let p = xless_secret_map(count, &locked) else { fatalError("out of memory") }
        base = p
        self.count = count
        isLocked = locked != 0
    }

    convenience init(_ secret: SecretBytes) {
        self.init(count: secret.count)
        secret.withUnsafeBytes { if let from = $0.baseAddress { base.copyMemory(from: from, byteCount: $0.count) } }
    }

    deinit { xless_secret_unmap(base, count) }

    func wipe() { xless_secure_zero(base, count) }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: base, count: count))
    }

    func copy() -> SecretBytes { withUnsafeBytes { SecretBytes(copying: $0) } }

    func utf8String() -> String { withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }

    /// In time that does not depend on where they differ.
    static func same(_ a: SecretPages, _ b: SecretBytes) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { l in
            b.withUnsafeBytes { r in
                var diff: UInt8 = 0
                for i in 0..<l.count { diff |= l[i] ^ r[i] }
                return diff == 0
            }
        }
    }
}

extension SecretPages: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SecretPages(\(count) bytes, redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
