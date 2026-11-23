import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessSign
import XlessVault

struct CertsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certs",
        abstract: "List, create, download and revoke certificates of every type; the private keys xless makes go straight into the secret store.",
        discussion: """
        Uses the App Store Connect API key (/v1/certificates; creating and revoking need the Admin role, and Developer ID \
        certificates the Account Holder). Types are App Store Connect's (DISTRIBUTION, DEVELOPMENT, \
        DEVELOPER_ID_APPLICATION_G2, MAC_INSTALLER_DISTRIBUTION, APPLE_PAY_MERCHANT_IDENTITY, PASS_TYPE_ID…), in any case \
        and with dashes; `developer-id` and `installer` stand for DEVELOPER_ID_APPLICATION_G2 and MAC_INSTALLER_DISTRIBUTION.

          xless certs list --expiring 30
          xless certs create --type distribution
          xless certs create --type apple-pay --merchant-id merchant.com.example.store --csr processing.csr
          xless certs download 8U3T4X5YZA --out distribution.cer
          xless certs revoke 8U3T4X5YZA
          xless certs link
        """,
        subcommands: [CertsListCommand.self, CertsCreateCommand.self, CertsShowCommand.self, CertsDownloadCommand.self, CertsRevokeCommand.self,
                      CertsLinkCommand.self])
}

/// A `--type` value: an App Store Connect certificate type.
enum CertificateTypeArgument {
    static let names = CertificateType.allCases.map(\.argument).joined(separator: ", ")

    /// For `list`: `developer-id` shows both Developer ID Application generations (they share Apple's limit).
    static func parseForList(_ text: String) throws -> [CertificateType] {
        let type = try parse(text)
        return text.lowercased() == "developer-id" ? type.capGroup : [type]
    }

    static func parse(_ text: String) throws -> CertificateType {
        guard let type = CertificateType(argument: text) else {
            throw ValidationError("--type \(text) is not a certificate type: use one of \(names) (or developer-id, installer)")
        }
        return type
    }
}

/// A certificate argument: its ID (`xless certs list`).
enum CertificateArgument {
    static let help = ArgumentHelp("The certificate's ID (see `xless certs list`).", valueName: "certificate-id")

    static func validate(_ text: String) throws {
        guard isASCResourceID(text) else { throw ValidationError("\(text) is not a certificate ID (letters and digits, see `xless certs list`)") }
    }
}

