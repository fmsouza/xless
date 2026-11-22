import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault

struct AuthAPIKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api-key",
        abstract: "Create, import, list and revoke App Store Connect API keys; their private keys go straight into the secret store.",
        discussion: """
        Team keys only: individual keys (each person's own, App Store Connect's /iris/v2) are not supported. The private \
        key never touches the disk in clear: it goes into the secret store (`xless secrets`) as ASC_KEY_P8@<TEAM_ID>, \
        with its key ID, issuer ID and role, where the pipeline and the account commands find it.
        """,
        subcommands: [AuthAPIKeyCreateCommand.self, AuthAPIKeyImportCommand.self, AuthAPIKeyListCommand.self, AuthAPIKeyRevokeCommand.self])
}

/// What the web-session `api-key` commands share: signing in, the team, and App Store Connect's provider for it.
enum APIKeyWebCLI {
    static func open(team: String?, verbose: Bool) async throws -> (AppleWebSession, URLSessionAppleTransport, PortalTeam) {
        let (session, transport) = try await AppleWebCLI.open(verbose: verbose)
        do {
            let selected = try await session.selectTeam(team)
            try await session.useProvider(for: selected, choose: AppleWebCLI.chooser())
            return (session, transport, selected)
        } catch {
            transport.invalidate()
            throw error
        }
    }

    /// The documented API's transport for the verification call (traced with --verbose).
    static func apiTransport(verbose: Bool) -> HTTPTransport {
        verbose ? TracingTransport(URLSessionTransport(), trace: .standardError) : URLSessionTransport()
    }

    static var store: VaultStore { VaultStore(location: .standard()) }

    static func existingStore() throws -> VaultFile {
        guard let file = try store.read() else { throw VaultStore.notInitialized(.standard()) }
        return file
    }
}

