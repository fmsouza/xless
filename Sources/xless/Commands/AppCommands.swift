import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List, show, update and create App Store Connect app records.",
        discussion: """
        list, show and update use the App Store Connect API key (/v1/apps). create uses the Apple ID web session, because \
        the API cannot create an app record; once it exists, everything else about the app goes through the API key. An \
        app is named by its app ID (digits, from `xless apps list`) or its bundle identifier.

          xless apps list
          xless apps show com.example.app
          xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US
          xless apps update com.example.app --content-rights does-not-use-third-party-content
          xless apps price-points com.example.app --territory USA --price 0.99
        """,
        subcommands: [AppsListCommand.self, AppsShowCommand.self, AppsUpdateCommand.self, AppsCreateCommand.self, AppsPricePointsCommand.self])
}

enum AppArgumentHelp {
    static let help = ArgumentHelp("The app ID (digits, see `xless apps list`) or the app's bundle identifier.", valueName: "app")

    static func validate(_ text: String) throws {
        do { try AppArgument.validate(text) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }
}

/// Opens the account session and runs `body` with the app operations; prints what it returns.
private func runApps(_ team: String?, verbose: Bool, _ body: (AppCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(AppCLI(apps: ASCApps(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

/// An explicit bundle identifier (no wildcard), for --bundle-id.
private func explicitBundleID(_ text: String) throws -> String {
    do {
        let id = try BundleIdentifier.validate(text)
        guard !id.contains("*") else { throw IdentifierInputError("an app's bundle ID is explicit: \(id) is a wildcard") }
        return id
    } catch let e as IdentifierInputError { throw ValidationError("--bundle-id: \(e.description)") }
}

struct AppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the apps the API key sees: app ID, name, bundle ID, SKU and primary locale.")

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runApps(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).list() }
    }
}

struct AppsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one app: its record, its app infos (state, age rating) and its App Store versions with their states.")

    @Argument(help: AppArgumentHelp.help) var app: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try AppArgumentHelp.validate(app) }

    func run() async throws {
        try await runApps(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).show(app) }
    }
}

struct AppsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Change an app's primary locale, content rights declaration or bundle ID (PATCH /v1/apps).",
        discussion: """
        Only the values that differ from the app's are sent; when none does, nothing is. --content-rights says whether the \
        app shows, contains or accesses third-party content: uses-third-party-content or does-not-use-third-party-content \
        (App Store review asks for it). Apple accepts a new --bundle-id only until the app's first build is uploaded.
        """)

    @Argument(help: AppArgumentHelp.help) var app: String
    @Option(help: ArgumentHelp("The primary locale (en-US, de-DE, ja, zh-Hans…).", valueName: "locale")) var primaryLocale: String?
    @Option(help: ArgumentHelp("uses-third-party-content or does-not-use-third-party-content.", valueName: "declaration")) var contentRights: String?
    @Option(help: ArgumentHelp("A registered bundle identifier for the app.", valueName: "identifier")) var bundleId: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        try AppArgumentHelp.validate(app)
        guard primaryLocale != nil || contentRights != nil || bundleId != nil else {
            throw ValidationError("nothing to update: pass --primary-locale, --content-rights or --bundle-id")
        }
        _ = try parsed()
    }

    func parsed() throws -> (locale: String?, rights: AppContentRights?, bundleID: String?) {
        var locale: String?
        if let primaryLocale {
            do { locale = try AppLocale.normalize(primaryLocale) } catch let e as IdentifierInputError { throw ValidationError("--primary-locale: \(e.description)") }
        }
        var rights: AppContentRights?
        if let contentRights {
            guard let r = AppContentRights(argument: contentRights) else {
                throw ValidationError("--content-rights \(contentRights): use uses-third-party-content or does-not-use-third-party-content")
            }
            rights = r
        }
        return (locale, rights, try bundleId.map(explicitBundleID))
    }

    func run() async throws {
        let (locale, rights, bundleID) = try parsed()
        try await runApps(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).update(app, primaryLocale: locale, contentRights: rights, bundleID: bundleID)
        }
    }
}

struct AppsPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "List an app's price points in a territory, or show one price's point and what it is in every other territory.",
        discussion: """
        A price point is a price App Store Connect lets the app take in a territory: its customer price and the proceeds, \
        in the territory's currency. app.yml's pricing names prices (`free`, "0.99"), and `xless store push` sends the \
        points with exactly those prices. With --price, the point with that customer price is shown with its \
        equalizations: the price App Store Connect sets in every other territory that follows the base price. A price \
        that is no point is an error naming the nearest ones.

          xless apps price-points com.example.app                       # every point in the United States
          xless apps price-points com.example.app --territory JPN
          xless apps price-points com.example.app --price 0.99          # and its price in every territory
        """)

    @Argument(help: AppArgumentHelp.help) var app: String
    @Option(help: ArgumentHelp("The territory, as a three-letter code (USA, GBR, JPN…; default USA).", valueName: "code")) var territory: String = "USA"
    @Option(help: ArgumentHelp("A customer price in the territory's currency (`free`, 0.99).", valueName: "price")) var price: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        try AppArgumentHelp.validate(app)
        guard territory.uppercased().range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ValidationError("--territory \(territory) is not a territory code: use three letters, e.g. USA, GBR, JPN")
        }
        if let price, CustomerPrice.parse(price) == nil {
            throw ValidationError("--price \(price) is not a price: write `free` or the customer price with a dot, e.g. 0.99")
        }
    }

    func run() async throws {
        try await runApps(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).pricePoints(app, territory: territory.uppercased(), price: price)
        }
    }
}

