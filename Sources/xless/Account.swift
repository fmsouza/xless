import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessVault

// What the "Apple account" commands share: the options every one of them takes, the App Store Connect session, the
// confirmation before a destructive call, and the `[account]` error contract (exit code 20). docs/apple-account.md.

struct TeamOption: ParsableArguments {
    @Option(help: "The Apple team (10-character team ID) whose API key is used: picks the store's ASC_KEY_P8 entry of that team. Default: the team saved by `xless team use`, else the only (or unteamed) key.")
    var team: String?

    func validate() throws {
        if let team, !AccountSession.isTeamID(team) {
            throw ValidationError("--team \(team) is not a team ID: 10 upper-case letters and digits, e.g. ABCDE12345")
        }
    }
}

struct JSONOption: ParsableArguments {
    @Flag(help: "Print JSON instead of a table (a stable format: see docs/apple-account.md).")
    var json = false
}

struct YesOption: ParsableArguments {
    @Flag(help: "Do not ask for confirmation (required without a terminal).")
    var yes = false
}

struct VerboseOption: ParsableArguments {
    @Flag(help: "Show every HTTP exchange with Apple on standard error, credentials and tokens redacted.")
    var verbose = false
}

/// The four shared options, for the resource commands (`xless devices list --team … --json`).
struct AccountOptions: ParsableArguments {
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption
}

/// One account command's connection to App Store Connect: the team in effect, the secrets it reads (the store filtered
/// by that team) and a client with the API key (traced with `--verbose`).
struct AccountSession {
    let team: String?
    let secrets: Secrets
    let client: ASCClient

    var resources: ASCResources { ASCResources(client: client) }

    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// `--team`, else the saved default team (`xless team use`, #84), else none: the API key that resolves without a team.
    static func resolveTeam(flag: String?, saved: String?) -> String? { flag ?? saved }

    /// The team saved by `xless team use` (config.yml), when it is a team ID.
    static func savedTeam(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let team = (try? UserConfig.load(env: env))?.team, isTeamID(team) else { return nil }
        return team
    }

    /// - Parameter fallback: the secret store's resolver for `team` (default: the store, filtered by the team when there is one).
    static func open(team flag: String?, verbose: Bool, env: [String: String] = ProcessInfo.processInfo.environment,
                     transport: HTTPTransport = URLSessionTransport(),
                     fallback: (String?) -> (any SecretFallback)? = AccountSession.storeFallback) throws -> AccountSession {
        SecretScope.enter()
        let team = resolveTeam(flag: flag, saved: savedTeam())
        let secrets = Secrets(env: env, fallback: fallback(team))
        let credentials = try ASCCredentials.fromSecrets(secrets, stage: .account)
        let wire: HTTPTransport = verbose ? TracingTransport(transport, trace: .standardError) : transport
        return AccountSession(team: team, secrets: secrets, client: ASCClient(credentials: credentials, transport: wire))
    }

    /// For a command run for a project (an appstore/ manifest, a release): `--team`, else the project configuration's
    /// team, whose API key is preferred and one recorded for no team accepted (as `provision` resolves it), else the
    /// saved team.
    /// - Parameter store: the secret store (default: the process's).
    static func open(team flag: String?, project: String?, verbose: Bool, env: [String: String] = ProcessInfo.processInfo.environment,
                     transport: HTTPTransport = URLSessionTransport(), store: () -> (any SecretStore)? = { try? SecretStoreCLI.store() }) throws -> AccountSession {
        guard flag == nil, let project else { return try open(team: flag, verbose: verbose, env: env, transport: transport) }
        return try open(team: project, verbose: verbose, env: env, transport: transport, fallback: { _ in
            guard let store = store() else { return Secrets.installedFallback }
            return VaultResolver(secrets: store).preferring(team: project)
        })
    }

    /// The store's resolver for a team; with no team, the one `main` installed.
    static func storeFallback(_ team: String?) -> (any SecretFallback)? {
        guard let team, let store = try? SecretStoreCLI.store() else { return Secrets.installedFallback }
        return VaultResolver(secrets: store, team: team)
    }

    /// Runs an account command's body; any failure leaves as `[account] cause — fix` (exit 20).
    static func run<T>(_ body: () async throws -> T) async throws -> T {
        try await withStage(.account, body)
    }
}

/// Something that can ask a yes/no question (the terminal; a fake in tests).
protocol Confirming {
    func confirm(_ question: String) throws -> Bool
}

extension TerminalPrompter: Confirming {}

enum AccountConfirm {
    /// Asks `question` before a destructive call. `--yes` skips it; without a terminal the call is refused (it never
    /// proceeds silently). Returns false when the answer is no.
    /// - Parameter action: what is refused without a terminal, e.g. "removing XLESS_DIST_KEY".
    static func confirm(_ question: String, action: String, yes: Bool, stage: Stage = .account,
                        terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }) throws -> Bool {
        if yes { return true }
        try InputGate.require("a confirmation (\(action))", fix: "re-run with --yes")
        guard let terminal = terminal() else {
            throw XlessError(stage, "\(action) needs a confirmation and there is no terminal", fix: "re-run with --yes")
        }
        return try terminal.confirm(question)
    }
}

extension TerminalPrompter {
    /// The terminal for an account command's confirmation.
    static func forAccount() throws -> TerminalPrompter {
        try TerminalPrompter(stage: .account, what: "a confirmation", need: "the confirmation is read from a terminal, and there is none", fix: "re-run with --yes")
    }
}
