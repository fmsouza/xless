import Foundation
import XlessCore

/// The developer portal and App Store Connect number teams differently (a 10-character team ID; a numeric provider ID),
/// and neither says which is which. They are matched by name; when several providers share the team's name, a person
/// chooses (never xless silently).
public enum AppleTeams {
    public enum Match: Sendable, Equatable {
        case one(OlympusProvider)
        case none
        case several([OlympusProvider])
    }

    /// Lower case, whitespace collapsed and trimmed.
    public static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func match(_ team: PortalTeam, in providers: [OlympusProvider]) -> Match {
        let name = normalized(team.name)
        var seen = Set<Int>()
        let found = providers.filter { normalized($0.name) == name && seen.insert($0.providerId).inserted }
        switch found.count {
        case 0: return .none
        case 1: return .one(found[0])
        default: return .several(found)
        }
    }

    /// The team `teamID` among `teams`; with no ID, the only team. An ID the Apple ID does not have, or several teams
    /// and no ID, is an `[account]` error.
    public static func select(_ teamID: String?, from teams: [PortalTeam]) throws -> PortalTeam {
        if let teamID {
            guard let team = teams.first(where: { $0.teamId == teamID }) else {
                throw XlessError(.account, "this Apple ID is not a member of team \(teamID) (its teams: \(list(teams)))",
                                 fix: "pass one of its team IDs (see `xless team list`), or save one with `xless team use <TEAM_ID>`")
            }
            return team
        }
        guard teams.count == 1 else {
            if teams.isEmpty {
                throw XlessError(.account, "this Apple ID belongs to no developer team",
                                 fix: "enroll in the Apple Developer Program or ask to be invited to a team, then re-run")
            }
            throw XlessError(.account, "this Apple ID belongs to \(teams.count) teams (\(list(teams))) and none was chosen",
                             fix: "pass --team <TEAM_ID>, or save the default with `xless team use <TEAM_ID>`")
        }
        return teams[0]
    }

    /// Makes `team`'s provider App Store Connect's current one (switching and confirming when needed); returns it.
    /// - Parameter choose: asks a person to pick among providers sharing the team's name; nil when there is no terminal.
    public static func useProvider(for team: PortalTeam, asc: ASCWebClient,
                                   choose: (([OlympusProvider]) async throws -> OlympusProvider)?) async throws -> OlympusProvider {
        let session = try await asc.session()
        let provider: OlympusProvider
        switch match(team, in: session.providers) {
        case .one(let p):
            provider = p
        case .none:
            throw XlessError(.account, "App Store Connect has no team named \"\(team.name)\" (\(team.teamId)) for this Apple ID",
                             fix: "the portal and App Store Connect are matched by team name: check that this Apple ID has App Store Connect access to the team (https://appstoreconnect.apple.com/access/users), then re-run")
        case .several(let ps):
            guard let choose else {
                throw XlessError(.account, "App Store Connect has \(ps.count) teams named \"\(team.name)\" (providers \(ps.map { String($0.providerId) }.joined(separator: ", ")))",
                                 fix: "re-run in a terminal to choose one")
            }
            provider = try await choose(ps)
        }
        if session.provider?.providerId != provider.providerId {
            try await asc.switchProvider(to: provider.providerId)
        }
        return provider
    }

    static func list(_ teams: [PortalTeam]) -> String {
        teams.map { "\($0.teamId) \($0.name)" }.joined(separator: ", ")
    }
}