struct AppsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an App Store Connect app record; an app that already has the bundle ID is reported, never created twice.",
        discussion: AppleWebHelp.note + """


        Needs an Apple ID with the Account Holder, Admin or App Manager role. With an App Store Connect API key, xless \
        first looks the app up by bundle ID (an existing app is reported and nothing is sent) and checks that the bundle \
        ID is registered, offering to register it (or --yes); without a key, those checks go through the web session \
        and an unregistered bundle ID is an error. Then one create request is sent, never retried: the app, its name in \
        the primary locale, and a first App Store version (--app-version, default 1.0) for each --platform (ios by \
        default; repeatable). When App Store Connect's answer is unclear, xless looks the app up before saying anything.

        The name (2 to 30 characters) is unique across the whole App Store; the SKU (letters, digits, -, . and _) is \
        unique within the team and never shown to customers; --company-name is asked only for a team's first app.
        """)

    @Option(help: ArgumentHelp("The app's bundle identifier (registered on the team, or registered now).", valueName: "identifier")) var bundleId: String
    @Option(help: ArgumentHelp("The app's name on the App Store, 2 to 30 characters.", valueName: "name")) var name: String
    @Option(help: ArgumentHelp("The app's SKU: letters, digits, -, . and _.", valueName: "sku")) var sku: String
    @Option(help: ArgumentHelp("The primary locale (en-US, de-DE, ja, zh-Hans…).", valueName: "locale")) var locale: String
    @Option(name: .customLong("platform"), help: ArgumentHelp("ios or macos; repeatable (default: ios).", valueName: "platform"))
    var platforms: [String] = []
    @Option(help: ArgumentHelp("The first App Store version (default: 1.0).", valueName: "version")) var appVersion: String = "1.0"
    @Option(help: ArgumentHelp("The seller name shown on the App Store; only for the team's first app.", valueName: "company")) var companyName: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { _ = try request() }

    /// The request, every value checked before anything is sent.
    func request() throws -> AppCreateRequest {
        let bundle = try explicitBundleID(bundleId)
        do {
            let name = try AppName.validate(self.name)
            let sku = try AppSKU.validate(self.sku)
            let locale = try AppLocale.normalize(self.locale)
            var chosen: [AppPlatform] = []
            for text in platforms.flatMap({ $0.split(separator: ",").map(String.init) }) {
                guard let p = AppPlatform(argument: text) else { throw IdentifierInputError("--platform \(text): use ios or macos") }
                if !chosen.contains(p) { chosen.append(p) }
            }
            guard appVersion.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil else {
                throw IdentifierInputError("--app-version \(appVersion) is not a version: use 1 to 3 numbers separated by dots, e.g. 1.0")
            }
            let company = companyName?.trimmingCharacters(in: .whitespaces)
            if let company, company.isEmpty { throw IdentifierInputError("--company-name is empty") }
            return AppCreateRequest(name: name, bundleID: bundle, sku: sku, primaryLocale: locale,
                                    platforms: (chosen.isEmpty ? [.ios] : chosen).map(\.rawValue), versionString: appVersion, companyName: company)
        } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let request = try request()
        try await AccountSession.run {
            SecretScope.enter()
            let wanted = AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam())
            var api: (any AppCreationAPI)?
            do { api = KeyAppCreationAPI(resources: try AccountSession.open(team: team.team, verbose: trace.verbose).resources) } catch {
                AppleWebCLI.say("note: no App Store Connect API key resolves (\(XlessError.wrapping(error, stage: .account).cause)); the checks go through the Apple ID web session")
            }
            let opened = WebSessionHolder()
            defer { opened.transport?.invalidate() }
            let creation = AppCreation(
                api: api,
                web: {
                    let (session, transport, _) = try await APIKeyWebCLI.open(team: wanted, verbose: trace.verbose)
                    opened.session = session
                    opened.transport = transport
                    await AppleWebCLI.warnAboutAgreements(session)
                    return WebAppCreation(apps: ASCWebApps(asc: session.asc), portal: PortalBundleIDs(portal: session.portal))
                },
                confirm: { question, action in try AccountConfirm.confirm(question, action: action, yes: confirmation.yes) },
                say: AppleWebCLI.say)
            let result = try await creation.run(request)
            if let session = opened.session { await session.end() }
            guard let result else { return }
            print(output.json ? try ASCOutput.json(result) : result.text, terminator: "")
        }
    }
}

/// The web session `apps create` opened, if it needed one, to end it afterwards.
private final class WebSessionHolder {
    var session: AppleWebSession?
    var transport: URLSessionAppleTransport?
}
