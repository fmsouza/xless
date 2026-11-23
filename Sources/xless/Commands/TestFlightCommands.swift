import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless testflight`: groups, testers, the builds each group gets, What to Test, the beta information App Review reads,
// the beta app review submission and public links (docs/apple-account.md#xless-testflight).

struct TestFlightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "testflight",
        abstract: "Manage TestFlight groups and testers, deliver builds, and run external testing (beta app review, public links).",
        discussion: """
        Uses the App Store Connect API key. A group is named by its exact (case-sensitive) name or its ID, within the app \
        --app names (app ID or bundle identifier); a build by its ID or <version>+<build number>. Internal testers must \
        be App Store Connect users of the team (`xless users invite`); external testers get a build once Apple approves it \
        (`beta-review submit`). Adding someone already there, or creating a group that exists, sends nothing.

          xless testflight groups create "Beta" --external --app com.example.app
          xless testflight testers add ada@example.com grace@example.com --group "Beta" --app com.example.app
          xless testflight builds add 1.2.0+42 --group "Beta" --app com.example.app
          xless testflight whats-new set 1.2.0+42 --app com.example.app --text "Try the new editor"
          xless testflight beta-info set --app com.example.app --description "…" --feedback-email beta@example.com
          xless testflight beta-review submit 1.2.0+42 --app com.example.app
          xless testflight public-link enable "Beta" --app com.example.app --limit 500
        """,
        subcommands: [TestFlightGroupsCommand.self, TestFlightTestersCommand.self, TestFlightBuildsCommand.self, TestFlightWhatsNewCommand.self,
                      TestFlightBetaInfoCommand.self, TestFlightBetaReviewCommand.self, TestFlightPublicLinkCommand.self])
}

/// `--app`, required: the app whose groups and testers these are.
struct TestFlightAppOption: ParsableArguments {
    @Option(help: AppArgumentHelp.help) var app: String
    func validate() throws { try AppArgumentHelp.validate(app) }
}

/// One or more tester email addresses.
enum TesterEmails {
    static let help = ArgumentHelp("The tester's email address; several may be given.", valueName: "email")

    static func validate(_ emails: [String]) throws -> [String] {
        var out: [String] = []
        for raw in emails {
            let email: String
            do { email = try BetaTesterEmail.validate(raw) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
            if !out.contains(where: { UserEmail.same($0, email) }) { out.append(email) }
        }
        return out
    }
}

enum GroupArgument {
    static let help = ArgumentHelp("The group's exact name (quote names with spaces) or its ID.", valueName: "group")

    static func validate(_ text: String, option: String = "group") throws {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("the \(option) name is empty") }
    }
}

/// Opens the account session and runs `body` with the TestFlight operations; prints what it returns.
private func runTestFlight(_ account: AccountOptions, _ body: (TestFlightCLI, AccountSession) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: account.team.team, verbose: account.trace.verbose)
        let out = try await body(TestFlightCLI(resources: session.resources, json: account.output.json), session)
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

// MARK: groups

struct TestFlightGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups", abstract: "List, create, update and delete an app's TestFlight groups.",
        subcommands: [TestFlightGroupsListCommand.self, TestFlightGroupsCreateCommand.self, TestFlightGroupsUpdateCommand.self, TestFlightGroupsDeleteCommand.self])
}

struct TestFlightGroupsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the app's groups: ID, name, internal or external, automatic distribution, feedback and public link.")
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func run() async throws { try await runTestFlight(account) { cli, _ in try await cli.groups(app: app.app) } }
}

struct TestFlightGroupsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create a group (internal by default); a group with that name is reported and nothing is sent.",
        discussion: "Whether a group is internal or external, and an internal group's automatic distribution (--all-builds: it gets every build), cannot change after it is created.")
    @Argument(help: ArgumentHelp("The group's name.", valueName: "name")) var name: String
    @Flag(help: "An internal group (the default): App Store Connect users of the team, no beta app review.") var `internal` = false
    @Flag(help: "An external group: anyone by email or public link, once Apple approves each build.") var external = false
    @Flag(help: "Internal groups only: every build of the app is delivered to the group (automatic distribution).") var allBuilds = false
    @Flag(inversion: .prefixedNo, help: "Let testers send feedback (Apple's default when not given).") var feedback: Bool?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    func validate() throws {
        try GroupArgument.validate(name)
        if `internal`, external { throw ValidationError("--internal and --external exclude each other") }
        if external, allBuilds { throw ValidationError("--all-builds is for internal groups: external groups get the builds you add (and Apple approves)") }
    }

    func run() async throws {
        try await runTestFlight(account) { cli, _ in
            try await cli.createGroup(name.trimmingCharacters(in: .whitespaces), app: app.app, external: external, allBuilds: allBuilds, feedback: feedback)
        }
    }
}

struct TestFlightGroupsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Rename a group or turn its feedback on or off; only what differs is sent.",
        discussion: "Public links: `xless testflight public-link`.")
    @Argument(help: GroupArgument.help) var group: String
    @Option(help: ArgumentHelp("The group's new name.", valueName: "name")) var name: String?
    @Flag(inversion: .prefixedNo, help: "Let testers send feedback, or not.") var feedback: Bool?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    func validate() throws {
        try GroupArgument.validate(group)
        if let name { try GroupArgument.validate(name, option: "--name") }
        if name == nil, feedback == nil { throw ValidationError("nothing to change: give --name or --[no-]feedback") }
    }

    func run() async throws {
        try await runTestFlight(account) { cli, _ in
            try await cli.updateGroup(group, app: app.app, name: name?.trimmingCharacters(in: .whitespaces), feedback: feedback)
        }
    }
}

struct TestFlightGroupsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a group (asks first): its testers lose the builds they got through it.")
    @Argument(help: GroupArgument.help) var group: String
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { try GroupArgument.validate(group) }
    func run() async throws { try await runTestFlight(account) { cli, _ in try await cli.deleteGroup(group, app: app.app, yes: account.confirmation.yes) } }
}

// MARK: testers

struct TestFlightTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "testers", abstract: "List, add, remove and re-invite TestFlight testers.",
        subcommands: [TestFlightTestersListCommand.self, TestFlightTestersAddCommand.self, TestFlightTestersRemoveCommand.self, TestFlightTestersInviteCommand.self])
}

struct TestFlightTestersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the app's testers (or one group's): ID, email, name, state, how they were invited and their groups.")
    @Option(help: ArgumentHelp("Only this group's testers (exact name or ID).", valueName: "group")) var group: String?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { if let group { try GroupArgument.validate(group, option: "--group") } }
    func run() async throws { try await runTestFlight(account) { cli, _ in try await cli.testers(app: app.app, group: group) } }
}

struct TestFlightTestersAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add testers to a group; someone already in it is reported and nothing is sent.",
        discussion: """
        An internal group's testers must be App Store Connect users of the team: an address that is not one is refused \
        with the `xless users invite` to run (the check reads /v1/users, which needs an Admin key; without one, Apple \
        decides). An external group takes any address: Apple emails new testers an invitation. --first-name and \
        --last-name name a new tester (one address only).
        """)
    @Argument(help: TesterEmails.help) var emails: [String]
    @Option(help: ArgumentHelp("The group (exact name or ID).", valueName: "group")) var group: String
    @Option(help: "A new tester's first name (with one address).") var firstName: String?
    @Option(help: "A new tester's last name (with one address).") var lastName: String?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    func validate() throws {
        _ = try TesterEmails.validate(emails)
        try GroupArgument.validate(group, option: "--group")
        if emails.count > 1, firstName != nil || lastName != nil { throw ValidationError("--first-name and --last-name go with one address") }
    }

    func run() async throws {
        let emails = try TesterEmails.validate(emails)
        try await runTestFlight(account) { cli, _ in
            try await cli.addTesters(emails, app: app.app, group: group, firstName: firstName?.trimmingCharacters(in: .whitespaces),
                                     lastName: lastName?.trimmingCharacters(in: .whitespaces))
        }
    }
}

struct TestFlightTestersRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove testers from a group, or with no --group from every group and build of the app (asks first).")
    @Argument(help: TesterEmails.help) var emails: [String]
    @Option(help: ArgumentHelp("Only from this group (exact name or ID).", valueName: "group")) var group: String?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    func validate() throws {
        _ = try TesterEmails.validate(emails)
        if let group { try GroupArgument.validate(group, option: "--group") }
    }

    func run() async throws {
        let emails = try TesterEmails.validate(emails)
        try await runTestFlight(account) { cli, _ in try await cli.removeTesters(emails, app: app.app, group: group, yes: account.confirmation.yes) }
    }
}

struct TestFlightTestersInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite", abstract: "Have Apple email testers of the app their invitation again (/v1/betaTesterInvitations).")
    @Argument(help: TesterEmails.help) var emails: [String]
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { _ = try TesterEmails.validate(emails) }
    func run() async throws {
        let emails = try TesterEmails.validate(emails)
        try await runTestFlight(account) { cli, _ in try await cli.invite(emails, app: app.app) }
    }
}

// MARK: builds

/// `--group`, repeatable.
struct TestFlightGroupsOption: ParsableArguments {
    @Option(name: .customLong("group"), help: ArgumentHelp("A group (exact name or ID); repeatable.", valueName: "group")) var groups: [String] = []
    func validate() throws {
        if groups.isEmpty { throw ValidationError("give at least one --group") }
        for g in groups { try GroupArgument.validate(g, option: "--group") }
    }
}

struct TestFlightBuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builds", abstract: "Give a build to groups, or take it away.",
        subcommands: [TestFlightBuildsAddCommand.self, TestFlightBuildsRemoveCommand.self])
}

struct TestFlightBuildsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add a build to groups; groups that have it already are left alone.",
        discussion: "External groups get the build once Apple approves it: `xless testflight beta-review submit <build>`.")
    @OptionGroup var selection: BuildSelection
    @OptionGroup var groups: TestFlightGroupsOption
    @OptionGroup var account: AccountOptions
    func run() async throws {
        try await runTestFlight(account) { cli, _ in
            try await cli.buildGroups(add: true, selection.reference, app: selection.app, platform: selection.platform.value, groups: groups.groups, yes: account.confirmation.yes)
        }
    }
}

struct TestFlightBuildsRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a build from groups (asks first): their testers can no longer install it.")
    @OptionGroup var selection: BuildSelection
    @OptionGroup var groups: TestFlightGroupsOption
    @OptionGroup var account: AccountOptions
    func run() async throws {
        try await runTestFlight(account) { cli, _ in
            try await cli.buildGroups(add: false, selection.reference, app: selection.app, platform: selection.platform.value, groups: groups.groups, yes: account.confirmation.yes)
        }
    }
}

// MARK: whats-new

struct TestFlightWhatsNewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whats-new", abstract: "Show or set a build's What to Test.",
        subcommands: [TestFlightWhatsNewShowCommand.self, TestFlightWhatsNewSetCommand.self])
}

struct TestFlightWhatsNewShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a build's What to Test, every locale.")
    @OptionGroup var selection: BuildSelection
    @OptionGroup var account: AccountOptions
    func run() async throws {
        try await runTestFlight(account) { cli, _ in try await cli.whatsNew(selection.reference, app: selection.app, platform: selection.platform.value) }
    }
}

struct TestFlightWhatsNewSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a build's What to Test for a locale (at most 4000 characters); the same text sends nothing.")
    @OptionGroup var selection: BuildSelection
    @Option(help: ArgumentHelp("The locale, e.g. en-US (default).", valueName: "locale")) var locale: String = "en-US"
    @Option(help: ArgumentHelp("The text.", valueName: "text")) var text: String?
    @Option(help: ArgumentHelp("A UTF-8 file with the text.", valueName: "path")) var file: String?
    @OptionGroup var account: AccountOptions

    func validate() throws {
        try BetaLocale.validate(locale)
        if (text == nil) == (file == nil) { throw ValidationError("give the text with --text or --file (one of them)") }
        if let text { try WhatToTestText.validate(text) }
    }

    func run() async throws {
        let value = try WhatToTestText.read(text: text, file: file)
        try await runTestFlight(account) { cli, _ in
            try await cli.setWhatsNew(selection.reference, app: selection.app, platform: selection.platform.value, locale: locale, text: value)
        }
    }
}

enum BetaLocale {
    static func validate(_ locale: String) throws {
        if locale.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil { throw ValidationError("--locale \(locale) is not a locale code: use e.g. en-US") }
    }
}

enum WhatToTestText {
    static func validate(_ text: String, option: String = "--text") throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw ValidationError("\(option) is empty") }
        if t.count > 4000 { throw ValidationError("\(option) is \(t.count) characters; App Store Connect allows at most 4000") }
    }

    /// The text of `--text` or `--file`, trimmed and checked.
    static func read(text: String?, file: String?, option: String = "--file") throws -> String {
        if let text { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let value = try TextFile.read(file ?? "", option: option)
        try validate(value, option: option)
        return value
    }
}

enum TextFile {
    /// A UTF-8 text file's contents, trailing whitespace trimmed (at most 1 MB).
    static func read(_ path: String, option: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
            throw XlessError(.account, "cannot read \(option) \(path) as a UTF-8 text file (at most 1 MB)", fix: "check the path")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: beta-info

struct TestFlightBetaInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-info", abstract: "Show or set what Apple's beta app review and external testers read: description, feedback email, review contact, demo account, license.",
        subcommands: [TestFlightBetaInfoShowCommand.self, TestFlightBetaInfoSetCommand.self])
}

struct TestFlightBetaInfoShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show the beta information of every locale (or --locale), the beta App Review details (never the demo password) and the license agreement.")
    @Option(help: ArgumentHelp("Only this locale.", valueName: "locale")) var locale: String?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { if let locale { try BetaLocale.validate(locale) } }
    func run() async throws { try await runTestFlight(account) { cli, _ in try await cli.betaInfo(app: app.app, locale: locale) } }
}

struct TestFlightBetaInfoSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Set the beta information, the beta App Review details and the license agreement; only what differs is sent.",
        discussion: """
        The demo account's password is never an option: it comes from the secret --demo-password-secret-name names \
        (XLESS_DEMO_PASSWORD by default: the environment, NAME_FILE, or `xless secrets import XLESS_DEMO_PASSWORD --file \
        <file> --kind password`). Apple never gives it back, so it is sent only when the demo account is required and had \
        no name, its name changes, it becomes required, or with --resend-demo-account. "" clears a text.
        """)
    @Option(help: ArgumentHelp("The locale of the texts, e.g. en-US (default).", valueName: "locale")) var locale: String = "en-US"
    @Option(help: ArgumentHelp("What testers read about the beta (at most 4000 characters).", valueName: "text")) var description: String?
    @Option(help: ArgumentHelp("A UTF-8 file with the description.", valueName: "path")) var descriptionFile: String?
    @Option(help: ArgumentHelp("Where testers' feedback goes.", valueName: "email")) var feedbackEmail: String?
    @Option(help: ArgumentHelp("The marketing URL.", valueName: "url")) var marketingUrl: String?
    @Option(help: ArgumentHelp("The privacy policy URL (required for external testing).", valueName: "url")) var privacyPolicyUrl: String?
    @Option(help: "The review contact's first name.") var contactFirstName: String?
    @Option(help: "The review contact's last name.") var contactLastName: String?
    @Option(help: ArgumentHelp("The review contact's phone number.", valueName: "phone")) var contactPhone: String?
    @Option(help: ArgumentHelp("The review contact's email address.", valueName: "email")) var contactEmail: String?
    @Option(help: ArgumentHelp("Notes for App Review.", valueName: "text")) var reviewNotes: String?
    @Option(help: ArgumentHelp("The account App Review signs in with.", valueName: "login")) var demoAccountName: String?
    @Flag(inversion: .prefixedNo, help: "Whether App Review needs the demo account to sign in.") var demoRequired: Bool?
    @Option(help: ArgumentHelp("The secret holding the demo account's password (default XLESS_DEMO_PASSWORD).", valueName: "secret-name"))
    var demoPasswordSecretName: String?
    @Flag(help: "Send the demo account's password even when nothing about the account changed.") var resendDemoAccount = false
    @Option(help: ArgumentHelp("A UTF-8 file with the beta license agreement's text.", valueName: "path")) var licenseFile: String?
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    var reviewGiven: Bool {
        [contactFirstName, contactLastName, contactPhone, contactEmail, reviewNotes, demoAccountName, demoPasswordSecretName].contains { $0 != nil }
            || demoRequired != nil || resendDemoAccount
    }

    func validate() throws {
        try BetaLocale.validate(locale)
        if description != nil, descriptionFile != nil { throw ValidationError("--description and --description-file exclude each other") }
        if let description, description.count > 4000 { throw ValidationError("--description is \(description.count) characters; App Store Connect allows at most 4000") }
        for (option, value) in [("--feedback-email", feedbackEmail), ("--contact-email", contactEmail)] {
            if let value, !value.isEmpty { do { _ = try UserEmail.validate(value) } catch let e as IdentifierInputError { throw ValidationError("\(option): \(e.description)") } }
        }
        for (option, value) in [("--marketing-url", marketingUrl), ("--privacy-policy-url", privacyPolicyUrl)] {
            if let value, !value.isEmpty, !(value.hasPrefix("https://") || value.hasPrefix("http://")) { throw ValidationError("\(option) \(value) is not an http(s) URL") }
        }
        if let name = demoPasswordSecretName, let problem = SecretEnvironment.passwordNameProblem(name) {
            throw ValidationError("--demo-password-secret-name \(name) \(problem): keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD")
        }
        if description == nil, descriptionFile == nil, feedbackEmail == nil, marketingUrl == nil, privacyPolicyUrl == nil, !reviewGiven, licenseFile == nil {
            throw ValidationError("nothing to set: give a text, a review detail or --license-file")
        }
    }

    func run() async throws {
        var descriptionText = description
        if let descriptionFile {
            descriptionText = try TextFile.read(descriptionFile, option: "--description-file")
            if descriptionText!.count > 4000 { throw XlessError(.account, "--description-file has \(descriptionText!.count) characters; App Store Connect allows at most 4000", fix: "shorten the text") }
        }
        let license = try licenseFile.map { try TextFile.read($0, option: "--license-file") }
        let text = BetaInfoText(description: descriptionText, feedbackEmail: feedbackEmail, marketingURL: marketingUrl, privacyPolicyURL: privacyPolicyUrl)
        let review = reviewGiven ? BetaReviewChange(contactFirstName: contactFirstName, contactLastName: contactLastName, contactPhone: contactPhone,
                                                    contactEmail: contactEmail, notes: reviewNotes, demoAccountName: demoAccountName,
                                                    demoAccountRequired: demoRequired,
                                                    passwordSecret: demoPasswordSecretName ?? BetaReviewChange.defaultPasswordSecret,
                                                    resendDemoAccount: resendDemoAccount) : nil
        try await runTestFlight(account) { cli, session in
            try await cli.setBetaInfo(app: app.app, locale: locale, text: text, review: review, license: license) { name in
                try StorePushCLI.demoPassword(name, secrets: session.secrets, source: "--demo-password-secret-name, XLESS_DEMO_PASSWORD by default")
            }
        }
    }
}

// MARK: beta-review

struct TestFlightBetaReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beta-review", abstract: "Submit a build for beta app review (external testing) and follow it.",
        subcommands: [TestFlightBetaReviewSubmitCommand.self, TestFlightBetaReviewStatusCommand.self])
}

struct TestFlightBetaReviewSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit", abstract: "Submit a processed build for beta app review; a build already submitted is reported and nothing is sent.",
        discussion: "Apple reviews the build with the beta information (`beta-info`): a description, a feedback email, a privacy policy URL, the review contact and, when the app needs one, a demo account; and the build's What to Test.")
    @OptionGroup var selection: BuildSelection
    @OptionGroup var account: AccountOptions
    func run() async throws {
        try await runTestFlight(account) { cli, _ in try await cli.submit(selection.reference, app: selection.app, platform: selection.platform.value) }
    }
}

struct TestFlightBetaReviewStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show a build's beta app review state and its external testing state.")
    @OptionGroup var selection: BuildSelection
    @OptionGroup var account: AccountOptions
    func run() async throws {
        try await runTestFlight(account) { cli, _ in try await cli.status(selection.reference, app: selection.app, platform: selection.platform.value) }
    }
}

// MARK: public-link

struct TestFlightPublicLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "public-link", abstract: "Show, enable or disable an external group's public link.",
        subcommands: [TestFlightPublicLinkShowCommand.self, TestFlightPublicLinkEnableCommand.self, TestFlightPublicLinkDisableCommand.self])
}

struct TestFlightPublicLinkShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the group's public link and its tester limit.")
    @Argument(help: GroupArgument.help) var group: String
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { try GroupArgument.validate(group) }
    func run() async throws {
        try await runTestFlight(account) { cli, _ in try await cli.publicLink(.show, group: group, app: app.app, limit: nil, yes: account.confirmation.yes) }
    }
}

struct TestFlightPublicLinkEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Enable the external group's public link (or change its limit) and print it.",
        discussion: "Anyone with the link can join the group, up to --limit testers (1–10000); --no-limit removes the limit.")
    @Argument(help: GroupArgument.help) var group: String
    @Option(help: ArgumentHelp("At most this many testers join through the link (1–10000).", valueName: "n")) var limit: Int?
    @Flag(help: "No limit.") var noLimit = false
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions

    func validate() throws {
        try GroupArgument.validate(group)
        if limit != nil, noLimit { throw ValidationError("--limit and --no-limit exclude each other") }
        if let limit, !(1...10_000).contains(limit) { throw ValidationError("--limit \(limit): use 1 to 10000") }
    }

    func run() async throws {
        let change: Int?? = noLimit ? .some(nil) : limit.map { .some($0) }
        try await runTestFlight(account) { cli, _ in try await cli.publicLink(.enable, group: group, app: app.app, limit: change, yes: account.confirmation.yes) }
    }
}

struct TestFlightPublicLinkDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable the group's public link (asks first): nobody new can join through it.")
    @Argument(help: GroupArgument.help) var group: String
    @OptionGroup var app: TestFlightAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { try GroupArgument.validate(group) }
    func run() async throws {
        try await runTestFlight(account) { cli, _ in try await cli.publicLink(.disable, group: group, app: app.app, limit: nil, yes: account.confirmation.yes) }
    }
}
