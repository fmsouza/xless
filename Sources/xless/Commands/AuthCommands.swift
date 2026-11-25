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
        `xless auth login --keep` kept one for the commands of this terminal (`xless auth logout` drops it).
        """,
        subcommands: [AuthLoginCommand.self, AuthLogoutCommand.self, AuthStatusCommand.self, AuthAPIKeyCommand.self])
}

struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in to your Apple ID on the terminal, list its teams, and optionally keep the session for a while.",
        discussion: AppleWebHelp.note + """


        With --keep, the session's cookies are sealed with a random key and kept, with that key, in memory only (the xless \
        agent; where none can run, the Linux kernel keyring, for an hour at most) for the time given or, without one, as long as config.yml's \
        `unlock` says (at most 7 days, never past the session's own expiry), so the commands of this terminal that need it \
        do not sign in again. The tools xless runs never reach it. Without --keep nothing is kept: this only checks the \
        sign-in.

        --across-reboots also saves the session in the encrypted secret store, sealed as its other entries are: after a \
        reboot it is there once the store is unlocked (its passphrase), until the time given. `xless auth logout` and \
        `xless lock` remove it.
        """)

    @Option(help: ArgumentHelp("Keep the session for later commands of this terminal, for this long (e.g. 30m, 8h) or, without a duration, as long as config.yml's `unlock` says. Off by default.", valueName: "duration"))
    var keep: String?
    @Flag(help: "With --keep: also save the session in the encrypted secret store, so it is there after a reboot too, once the store is unlocked. Off by default.")
    var acrossReboots = false
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if acrossReboots, keep == nil { throw ValidationError("--across-reboots needs --keep (for how long)") }
    }

    func run() async throws {
        try await AccountSession.run {
            SecretScope.enter()
            let hold = try keep.map { try HeldSecrets.settings.get().hold($0, option: "--keep", stage: .account) }
            if hold != nil, !AppleWebCLI.cache.isAvailable { throw AppleSessionCache.unavailable(AppleWebCLI.held.obstacle) }
            if acrossReboots {
                // The store's passphrase, before the sign-in.
                let store = try VaultSavedSession.configured()
                try store.unlock(try store.existingCatalog(), remember: nil, reason: "saving the Apple ID session")
            }
            let prompter = try AppleWebCLI.prompter()
            let (web, transport) = AppleWebCLI.client(verbose: trace.verbose)
            defer { transport.invalidate() }
            let session = try await AppleWebSession.signIn(web: web, prompter: prompter)
            print("signed in as \(session.appleID)")
            let teams = try await session.portal.teams()
            print(TeamListing.table(teams, providers: nil, saved: AccountSession.savedTeam()), terminator: "")
            await AppleWebCLI.warnAboutAgreements(session)
            if let hold {
                let info = try await AppleWebCLI.cache.keep(web, appleID: session.appleID, hold: hold, acrossReboots: acrossReboots)
                let place = AppleWebCLI.held.held()?.backend == .keyring ? "the kernel keyring" : "the xless agent"
                print("kept the session in \(place) for \(AuthStatusReport.duration(info.expires.timeIntervalSince(info.created))) (until \(AuthStatusReport.time(info.expires))); `xless auth logout` drops it")
                if acrossReboots { print("and saved it in the secret store until then: after a reboot, `xless unlock` is enough") }
            } else {
                print("nothing was kept: each command that needs the Apple ID session signs in (or use --keep)")
            }
            await session.end()
        }
    }
}

struct AuthLogoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Forget the Apple ID session kept by `xless auth login --keep`.")

    func run() throws {
        let any = AppleWebCLI.cache.forget()
        if any { print("forgot the kept Apple ID session") }
        if let unreached = AppleWebCLI.held.agents.unreached { throw XlessError(.account, unreached.cause, fix: unreached.fix) }
        if !any { print("no Apple ID session was kept") }
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
            guard let file = try SecretStoreCLI.store().catalog(),
                  let entry = try VaultResolver.candidate(for: "ASC_KEY_P8", in: file, team: selected) else { return nil }
            return .init(name: entry.name, teamID: entry.metadata.teamID ?? AuthStatusReport.team(fromName: entry.name),
                         hasKeyID: entry.metadata.keyID != nil, hasIssuerID: entry.metadata.issuerID != nil, role: entry.metadata.role)
        }
        let held = AppleWebCLI.held
        let session = AppleWebCLI.cache.info()
        let report = AuthStatusReport.build(env: ProcessInfo.processInfo.environment, storeKey: storeKey, teamFlag: team.team, savedTeam: saved,
                                            canKeep: held.isAvailable, session: session, sessionHeld: session == nil ? nil : held.held(), savedUntil: AppleWebCLI.cache.savedUntil,
                                            store: AuthStatusReport.Store.current(), neededBy: AppleWebHelp.commands, now: Date())
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
        /// kept, saved (in the secret store, which is locked), none or unavailable (nothing to keep one in here).
        let state: String
        let appleID: String?
        let expires: String?
        let remainingSeconds: Int?
        /// agent, keyring or store (saved, and the store is unlocked), when kept.
        var backend: String? = nil
        /// When kept in the agent: it is dropped after this long without use, the soonest in `idleRemainingSeconds`.
        var idleSeconds: Int? = nil
        var idleRemainingSeconds: Int? = nil
        /// The commands that need it; the others need the API key at most.
        var neededBy: [String] = []
        /// When it is (also) saved in the secret store (`--across-reboots`): until when.
        var savedUntil: String? = nil
    }

    /// The secret store's lock.
    struct Store: Encodable, Equatable {
        /// unlocked, locked, unavailable (locked, and nothing to keep it unlocked in here), helper (the credential
        /// helper's own lock), missing (no store) or error.
        let state: String
        var detail: String? = nil
        /// agent or keyring, when unlocked.
        var backend: String? = nil
        var expires: String? = nil
        var remainingSeconds: Int? = nil
        var idleSeconds: Int? = nil
        var idleRemainingSeconds: Int? = nil

        static func unlocked(_ held: HeldUnlock, now: Date) -> Store {
            Store(state: "unlocked", backend: held.backend.rawValue, expires: held.expires.map(AuthStatusReport.iso),
                  remainingSeconds: held.expires.map { max(0, Int($0.timeIntervalSince(now).rounded())) }, idleSeconds: held.idle,
                  idleRemainingSeconds: held.idleExpires.map { max(0, Int($0.timeIntervalSince(now).rounded())) })
        }

        /// The configured store's, without opening it.
        static func current() -> Store {
            do {
                switch try SecretStoreCLI.backend() {
                case .helper(let helper): return Store(state: "helper", detail: helper.helper.command)
                case .vault(let vault):
                    guard let file = try vault.vault.read() else { return Store(state: "missing") }
                    if let held = SecretStoreCLI.cache.held(id: file.id) { return .unlocked(held, now: Date()) }
                    return Store(state: SecretStoreCLI.cache.isAvailable ? "locked" : "unavailable")
                }
            } catch {
                return Store(state: "error", detail: XlessError.wrapping(error, stage: .config).cause)
            }
        }
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
    let store: Store

    static let names = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"]

    static func build(env: [String: String], storeKey: Result<StoreKey?, any Error>, teamFlag: String?, savedTeam: String?,
                      canKeep: Bool, session info: KeptSessionInfo?, sessionHeld: HeldUnlock? = nil, savedUntil: Date? = nil, store: Store = Store(state: "missing"),
                      neededBy: [String] = [], now: Date) -> AuthStatusReport {
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
        var session: Session
        if let info, info.expires > now {
            session = Session(state: "kept", appleID: info.appleID, expires: iso(info.expires),
                              remainingSeconds: Int(info.expires.timeIntervalSince(now)), backend: sessionHeld?.backend.rawValue ?? (savedUntil == nil ? nil : "store"),
                              idleSeconds: sessionHeld?.idle,
                              idleRemainingSeconds: sessionHeld?.idleExpires.map { max(0, Int($0.timeIntervalSince(now).rounded())) }, neededBy: neededBy)
        } else {
            session = Session(state: savedUntil != nil ? "saved" : canKeep ? "none" : "unavailable", appleID: nil, expires: nil, remainingSeconds: nil, neededBy: neededBy)
        }
        session.savedUntil = savedUntil.map(iso)
        let team = teamFlag ?? savedTeam
        return AuthStatusReport(team: team, teamSource: teamFlag != nil ? "flag" : (savedTeam != nil ? "saved" : "none"),
                                apiKey: credentials, keyTeam: keyTeam, keyRole: keyRole, session: session, store: store)
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
        lines.append("Secret store:")
        switch store.state {
        case "unlocked":
            let until = store.expires.map { " until \($0) (\(Self.duration(TimeInterval(store.remainingSeconds ?? 0))) left\(Self.idle(store.idleSeconds)))" } ?? ""
            lines.append("  unlocked in \(Self.place(store.backend))\(until); `xless lock` ends it")
        case "locked": lines.append("  locked: a command that reads it asks the passphrase (`xless unlock` keeps it unlocked for this terminal)")
        case "unavailable": lines.append("  locked: each command that reads it asks the passphrase (it cannot be kept unlocked here)")
        case "helper": lines.append("  kept by the credential helper \(store.detail ?? "?"), which locks itself")
        case "missing": lines.append("  none (`xless secrets init` creates one)")
        default: lines.append("  error (\(store.detail ?? "?"))")
        }
        lines.append("Apple ID web session:")
        switch session.state {
        case "kept":
            let left = session.remainingSeconds.map { Self.duration(TimeInterval($0)) } ?? "?"
            lines.append("  kept for \(session.appleID ?? "?")\(session.backend.map { " in \(Self.place($0))" } ?? "") until \(session.expires ?? "?") (\(left) left\(Self.idle(session.idleSeconds))); `xless auth logout` drops it")
        case "saved":
            lines.append("  saved in the secret store until \(session.savedUntil ?? "?"), which is locked: a command that needs it asks the passphrase (`xless unlock` opens it for this terminal)")
        case "unavailable":
            lines.append("  none kept (it cannot be kept here): each command that needs it signs in")
        default:
            lines.append("  none kept: each command that needs it signs in (`xless auth login --keep` keeps one for this terminal)")
        }
        if !session.neededBy.isEmpty { lines.append("  needed by: \(session.neededBy.joined(separator: ", ")); the other commands use the API key") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func place(_ backend: String?) -> String { ["keyring": "the kernel keyring", "store": "the secret store"][backend ?? ""] ?? "the xless agent" }

    private static func idle(_ seconds: Int?) -> String { seconds.map { ", or \(duration(TimeInterval($0))) without use" } ?? "" }

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
    static func duration(_ seconds: TimeInterval) -> String { HoldDuration.text(Int(seconds)) }
}
