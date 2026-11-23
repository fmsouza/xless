import Foundation
import XlessCore

/// The secrets kept by an external credential helper (`CredentialHelper`), as a `SecretStore`.
///
/// Each entry is one credential: ServerURL `xless:<NAME>`, Username its kind and metadata as compact JSON
/// (`{"kind":"asc-api-key","keyID":"…","teamID":"…"}`; not secret, so `list` gives the whole catalog without reading
/// a value), Secret its value. Other credentials the helper lists (no `xless:` prefix) are not xless's and are left
/// alone. An update lists, then stores and erases one credential at a time, holding the vault's writers' lock
/// (`writersLock`'s `lock` file) throughout, so two xless commands writing at once take turns and neither works from a
/// stale list; the metadata's integrity is the keyring's, as the secrets' are.
public final class HelperSecretStore: SecretStore, @unchecked Sendable {
    public let helper: CredentialHelper
    /// Where the writers' lock is: the vault's directory (`VaultLocation.standard`), created 0700 when missing. nil: no
    /// lock (tests that do not write concurrently).
    public let writersLock: VaultLocation?
    private let lock = NSLock()
    /// The last `list`, for the rest of the process: each lookup would otherwise run the helper again (with pass, a
    /// decryption per entry). `update` lists afresh and drops it.
    private var listed: SecretCatalog?
    /// Whether `probeWrites` passed in this process.
    private var probed = false

    public init(helper: CredentialHelper, lock: VaultLocation? = nil) {
        self.helper = helper
        writersLock = lock
    }

    /// The name of `probeWrites`' throwaway entries (a valid entry name, so a leftover shows in `xless secrets list`).
    static let probePrefix = "xless-helper-probe."

    static let urlPrefix = "xless:"
    /// What a Docker credential helper prints (exit 1) for a credential it does not have.
    public static let notFound = "credentials not found in native keychain"

    public var place: String { "the credential helper \(helper.command) (\(helper.executable))" }
    var catalogID: String { "helper:\(helper.name)" }

    static func serverURL(_ name: String) -> String { urlPrefix + name }

    // MARK: SecretStore

    public func catalog() throws -> SecretCatalog? { try existingCatalog() }

    public func existingCatalog() throws -> SecretCatalog {
        if let listed = lock.withLock({ listed }) { return listed }
        let fresh = try list()
        lock.withLock { listed = fresh }
        return fresh
    }

    /// Nothing to unlock: the keyring asks for itself. (Callers read the catalog first, so the helper has answered.)
    public func unlock(_ catalog: SecretCatalog, remember: Int?, reason: String) throws {}

    public func authenticate(_ entry: VaultEntry, in catalog: SecretCatalog, reason: String) throws {}

    public func secret(_ entry: VaultEntry, in catalog: SecretCatalog, reason: String) throws -> SecretBytes {
        SecretScope.enter() // before the value is in memory
        guard let secret = try get(entry.name) else {
            throw VaultError(.noEntry, "\(place) no longer has \(entry.name) (needed for \(reason))", fix: "see the names with `xless secrets list`")
        }
        return secret
    }

    public func update(reason: String, _ body: (SecretCatalog) throws -> [SecretChange]) throws {
        lock.withLock { listed = nil }
        defer { lock.withLock { listed = nil } }
        try locked {
            let current = try list()
            for change in try body(current) {
                switch change {
                case .add(let name, let kind, let metadata, let secret):
                    guard current.entry(named: name) == nil else { throw VaultSecretStore.exists(name) }
                    try store(name: name, kind: kind, metadata: metadata, secret: secret)
                case .replace(let name, let kind, let metadata, let secret):
                    guard current.entry(named: name) != nil else { throw VaultSecretStore.missing(name) }
                    try store(name: name, kind: kind, metadata: metadata, secret: secret)
                case .remove(let name):
                    if current.entry(named: name) != nil { try erase(name) }
                }
            }
        }
    }

