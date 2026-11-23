import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless users`: the team's App Store Connect users and their invitations (docs/apple-account.md#xless-users).

struct UsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List, invite, update and remove the team's App Store Connect users (internal TestFlight testers are users).",
        discussion: """
        Uses the App Store Connect API key (/v1/users, /v1/userInvitations), which needs the Admin role: create one with \
        `xless auth api-key create --role ADMIN`. A person is named by email address or by ID. Inviting an address that \
        is already a user or already invited reports it and sends nothing.

          xless users list --role admin
          xless users invite grace@example.com --first-name Grace --last-name Hopper --role developer --app com.example.app
          xless users update grace@example.com --role developer,marketing --all-apps
          xless users remove grace@example.com
          xless users invitations list
        """,
        subcommands: [UsersListCommand.self, UsersShowCommand.self, UsersInviteCommand.self, UsersUpdateCommand.self,
                      UsersRemoveCommand.self, UsersInvitationsCommand.self])
}

struct UsersInvitationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invitations",
        abstract: "List or cancel the invitations that have not been accepted yet.",
        subcommands: [UsersInvitationsListCommand.self, UsersInvitationsCancelCommand.self])
}

/// `--role`, repeatable and comma-separated.
struct UserRoleOption: ParsableArguments {
    @Option(name: .customLong("role"), help: ArgumentHelp("A role: \(UserRole.assignable.map(\.rawValue).joined(separator: ", ")) (any case, - or _); repeatable or comma-separated.", valueName: "role"))
    var roles: [String] = []

    /// The roles; `filter` also accepts ACCOUNT_HOLDER (to list them).
    func parsed(filter: Bool = false) throws -> [UserRole] {
        do { return try UserRole.parse(roles, allowAccountHolder: filter) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }
}

/// `--all-apps` / `--app`: which apps a person sees.
struct UserAppsOption: ParsableArguments {
    @Flag(name: .customLong("all-apps"), help: "The person sees every app of the team, present and future.")
    var allApps = false
    @Option(name: .customLong("app"), help: ArgumentHelp("An app the person sees (app ID or bundle identifier); repeatable. Only these apps.", valueName: "app"))
    var apps: [String] = []

    func validate(roles: [UserRole]) throws {
        if allApps, !apps.isEmpty { throw ValidationError("--all-apps and --app exclude each other") }
        if roles.contains(.admin), !apps.isEmpty { throw ValidationError("an ADMIN sees every app: drop --app, or choose another role") }
        for app in apps {
            do { try AppArgument.validate(app) } catch let e as IdentifierInputError { throw ValidationError("--app \(app): \(e.description)") }
        }
    }
}

/// A person argument: an email address or an ID.
enum PersonArgument {
    static func help(_ what: String, list: String) -> ArgumentHelp {
        ArgumentHelp("The \(what)'s email address, or its ID (see `\(list)`).", valueName: "email-or-id")
    }

    /// The argument as it is looked up: trimmed.
    static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    static func validate(_ raw: String) throws {
        let text = normalized(raw)
        if UserEmail.isEmail(text) {
            do { _ = try UserEmail.validate(text) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        } else if !ASCUsers.isID(text) {
            throw ValidationError("\(text) is neither an email address nor an ID (letters, digits and dashes)")
        }
    }
}

/// Opens the account session and runs `body` with the user operations; prints what it returns.
private func runUsers(_ team: String?, verbose: Bool, json: Bool, _ body: (UserCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(UserCLI(resources: session.resources, json: json))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct UsersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's users: ID, email, name, roles, the apps they see and whether they manage certificates and profiles.")

    @OptionGroup var role: UserRoleOption
    @OptionGroup var account: AccountOptions

    func validate() throws { _ = try role.parsed(filter: true) }

    func run() async throws {
        let roles = try role.parsed(filter: true)
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) { try await $0.list(roles: roles) }
    }
}

struct UsersShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one user, with every app they see.")

    @Argument(help: PersonArgument.help("user", list: "xless users list")) var user: String
    @OptionGroup var account: AccountOptions

    func validate() throws { try PersonArgument.validate(user) }

    func run() async throws {
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) { try await $0.show(PersonArgument.normalized(user)) }
    }
}

struct UsersInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Invite someone to the team by email; an address that is already a user or invited is reported, never invited twice.",
        discussion: """
        Apple emails the invitation; the person becomes a user once they accept it (`xless users invitations list` shows \
        it until then). Give the roles (--role, at least one) and the apps the person sees: --all-apps, or --app for each \
        one (an ADMIN sees every app). --provisioning lets them manage certificates, identifiers and profiles.
        """)

    @Argument(help: ArgumentHelp("The person's email address (their Apple ID).", valueName: "email")) var email: String
    @Option(name: .customLong("first-name"), help: "The person's first name.") var firstName: String
    @Option(name: .customLong("last-name"), help: "The person's last name.") var lastName: String
    @OptionGroup var role: UserRoleOption
    @OptionGroup var visibility: UserAppsOption
    @Flag(help: "Allow access to Certificates, Identifiers & Profiles.") var provisioning = false
    @OptionGroup var account: AccountOptions

    func validate() throws {
        do { _ = try UserEmail.validate(email) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        if firstName.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--first-name is empty") }
        if lastName.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--last-name is empty") }
        let roles = try role.parsed()
        if roles.isEmpty { throw ValidationError("give at least one --role (\(UserRole.assignable.map(\.rawValue).joined(separator: ", ")))") }
        try visibility.validate(roles: roles)
        if !roles.contains(.admin), !visibility.allApps, visibility.apps.isEmpty {
            throw ValidationError("say which apps the person sees: --all-apps, or --app <app> for each one")
        }
    }

    func run() async throws {
        let roles = try role.parsed()
        let email = try UserEmail.validate(email)
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) {
            try await $0.invite(email: email, firstName: firstName.trimmingCharacters(in: .whitespaces),
                                lastName: lastName.trimmingCharacters(in: .whitespaces), roles: roles,
                                allApps: visibility.allApps || roles.contains(.admin), apps: visibility.apps, provisioning: provisioning)
        }
    }
}

struct UsersUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change a user's roles, the apps they see, or their access to certificates and profiles.",
        discussion: "--role replaces every role the user has. Only what differs from the user's current settings is sent.")

    @Argument(help: PersonArgument.help("user", list: "xless users list")) var user: String
    @OptionGroup var role: UserRoleOption
    @OptionGroup var visibility: UserAppsOption
    @Flag(inversion: .prefixedNo, help: "Allow (or, with --no-provisioning, stop) access to Certificates, Identifiers & Profiles.")
    var provisioning: Bool?
    @OptionGroup var account: AccountOptions

    func validate() throws {
        try PersonArgument.validate(user)
        let roles = try role.parsed()
        try visibility.validate(roles: roles)
        if roles.isEmpty, !visibility.allApps, visibility.apps.isEmpty, provisioning == nil {
            throw ValidationError("nothing to change: give --role, --all-apps, --app or --[no-]provisioning")
        }
    }

    func run() async throws {
        let roles = try role.parsed()
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) {
            try await $0.update(PersonArgument.normalized(user), roles: roles.isEmpty ? nil : roles, allApps: visibility.allApps || roles.contains(.admin),
                                apps: visibility.apps.isEmpty ? nil : visibility.apps, provisioning: provisioning)
        }
    }
}

struct UsersRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a user from the team (asks first): they lose access to App Store Connect and to internal testing.")

    @Argument(help: PersonArgument.help("user", list: "xless users list")) var user: String
    @OptionGroup var account: AccountOptions

    func validate() throws { try PersonArgument.validate(user) }

    func run() async throws {
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) {
            try await $0.remove(PersonArgument.normalized(user), yes: account.confirmation.yes)
        }
    }
}

struct UsersInvitationsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the pending invitations: ID, email, name, roles, apps, provisioning access and expiry.")

    @OptionGroup var role: UserRoleOption
    @OptionGroup var account: AccountOptions

    func validate() throws { _ = try role.parsed(filter: true) }

    func run() async throws {
        let roles = try role.parsed(filter: true)
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) { try await $0.invitations(roles: roles) }
    }
}

struct UsersInvitationsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel a pending invitation (asks first): the link Apple emailed stops working.")

    @Argument(help: PersonArgument.help("invitation", list: "xless users invitations list")) var invitation: String
    @OptionGroup var account: AccountOptions

    func validate() throws { try PersonArgument.validate(invitation) }

    func run() async throws {
        try await runUsers(account.team.team, verbose: account.trace.verbose, json: account.output.json) {
            try await $0.cancel(PersonArgument.normalized(invitation), yes: account.confirmation.yes)
        }
    }
}

/// What the user commands do once their arguments are valid; returns what goes to standard output and says the rest
/// (cancellations, hints) on standard error.
struct UserCLI {
    let users: ASCUsers
    let apps: ASCApps
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    init(resources: ASCResources, json: Bool = false, terminal: @escaping () -> (any Confirming)? = { try? TerminalPrompter.forAccount() },
         say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        users = ASCUsers(resources: resources); apps = ASCApps(resources: resources)
        self.json = json; self.terminal = terminal; self.say = say
    }

    struct Listing<D: Encodable>: Encodable { var data: D; var included: [ASCAnyResource] }

    func list(roles: [UserRole]) async throws -> String {
        let listing = try await users.list(roles: roles)
        if json { return try ASCOutput.json(Listing(data: listing.items, included: listing.included)) }
        guard !listing.items.isEmpty else { return roles.isEmpty ? "This team has no users visible to this key.\n" : "No user has \(roles.map(\.rawValue).joined(separator: " or ")).\n" }
        return UserTable.users(listing.items, included: listing.included)
    }

    func invitations(roles: [UserRole]) async throws -> String {
        let listing = try await users.invitations(roles: roles)
        if json { return try ASCOutput.json(Listing(data: listing.items, included: listing.included)) }
        guard !listing.items.isEmpty else { return "No invitation is pending.\n" }
        return UserTable.invitations(listing.items, included: listing.included)
    }

    func show(_ argument: String) async throws -> String {
        let user = try await users.resolve(argument)
        let visible = user.allAppsVisible ? [] : try await users.visibleApps(of: user.id)
        if json { return try ASCOutput.json(Listing(data: user, included: visible.map(\.resource))) }
        return UserTable.detail([
            ("ID", user.id), ("Email", user.email), ("Name", user.fullName), ("Roles", UserRole.display(user.roles)),
            ("Apps", user.allAppsVisible ? "all" : visible.isEmpty ? "none" : visible.map { "\($0.bundleID) (\($0.id))" }.joined(separator: ", ")),
            ("Provisioning", user.provisioningAllowed ? "yes" : "no"),
        ])
    }

    struct InviteReport: Encodable {
        /// `invited`, `existing-user` or `existing-invitation`.
        var result: String
        var data: ASCAnyResource
    }

    func invite(email: String, firstName: String, lastName: String, roles: [UserRole], allApps: Bool, apps appArguments: [String],
                provisioning: Bool) async throws -> String {
        // Someone already there is reported before the apps are looked up, so a re-run never fails on them.
        let result: ASCUsers.Invitation
        if let found = try await users.existing(email: email) {
            result = found
        } else {
            let appIDs = allApps ? [] : try await resolve(appArguments)
            let request = UserInvitationRequest(email: email, firstName: firstName, lastName: lastName, roles: roles,
                                                allAppsVisible: allApps, appIDs: appIDs, provisioningAllowed: provisioning)
            result = try await users.invite(request, checked: true)
        }
        let wanted = Set(roles.map(\.rawValue))
        switch result {
        case .invited(let i):
            if json { return try ASCOutput.json(InviteReport(result: "invited", data: i.resource)) }
            let expiry = i.attributes.expirationDate.map { ", expires \($0.prefix(10))" } ?? ""
            return "invited \(i.email) (\(i.fullName)) as \(UserRole.display(i.roles)), \(allApps ? "all apps" : "apps \(appArguments.joined(separator: ", "))"): invitation \(i.id)\(expiry); Apple emails them the link\n"
        case .existingUser(let u):
            if Set(u.roles) != wanted, !u.isAccountHolder { say("to change their roles: `xless users update \(u.email) --role \(roles.map(\.rawValue).joined(separator: ","))`") }
            if json { return try ASCOutput.json(InviteReport(result: "existing-user", data: u.resource)) }
            return "\(u.email) is already a user of this team (user \(u.id), \(UserRole.display(u.roles))); nothing was sent\n"
        case .existingInvitation(let i):
            if Set(i.roles) != wanted { say("to invite them differently, cancel it first: `xless users invitations cancel \(i.email)`") }
            if json { return try ASCOutput.json(InviteReport(result: "existing-invitation", data: i.resource)) }
            let expiry = i.attributes.expirationDate.map { ", expires \($0.prefix(10))" } ?? ""
            return "\(i.email) is already invited (invitation \(i.id), \(UserRole.display(i.roles))\(expiry)); nothing was sent\n"
        }
    }

    func update(_ argument: String, roles: [UserRole]?, allApps: Bool, apps appArguments: [String]?, provisioning: Bool?) async throws -> String {
        let user = try await users.resolve(argument)
        if roles != nil, user.isAccountHolder {
            throw XlessError(.account, "\(user.email) is the team's Account Holder, whose roles App Store Connect does not let anyone change",
                             fix: "drop --role; only a transfer of the Account Holder role (developer.apple.com → Membership details) changes them")
        }
        if appArguments != nil, (roles?.map(\.rawValue) ?? user.roles).contains(UserRole.admin.rawValue) {
            throw XlessError(.account, "\(user.email) is an ADMIN, who sees every app", fix: "drop --app, or give other roles with --role")
        }
        var appIDs: [String]?
        if let appArguments { appIDs = try await resolve(appArguments) }
        guard let updated = try await users.update(user, roles: roles, allApps: allApps, appIDs: appIDs, provisioning: provisioning) else {
            if json { return try ASCOutput.json(Listing(data: user, included: [])) }
            return "\(user.email) (user \(user.id)) already has these settings; nothing was sent\n"
        }
        if json { return try ASCOutput.json(Listing(data: updated, included: [])) }
        let seen = updated.allAppsVisible ? "all apps" : appArguments.map { "apps \($0.joined(separator: ", "))" } ?? "the same apps"
        return "updated \(updated.email) (user \(updated.id)): \(UserRole.display(updated.roles)), \(seen), provisioning \(updated.provisioningAllowed ? "yes" : "no")\n"
    }

    /// The app IDs of `--app` arguments (app IDs or bundle identifiers), each once.
    private func resolve(_ arguments: [String]) async throws -> [String] {
        var ids: [String] = []
        for argument in arguments {
            let id = try await apps.resolve(argument).id
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    func remove(_ argument: String, yes: Bool) async throws -> String {
        let user = try await users.resolve(argument)
        if user.isAccountHolder {
            throw XlessError(.account, "\(user.email) is the team's Account Holder, whom Apple does not let anyone remove",
                             fix: "transfer the Account Holder role first (developer.apple.com → Membership details), then remove them")
        }
        let question = "Remove \(user.email) (\(user.fullName), \(UserRole.display(user.roles))) from the team? They lose access to App Store Connect and to internal TestFlight testing."
        guard try AccountConfirm.confirm(question, action: "removing user \(user.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await users.remove(user)
        return json ? try ASCOutput.json(["removed": user]) : "removed \(user.email) (user \(user.id)) from the team\n"
    }

    func cancel(_ argument: String, yes: Bool) async throws -> String {
        let invitation = try await users.resolveInvitation(argument)
        let question = "Cancel the invitation of \(invitation.email) (\(invitation.fullName))? The link Apple emailed stops working."
        guard try AccountConfirm.confirm(question, action: "cancelling invitation \(invitation.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await users.cancel(invitation)
        return json ? try ASCOutput.json(["cancelled": invitation]) : "cancelled the invitation of \(invitation.email) (invitation \(invitation.id))\n"
    }
}

enum UserTable {
    /// `all`, the bundle IDs of the included apps (IDs when not included), or `none`; `,…` when the listing may have
    /// included only part of them (Apple includes at most 50 per person).
    static func apps<A: ASCPersonAttributes>(_ person: ASCKeptResource<A>, included: [ASCAnyResource]) -> String {
        if person.allAppsVisible { return "all" }
        guard let ids = person.visibleAppIDs else { return "-" }
        if ids.isEmpty { return "none" }
        let names = ids.map { id in included.first { $0.type == "apps" && $0.id == id }?.attributes?["bundleId"]?.string ?? id }
        return names.joined(separator: ",") + (ids.count >= ASCUsers.includedAppsLimit ? ",…" : "")
    }

    static func users(_ users: [ASCUser], included: [ASCAnyResource]) -> String {
        TextTable(["ID", "EMAIL", "NAME", "ROLES", "APPS", "PROVISIONING"], users.map { u in
            [u.id, u.email, u.fullName, u.roles.joined(separator: ","), apps(u, included: included), u.provisioningAllowed ? "yes" : "no"]
        }).rendered
    }

    static func invitations(_ invitations: [ASCUserInvitation], included: [ASCAnyResource]) -> String {
        TextTable(["ID", "EMAIL", "NAME", "ROLES", "APPS", "PROVISIONING", "EXPIRES"], invitations.map { i in
            [i.id, i.email, i.fullName, i.roles.joined(separator: ","), apps(i, included: included), i.provisioningAllowed ? "yes" : "no",
             String((i.attributes.expirationDate ?? "").prefix(10))]
        }).rendered
    }

    static func detail(_ rows: [(String, String)]) -> String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n") + "\n"
    }
}
