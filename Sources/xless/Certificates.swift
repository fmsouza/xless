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
    static func precheck(_ file: VaultFile, name: String, base: String?, team: String?, stage: Stage,
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

    let store: VaultStore
    /// The store this command unlocked (its key is `dataKey`).
    let fileID: String
    let dataKey: SymmetricKey

    /// Seals a new signing-key entry; a name taken meanwhile is an error (nothing was sent to Apple yet).
    func save(name: String, secret: SecretBytes, metadata: VaultEntry.Metadata) throws {
        try store.update { file in
            guard file.id == fileID else { throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command") }
            guard file.entry(named: name) == nil else {
                throw VaultError(.entryExists, "the secret store already has an entry \(name)", fix: "pass --name <another entry name>, or remove it (`xless secrets rm \(name)`)")
            }
            var next = file
            next.entries.append(try VaultCrypto.seal(name: name, kind: .signingKey, metadata: metadata, secret: secret, dataKey: dataKey))
            return next
        }
    }

    /// Re-seals `name` with the certificate's ID and expiry, and `team` (the certificate's own, when known) over the
    /// entry's.
    func record(name: String, secret: SecretBytes, certificateID: String, expires: Date?, team: String?) throws {
        try store.update { file in
            guard file.id == fileID, let index = file.entries.firstIndex(where: { $0.name == name }) else {
                throw VaultError(.noEntry, "the entry \(name) is no longer in the secret store", fix: "re-import the key with `xless secrets import`")
            }
            var metadata = file.entries[index].metadata
            metadata.teamID = team ?? metadata.teamID
            metadata.certificateID = certificateID
            metadata.expires = expires.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
            var next = file
            next.entries[index] = try VaultCrypto.seal(name: name, kind: .signingKey, metadata: metadata, secret: secret, dataKey: dataKey)
            return next
        }
    }

    /// Removes `name` (needs no passphrase).
    static func remove(_ name: String, from store: VaultStore) throws {
        try store.update { file in
            var next = file
            next.entries.removeAll { $0.name == name }
            return next
        }
    }

    /// The names of the entries holding the private key of certificate `id`.
    static func entries(holding id: String, in file: VaultFile?) -> [String] {
        (file?.entries ?? []).filter { $0.metadata.certificateID == id }.map(\.name).sorted()
    }
}

/// What `certs create` reports (`--json` prints it as is: Apple's certificate resource, and where its key went).
struct CertificateCreated: Encodable {
    let certificate: ASCCertificate
    /// The secret-store entry holding its private key; nil for a certificate made from a CSR.
    let entry: String?
    let team: String?

    var text: String {
        let type = CertificateType(rawValue: certificate.certificateType)
        var lines = ["created \(type?.displayName ?? certificate.certificateType) certificate \(certificate.id)"
            + (certificate.attributes.name.map { " (\($0))" } ?? "")
            + (certificate.expires.map { ", expires \(CertTable.day($0))" } ?? "")]
        if let entry {
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
            if ASCCertificates.isAmbiguous(error) { throw ambiguous(type, error, kept: entry) }
            var removed = true
            do { try CertificateKeyStore.remove(entry, from: store.store) } catch { removed = false }
            throw refused(type, error, removedEntry: removed ? entry : nil, keptEntry: removed ? nil : entry)
        }
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
        do {
            let certificate = try await api.create(type: type, csrPEM: csrPEM, relatedID: relatedID)
            return CertificateCreated(certificate: certificate, entry: nil, team: certificate.der.flatMap { CertificateFacts(der: $0) }?.teamID)
        } catch {
            if ASCCertificates.isAmbiguous(error) { throw ambiguous(type, error, kept: nil) }
            throw refused(type, error, removedEntry: nil, keptEntry: nil)
        }
    }

    static func needsCSR(_ type: CertificateType, stage: Stage) -> XlessError {
        XlessError(stage, "a \(type.displayName) certificate needs an ECC P-256 key, which xless does not generate",
                   fix: "pass the CSR your payment provider (or `openssl req -new` with an prime256v1 key) gave you: --csr <file>")
    }

    func ambiguous(_ type: CertificateType, _ error: Error, kept entry: String?) -> XlessError {
        XlessError(stage, "\(CertificateService.ambiguousMarker): the request to create the \(type.displayName) certificate failed (\(XlessError.wrapping(error, stage: stage).cause)) and may or may not have succeeded",
                   fix: "check `xless certs list \(type.listArguments)` before retrying"
                       + (entry.map { "; the private key is kept in the secret store as \($0) in case the certificate exists (if none matches it, remove it with `xless secrets rm \($0)`)" } ?? ""))
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
