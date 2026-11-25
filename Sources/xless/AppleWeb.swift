import ArgumentParser
import Foundation
import XlessAgent
import XlessAppleID
import XlessCore
import XlessVault

// What the commands that use the Apple ID web session share (docs/apple-account.md#the-apple-id-web-session): the
// help text that says so, the terminal, the transport (traced with --verbose) and the opt-in kept session.

enum AppleWebHelp {
    /// Part of the `--help` of every command that uses the Apple ID web session.
    static let note = """
    Uses the Apple ID web session, not the App Store Connect API: Apple's own web interface, undocumented, for what the \
    API cannot do. It uses the session kept for this terminal (`xless auth login --keep`, or a yes to the offer after a \
    sign-in); without one it signs in with your Apple ID, password and two-factor code (or security key) on the terminal. \
    Nothing of the session is written to disk in clear.
    """

    /// The commands that say so.
    static var commands: [String] {
        func walk(_ command: any ParsableCommand.Type, _ path: [String]) -> [String] {
            let c = command.configuration
            let here = path + [c.commandName ?? ""]
            let below = c.subcommands.flatMap { walk($0, here) } // the groups' too
            return (c.discussion.contains(note) && below.isEmpty ? [here.joined(separator: " ")] : []) + below
        }
        return walk(Xless.self, []).map { String($0.dropFirst("xless ".count)) }
    }
}

enum AppleWebCLI {
    static let saved = VaultSavedSession()
    static let held = HeldSessionStore(witness: { SecretStoreCLI.witness() })
    static let cache = AppleSessionCache(store: held, saved: saved, maximum: { HeldSecrets.maximum })

    /// The terminal for the sign-in of an account command.
    static func prompter() throws -> TerminalPrompter {
        try TerminalPrompter(stage: .account, need: "signing in to Apple needs an interactive terminal",
                             fix: "run it in a terminal (the Apple ID, password and code are never read from a pipe, a file or the environment), or keep a session first with `xless auth login --keep` in this terminal")
    }

    /// A web client for one command; `invalidate` the transport at the end.
    static func client(verbose: Bool, stage: Stage = .account) -> (AppleWebClient, URLSessionAppleTransport) {
        let transport = URLSessionAppleTransport()
        let wire: AppleTransport = verbose ? TracingAppleTransport(transport, trace: .standardError) : transport
        return (AppleWebClient(transport: wire, userAgent: "xless/\(XlessVersion.current)", stage: stage), transport)
    }

    /// The kept session, else a sign-in on the terminal (forgotten when the command ends, unless the person keeps it).
    static func open(verbose: Bool) async throws -> (AppleWebSession, URLSessionAppleTransport) {
        SecretScope.enter()
        let (web, transport) = client(verbose: verbose)
        do {
            return (try await session(web) { try prompter() }.session, transport)
        } catch {
            transport.invalidate()
            throw error
        }
    }

    /// The session of `web`: the kept one, else a sign-in on `terminal`, announced.
    /// - Parameter offering: false when the command itself says how long it is kept.
    /// - Returns: also the terminal it signed in on; nil when it did not have to.
    static func session<T: SignInPrompter & PassphrasePrompter>(_ web: AppleWebClient, offering: Bool = true, cache: AppleSessionCache = cache, offer: KeepOffer = .shared,
                                                                terminal: () throws -> T) async throws -> (session: AppleWebSession, signedInOn: T?) {
        var signedInOn: T?
        let session = try await AppleWebSession.open(web: web, cache: cache, prompter: {
            let opened = try terminal()
            (opened as any PassphrasePrompter).say(offer.signInAnnouncement(offering: offering))
            signedInOn = opened
            return opened
        }, keep: {
            guard offering, let signedInOn else { return nil }
            return offer.session(signedInOn)
        })
        if signedInOn != nil { say("Signed in to Apple as \(session.appleID).") }
        return (session, signedInOn)
    }

    /// Selects the team: `team` (the option's, the project's or the saved one), else the Apple ID's only one, else that of
    /// the xless.yml here or of the store's API keys.
    /// - Parameter known: false for a command that must be told among several.
    static func selectTeam(_ team: String?, in session: AppleWebSession, known: Bool = true) async throws -> PortalTeam {
        guard team == nil, known else { return try await session.selectTeam(team) }
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("appstore")
        let project = StoreProject.nextTo(manifestDir: here)?.team, key = AccountSession.keyTeam(of: AccountSession.storeEntries())
        let selected = try await session.selectTeam(nil, preferring: [project, key].compactMap { $0 })
        if selected.teamId == project { say("Team \(selected.teamId), as in xless.yml here (--team chooses another).") }
        else if selected.teamId == key { say("Team \(selected.teamId), the App Store Connect API key's (--team chooses another).") }
        return selected
    }

    /// Makes the team's App Store Connect provider the current one.
    static func useProvider(for team: PortalTeam, in session: AppleWebSession) async throws {
        try await session.useProvider(for: team, issuers: AccountSession.keyIssuers(of: AccountSession.storeEntries(), team: team.teamId), choose: chooser())
    }

    /// Asks which provider, when several App Store Connect teams share the portal team's name; nil without a terminal.
    static func chooser() -> (([OlympusProvider]) async throws -> OlympusProvider)? {
        if InputGate.isOff {
            return { _ in throw InputGate.refusal("which App Store Connect team to use (several have that name)", fix: "run it without --no-input, in a terminal") }
        }
        guard let terminal = try? prompter() else { return nil }
        return { providers in
            terminal.say("App Store Connect has several teams with that name:")
            for (i, p) in providers.enumerated() { terminal.say("  \(i + 1): \(p.name) (provider \(p.providerId))") }
            for _ in 0..<5 {
                let answer = try terminal.ask("Which one? [1-\(providers.count)]: ")
                if let n = Int(answer.trimmingCharacters(in: .whitespaces)), providers.indices.contains(n - 1) { return providers[n - 1] }
                terminal.say("Type a number from 1 to \(providers.count).")
            }
            throw XlessError(.account, "no App Store Connect team chosen", fix: "re-run and type the number of a team")
        }
    }

    /// Warns (standard error) about agreements App Store Connect says are pending; xless never accepts them.
    static func warnAboutAgreements(_ session: AppleWebSession) async {
        guard let pending = await session.asc.pendingAgreements(), !pending.isEmpty else { return }
        say("warning: App Store Connect has agreements pending; the Account Holder accepts them at https://appstoreconnect.apple.com/agreements (xless never does):")
        for line in pending { say("  - \(line)") }
    }

    static func say(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
}