struct AuthAPIKeyCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an App Store Connect API key, put its private key straight into the secret store, and check it works.",
        discussion: AppleWebHelp.note + """


        Needs an Apple ID that is the team's Account Holder, or an Admin the Account Holder allowed to generate API keys, \
        and a secret store (`xless secrets init`); the store is unlocked before anything is created. Apple offers a new \
        key's private key once: xless downloads it once, never retries, seals it into the store as ASC_KEY_P8@<TEAM_ID> \
        (with its key ID, issuer ID and role), then checks it with one documented call (GET /v1/apps). If anything fails \
        after the key was created, the error says so: the key exists and should be revoked.

        Roles (--role, repeatable): pick the narrowest that covers what you plan. APP_MANAGER (the default) works for \
        apps, the listing, TestFlight, builds, certificates and profiles; users and invitations need ADMIN; DEVELOPER \
        cannot create certificates; FINANCE, SALES and ACCESS_TO_REPORTS read reports. The role is shown now and by \
        `xless auth status`.
        """)

    @Option(name: .customLong("name"), help: ArgumentHelp("The key's name in App Store Connect (default: xless <date>).", valueName: "nickname"))
    var nickname: String?
    @Option(name: .customLong("role"), help: ArgumentHelp("The key's role: \(APIKeyRoles.known.joined(separator: ", ")); repeatable. Default: APP_MANAGER.", valueName: "role"))
    var roles: [String] = []
    @Flag(help: "The key sees every app (the default).")
    var allApps = false
    @Option(name: .customLong("app"), help: ArgumentHelp("Only this app (its App Store Connect app ID, e.g. 1234567890); repeatable.", valueName: "app-id"))
    var apps: [String] = []
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if allApps, !apps.isEmpty { throw ValidationError("--all-apps and --app exclude each other") }
        if let bad = apps.first(where: { $0.isEmpty || !$0.allSatisfy(\.isNumber) || !$0.allSatisfy(\.isASCII) }) {
            throw ValidationError("--app \(bad) is not an App Store Connect app ID (digits, e.g. 1234567890; see `xless api GET /v1/apps`)")
        }
        let parsed: [String]
        do { parsed = try APIKeyRoles.parse(roles) } catch let e as XlessError { throw ValidationError("\(e.cause); \(e.fix)") }
        if parsed.contains("ADMIN"), !apps.isEmpty { throw ValidationError("an ADMIN key sees every app: drop --app, or choose another role") }
        if let nickname, nickname.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--name is empty") }
    }

    func run() async throws {
        try await AccountSession.run {
            SecretScope.enter()
            let roles = try APIKeyRoles.parse(self.roles)
            let file = try APIKeyWebCLI.existingStore()
            let wanted = AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())
            if let wanted { try APIKeyStore.precheck(file, name: APIKeyStore.entryName(team: wanted), team: wanted) }
            let dataKey = try SecretStoreCLI.unlock(file, remember: nil, reason: "storing the new API key")
            let (session, transport, selected) = try await APIKeyWebCLI.open(team: wanted, verbose: trace.verbose)
            defer { transport.invalidate() }
            guard let issuer = try await session.asc.session().provider?.publicProviderId, !issuer.isEmpty else {
                throw XlessError(.account, "App Store Connect did not give this team's issuer ID; nothing was created",
                                 fix: "App Store Connect's web interface is undocumented and may have changed: re-run with --verbose to see the exchange (redacted), or create the key at \(ASCAPIKeys.page) and run `xless auth api-key import`")
            }
            let entry = APIKeyStore.entryName(team: selected.teamId)
            try APIKeyStore.precheck(try APIKeyWebCLI.existingStore(), name: entry, team: selected.teamId)
            let creation = APIKeyCreation(web: ASCAPIKeys(asc: session.asc),
                                          vault: APIKeyStore(store: APIKeyWebCLI.store, fileID: file.id, dataKey: dataKey),
                                          verify: APIKeyVerification.verifier(transport: APIKeyWebCLI.apiTransport(verbose: trace.verbose), unauthorizedRetries: 6),
                                          say: AppleWebCLI.say)
            let created = try await creation.run(nickname: nickname?.trimmingCharacters(in: .whitespaces) ?? "xless \(AuthAPIKeyCreateCommand.today())",
                                                 roles: roles, appIDs: apps, team: selected.teamId, issuerID: issuer, entry: entry)
            await session.end()
            print(output.json ? try ASCOutput.json(created) : created.text, terminator: "")
            if wanted == nil {
                AppleWebCLI.say("hint: `xless team use \(selected.teamId)` makes this team the default of the account commands")
            }
        }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct AuthAPIKeyImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Put an App Store Connect API key's .p8 file into the secret store, after checking it works; offers to delete the file.",
        discussion: """
        No Apple ID sign-in. Reads the file once (at most 1 MiB), checks that it is a P-256 private key and that App Store \
        Connect accepts it (one documented call, GET /v1/apps), then stores it as ASC_KEY_P8@<TEAM_ID> (with --team or the \
        team saved by `xless team use`), else as ASC_KEY_P8. A key that does not work is not stored.
        """)

    @Option(help: "The AuthKey_<KEY_ID>.p8 file App Store Connect gave you.")
    var p8File: String
    @Option(help: "The key ID (default: from an AuthKey_<KEY_ID>.p8 file name).")
    var keyId: String?
    @Option(help: "The issuer ID (App Store Connect > Users and Access > Integrations).")
    var issuerId: String
    @Option(help: ArgumentHelp("The key's role, recorded for `xless auth status` (App Store Connect does not tell a key its role).", valueName: "role"))
    var role: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if let keyId, !ASCAPIKeys.isKeyID(keyId) { throw ValidationError("--key-id \(keyId) is not a key ID (upper-case letters and digits, e.g. 2X9R4HXF34)") }
        if let role { do { _ = try APIKeyRoles.parse([role]) } catch let e as XlessError { throw ValidationError("\(e.cause); \(e.fix)") } }
        if issuerId.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--issuer-id is empty") }
    }

    func run() async throws {
        try await AccountSession.run {
            SecretScope.enter()
            guard let keyID = keyId ?? VaultImport.keyID(fromFileName: URL(fileURLWithPath: p8File).lastPathComponent) else {
                throw XlessError(.account, "the key ID is not in the file name \(URL(fileURLWithPath: p8File).lastPathComponent)", fix: "pass --key-id")
            }
            let teamID = AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())
            let entry = APIKeyStore.entryName(team: teamID)
            try APIKeyStore.precheck(try APIKeyWebCLI.existingStore(), name: entry, team: teamID)
            let secret = try SecretsImportCommand.readFile(p8File)
            defer { secret.wipe() }
            let name = try await APIKeyImport.run(
                secret: secret, keyID: keyID, issuerID: issuerId.trimmingCharacters(in: .whitespaces),
                role: try role.map { try APIKeyRoles.parse([$0])[0] }, team: teamID, entry: entry,
                verify: APIKeyVerification.verifier(transport: APIKeyWebCLI.apiTransport(verbose: trace.verbose)),
                unlock: {
                    let file = try APIKeyWebCLI.existingStore()
                    return APIKeyStore(store: APIKeyWebCLI.store, fileID: file.id,
                                       dataKey: try SecretStoreCLI.unlock(file, remember: nil, reason: "importing API key \(keyID)"))
                })
            print("imported API key \(keyID) into the secret store as \(name) (App Store Connect accepted it)")
            try SecretStoreCLI.offerToDelete(p8File)
        }
    }
}