/// Opens the account session and runs `body` with the certificate operations; prints what it returns.
private func runCerts(_ team: String?, verbose: Bool, _ body: (CertCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(CertCLI(certificates: ASCCertificates(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct CertsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's certificates: ID, type, name, serial number, expiry, and the secret-store entry holding the private key.")

    @Option(name: .customLong("type"), help: ArgumentHelp("Only this type; repeatable.", valueName: "type"))
    var types: [String] = []
    @Option(help: ArgumentHelp("Only certificates that expire within this many days (or have expired).", valueName: "days"))
    var expiring: Int?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        for type in types { _ = try CertificateTypeArgument.parse(type) }
        if let expiring, expiring < 0 { throw ValidationError("--expiring takes a number of days, 0 or more") }
    }

    func run() async throws {
        var types: [CertificateType] = []
        for type in try self.types.flatMap(CertificateTypeArgument.parseForList) where !types.contains(type) { types.append(type) }
        try await runCerts(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).list(types: types, expiringWithin: expiring) }
    }
}

struct CertsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a certificate: xless generates its private key and keeps it in the secret store, or signs nothing and sends your CSR.",
        discussion: """
        Without --csr, xless generates an RSA-2048 key and seals it into the secret store (`xless secrets init` first) \
        before anything is sent, as XLESS_DIST_KEY, XLESS_DEVID_KEY or XLESS_INSTALLER_KEY for the three certificates \
        `sign` uses and XLESS_<TYPE>_KEY for the others, with @<TEAM_ID> when a team is selected (--name picks another \
        entry). The create request is sent once, never retried. If App Store Connect refuses it, the key is removed again; \
        if the request fails in a way that may have created the certificate, the key is kept and the error says so. The \
        entry records the team, the certificate's ID, type and expiry.

        With --csr, the key lives elsewhere (an HSM, another machine): xless only sends the CSR, and nothing secret \
        touches it. Apple Pay payment processing (apple-pay) needs an ECC P-256 key, so it always takes --csr. Apple Pay \
        certificates need --merchant-id, Wallet pass certificates --pass-type-id.

        Apple allows five Developer ID Application certificates per team (checked before anything is generated); for the \
        other types Apple documents no number and refuses one too many itself.
        """)

    @Option(help: ArgumentHelp("The certificate type (see `xless certs --help`).", valueName: "type"))
    var type: String
    @Option(help: ArgumentHelp("Send this certificate signing request (PEM or DER) instead of generating a key.", valueName: "file"))
    var csr: String?
    @Option(help: ArgumentHelp("The secret-store entry for the generated key (default: from the type and the team).", valueName: "store-entry-name"))
    var name: String?
    @Option(help: ArgumentHelp("The merchant ID an Apple Pay certificate is for: its identifier (merchant.…) or ID.", valueName: "merchant-id"))
    var merchantId: String?
    @Option(help: ArgumentHelp("The pass type ID a Wallet pass certificate is for: its identifier (pass.…) or ID.", valueName: "pass-type-id"))
    var passTypeId: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        let type = try CertificateTypeArgument.parse(type)
        if csr != nil, name != nil { throw ValidationError("--name names where a generated key goes; with --csr nothing is stored") }
        if let name, !VaultEntry.isValidName(name) { throw ValidationError("--name \(name) is not an entry name: letters, digits and . _ @ -") }
        if type.needsECCKey, csr == nil { let e = CertificateCreation.needsCSR(type, stage: .account); throw ValidationError("\(e.cause); \(e.fix)") }
        switch type.relationship {
        case .merchantID?:
            if merchantId == nil { throw ValidationError("a \(type.argument) certificate is for a merchant ID: pass --merchant-id") }
            if passTypeId != nil { throw ValidationError("--pass-type-id is for pass-type-id certificates") }
        case .passTypeID?:
            if passTypeId == nil { throw ValidationError("a \(type.argument) certificate is for a pass type ID: pass --pass-type-id") }
            if merchantId != nil { throw ValidationError("--merchant-id is for Apple Pay certificates") }
        case nil:
            if merchantId != nil || passTypeId != nil { throw ValidationError("a \(type.argument) certificate is for no merchant ID or pass type ID") }
        }
    }

    func run() async throws {
        let type = try CertificateTypeArgument.parse(type)
        try await AccountSession.run {
            SecretScope.enter()
            let csrPEM = try csr.map { path in
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw XlessError(.account, "cannot read \(path)", fix: "check the path given to --csr")
                }
                return try CSRFile.pem(from: data, path: path)
            }
            // The store is checked before any request, so a missing store or a taken name costs nothing.
            let file: SecretCatalog? = csrPEM == nil ? try APIKeyWebCLI.existingStore() : nil
            let session = try AccountSession.open(team: team.team, verbose: trace.verbose)
            let certificates = ASCCertificates(resources: session.resources)
            let entry = name ?? CertificateKeyStore.entryName(base: type.defaultEntryBase, team: session.team)
            if let file {
                try CertificateKeyStore.precheck(file, name: entry, base: CertificateKeyStore.signBase(of: entry) ?? (name == nil ? type.defaultEntryBase : nil),
                                                 team: session.team, stage: .account)
            }
            let related: String?
            switch type.relationship {
            case .merchantID?: related = try await ASCMerchantIDs(resources: session.resources).resolve(merchantId ?? "").id
            case .passTypeID?: related = try await certificates.passTypeID(passTypeId ?? "")
            case nil: related = nil
            }
            var creation = CertificateCreation(api: certificates, say: AppleWebCLI.say)
            let created: CertificateCreated
            if let csrPEM {
                // The CSR may have been made from a key the store holds (`sign bootstrap --csr-only`, then imported).
                creation.link = (try? SecretStoreCLI.store()).map { CertificateKeyLink(store: $0, team: session.team) }
                created = try await creation.run(type: type, relatedID: related, csrPEM: csrPEM)
            } else {
                created = try await creation.run(type: type, relatedID: related, entry: entry, team: session.team, keys: {
                    try APIKeyWebCLI.unlocked(reason: "storing the new certificate's private key") { CertificateKeyStore(store: $0, catalogID: $1.id) }
                })
            }
            print(output.json ? try ASCOutput.json(created) : created.text, terminator: "")
        }
    }
}

struct CertsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one certificate (never a private key).")

    @Argument(help: CertificateArgument.help) var certificate: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try CertificateArgument.validate(certificate) }

    func run() async throws {
        try await runCerts(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).show(certificate) }
    }
}

