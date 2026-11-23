import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault

struct KeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Create, list, show and revoke auth keys (APNs, Sign in with Apple, DeviceCheck, MusicKit); their .p8 goes straight into the secret store.",
        discussion: AppleWebHelp.note + """


        Services (--service, repeatable or comma-separated): apns (token-based push notifications), siwa (Sign in with \
        Apple; needs --bundle-id), devicecheck, musickit (needs --music-id). Apple offers a new key's .p8 once: `create` downloads it once \
        and seals it into the secret store as XLESS_APNS_KEY@<TEAM_ID> (XLESS_SIWA_KEY, XLESS_DEVICECHECK_KEY, \
        XLESS_MUSICKIT_KEY; XLESS_AUTH_KEY for several services), with the key ID, team and services. \
        `xless secrets export <entry> --out AuthKey_<KEY_ID>.p8` writes it out when a server needs the file.

          xless keys list
          xless keys create --service apns --name "Push"
          xless keys create --service siwa --bundle-id com.example.app
          xless keys create --service musickit --music-id AB12CD34EF
          xless keys show 2X9R4HXF34
          xless keys revoke 2X9R4HXF34
        """,
        subcommands: [KeysListCommand.self, KeysCreateCommand.self, KeysShowCommand.self, KeysRevokeCommand.self])
}

/// A key ID argument.
enum AuthKeyArgument {
    static let help = ArgumentHelp("The key ID (see `xless keys list`).", valueName: "key-id")

    static func validate(_ text: String) throws {
        guard PortalAuthKeys.isKeyID(text) else { throw ValidationError("\(text) is not a key ID (letters and digits, e.g. 2X9R4HXF34)") }
    }
}

/// The services of `--service`: repeatable, comma-separated, in the order given, without repeats.
enum AuthKeyServiceArgument {
    static let names = AuthKeyService.allCases.map(\.argument).joined(separator: ", ")

    static func parse(_ texts: [String]) throws -> [AuthKeyService] {
        var services: [AuthKeyService] = []
        for text in texts.flatMap({ $0.split(separator: ",").map(String.init) }) {
            guard let s = AuthKeyService(argument: text) else {
                throw ValidationError("--service \(text) is not an auth key service: use \(names) (MapKit and WeatherKit are not supported)")
            }
            if !services.contains(s) { services.append(s) }
        }
        guard !services.isEmpty else { throw ValidationError("pass --service (\(names))") }
        return services
    }
}

/// Signs in, selects the team, runs `body` with the portal's keys and the team ID, prints what it returns.
private func runKeys(team: String?, verbose: Bool, _ body: (PortalAuthKeys) async throws -> String) async throws {
    try await AccountSession.run {
        let (session, transport) = try await AppleWebCLI.open(verbose: verbose)
        defer { transport.invalidate() }
        _ = try await session.selectTeam(AccountSession.resolveTeam(flag: team, saved: AccountSession.savedTeam()))
        let out = try await body(PortalAuthKeys(portal: session.portal))
        await session.end()
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

private func keysCLI(_ keys: PortalAuthKeys, json: Bool) -> AuthKeyCLI {
    AuthKeyCLI(web: keys, json: json, storeFile: { try? APIKeyWebCLI.store().catalog() },
               removeEntries: { try AuthKeyStore.removeKeys(id: $0, from: try APIKeyWebCLI.store()) })
}

struct KeysListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's auth keys: key ID, name, services and the secret-store entry holding the .p8 (never a private key).",
        discussion: AppleWebHelp.note)

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runKeys(team: team.team, verbose: trace.verbose) { keys in try await keysCLI(keys, json: output.json).list() }
    }
}

struct KeysShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one auth key: its services, Sign in with Apple bundle IDs, and whether the secret store holds its .p8.",
        discussion: AppleWebHelp.note)

    @Argument(help: AuthKeyArgument.help) var keyID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try AuthKeyArgument.validate(keyID) }

    func run() async throws {
        try await runKeys(team: team.team, verbose: trace.verbose) { keys in try await keysCLI(keys, json: output.json).show(keyID) }
    }
}