struct AuthAPIKeyListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's App Store Connect API keys (never a private key), marking the one xless uses.",
        discussion: AppleWebHelp.note)

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            let wanted = AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())
            let (session, transport, _) = try await APIKeyWebCLI.open(team: wanted, verbose: trace.verbose)
            defer { transport.invalidate() }
            let keys = try await ASCAPIKeys(asc: session.asc).list()
            await session.end()
            let used = APIKeyListing.usedKeyID(env: ProcessInfo.processInfo.environment, store: { try APIKeyWebCLI.store.read() }, team: wanted)
            let rows = APIKeyListing.rows(keys, used: used)
            print(output.json ? try ASCOutput.json(rows) : APIKeyListing.table(rows), terminator: "")
        }
    }
}

struct AuthAPIKeyRevokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke an App Store Connect API key (asks first; Apple cannot undo it) and remove it from the secret store.",
        discussion: AppleWebHelp.note)

    @Argument(help: "The key ID (see `xless auth api-key list`).")
    var keyID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if !ASCAPIKeys.isKeyID(keyID) { throw ValidationError("\(keyID) is not a key ID (upper-case letters and digits, e.g. 2X9R4HXF34)") }
    }

    func run() async throws {
        try await AccountSession.run {
            let wanted = AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())
            let (session, transport, _) = try await APIKeyWebCLI.open(team: wanted, verbose: trace.verbose)
            defer { transport.invalidate() }
            let keys = ASCAPIKeys(asc: session.asc)
            let key = try await keys.get(id: keyID)
            if key.isActive {
                let used = APIKeyListing.usedKeyID(env: ProcessInfo.processInfo.environment, store: { try APIKeyWebCLI.store.read() }, team: wanted) == keyID
                let what = [key.nickname.map { "\"\($0)\"" }, key.roles.isEmpty ? nil : key.roles.joined(separator: ", ")].compactMap { $0 }.joined(separator: ", ")
                let question = "Revoke API key \(keyID)\(what.isEmpty ? "" : " (\(what))")? Everything using it stops working at once, and Apple cannot undo it."
                    + (used ? " xless uses this key." : "")
                guard try AccountConfirm.confirm(question, action: "revoking API key \(keyID)", yes: confirmation.yes) else {
                    print("cancelled; nothing was sent")
                    await session.end()
                    return
                }
                try await keys.revoke(id: keyID)
                print("revoked API key \(keyID)")
            } else {
                print("API key \(keyID) was already revoked")
            }
            await session.end()
            let removed = try APIKeyStore.removeKeys(id: keyID, from: APIKeyWebCLI.store)
            print(removed.isEmpty ? "the secret store held no entry for it" : "removed \(removed.joined(separator: ", ")) from the secret store")
        }
    }
}