struct CertsDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Write a certificate (public material, DER .cer) to a new file, mode 0644; never overwrites.")

    @Argument(help: CertificateArgument.help) var certificate: String
    @Option(help: ArgumentHelp("The file to create (e.g. distribution.cer).", valueName: "file")) var out: String
    @OptionGroup var team: TeamOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try CertificateArgument.validate(certificate) }

    func run() async throws {
        try await runCerts(team.team, verbose: trace.verbose) { try await $0.download(certificate, to: out) }
    }
}

struct CertsRevokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke a certificate (asks first, naming the profiles that stop working). Apple has no undo.",
        discussion: """
        Profiles that contain the certificate become invalid (`sign` makes its own again with another certificate). For a \
        Developer ID certificate, users can no longer install apps signed with it. The secret-store entry holding its \
        private key is left in place, and named so you can remove it.
        """)

    @Argument(help: CertificateArgument.help) var certificate: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try CertificateArgument.validate(certificate) }

    func run() async throws {
        try await runCerts(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).revoke(certificate, yes: confirmation.yes) }
    }
}

struct CertsLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Record with each signing key in the secret store the certificate issued for it, matched by public key.",
        discussion: """
        For keys the store does not link to a certificate: imported with `xless secrets import`, kept after a create whose \
        answer was lost, or whose certificate was made from a CSR. Their certificate ID, type, expiry and team are recorded \
        with them, so `xless certs list` and `show` name the key. Asks the passphrase only when such a key is there; keys \
        of another team are never opened.
        """)

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            let session = try AccountSession.open(team: team.team, verbose: trace.verbose)
            let cli = CertCLI(certificates: ASCCertificates(resources: session.resources)).with(json: output.json)
            print(try await cli.link(store: try SecretStoreCLI.store(), team: session.team), terminator: "")
        }
    }
}

/// What the certificate commands do once their arguments are valid; returns what goes to standard output and says the
/// rest (warnings, cancellations) on standard error.
struct CertCLI {
    let certificates: ASCCertificates
    var json = false
    /// The secret store's file, read without a passphrase (names and metadata only).
    var storeFile: () -> (any SecretEntries)? = { try? SecretStoreCLI.store().catalog() }
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var now: () -> Date = { Date() }

    func with(json: Bool) -> CertCLI { var copy = self; copy.json = json; return copy }

    func list(types: [CertificateType], expiringWithin days: Int?) async throws -> String {
        var list = try await certificates.list(types: types)
        if let days {
            let limit = now().addingTimeInterval(Double(days) * 86400)
            list = list.filter { ($0.expires ?? .distantFuture) <= limit }
        }
        if json { return try ASCOutput.json(["data": list]) }
        if list.isEmpty {
            return days == nil ? "This team has no\(types.isEmpty ? "" : " such") certificates (create one with `xless certs create --type <type>`).\n"
                : "No certificate expires within \(days!) days.\n"
        }
        return CertTable.render(list, store: storeFile())
    }

    func show(_ id: String) async throws -> String {
        let c = try await certificates.get(id: id)
        if json { return try ASCOutput.json(c) }
        let a = c.attributes
        let keys = CertificateKeyStore.entries(holding: c.id, in: storeFile())
        let rows: [(String, String?)] = [
            ("ID", c.id), ("Type", c.certificateType + (CertificateType(rawValue: c.certificateType).map { " (\($0.displayName))" } ?? "")),
            ("Name", a.name), ("Display name", a.displayName), ("Serial", a.serialNumber), ("Platform", a.platform),
            ("Expires", c.expires.map(CertTable.day) ?? a.expirationDate), ("Activated", a.activated.map { $0 ? "yes" : "no" }),
            ("Private key", keys.isEmpty ? "not in the secret store" : "in the secret store as \(keys.joined(separator: ", "))"),
        ]
        return rows.compactMap { k, v in v.map { "\((k + ":").padding(toLength: 14, withPad: " ", startingAt: 0))\($0)" } }.joined(separator: "\n") + "\n"
    }

    func download(_ id: String, to path: String) async throws -> String {
        let c = try await certificates.get(id: id)
        guard let der = c.der, !der.isEmpty else {
            throw XlessError(.account, "App Store Connect sent certificate \(id) without its content", fix: "re-run; if it persists, check the certificate with `xless certs show \(id) --json`")
        }
        do { try SigningKey.writeExclusively(der, toPath: path, mode: 0o644) } catch let e as XlessError {
            throw XlessError(.account, e.cause, fix: e.fix)
        }
        return "wrote certificate \(c.id) (\(c.certificateType)\(c.expires.map { ", expires \(CertTable.day($0))" } ?? "")) to \(path)\n"
    }

