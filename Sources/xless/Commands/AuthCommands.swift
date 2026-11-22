import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessVault

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Sign in to your Apple ID for what the App Store Connect API cannot do, and see which credentials xless uses.",
        discussion: """
        Most account commands use the App Store Connect API key (see `xless auth status`). A few things have no documented \
        API (creating the app record, API keys, auth keys, App Privacy, app groups, iCloud containers): those commands use \
        the Apple ID web session, and say so in their --help. Each of them signs in and forgets the session at exit, unless \
        `xless auth login --keep 30m` kept one in the kernel keyring (Linux; at most an hour; `xless auth logout` drops it).
        """,
        subcommands: [AuthLoginCommand.self, AuthLogoutCommand.self, AuthStatusCommand.self, AuthAPIKeyCommand.self])
}

struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in to your Apple ID on the terminal, list its teams, and optionally keep the session for a while.",
        discussion: AppleWebHelp.note + """


        With --keep, the session's cookies are sealed with a random key and kept, with that key, in the kernel keyring \
        (Linux) for the time given (at most 1h, never past the session's own expiry), so the commands of this login \
        session that need it do not sign in again. Reading it needs the same login session, as with ssh-agent. Without \
        --keep nothing is kept: this only checks the sign-in.
        """)

    @Option(help: ArgumentHelp("Keep the session this long in the kernel keyring, e.g. 30m; at most 1h. Off by default.", valueName: "duration"))
    var keep: String?
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            SecretScope.enter()
            let seconds = try keep.map(KeepDuration.seconds)
            if seconds != nil, !AppleWebCLI.cache.isAvailable { throw AppleSessionCache.unavailable() }
            let prompter = try AppleWebCLI.prompter()
            let (web, transport) = AppleWebCLI.client(verbose: trace.verbose)
            defer { transport.invalidate() }
            let session = try await AppleWebSession.signIn(web: web, prompter: prompter)
            print("signed in as \(session.appleID)")
            let teams = try await session.portal.teams()
            print(TeamListing.table(teams, providers: nil, saved: AccountSession.savedTeam()), terminator: "")
            await AppleWebCLI.warnAboutAgreements(session)
            if let seconds {
                let info = try await AppleWebCLI.cache.keep(web, appleID: session.appleID, seconds: seconds)
                print("kept the session in the kernel keyring for \(AuthStatusReport.duration(info.expires.timeIntervalSince(info.created))) (until \(AuthStatusReport.time(info.expires))); `xless auth logout` drops it")
            } else {
                print("nothing was kept: each command that needs the Apple ID session signs in (or use --keep 30m)")
            }
            await session.end()
        }
    }
}

struct AuthLogoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Forget the Apple ID session kept by `xless auth login --keep`.")

    func run() throws {
        print(AppleWebCLI.cache.forget() ? "forgot the kept Apple ID session" : "no Apple ID session was kept")
    }
}

struct AuthStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Which credentials resolve and from where (environment, file, secret store), for which team; never a value.",
        discussion: "Reads no secret: the secret store stays locked (its names and IDs are readable without the passphrase), and nothing is sent to Apple.")

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption

    func run() throws {
        let saved = AccountSession.savedTeam()
        let selected = AccountSession.resolveTeam(flag: team.team, saved: saved)
        let storeKey = Result { () -> AuthStatusReport.StoreKey? in
            guard let file = try VaultStore(location: .standard()).read(),
                  let entry = try VaultResolver.candidate(for: "ASC_KEY_P8", in: file, team: selected) else { return nil }
            return .init(name: entry.name, teamID: entry.metadata.teamID ?? AuthStatusReport.team(fromName: entry.name),
                         hasKeyID: entry.metadata.keyID != nil, hasIssuerID: entry.metadata.issuerID != nil, role: entry.metadata.role)
        }
        let cache = AppleWebCLI.cache
        let report = AuthStatusReport.build(env: ProcessInfo.processInfo.environment, storeKey: storeKey, teamFlag: team.team,
                                            savedTeam: saved, keyringAvailable: cache.isAvailable, session: cache.info(), now: Date())
        print(output.json ? try ASCOutput.json(report) : report.text, terminator: "")
    }
}

/// `xless auth status`: where each API-key credential comes from and the Apple ID session's state. Names, sources,
/// paths and IDs only; never a value.
struct AuthStatusReport: Encodable, Equatable {
    struct Credential: Encodable, Equatable {
        let name: String
        /// environment, file, store, missing, or error (the store could not say: unreadable, or several entries).
        let source: String
        let detail: String?
    }