    /// Stores, reads back and erases a throwaway entry (`xless-helper-probe.<random>`), under the writers' lock, once
    /// per process: a helper that cannot keep a secret is found before Apple creates a key it offers only once.
    public func probeWrites(reason: String) throws {
        if lock.withLock({ probed }) { return }
        // Shaped like what is stored for real: `NAME@TEAMID`, a multi-line PEM of a few hundred bytes.
        let name = Self.probePrefix + Self.randomHex(8) + "@XLESSPROBE"
        let value = SecretBytes(utf8: "-----BEGIN XLESS PROBE-----\n" + (0..<4).map { _ in Self.randomHex(32) }.joined(separator: "\n") + "\n-----END XLESS PROBE-----\n")
        defer { value.wipe() }
        func failed(_ what: String, fix: String) -> VaultError {
            VaultError(.helper, "\(helper.command) failed xless's test write (store, read back and erase a throwaway entry) before \(reason): \(what)",
                       fix: fix + "; nothing was created")
        }
        try locked {
            do {
                try store(name: name, kind: .generic, metadata: VaultEntry.Metadata(), secret: value)
            } catch let e as VaultError {
                try? erase(name) // whatever half of it the helper kept
                throw failed(e.cause, fix: e.fix)
            }
            let back: SecretBytes?
            do { back = try get(name) } catch let e as VaultError {
                try? erase(name)
                throw failed(e.cause, fix: e.fix)
            }
            defer { back?.wipe() }
            guard back == value else {
                try? erase(name)
                throw failed(back == nil ? "it did not have the entry it had just stored" : "it gave back another value than the one it stored",
                             fix: "fix the helper (docs/secrets.md#writing-a-credential-helper says what it must do)")
            }
            do { try erase(name) } catch let e as VaultError {
                throw failed("\(e.cause); it may still hold the throwaway entry \(name)",
                             fix: "remove it with `xless secrets rm \(name)` (or the keyring's own tool) once the helper works")
            }
        }
        lock.withLock { probed = true }
    }

    /// `body` holding the writers' lock (none when `writersLock` is nil).
    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard let writersLock else { return try body() }
        try writersLock.createDirectory()
        return try VaultStore(location: writersLock).withLock(body)
    }

    static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    // MARK: The protocol

    /// `list`: xless's credentials, as entries (names, kinds, metadata).
    func list() throws -> SecretCatalog {
        let answer = try helper.run(.list, input: nil)
        try check(answer, .list)
        let members: [(key: String, value: SecretBytes)]
        do { members = try answer.output.withUnsafeBytes { try HelperJSON.members($0) } } catch { throw junk(.list) }
        var entries: [VaultEntry] = []
        for (url, label) in members where url.hasPrefix(Self.urlPrefix) {
            let name = String(url.dropFirst(Self.urlPrefix.count))
            guard VaultEntry.isValidName(name), !entries.contains(where: { $0.name == name }) else { continue }
            guard let decoded = HelperLabel.decode(label.utf8String()) else {
                throw VaultError(.helper, "\(helper.command) lists \(url) with a description xless cannot read, so which team and key it is for is unknown",
                                 fix: "remove it with the helper's own tool (or `\(helper.command) erase`), then import the secret again")
            }
            entries.append(VaultEntry(name: name, kind: decoded.kind, metadata: decoded.metadata, sealed: Data()))
        }
        return SecretCatalog(id: catalogID, entries: entries)
    }

    /// `get`: the value of `name`; nil when the helper does not have it.
    func get(_ name: String) throws -> SecretBytes? {
        let answer = try helper.run(.get, input: SecretBytes(utf8: Self.serverURL(name)))
        if answer.status != 0 {
            let said = answer.output.withUnsafeBytes { String(decoding: $0.prefix(Self.notFound.utf8.count + 8), as: UTF8.self) }
            if said.trimmingCharacters(in: .whitespacesAndNewlines) == Self.notFound { return nil }
            // Never quoted: whatever a failed `get` printed may hold the secret.
            throw VaultError(.helper, "\(helper.command) get failed for \(name) (exit \(answer.status))",
                             fix: "see its messages above, if any; check that \(helper.command) works on its own (`echo \(Self.serverURL(name)) | \(helper.command) get`)")
        }
        let members: [(key: String, value: SecretBytes)]
        do { members = try answer.output.withUnsafeBytes { try HelperJSON.members($0) } } catch { throw junk(.get) }
        if let url = members.first(where: { $0.key == "ServerURL" }), url.value != SecretBytes(utf8: Self.serverURL(name)) {
            throw VaultError(.helper, "\(helper.command) get answered for another credential than \(Self.serverURL(name))", fix: "fix the helper")
        }
        guard let secret = members.first(where: { $0.key == "Secret" })?.value else { throw junk(.get) }
        return secret
    }

    /// `store`: `name` with its kind, metadata and value (replacing what the helper had for it).
    func store(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes) throws {
        guard Self.isText(secret) else {
            throw VaultError(.invalidSecret, "\(name) is not UTF-8 text without NUL bytes, which is all a credential helper can carry",
                             fix: "keep it in the encrypted vault (`secrets: { backend: vault }`), or store a text form of it")
        }
        let input = HelperJSON.object([
            ("ServerURL", SecretBytes(utf8: Self.serverURL(name))),
            ("Username", SecretBytes(utf8: HelperLabel(kind: kind, metadata: metadata).encoded())),
            ("Secret", secret),
        ])
        defer { input.wipe() }
        try check(try helper.run(.store, input: input), .store)
    }

    /// `erase`: removes `name`.
    func erase(_ name: String) throws {
        try check(try helper.run(.erase, input: SecretBytes(utf8: Self.serverURL(name))), .erase)
    }

    /// A non-zero exit is an error, quoting the first line the helper printed for `list` and `erase` (whose requests
    /// hold no secret); never for `store`, whose request a helper might echo back, nor `get` (checked on its own).
    private func check(_ answer: CredentialHelper.Answer, _ verb: CredentialHelper.Verb) throws {
        guard answer.status != 0 else { return }
        let line = verb == .store ? "" : answer.output.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(400).prefix { $0 != 0x0a }, as: UTF8.self)
        }
        let shown = String(line.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f ? Character($0) : "?" }.prefix(200))
        throw VaultError(.helper, "\(helper.command) \(verb.rawValue) failed (exit \(answer.status))\(shown.isEmpty ? "" : ": \(shown)")",
                         fix: "see its messages above, if any; check that \(helper.command) works on its own (`\(helper.command) list`)")
    }

    private func junk(_ verb: CredentialHelper.Verb) -> VaultError {
        VaultError(.helper, "\(helper.command) \(verb.rawValue) printed something that is not a credential helper's JSON answer",
                   fix: "fix the helper (docs/secrets.md#writing-a-credential-helper says what it must print)")
    }

    /// Valid UTF-8 without a NUL byte (checked without making a `String` of it).
    static func isText(_ secret: SecretBytes) -> Bool {
        secret.withUnsafeBytes { bytes in
            guard !bytes.contains(0) else { return false }
            var iterator = bytes.makeIterator()
            var decoder = UTF8()
            while true {
                switch decoder.decode(&iterator) {
                case .scalarValue: continue
                case .emptyInput: return true
                case .error: return false
                }
            }
        }
    }
}

