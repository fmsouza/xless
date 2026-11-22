import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore

struct TeamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "team",
        abstract: "List your Apple developer teams, and choose the default one for the account commands.",
        subcommands: [TeamListCommand.self, TeamUseCommand.self])
}

struct TeamListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the teams of your Apple ID: team ID, name, type, and the App Store Connect provider of the same name.",
        discussion: AppleWebHelp.note + """


        The developer portal names a team by its team ID and App Store Connect by a provider number; xless matches them by \
        name (PROVIDER is "?" when several App Store Connect teams share the name, empty when none has it). The default \
        team (`xless team use`) is marked with *.
        """)

    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            let (session, transport) = try await AppleWebCLI.open(verbose: trace.verbose)
            defer { transport.invalidate() }
            let teams = try await session.portal.teams()
            let providers = try? await session.asc.session().providers
            let saved = AccountSession.savedTeam()
            if output.json {
                print(try ASCOutput.json(TeamListing.rows(teams, providers: providers, saved: saved)), terminator: "")
            } else {
                print(TeamListing.table(teams, providers: providers, saved: saved), terminator: "")
            }
            await AppleWebCLI.warnAboutAgreements(session)
            await session.end()
        }
    }
}

struct TeamUseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Save the default team for the account commands (--team overrides it).",
        discussion: "Saved as `team:` in $XDG_CONFIG_HOME/xless/config.yml (else ~/.config/xless/config.yml), a plain preference, not a secret. It is checked against your teams when a command uses it.")

    @Argument(help: ArgumentHelp("The 10-character team ID (see `xless team list`).", valueName: "TEAM_ID"))
    var teamID: String?
    @Flag(help: "Forget the default team instead.") var clear = false

    func validate() throws {
        switch (teamID, clear) {
        case (nil, false): throw ValidationError("name a team ID (e.g. xless team use ABCDE12345), or pass --clear")
        case (_?, true): throw ValidationError("give either a team ID or --clear, not both")
        case (let id?, false) where !AccountSession.isTeamID(id):
            throw ValidationError("\(id) is not a team ID: 10 upper-case letters and digits, e.g. ABCDE12345")
        default: break
        }
    }

    func run() throws {
        do {
            try UserConfig.update { $0.team = clear ? nil : teamID }
        } catch {
            throw XlessError.wrapping(error, stage: .account)
        }
        let file = UserConfig.file().path
        print(clear ? "cleared the default team (\(file))" : "the default team is now \(teamID ?? "") (saved in \(file))")
    }
}

/// `xless team list`'s rows (also `xless auth login`'s list).
enum TeamListing {
    struct Row: Encodable, Equatable {
        let teamId: String
        let name: String
        let type: String?
        /// The App Store Connect provider of the same name; nil when none or several (`providerMatch` says which).
        let providerId: Int?
        /// one, none, several, or unknown (App Store Connect was not asked or did not answer).
        let providerMatch: String
        let isDefault: Bool
    }

    static func rows(_ teams: [PortalTeam], providers: [OlympusProvider]?, saved: String?) -> [Row] {
        teams.map { team in
            var id: Int?
            var match = "unknown"
            if let providers {
                switch AppleTeams.match(team, in: providers) {
                case .one(let p): id = p.providerId; match = "one"
                case .none: match = "none"
                case .several: match = "several"
                }
            }
            return Row(teamId: team.teamId, name: team.name, type: team.type, providerId: id, providerMatch: match, isDefault: team.teamId == saved)
        }
    }

    static func table(_ teams: [PortalTeam], providers: [OlympusProvider]?, saved: String?) -> String {
        let rows = rows(teams, providers: providers, saved: saved)
        var headers = ["", "TEAM ID", "NAME", "TYPE"]
        if providers != nil { headers.append("PROVIDER") }
        return TextTable(headers, rows.map { r in
            var cells = [r.isDefault ? "*" : "", r.teamId, r.name, r.type ?? ""]
            if providers != nil { cells.append(r.providerId.map(String.init) ?? (r.providerMatch == "several" ? "?" : "")) }
            return cells
        }).rendered
    }
}