    struct Session: Encodable, Equatable {
        /// kept, none or unavailable (no kernel keyring here).
        let state: String
        let appleID: String?
        let expires: String?
        let remainingSeconds: Int?
    }

    /// The store's `ASC_KEY_P8` entry for the team, as `secrets list` shows it.
    struct StoreKey: Equatable {
        let name: String
        let teamID: String?
        let hasKeyID: Bool
        let hasIssuerID: Bool
        /// The role xless recorded when it created or imported the key.
        var role: String? = nil
    }

    let team: String?
    /// flag (--team), saved (`xless team use`) or none.
    let teamSource: String
    let apiKey: [Credential]
    let keyTeam: String?
    /// The key's App Store Connect role, when xless knows it; App Store Connect does not tell a key its own role.
    let keyRole: String?
    let session: Session

    static let names = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"]

    static func build(env: [String: String], storeKey: Result<StoreKey?, any Error>, teamFlag: String?, savedTeam: String?,
                      keyringAvailable: Bool, session info: KeptSessionInfo?, now: Date) -> AuthStatusReport {
        var keyTeam: String?
        var keyRole: String?
        let credentials = names.map { name -> Credential in
            if let v = env[name], !v.isEmpty { return Credential(name: name, source: "environment", detail: "$\(name)") }
            if let path = env["\(name)_FILE"], !path.isEmpty { return Credential(name: name, source: "file", detail: "$\(name)_FILE: \(path)") }
            switch storeKey {
            case .failure(let error):
                return Credential(name: name, source: "error", detail: XlessError.wrapping(error, stage: .config).cause)
            case .success(nil):
                return Credential(name: name, source: "missing", detail: nil)
            case .success(let key?):
                let present = name == "ASC_KEY_P8" || (name == "ASC_KEY_ID" ? key.hasKeyID : key.hasIssuerID)
                guard present else { return Credential(name: name, source: "missing", detail: "the store's \(key.name) has no \(name == "ASC_KEY_ID" ? "key" : "issuer") ID") }
                keyTeam = key.teamID
                if name == "ASC_KEY_P8" { keyRole = key.role }
                return Credential(name: name, source: "store", detail: name == "ASC_KEY_P8" ? key.name : "\(key.name)'s \(name == "ASC_KEY_ID" ? "key" : "issuer") ID")
            }
        }
        let session: Session
        if let info, info.expires > now {
            session = Session(state: "kept", appleID: info.appleID, expires: iso(info.expires),
                              remainingSeconds: Int(info.expires.timeIntervalSince(now)))
        } else {
            session = Session(state: keyringAvailable ? "none" : "unavailable", appleID: nil, expires: nil, remainingSeconds: nil)
        }
        let team = teamFlag ?? savedTeam
        return AuthStatusReport(team: team, teamSource: teamFlag != nil ? "flag" : (savedTeam != nil ? "saved" : "none"),
                                apiKey: credentials, keyTeam: keyTeam, keyRole: keyRole, session: session)
    }

    var text: String {
        var lines: [String] = []
        let teamText = switch teamSource {
        case "flag": "team \(team ?? "") (--team)"
        case "saved": "team \(team ?? "") (saved by `xless team use`)"
        default: "no team selected"
        }
        lines.append("App Store Connect API key, \(teamText):")
        let width = Self.names.map(\.count).max() ?? 0
        for c in apiKey {
            let name = c.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(c.source)\(c.detail.map { " (\($0))" } ?? "")")
        }
        if let keyTeam { lines.append("  key's team     \(keyTeam)") }
        lines.append("  key's role     \(keyRole.map { $0.replacingOccurrences(of: ",", with: ", ") } ?? "unknown to xless (see App Store Connect > Users and Access > Integrations)")")
        lines.append("Apple ID web session:")
        switch session.state {
        case "kept":
            let left = session.remainingSeconds.map { Self.duration(TimeInterval($0)) } ?? "?"
            lines.append("  kept for \(session.appleID ?? "?") until \(session.expires ?? "?") (\(left) left); `xless auth logout` drops it")
        case "unavailable":
            lines.append("  none kept (no kernel keyring here): each command that needs it signs in")
        default:
            lines.append("  none kept: each command that needs it signs in (`xless auth login --keep 30m` keeps one)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `ASC_KEY_P8@ABCDE12345` → ABCDE12345.
    static func team(fromName name: String) -> String? {
        guard let at = name.firstIndex(of: "@") else { return nil }
        let suffix = String(name[name.index(after: at)...])
        return AccountSession.isTeamID(suffix) ? suffix : nil
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String { iso(date) }

    /// "45 s", "23 min", "1 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return s % 3600 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
