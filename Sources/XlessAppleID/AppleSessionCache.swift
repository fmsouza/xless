import Crypto
import Foundation
import XlessCore

/// Where a kept session's two keys live: the xless agent or the Linux kernel keyring in the CLI, memory in tests.
public protocol SessionKeyStore: Sendable {
    /// Whether a session can be kept here.
    var isAvailable: Bool { get }
    /// How many seconds of `hold` it can keep one.
    func allowed(_ hold: SecretHold) -> Int
    /// Stores (replacing) `secret` as `name`, dropped by the store when the hold ends.
    func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws
    /// - Parameter using: false to look only (its idle time goes on).
    func get(_ name: String, using: Bool) throws -> SecretBytes?
    /// Drops `name`; whether there was one.
    @discardableResult func revoke(_ name: String) throws -> Bool
}

/// The session keyring (possessor-only, expired by the kernel after at most an hour; see `KernelKeyring`).
public struct KernelKeyringSessionStore: SessionKeyStore {
    public init() {}

    public var isAvailable: Bool { KernelKeyring.isAvailable }

    public func allowed(_ hold: SecretHold) -> Int { min(hold.seconds, KernelKeyring.maximumTimeout) }

    public func put(_ name: String, _ secret: SecretBytes, hold: SecretHold) throws {
        try KernelKeyring.store(name: name, secret: secret, timeout: allowed(hold))
    }

    public func get(_ name: String, using: Bool) throws -> SecretBytes? {
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
/// made for it; the sealed jar and the key are two items of the xless agent, or two kernel-keyring keys, both dropped at
/// the end of the hold (never past the session cookie's own expiry). Nothing is written to disk. Reading it back needs
/// the same terminal session (the agent) or login session (the keyring). A kept session that cannot be opened (expired,
/// tampered, half gone) is dropped and treated as none.
public struct AppleSessionCache: Sendable {
    /// What every item of a kept session starts with.
    public static let prefix = "xless-apple-session"
    static let blobName = prefix
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
        /// The hold's idle time and maximum, for a session kept again after Apple refused it (nil: an older xless).
        var idle: Int?
        var maximum: Int?
    }

    let store: any SessionKeyStore
    let now: @Sendable () -> Date

    public init(store: any SessionKeyStore = KernelKeyringSessionStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public var isAvailable: Bool { store.isAvailable }

    /// Seals `web`'s cookies and keeps them for the hold, or less when Apple's session cookie (`myacinfo`; any of them when
    /// there is none) expires sooner. Replaces a kept session.
    @discardableResult
    public func keep(_ web: AppleWebClient, appleID: String, hold: SecretHold) async throws -> KeptSessionInfo {
        guard store.isAvailable else { throw Self.unavailable() }
        let created = Self.whole(now())
        var lifetime = store.allowed(hold)
        if let expiry = await web.sessionCookieExpiry() {
            lifetime = min(lifetime, Int(expiry.timeIntervalSince(created).rounded(.down)))
        }
        guard lifetime >= Self.minimumSeconds else {
            throw XlessError(.account, "Apple's session runs out in \(max(lifetime, 0)) s, too soon to keep",
                             fix: "re-run without --keep; each command signs in")
        }
        let cookies = await web.cookieSnapshot()
        guard !cookies.isEmpty else {
            throw XlessError(.account, "there is no Apple ID session to keep", fix: "sign in first (`xless auth login --keep`)")
        }
        let info = KeptSessionInfo(appleID: appleID, created: created, expires: created.addingTimeInterval(TimeInterval(lifetime)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var plain = try encoder.encode(Payload(appleID: appleID, created: info.created, expires: info.expires, cookies: cookies,
                                                   idle: hold.idle, maximum: hold.maximum))
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
            let kept = SecretHold(seconds: lifetime, idle: min(hold.idle, lifetime), maximum: hold.maximum)
            try store.put(Self.blobName, blob, hold: kept)
            try store.put(Self.keyName, keyBytes, hold: kept)
        } catch {
            forget()
            throw XlessError(.account, "cannot keep the Apple ID session: \(error)", fix: "re-run without --keep")
        }
        return info
    }

    /// The kept session's Apple ID and expiry, without its cookies; nil when none is kept.
    public func info() -> KeptSessionInfo? {
        guard let payload = load(using: false) else { return nil }
        return KeptSessionInfo(appleID: payload.appleID, created: payload.created, expires: payload.expires)
    }

    /// Puts the kept session's cookies into `web`; its info, or nil when none is kept (nothing changes then).
    public func restore(into web: AppleWebClient) async -> KeptSessionInfo? {
        guard let payload = load(using: true) else { return nil }
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

    /// What is left of the kept session's hold, to keep the session that replaces it for no longer.
    func remainingHold() -> SecretHold? {
        guard let payload = load(using: false) else { return nil }
        let seconds = Int(payload.expires.timeIntervalSince(now()))
        guard seconds > 0 else { return nil }
        return SecretHold(seconds: seconds, idle: payload.idle ?? seconds, maximum: payload.maximum ?? seconds)
    }

    private func load(using: Bool) -> Payload? {
        let blob = try? store.get(Self.blobName, using: using), keyBytes = try? store.get(Self.keyName, using: using)
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

    /// - Parameter why: what stands in the way.
    public static func unavailable(_ why: String? = nil) -> XlessError {
        XlessError(.account, "the Apple ID session cannot be kept here\(why.map { ": \($0)" } ?? "")",
                   fix: "run without --keep; each command that needs the Apple ID session signs in")
    }

    static func whole(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
}
