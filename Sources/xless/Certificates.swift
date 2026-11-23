import Crypto
import Foundation
import XlessASC
import XlessCore
import XlessSign
import XlessVault

// `xless certs create` and `xless sign bootstrap`: what creating a certificate sequences, kept apart from the terminal and
// the network so the order (store the key, then POST once, then record the certificate) and every failure message are
// tested with fakes (docs/apple-account.md#xless-certs).

/// What creating a certificate needs from App Store Connect (`ASCCertificates`; a fake in tests).
protocol CertificateAPI: Sendable {
    func list(types: [CertificateType], withContent: Bool) async throws -> [ASCCertificate]
    func create(type: CertificateType, csrPEM: String, relatedID: String?) async throws -> ASCCertificate
}

extension ASCCertificates: CertificateAPI {}

/// The store side: which entry a certificate's private key goes to, and keeping it there.
struct CertificateKeyStore {
    /// The secret the `sign` stage reads that `name` stands for (`XLESS_DIST_KEY@ABCDE12345` → `XLESS_DIST_KEY`), if any:
    /// a key stored under such a name, even one chosen with `--name`, must not make the stage's choice ambiguous.
    static func signBase(of name: String) -> String? {
        let base = String(name.split(separator: "@", maxSplits: 1).first ?? "")
        return CertificateKind.allCases.map(\.secretName).contains(base) ? base : nil
    }

    /// `<base>@<TEAM_ID>`, or `<base>` without a team.
    static func entryName(base: String, team: String?) -> String { team.map { "\(base)@\($0)" } ?? base }

    /// Refuses, before a key is generated, when `name` is taken, or (for a default name, `base` given) when the store
    /// already holds a `base` key the `sign` stage would pick for the team: a second one would make its choice ambiguous.
    /// - Parameter keepBoth: how to keep the existing key and add the new one (`certs create` has `--name`; bootstrap has not).
    static func precheck(_ file: some SecretEntries, name: String, base: String?, team: String?, stage: Stage,
                         keepBoth: String = "pass --name <another entry name>") throws {
        var clashing = file.entry(named: name).map { [$0.name] } ?? []
        if let base {
            clashing += file.entries.filter { e in
                guard e.name != name, e.name == base || e.name.hasPrefix(base + "@") else { return false }
                guard let team else { return true }
                return e.metadata.teamID == team || e.name == "\(base)@\(team)" || (e.metadata.teamID == nil && e.name == base)
            }.map(\.name)
        }
        guard !clashing.isEmpty else { return }
        throw XlessError(stage, "the secret store already has \(clashing.joined(separator: ", ")), where this certificate's private key would go",
                         fix: "if its certificate is gone, remove it (`xless secrets rm \(clashing[0])`); to keep both, \(keepBoth)\(base.map { " (the sign stage reads \($0))" } ?? "")")
    }

    /// The store, unlocked by this command (`SecretStore.unlock`) before anything was asked of Apple.
    let store: any SecretStore
    /// The store this command read and unlocked.
    let catalogID: String

    /// Adds a new signing-key entry; a name taken meanwhile is an error (nothing was sent to Apple yet).
    func save(name: String, secret: SecretBytes, metadata: VaultEntry.Metadata) throws {
        try store.update(reason: "storing the new signing key") { file in
            guard file.id == catalogID else { throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command") }
            guard file.entry(named: name) == nil else {
                throw VaultError(.entryExists, "the secret store already has an entry \(name)", fix: "pass --name <another entry name>, or remove it (`xless secrets rm \(name)`)")
            }
            return [.add(name: name, kind: .signingKey, metadata: metadata, secret: secret)]
        }
    }

    /// Re-seals `name` with the certificate's ID and expiry, and `team` (the certificate's own, when known) over the
    /// entry's.
    func record(name: String, secret: SecretBytes, certificateID: String, expires: Date?, team: String?, certificateType: String? = nil) throws {
        try store.update(reason: "recording the certificate") { file in
            guard file.id == catalogID, let entry = file.entry(named: name) else {
                throw VaultError(.noEntry, "the entry \(name) is no longer in the secret store", fix: "re-import the key with `xless secrets import`")
            }
            var metadata = entry.metadata
            metadata.teamID = team ?? metadata.teamID
            metadata.certificateID = certificateID
            metadata.certificateType = certificateType ?? metadata.certificateType
            metadata.expires = expires.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
            return [.replace(name: name, kind: .signingKey, metadata: metadata, secret: secret)]
        }
    }

    /// Removes `name` (needs no passphrase).
    static func remove(_ name: String, from store: any SecretStore) throws {
        try store.update(reason: "removing \(name)") { _ in [.remove(name: name)] }
    }

    /// The names of the entries holding the private key of certificate `id`.
    static func entries(holding id: String, in file: (any SecretEntries)?) -> [String] {
        (file?.entries ?? []).filter { $0.metadata.certificateID == id }.map(\.name).sorted()
    }
}

/// Links the signing keys in the secret store to their certificates by public key, where the store does not say which
/// certificate a key has: a key imported with `xless secrets import`, kept after a create whose answer was lost, or
/// whose certificate was made from a CSR (`xless certs create --csr`, `xless certs link`). A match is recorded on the
/// entry (certificate ID, type, expiry and the certificate's team), as `certs create` records its own.
struct CertificateKeyLink {
    let store: any SecretStore
    /// The team whose certificates are matched: another team's keys are never opened.
    let team: String?

