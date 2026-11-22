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
    public static func open(web: AppleWebClient, cache: AppleSessionCache?,
                            prompter: () throws -> any SignInPrompter) async throws -> AppleWebSession {
        if let cache, let kept = await cache.restore(into: web) {
            return AppleWebSession(web: web, appleID: kept.appleID, kept: kept)
        }
        return try await signIn(web: web, prompter: try prompter())
    }

    /// Always signs in (SRP and the second factor, on `prompter`); errors report `web.stage`.
    public static func signIn(web: AppleWebClient, prompter: any SignInPrompter) async throws -> AppleWebSession {
        let appleID = try await AppleSignIn(client: web, prompter: prompter, stage: web.stage).run()
        return AppleWebSession(web: web, appleID: appleID, kept: nil)
    }

    /// Selects `teamID` (or the only team) on the developer portal; returns it.
    @discardableResult
    public func selectTeam(_ teamID: String?) async throws -> PortalTeam {
        let team = try AppleTeams.select(teamID, from: try await portal.teams())
        await portal.use(team: team.teamId)
        return team
    }

    /// Makes `team` App Store Connect's current provider (see `AppleTeams.useProvider`).
    @discardableResult
    public func useProvider(for team: PortalTeam,
                            choose: (([OlympusProvider]) async throws -> OlympusProvider)?) async throws -> OlympusProvider {
        try await AppleTeams.useProvider(for: team, asc: asc, choose: choose)
    }

    /// Forgets this process's copy of the session (a kept one stays kept until `xless auth logout` or its expiry).
    public func end() async { await web.signOut() }
}
