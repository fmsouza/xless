import Crypto
import Foundation
import XlessCore

/// Where a kept session's two keys live: the Linux kernel keyring in the CLI, memory in tests.
public protocol SessionKeyStore: Sendable {
    var isAvailable: Bool { get }
    /// Stores (replacing) `secret` as `name`, dropped by the store after `seconds`.
    func put(_ name: String, _ secret: SecretBytes, seconds: Int) throws
    func get(_ name: String) throws -> SecretBytes?
    /// Drops `name`; whether there was one.
    @discardableResult func revoke(_ name: String) throws -> Bool
}

/// The session keyring (possessor-only, expired by the kernel; see `KernelKeyring`).
public struct KernelKeyringSessionStore: SessionKeyStore {
    public init() {}

    public var isAvailable: Bool { KernelKeyring.isAvailable }

    public func put(_ name: String, _ secret: SecretBytes, seconds: Int) throws {
        try KernelKeyring.store(name: name, secret: secret, timeout: seconds)
    }

    public func get(_ name: String) throws -> SecretBytes? {
        guard isAvailable, let key = try KernelKeyring.find(name: name) else { return nil }
        return try? KernelKeyring.read(key)
    }

    public func revoke(_ name: String) throws -> Bool {
        guard isAvailable else { return false }
        var any = false
        while let key = try KernelKeyring.find(name: name) {
            try KernelKeyring.revoke(key)
            any = true
        }
        return any
    }
}

/// What `xless auth status` shows of a kept session (never a cookie).
public struct KeptSessionInfo: Sendable, Equatable {
    public let appleID: String
    public let created: Date
    public let expires: Date

    public init(appleID: String, created: Date, expires: Date) {
        self.appleID = appleID; self.created = created; self.expires = expires
    }
}

/// The opt-in Apple ID session cache (`xless auth login --keep`). The cookie jar is sealed (AES-256-GCM) with a random key
/// made for it; the sealed jar and the key are two kernel-keyring keys, both expiring after `--keep` (at most an hour,
/// never past the cookies' own expiry). Nothing is written to disk. Reading it back needs the same login session
/// (keyring possession), as with `ssh-agent`. A kept session that cannot be opened (expired, tampered, half gone) is
/// dropped and treated as none.
public struct AppleSessionCache: Sendable {
    static let blobName = "xless-apple-session"
    static let keyName = "xless-apple-session-key"
    static let associatedData = Data("xless-apple-session/1".utf8)
    /// A session that would be kept for less than this is not kept.
    public static let minimumSeconds = 60

    struct Payload: Codable {
        var version = 1
        let appleID: String
        let created: Date
        let expires: Date
        let cookies: [CookieJar.Cookie]
    }

    let store: any SessionKeyStore
    let now: @Sendable () -> Date