    struct Linked: Encodable, Equatable {
        let entry: String
        let certificate: String
    }

    struct Outcome: Encodable, Equatable {
        var linked: [Linked] = []
        /// Keys without a recorded certificate that no certificate matched.
        var unmatched: [String] = []
    }

    /// The signing keys of `team` (or of no team) with no certificate recorded, or one that is not among `known` (the
    /// team's certificates as App Store Connect lists them: one that is gone, revoked or expired).
    static func candidates(in catalog: some SecretEntries, known: Set<String>, team: String?) -> [VaultEntry] {
        catalog.entries.filter { e in
            guard e.kind == .signingKey, e.metadata.certificateID.map({ !known.contains($0) }) ?? true else { return false }
            guard let team else { return true }
            if let owner = e.metadata.teamID { return owner == team }
            guard let at = e.name.split(separator: "@", maxSplits: 1).dropFirst().first else { return true }
            return at == team
        }
    }

    /// Opens the candidates (unlocking the store only when there is one) and records with each the certificate of
    /// `certificates` issued for its key (the latest-expiring one when several are). `known` is every certificate ID the
    /// team has.
    func link(_ certificates: [ASCCertificate], known: Set<String>, reason: String) throws -> Outcome {
        guard let catalog = try store.catalog() else { return Outcome() }
        let open = Self.candidates(in: catalog, known: known, team: team)
        let issued = certificates.filter { $0.der != nil }.sorted { ($0.expires ?? .distantPast) > ($1.expires ?? .distantPast) }
        guard !open.isEmpty else { return Outcome() }
        guard !issued.isEmpty else { return Outcome(unmatched: open.map(\.name)) }
        try catalog.requireWritable()
        try store.unlock(catalog, remember: nil, reason: reason)
        let keys = CertificateKeyStore(store: store, catalogID: catalog.id)
        var outcome = Outcome()
        for entry in open {
            let secret = try store.secret(entry, in: catalog, reason: reason)
            defer { secret.wipe() }
            guard let key = KeyMatch.publicKey(privateKeyPEM: secret.utf8String()), let certificate = KeyMatch.certificate(for: key, in: issued) else {
                outcome.unmatched.append(entry.name)
                continue
            }
            let facts = certificate.der.flatMap { CertificateFacts(der: $0) }
            try keys.record(name: entry.name, secret: secret, certificateID: certificate.id, expires: facts?.expires ?? certificate.expires,
                            team: facts?.teamID ?? entry.metadata.teamID, certificateType: certificate.certificateType)
            outcome.linked.append(Linked(entry: entry.name, certificate: certificate.id))
        }
        return outcome
    }

    /// After `certs create --csr`: records the new certificate with its key when that key is in the store (asking the
    /// passphrase only when a key without a recorded certificate is there). Never fails the command: returns the entry,
    /// or nil with a note said.
    func linkNew(_ certificate: ASCCertificate, known: () async throws -> Set<String>, say: (String) -> Void) async -> String? {
        do {
            guard let catalog = try store.catalog(), !Self.candidates(in: catalog, known: [], team: team).isEmpty else { return nil }
            let ids = try await known().union([certificate.id])
            let outcome = try link([certificate], known: ids, reason: "matching the new certificate with the keys in the secret store")
            return outcome.linked.first?.entry
        } catch {
            say("note: could not check whether the secret store holds the key of certificate \(certificate.id) (\(XlessError.wrapping(error, stage: .account).cause)); `xless certs link` records it later")
            return nil
        }
    }
}

/// What `certs create` reports (`--json` prints it as is: Apple's certificate resource, and where its key went).
struct CertificateCreated: Encodable {
    let certificate: ASCCertificate
    /// The secret-store entry holding its private key; nil for a certificate made from a CSR whose key is not there.
    var entry: String?
    let team: String?
    /// The key was already in the store, found by its public key (a CSR made from it): not stored by this command.
    var matched = false

    enum CodingKeys: String, CodingKey { case certificate, entry, team }

