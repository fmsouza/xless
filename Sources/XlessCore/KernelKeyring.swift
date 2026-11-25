import CXlessProcess
import Foundation

/// The Linux kernel keyring, for secrets a later command of the same login session may reuse for a bounded time (the
/// secret store's unlock, the opt-in Apple ID session). Keys go into the session keyring as `user` keys readable only by
/// a possessor (a process that has that session keyring, as with `ssh-agent`: the same login session, not other users),
/// and the kernel itself expires them after at most an hour. Raw syscalls, no libkeyutils: the static musl build works.
///
/// Not available everywhere: macOS has no such keyring, and containers often block the syscalls (Docker's default
/// seccomp profile does). Callers check `isAvailable` and treat a missing keyring as "no cache".
public enum KernelKeyring {
    public struct Key: Sendable, Hashable {
        public let serial: Int32
    }

    /// A failed keyring call: the operation and its errno.
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public let operation: String
        public let code: Int32
        public var description: String { "kernel keyring: \(operation) failed: \(String(cString: strerror(code)))" }
    }

    /// The longest a key may live: one hour.
    public static let maximumTimeout = 3600

    /// Possessor view, read, search, link and setattr (not write); nothing for the user, group or others
    /// (`KEY_POS_VIEW | KEY_POS_READ | KEY_POS_SEARCH | KEY_POS_LINK | KEY_POS_SETATTR`).
    public static let possessorOnly: UInt32 = 0x3b00_0000

    private static let sessionKeyring = Int32(XLESS_KEY_SPEC_SESSION_KEYRING)
    private static let userSessionKeyring = Int32(XLESS_KEY_SPEC_USER_SESSION_KEYRING)
    /// ENOKEY, EKEYEXPIRED, EKEYREVOKED (Linux's values; the calls only succeed on Linux).
    private static let gone: [Int32] = [126, 127, 128]

    /// Whether the kernel keyring can be used by this process (a session keyring is there or can be joined).
    public static var isAvailable: Bool { xless_key_keyring_id(sessionKeyring) >= 0 }

    /// Leaves the session keyring for a new, empty one, for this process and its children: a remembered unlock or a
    /// kept Apple ID session (possessor-only keys) is out of their reach. False where there is no keyring.
    @discardableResult
    public static func leaveSession() -> Bool { xless_key_join_new_session() >= 0 }

    /// `leaveSession`, throwing the kernel's reason when it fails. Linux credentials belong to a thread: the calling
    /// thread, and the threads and processes it starts from then on, get the new keyring; the process's other threads
    /// keep theirs (`ChildProcess.start` relies on this).
    public static func joinNewSession() throws {
        if xless_key_join_new_session() < 0 { throw failure("join_session_keyring") }
    }

    /// Stores `secret` as the `user` key `name` in the session keyring (replacing a key of that name), possessor-only,
    /// expiring after `timeout` seconds (1…3600). If the permissions or the timeout cannot be set, the key is revoked
    /// and the call fails: a key never outlives its bound or is readable more widely than asked. A key of that name there
    /// already is revoked first: add_key would update it, which its permissions refuse.
    @discardableResult
    public static func store(name: String, secret: SecretBytes, timeout: Int) throws -> Key {
        guard (1...maximumTimeout).contains(timeout) else {
            throw Failure(operation: "store (timeout \(timeout)s is outside 1…\(maximumTimeout)s)", code: EINVAL)
        }
        while let old = try find(name: name) {
            if xless_key_revoke(old.serial) < 0, !gone.contains(errno) { throw failure("revoke") }
        }
        let serial = secret.withUnsafeBytes { xless_key_add(name, $0.baseAddress, $0.count, sessionKeyring) }
        guard serial >= 0 else { throw failure("add_key") }
        let key = Key(serial: Int32(serial))
        do {
            try check(xless_key_setperm(key.serial, possessorOnly), "setperm")
            try check(xless_key_set_timeout(key.serial, UInt32(timeout)), "set_timeout")
            // Every process of the user possesses the user's default session keyring (it is reachable by its special ID
            // from any session), so a key there is no secret from the code the user builds. Linux gives a process
            // without a session keyring of its own a fresh one when a key is added to it, so this does not happen; if
            // a kernel ever did, the key is revoked rather than left there.
            if xless_key_search(userSessionKeyring, name) == serial {
                throw Failure(operation: "store (the key would be in your user's default session keyring, which every process of yours can read)", code: EPERM)
            }
        } catch {
            _ = xless_key_revoke(key.serial)
            throw error
        }
        return key
    }

    /// The key named `name` in the session keyring, or nil when there is none (or it expired or was revoked).
    public static func find(name: String) throws -> Key? {
        let serial = xless_key_search(sessionKeyring, name)
        if serial >= 0 { return Key(serial: Int32(serial)) }
        let code = errno
        if gone.contains(code) { return nil }
        throw Failure(operation: "search", code: code)
    }

    /// The key's payload, straight into a `SecretBytes`.
    public static func read(_ key: Key) throws -> SecretBytes {
        while true {
            let size = xless_key_read(key.serial, nil, 0)
            guard size >= 0 else { throw failure("read") }
            let bytes = SecretBytes(count: Int(size))
            let got = bytes.withUnsafeMutableBytes { xless_key_read(key.serial, $0.baseAddress, $0.count) }
            guard got >= 0 else { throw failure("read") }
            if got == size { return bytes }
            // The key changed size between the two calls (it was updated): read again.
        }
    }

    /// The key's permission mask, as the kernel reports it (KEYCTL_DESCRIBE).
    public static func permissions(_ key: Key) throws -> UInt32 {
        var buffer = [CChar](repeating: 0, count: 512)
        let size = buffer.withUnsafeMutableBufferPointer { xless_key_describe(key.serial, $0.baseAddress, $0.count) }
        guard size >= 0 else { throw failure("describe") }
        let fields = String(cString: buffer).split(separator: ";", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, let perm = UInt32(fields[3], radix: 16) else { throw Failure(operation: "describe", code: EINVAL) }
        return perm
    }

    /// Revokes the key: it can no longer be read and the kernel drops it.
    public static func revoke(_ key: Key) throws {
        try check(xless_key_revoke(key.serial), "revoke")
    }

    /// Revokes every key of the session keyring whose name starts with `prefix`; how many.
    @discardableResult
    public static func revokeAll(prefix: String) throws -> Int {
        guard isAvailable else { return 0 }
        var serials = [Int32](repeating: 0, count: 256)
        while true {
            let size = serials.withUnsafeMutableBytes { xless_key_read(sessionKeyring, $0.baseAddress, $0.count) }
            guard size >= 0 else { throw failure("read (session keyring)") }
            let count = Int(size) / MemoryLayout<Int32>.size
            if count <= serials.count { serials.removeLast(serials.count - count); break }
            serials = [Int32](repeating: 0, count: count)
        }
        var revoked = 0
        var failed: Failure?
        for serial in serials where name(serial)?.hasPrefix(prefix) == true {
            if xless_key_revoke(serial) >= 0 { revoked += 1 } else if !gone.contains(errno) { failed = failure("revoke") }
        }
        if let failed { throw failed }
        return revoked
    }

    /// The name of a `user` key this process may look at.
    private static func name(_ serial: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = buffer.withUnsafeMutableBufferPointer { xless_key_describe(serial, $0.baseAddress, $0.count) }
        guard size >= 0, size <= buffer.count else { return nil }
        let fields = String(cString: buffer).split(separator: ";", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "user" else { return nil }
        return String(fields[4])
    }

    private static func check(_ result: Int, _ operation: String) throws {
        if result < 0 { throw failure(operation) }
    }

    private static func failure(_ operation: String) -> Failure { Failure(operation: operation, code: errno) }
}