struct KeysCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an auth key and put its .p8 straight into the secret store.",
        discussion: AppleWebHelp.note + """


        Needs a secret store (`xless secrets init`); it is unlocked (a credential helper must pass a test write) before \
        anything is created. xless first lists the \
        team's keys: a name already used, or a service at Apple's limit (two APNs keys per team; the error lists them), \
        stops it before anything is sent. The create request is sent once, never retried. Apple offers the new key's \
        .p8 once: xless downloads it once and seals it into the store. If anything fails once the key exists, the error \
        says so: the key cannot be downloaded again and should be revoked (`xless keys revoke <KEY_ID>`); if only the \
        store failed, the .p8 is saved to a new 0600 file ($XDG_RUNTIME_DIR, or a path asked on the terminal) and the \
        error gives the `xless secrets import` command that stores it.

        An APNs key works for every app of the team, in the sandbox and production environments.
        """)

    @Option(name: .customLong("service"), help: ArgumentHelp("apns, siwa, devicecheck or musickit; repeatable or comma-separated.", valueName: "service"))
    var services: [String] = []
    @Option(help: ArgumentHelp("The key's name in the portal: ASCII letters, digits and spaces (default: xless <services> <date>).", valueName: "name"))
    var name: String?
    @Option(name: .customLong("bundle-id"), help: ArgumentHelp("Sign in with Apple: the primary App ID the key is for (its identifier or ID).", valueName: "bundle-id"))
    var bundleID: String?
    @Option(name: .customLong("music-id"), help: ArgumentHelp("MusicKit: the Music ID the key is for (its ID in the portal's Identifiers > Music IDs); repeatable.", valueName: "music-id"))
    var musicIDs: [String] = []
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        let services = try AuthKeyServiceArgument.parse(self.services)
        if services.contains(.signInWithApple), bundleID == nil {
            throw ValidationError("a Sign in with Apple key is for an app: pass --bundle-id <identifier> (its primary App ID)")
        }
        if !services.contains(.signInWithApple), bundleID != nil { throw ValidationError("--bundle-id is for Sign in with Apple keys (--service siwa)") }
        if services.contains(.musicKit), musicIDs.isEmpty {
            throw ValidationError("a MusicKit key is for a Music ID: pass --music-id <ID> (register one at https://developer.apple.com/account/resources/identifiers/list/musicId)")
        }
        if !services.contains(.musicKit), !musicIDs.isEmpty { throw ValidationError("--music-id is for MusicKit keys (--service musickit)") }
        if let bad = musicIDs.first(where: { !PortalIdentifiers.isResourceID($0) }) {
            throw ValidationError("--music-id \(bad) is not a Music ID's ID (letters and digits, as the portal shows it)")
        }
        if let name { do { try PortalName.validate(name) } catch let e as IdentifierInputError { throw ValidationError(e.description) } }
        if let b = bundleID {
            let t = b.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.".unicodeScalars.contains($0)) }) else {
                throw ValidationError("--bundle-id \(b) is neither a bundle identifier (com.example.app) nor a bundle ID's ID")
            }
        }
    }

    func run() async throws {
        let services = try AuthKeyServiceArgument.parse(self.services)
        try await AccountSession.run {
            SecretScope.enter()
            // The store is checked and unlocked before signing in, so nothing is created that could not be kept.
            let keys = try APIKeyWebCLI.unlocked(reason: "storing the new auth key") { AuthKeyStore(store: $0, catalogID: $1.id) }
            let (session, transport) = try await AppleWebCLI.open(verbose: trace.verbose)
            defer { transport.invalidate() }
            let teamID = try await session.selectTeam(AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())).teamId
            var bundles: [String] = []
            if let bundleID { bundles.append(try await PortalBundleIDs(portal: session.portal).resolve(bundleID).id) }
            let creation = AuthKeyCreation(web: PortalAuthKeys(portal: session.portal),
                                           vault: keys, say: AppleWebCLI.say)
            let created = try await creation.run(name: name?.trimmingCharacters(in: .whitespaces), services: services, bundleIDs: bundles,
                                                 musicIDs: musicIDs, team: teamID)
            await session.end()
            print(output.json ? try ASCOutput.json(created) : created.text, terminator: "")
        }
    }
}

struct KeysRevokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke an auth key (asks first; Apple cannot undo it) and remove its .p8 from the secret store.",
        discussion: AppleWebHelp.note)

    @Argument(help: AuthKeyArgument.help) var keyID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try AuthKeyArgument.validate(keyID) }

    func run() async throws {
        try await runKeys(team: team.team, verbose: trace.verbose) { keys in
            try await keysCLI(keys, json: false).revoke(keyID) { question in
                try AccountConfirm.confirm(question, action: "revoking auth key \(keyID)", yes: confirmation.yes)
            }
        }
    }
}