    var text: String {
        let type = CertificateType(rawValue: certificate.certificateType)
        var lines = ["created \(type?.displayName ?? certificate.certificateType) certificate \(certificate.id)"
            + (certificate.attributes.name.map { " (\($0))" } ?? "")
            + (certificate.expires.map { ", expires \(CertTable.day($0))" } ?? "")]
        if let entry, matched {
            lines.append("its private key is in the secret store as \(entry) (matched by its public key); the certificate is recorded with it")
        } else if let entry {
            lines.append("stored its private key in the secret store as \(entry) (it never touched the disk in clear)")
        } else {
            lines.append("its private key is wherever the CSR was made; download the certificate with `xless certs download \(certificate.id) --out <file.cer>`")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Creating a certificate: from a key xless generates (stored first), or from someone else's CSR.
struct CertificateCreation {
    let api: any CertificateAPI
    var stage: Stage = .account
    /// `xless sign bootstrap` without `--allow-new`: refuse when the team already has a certificate of the type (their
    /// private keys cannot be downloaded, so another one is rarely what is wanted).
    var refuseIfAny = false
    var generate: () throws -> SigningKey = { try SigningKey.generate() }
    /// Progress lines and warnings (standard error).
    var say: (String) -> Void = { _ in }

    /// Apple's documented limit, checked before anything is generated or sent.
    func precheck(_ type: CertificateType) async throws {
        guard type.cap != nil || refuseIfAny else { return }
        let group = type.capGroup.isEmpty ? [type] : type.capGroup
        let existing = try await api.list(types: group, withContent: false)
        if let cap = type.cap, existing.count >= cap {
            throw XlessError(stage, "the team already has \(existing.count) \(type.displayName) certificates (Apple allows \(cap))",
                             fix: "revoke one you no longer use (`xless certs list \(type.listArguments)`, `xless certs revoke <id>`), then re-run")
        }
        if refuseIfAny, !existing.isEmpty {
            throw XlessError(stage, "the team already has \(existing.count) \(type.displayName) certificate(s); their private keys cannot be downloaded",
                             fix: "reuse the key you already stored, or pass --allow-new to create another")
        }
    }

    /// Generates the key, seals it into the store as `entry` *before* the create request (a store that cannot keep it
    /// means nothing is sent), sends the request once, then records the certificate's ID and expiry with the key. A
    /// definite refusal removes the entry again; a failure that may have created the certificate keeps it.
    func run(type: CertificateType, relatedID: String?, entry: String, team: String?, keys: () throws -> CertificateKeyStore,
             now: Date = Date()) async throws -> CertificateCreated {
        guard !type.needsECCKey else { throw Self.needsCSR(type, stage: stage) }
        try await precheck(type)
        let key = try generate()
        let csr = try key.csrPEM(commonName: "xless")
        let secret = SecretBytes(utf8: key.pem)
        defer { secret.wipe() }
        let store: CertificateKeyStore
        do {
            store = try keys()
            try store.save(name: entry, secret: secret, metadata: VaultEntry.Metadata(teamID: team, created: now, certificateType: type.rawValue))
        } catch {
            throw XlessError(stage, "the secret store could not keep the new private key (\(XlessError.wrapping(error, stage: stage).cause)); nothing was sent to Apple",
                             fix: XlessError.wrapping(error, stage: stage).fix)
        }
        say("Stored the new private key in the secret store as \(entry); asking App Store Connect for the certificate.")
        let certificate: ASCCertificate
        do {
            certificate = try await api.create(type: type, csrPEM: csr, relatedID: relatedID)
        } catch {
            if ASCCertificates.isAmbiguous(error) {
                guard let made = await made(type, for: KeyMatch.publicKey(privateKeyPEM: key.pem), after: error) else {
                    throw ambiguous(type, error, kept: entry)
                }
                certificate = made
                return try finish(certificate, entry: entry, team: team, store: store, secret: secret)
            }
            var removed = true
            do { try CertificateKeyStore.remove(entry, from: store.store) } catch { removed = false }
            throw refused(type, error, removedEntry: removed ? entry : nil, keptEntry: removed ? nil : entry)
        }
        return try finish(certificate, entry: entry, team: team, store: store, secret: secret)
    }

    /// Records the certificate made for the key stored as `entry`.
    private func finish(_ certificate: ASCCertificate, entry: String, team: String?, store: CertificateKeyStore, secret: SecretBytes) throws -> CertificateCreated {
        let facts = certificate.der.flatMap { CertificateFacts(der: $0) }
        if let selected = team, let actual = facts?.teamID, actual != selected {
            say("warning: certificate \(certificate.id) belongs to team \(actual) (the API key's), not \(selected); its key is recorded as team \(actual)'s in \(entry)")
        }
        do {
            try store.record(name: entry, secret: secret, certificateID: certificate.id, expires: facts?.expires ?? certificate.expires,
                             team: facts?.teamID ?? team)
        } catch {
            say("warning: certificate \(certificate.id) was created and its key is in the store as \(entry), but its ID could not be recorded with it (\(XlessError.wrapping(error, stage: stage).cause)); the sign stage still finds it by its public key")
        }
        return CertificateCreated(certificate: certificate, entry: entry, team: facts?.teamID ?? team)
    }

    /// A certificate for a key xless never sees: the CSR is sent as given, once.
    func run(type: CertificateType, relatedID: String?, csrPEM: String) async throws -> CertificateCreated {
        try await precheck(type)
        let certificate: ASCCertificate
        do {
            certificate = try await api.create(type: type, csrPEM: csrPEM, relatedID: relatedID)
        } catch {
            guard ASCCertificates.isAmbiguous(error) else { throw refused(type, error, removedEntry: nil, keptEntry: nil) }
            guard let made = await made(type, for: KeyMatch.publicKey(csrPEM: csrPEM), after: error) else { throw ambiguous(type, error, kept: nil) }
            certificate = made
        }
        return CertificateCreated(certificate: certificate, entry: nil, team: certificate.der.flatMap { CertificateFacts(der: $0) }?.teamID)
    }

    /// After a create request that may or may not have gone through: the certificate of `type` App Store Connect now
    /// lists for `key` (the one just asked for: a key is new, and a CSR's key is matched to its certificate by its public
    /// key), or nil when none is listed or the listing fails too (then the create stays ambiguous).
    func made(_ type: CertificateType, for key: KeyMatch.PublicKey?, after error: Error) async -> ASCCertificate? {
        guard let key, let listed = try? await api.list(types: [type], withContent: true),
              let found = KeyMatch.certificate(for: key, in: listed) else { return nil }
        say("The create request failed (\(XlessError.wrapping(error, stage: stage).cause)), but App Store Connect lists certificate \(found.id) for this key: it was created.")
        return found
    }

    static func needsCSR(_ type: CertificateType, stage: Stage) -> XlessError {
        XlessError(stage, "a \(type.displayName) certificate needs an ECC P-256 key, which xless does not generate",
                   fix: "pass the CSR your payment provider (or `openssl req -new` with an prime256v1 key) gave you: --csr <file>")
    }

    func ambiguous(_ type: CertificateType, _ error: Error, kept entry: String?) -> XlessError {
        XlessError(stage, "\(CertificateService.ambiguousMarker): the request to create the \(type.displayName) certificate failed (\(XlessError.wrapping(error, stage: stage).cause)) and may or may not have succeeded",
                   fix: "check `xless certs list \(type.listArguments)` before retrying"
                       + (entry.map { "; the private key is kept in the secret store as \($0) in case the certificate exists: `xless certs link` records it with its certificate once App Store Connect lists one for it (if none ever does, remove it with `xless secrets rm \($0)`)" } ?? ""))
    }

    func refused(_ type: CertificateType, _ error: Error, removedEntry: String?, keptEntry: String?) -> XlessError {
        let wrapped = XlessError.wrapping(error, stage: stage)
        let what = removedEntry.map { "; its private key was removed from the secret store (\($0))" }
            ?? keptEntry.map { "; its private key could not be removed from the secret store: remove \($0) with `xless secrets rm \($0)`" } ?? ""
        var fix = wrapped.fix
        if let e = error as? ASCError {
            switch e.status {
            case 403:
                fix = type.isDeveloperID
                    ? "Developer ID certificates need the Account Holder (developer.apple.com/help/account/certificates/create-developer-id-certificates/): have them create it, or make a CSR with `xless sign bootstrap --type developer-id --csr-only --out <key file>` and have them run `xless certs create --type \(type.argument) --csr <key file>.csr`"
                    : "creating certificates needs an API key with the Admin role (distribution certificates: the Account Holder or an Admin)"
            case 409:
                fix = "App Store Connect refuses another one when the team has as many \(type.displayName) certificates as Apple allows: revoke one you no longer use (`xless certs list \(type.listArguments)`, `xless certs revoke <id>`); otherwise check the type and the merchant or pass type ID"
            default: break
            }
        }
        let failed = error is ASCError ? "App Store Connect refused to create" : "xless could not ask App Store Connect for"
        return XlessError(stage, "\(failed) the \(type.displayName) certificate (\(wrapped.cause))\(what)", fix: fix)
    }
}

extension CertificateType {
    /// The `xless certs list` options showing every certificate counted with this one (both Developer ID Application
    /// generations share Apple's limit).
    var listArguments: String { (capGroup.isEmpty ? [self] : capGroup).map { "--type \($0.argument)" }.joined(separator: " ") }
}