    public init(store: any SessionKeyStore = KernelKeyringSessionStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public var isAvailable: Bool { store.isAvailable }

    /// Seals `web`'s cookies and keeps them for `seconds`, or less when a cookie expires sooner. Replaces a kept session.
    @discardableResult
    public func keep(_ web: AppleWebClient, appleID: String, seconds: Int) async throws -> KeptSessionInfo {
        guard store.isAvailable else { throw Self.unavailable() }
        let created = Self.whole(now())
        var lifetime = min(seconds, KernelKeyring.maximumTimeout)
        if let expiry = await web.earliestCookieExpiry() {
            lifetime = min(lifetime, Int(expiry.timeIntervalSince(created).rounded(.down)))
        }
        guard lifetime >= Self.minimumSeconds else {
            throw XlessError(.account, "Apple's session runs out in \(max(lifetime, 0)) s, too soon to keep",
                             fix: "re-run without --keep; each command signs in")
        }
        let cookies = await web.cookieSnapshot()
        guard !cookies.isEmpty else {
            throw XlessError(.account, "there is no Apple ID session to keep", fix: "sign in first (`xless auth login --keep 30m`)")
        }
        let info = KeptSessionInfo(appleID: appleID, created: created, expires: created.addingTimeInterval(TimeInterval(lifetime)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var plain = try encoder.encode(Payload(appleID: appleID, created: info.created, expires: info.expires, cookies: cookies))
        defer { plain.withUnsafeMutableBytes { SecretBytes.zero($0) } }
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.associatedData)
        guard var combined = sealed.combined else {
            throw XlessError(.account, "cannot seal the Apple ID session", fix: "re-run without --keep")
        }
        let blob = SecretBytes(wiping: &combined)
        let keyBytes = key.withUnsafeBytes { SecretBytes(copying: $0) }
        defer { blob.wipe(); keyBytes.wipe() }
        forget()
        do {
            try store.put(Self.blobName, blob, seconds: lifetime)
            try store.put(Self.keyName, keyBytes, seconds: lifetime)
        } catch {
            forget()
            throw XlessError(.account, "cannot keep the Apple ID session in the kernel keyring: \(error)", fix: "re-run without --keep")
        }
        return info
    }

    /// The kept session's Apple ID and expiry, without its cookies; nil when none is kept.
    public func info() -> KeptSessionInfo? {
        guard let payload = load() else { return nil }
        return KeptSessionInfo(appleID: payload.appleID, created: payload.created, expires: payload.expires)
    }

    /// Puts the kept session's cookies into `web`; its info, or nil when none is kept (nothing changes then).
    public func restore(into web: AppleWebClient) async -> KeptSessionInfo? {
        guard let payload = load() else { return nil }
        await web.restoreCookies(payload.cookies)
        return KeptSessionInfo(appleID: payload.appleID, created: payload.created, expires: payload.expires)
    }

    /// Drops the kept session; whether there was one.
    @discardableResult
    public func forget() -> Bool {
        let a = (try? store.revoke(Self.blobName)) ?? false
        let b = (try? store.revoke(Self.keyName)) ?? false
        return a || b
    }

    private func load() -> Payload? {
        guard store.isAvailable else { return nil }
        let blob = try? store.get(Self.blobName), keyBytes = try? store.get(Self.keyName)
        guard let blob, let keyBytes else {
            if blob != nil || keyBytes != nil { forget() }
            return nil
        }
        defer { blob.wipe(); keyBytes.wipe() }
        let key = keyBytes.withUnsafeBytes { SymmetricKey(data: $0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var plain = try? blob.withUnsafeBytes({ bytes -> Data in
            let box = try AES.GCM.SealedBox(combined: Data(bytes))
            return try AES.GCM.open(box, using: key, authenticating: Self.associatedData)
        }) else {
            forget()
            return nil
        }
        defer { plain.withUnsafeMutableBytes { SecretBytes.zero($0) } }
        guard let payload = try? decoder.decode(Payload.self, from: plain), payload.version == 1 else {
            forget()
            return nil
        }
        guard payload.expires > now() else {
            forget()
            return nil
        }
        return payload
    }

    public static func unavailable() -> XlessError {
        XlessError(.account, "--keep needs the kernel keyring, which is not available here (macOS, or a container that blocks it)",
                   fix: "run without --keep; each command that needs the Apple ID session signs in")
    }

    static func whole(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
}

/// `--keep` durations: `90s`, `30m`, `1h` or bare seconds; 1 s … 1 h.
public enum KeepDuration {
    public static func seconds(_ text: String) throws -> Int {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        var digits = Substring(t)
        var unit = 1
        if let last = t.last, let u = units[last] { digits = t.dropLast(); unit = u }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n > 0,
              n <= KernelKeyring.maximumTimeout / unit else {
            throw XlessError(.account, "--keep \(text) is not a duration between 1s and 1h", fix: "e.g. --keep 30m (at most 1h)")
        }
        return n * unit
    }
}
