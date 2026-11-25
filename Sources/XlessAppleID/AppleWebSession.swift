import Foundation
import XlessCore

/// The Apple ID web session one command uses: the sign-in's cookie jar (in `web`) and the two clients on it. It comes
/// from a session kept by `xless auth login --keep`, else from a sign-in on the terminal that is forgotten at exit.
/// Used only for what the App Store Connect API cannot do.
public final class AppleWebSession: Sendable {
    public let web: AppleWebClient
    public let asc: ASCWebClient
    public let portal: PortalWebClient
    /// The Apple ID (email) signed in, for display.
    public let appleID: String
    /// The kept session this one came from; nil when it signed in for this command.
    public let kept: KeptSessionInfo?

    public init(web: AppleWebClient, appleID: String, kept: KeptSessionInfo?) {
        self.web = web
        self.asc = ASCWebClient(web: web)
        self.portal = PortalWebClient(web: web)
        self.appleID = appleID
        self.kept = kept
    }

    /// The kept session when there is one (`cache`), else a sign-in through `prompter` (asked for only then).
    /// - Parameter keep: asked after a sign-in: how long to keep the session (nil: for this command).
    public static func open(web: AppleWebClient, cache: AppleSessionCache?, prompter: () throws -> any SignInPrompter,
                            keep: () -> SecretHold? = { nil }) async throws -> AppleWebSession {
        let terminal: any SignInPrompter
        let session: AppleWebSession
        if let cache, let kept = try await cache.restore(into: web) {
            let restored = AppleWebSession(web: web, appleID: kept.appleID, kept: kept)
            guard await restored.isRefused() else { return restored }
            terminal = try prompter()
            session = try await signInAgain(web: web, kept: kept, cache: cache, prompter: terminal)
        } else {
            terminal = try prompter()
            session = try await signIn(web: web, prompter: terminal)
        }
        guard session.kept == nil, let cache, let hold = keep() else { return session }
        do {
            return AppleWebSession(web: web, appleID: session.appleID, kept: try await cache.keep(web, appleID: session.appleID, hold: hold))
        } catch {
            terminal.say("note: \(error)")
            return session
        }
    }

    /// Whether Apple no longer takes the session: App Store Connect says so, and the developer portal too (an Apple ID
    /// without App Store Connect is refused there only). A failure to reach Apple says nothing.
    private func isRefused() async -> Bool {
        guard let answer = try? await asc.send("GET", ASCWebClient.sessionPath), [401, 403].contains(answer.status) else { return false }
        return (try? await portal.teams()) == nil
    }

    /// Signs in to the kept session's Apple ID again, as the device Apple trusted at the last sign-in, and keeps the new
    /// session for what was left of the old one's time.
    private static func signInAgain(web: AppleWebClient, kept: KeptSessionInfo, cache: AppleSessionCache,
                                    prompter: any SignInPrompter) async throws -> AppleWebSession {
        prompter.say("Apple no longer accepts the kept session: signing in again as \(kept.appleID) (it is kept as before).")
        let hold = cache.remainingHold(), saved = cache.isSaved
        await web.keepTrustedDevice()
        let appleID = try await AppleSignIn(client: web, prompter: prompter, stage: web.stage).run(as: kept.appleID)
        var info: KeptSessionInfo?
        if let hold { info = try? await cache.keep(web, appleID: appleID, hold: hold, acrossReboots: saved) } // too little left: not kept
        return AppleWebSession(web: web, appleID: appleID, kept: info)
    }

    /// Always signs in (SRP and the second factor, on `prompter`); errors report `web.stage`.
    public static func signIn(web: AppleWebClient, prompter: any SignInPrompter) async throws -> AppleWebSession {
        let appleID = try await AppleSignIn(client: web, prompter: prompter, stage: web.stage).run()
        return AppleWebSession(web: web, appleID: appleID, kept: nil)
    }

    /// Selects `teamID` (or the only team) on the developer portal; returns it.
    @discardableResult
    public func selectTeam(_ teamID: String?, preferring known: [String] = []) async throws -> PortalTeam {
        let team = try AppleTeams.select(teamID, preferring: known, from: try await portal.teams())
        await portal.use(team: team.teamId)
        return team
    }

    /// Makes `team` App Store Connect's current provider (see `AppleTeams.useProvider`).
    @discardableResult
    public func useProvider(for team: PortalTeam, issuers: [String] = [],
                            choose: (([OlympusProvider]) async throws -> OlympusProvider)?) async throws -> OlympusProvider {
        try await AppleTeams.useProvider(for: team, asc: asc, issuers: issuers, choose: choose)
    }

    /// Forgets this process's copy of the session (a kept one stays kept until `xless auth logout` or its expiry).
    public func end() async { await web.signOut() }
}
