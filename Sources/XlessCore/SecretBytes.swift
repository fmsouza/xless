#if os(Windows)
import CXlessWindows
#else
import CXlessProcess
#endif
import Foundation

/// A secret's bytes (a password, a private key, a cookie value) in one heap buffer that is zeroed when it is released or
/// `wipe()`d, and that never prints: `description`, `debugDescription` and `dump` show only its size.
///
/// A class, so the bytes are never silently copied by value semantics; there is exactly one buffer per value. Not
/// synchronised: share it between tasks only to read it.
///
/// Where a `String` (or `Data`) copy cannot be avoided, it is out of this type's reach, and Swift gives no way to zero it:
/// - parsing PEM / `.p8` text (swift-crypto's `pemRepresentation:` initialisers take a `String`);
/// - HTTP header values (`URLRequest` headers are strings: cookies, `scnt`, `Authorization`);
/// - JSON bodies (`JSONSerialization` / `JSONEncoder` build their own copies);
/// - environment variables and files read through `Secrets` (CI's `NAME` / `NAME_FILE`).
/// Keep such copies short-lived and local; convert to `SecretBytes` as early as possible and back as late as possible.
public final class SecretBytes: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    private let release: (UnsafeMutableRawBufferPointer) -> Void

    /// `count` zero bytes.
    public convenience init(count: Int) {
        self.init(count: count, release: { $0.deallocate() })
    }

    /// Tests observe the release through `release`, which receives the (already zeroed) buffer to deallocate.
    init(count: Int, release: @escaping (UnsafeMutableRawBufferPointer) -> Void) {
        precondition(count >= 0, "negative SecretBytes count")
        buffer = .allocate(byteCount: count, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        self.release = release
    }

    /// A copy of `bytes`; the source is left as it is (prefer `init(wiping:)` when the caller owns it).
    public convenience init<C: Collection>(copying bytes: C) where C.Element == UInt8 {
        self.init(count: bytes.count)
        _ = UnsafeMutableBufferPointer(start: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), count: buffer.count)
            .initialize(from: bytes)
    }

    /// Moves `bytes` in: copies them, then zeroes the array.
    public convenience init(wiping bytes: inout [UInt8]) {
        self.init(copying: bytes)
        bytes.withUnsafeMutableBytes { Self.zero($0) }
    }

    /// Moves `data` in: copies it, then zeroes it.
    public convenience init(wiping data: inout Data) {
        self.init(copying: data)
        data.withUnsafeMutableBytes { Self.zero($0) }
    }

    /// The UTF-8 of `string` (the `String` itself stays wherever it came from).
    public convenience init(utf8 string: String) {
        self.init(copying: string.utf8)
    }

    deinit {
        Self.zero(buffer)
        release(buffer)
    }

    public var count: Int { buffer.count }
    public var isEmpty: Bool { buffer.isEmpty }

    /// Zeroes the bytes now (the size stays).
    public func wipe() { Self.zero(buffer) }

    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(buffer)
    }

    /// The first `length` bytes as a new value.
    public func prefix(_ length: Int) -> SecretBytes {
        withUnsafeBytes { SecretBytes(copying: $0.prefix(max(0, min(length, count)))) }
    }

    /// A `String` copy of the bytes, for an API that only takes one (see the type's note on unavoidable copies).
    public func utf8String() -> String {
        withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    /// Overwrites `bytes` with zeros in a way the optimiser may not remove.
    public static func zero(_ bytes: UnsafeMutableRawBufferPointer) {
        xless_secure_zero(bytes.baseAddress, bytes.count)
    }
}

extension SecretBytes: ContiguousBytes {
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(buffer))
    }
}

extension SecretBytes: Equatable {
    /// Constant time in the content: a mismatch early in the bytes takes as long to find as one at the end.
    public static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { l in
            rhs.withUnsafeBytes { r in
                var diff: UInt8 = 0
                for i in 0..<l.count { diff |= l[i] ^ r[i] }
                return diff == 0
            }
        }
    }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SecretBytes(\(count) bytes, redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