/// An entry's kind and metadata as a helper keeps them (its credential's Username): compact JSON, sorted keys, dates
/// as whole seconds since 1970. Keys a later xless adds are ignored by this one.
struct HelperLabel: Codable, Equatable {
    var kind: VaultEntry.Kind
    var teamID: String?
    var keyID: String?
    var issuerID: String?
    var certificateID: String?
    var created: Int64?
    var expires: Int64?
    var role: String?
    var certificateType: String?
    var services: String?

    init(kind: VaultEntry.Kind, metadata m: VaultEntry.Metadata) {
        self.kind = kind
        teamID = m.teamID
        keyID = m.keyID
        issuerID = m.issuerID
        certificateID = m.certificateID
        created = m.created.map { Int64($0.timeIntervalSince1970) }
        expires = m.expires.map { Int64($0.timeIntervalSince1970) }
        role = m.role
        certificateType = m.certificateType
        services = m.services
    }

    var metadata: VaultEntry.Metadata {
        VaultEntry.Metadata(teamID: teamID, keyID: keyID, issuerID: issuerID, certificateID: certificateID,
                            created: created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            expires: expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            role: role, certificateType: certificateType, services: services)
    }

    func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self)
    }

    static func decode(_ text: String) -> HelperLabel? { try? JSONDecoder().decode(HelperLabel.self, from: Data(text.utf8)) }
}

/// The store `secrets.backend` in config.yml names.
public enum ConfiguredSecretStore: Sendable {
    case vault(VaultSecretStore)
    case helper(HelperSecretStore)

    public var store: any SecretStore {
        switch self {
        case .vault(let v): v
        case .helper(let h): h
        }
    }

    /// From `$XDG_CONFIG_HOME/xless/config.yml`: the vault at its standard place, or the helper found on PATH.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment, cache: (any VaultKeyCache)? = KernelKeyringCache(),
                            prompter: @escaping () -> (any PassphrasePrompter)?) throws -> ConfiguredSecretStore {
        switch try UserConfig.secretsBackend(env: env) {
        case .vault: .vault(VaultSecretStore(store: VaultStore(location: .standard(env: env)), cache: cache, prompter: prompter))
        case .helper(let name): .helper(HelperSecretStore(helper: try CredentialHelper.find(name: name, env: env), lock: .standard(env: env)))
        }
    }
}