    /// `certs link`: every certificate of the team (with its content) matched with the store's unlinked signing keys.
    func link(store: any SecretStore, team: String?) async throws -> String {
        guard try store.catalog() != nil else {
            throw XlessError(.account, "there is no secret store, so no key to link", fix: "create it with `xless secrets init`")
        }
        let all = try await certificates.list(withContent: true)
        // Without a selected team, the team the certificates are for (Apple puts it in each one): another team's keys
        // are never opened, nor called unmatched.
        let teams = Set(all.compactMap { $0.der.flatMap { CertificateFacts(der: $0) }?.teamID })
        let link = CertificateKeyLink(store: store, team: team ?? (teams.count == 1 ? teams.first : nil))
        let outcome = try link.link(all, known: Set(all.map(\.id)), reason: "matching the signing keys with their certificates")
        if json { return try ASCOutput.json(outcome) }
        if outcome.linked.isEmpty, outcome.unmatched.isEmpty { return "Every signing key in the secret store has its certificate recorded.\n" }
        var text = ""
        for l in outcome.linked {
            let c = all.first { $0.id == l.certificate }
            let type = c.flatMap { CertificateType(rawValue: $0.certificateType)?.displayName } ?? c?.certificateType ?? "?"
            text += "linked \(l.entry) to \(type) certificate \(l.certificate)\(c?.expires.map { ", expires \(CertTable.day($0))" } ?? "")\n"
        }
        for name in outcome.unmatched {
            text += "no certificate of the team matches \(name): if its certificate is gone, remove it with `xless secrets rm \(name)`\n"
        }
        return text
    }

    struct Revoked: Encodable {
        let revoked: String
        let certificateType: String
        let profiles: [ASCCertificateProfile]
        let storeEntries: [String]
    }

    func revoke(_ id: String, yes: Bool) async throws -> String {
        let c = try await certificates.get(id: id)
        let profiles = try await certificates.profiles(using: c.id)
        let store = storeFile()
        let keys = CertificateKeyStore.entries(holding: c.id, in: store)
        let type = CertificateType(rawValue: c.certificateType)
        for p in profiles { say("stops working: profile \(p.name) (\(p.id), \(p.profileType ?? "?"))") }
        var question = "Revoke \(type?.displayName ?? c.certificateType) certificate \(c.id)\(c.attributes.name.map { " (\($0))" } ?? "")"
            + "\(c.expires.map { ", expires \(CertTable.day($0))" } ?? "")? "
        question += profiles.isEmpty ? "No profile contains it. " : "\(profiles.count) profile\(profiles.count == 1 ? "" : "s") stop working. "
        if type?.isDeveloperID == true { question += "Users can no longer install apps signed with it. " }
        question += "Apple has no undo."
        guard try AccountConfirm.confirm(question, action: "revoking certificate \(c.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await certificates.revoke(id: c.id)
        if json { return try ASCOutput.json(Revoked(revoked: c.id, certificateType: c.certificateType, profiles: profiles, storeEntries: keys)) }
        var text = "revoked certificate \(c.id)\n"
        if !profiles.isEmpty {
            text += "now invalid: \(profiles.map(\.name).joined(separator: ", ")) (`xless sign` makes its own profiles again with another certificate)\n"
        }
        let writable = (store as? SecretCatalog)?.isWritable ?? (store as? VaultFile)?.isWritable ?? true
        for key in keys { text += StoreCleanup.leftEntry(key, writable: writable) + "\n" }
        return text
    }
}

enum CertTable {
    static func render(_ list: [ASCCertificate], store: (any SecretEntries)?) -> String {
        TextTable(["ID", "TYPE", "NAME", "SERIAL", "EXPIRES", "KEY IN STORE"], list.map { c in
            let keys = CertificateKeyStore.entries(holding: c.id, in: store)
            return [c.id, CertificateType(rawValue: c.certificateType)?.argument ?? c.certificateType, c.attributes.displayName ?? c.attributes.name ?? "",
                    c.attributes.serialNumber ?? "", c.expires.map(day) ?? "", keys.isEmpty ? "-" : keys.joined(separator: ",")]
        }).rendered
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
