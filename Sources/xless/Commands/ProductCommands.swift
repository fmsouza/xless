import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless iap`, `xless subscriptions`, `xless sandbox-testers` (docs/apple-account.md#xless-iap-and-xless-subscriptions).
// The products themselves are written in appstore/iap/ and appstore/subscriptions/ and sent by `xless store push`.

/// Opens the account session and runs `body` with the product operations; prints what it returns.
private func runProducts(_ account: AccountOptions, _ body: (ProductCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: account.team.team, verbose: account.trace.verbose)
        let out = try await body(ProductCLI(resources: session.resources, json: account.output.json))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

/// `--app`: the app the products belong to.
struct ProductAppOption: ParsableArguments {
    @Option(help: AppArgumentHelp.help) var app: String
    func validate() throws { try AppArgumentHelp.validate(app) }
}

enum ProductArgument {
    static let help = ArgumentHelp("The product ID (com.example.coins100) or its App Store Connect ID.", valueName: "product")

    static func validate(_ text: String) throws {
        guard ProductID.isProductID(text) else { throw ValidationError("\(text) is neither a product ID nor an ID (letters, digits, dots, dashes, underscores)") }
    }
}

/// `--territory` and `--price` of the price-points commands.
struct PricePointOptions: ParsableArguments {
    @Option(help: ArgumentHelp("The territory, as a three-letter code (USA, GBR, JPN…; default USA).", valueName: "code")) var territory: String = "USA"
    @Option(help: ArgumentHelp("A customer price in the territory's currency (`free`, 0.99).", valueName: "price")) var price: String?

    func validate() throws {
        guard territory.uppercased().range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ValidationError("--territory \(territory) is not a territory code: use three letters, e.g. USA, GBR, JPN")
        }
        if let price, CustomerPrice.parse(price) == nil {
            throw ValidationError("--price \(price) is not a price: write `free` or the customer price with a dot, e.g. 0.99")
        }
    }
}

// MARK: - xless iap

struct IAPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iap",
        abstract: "List and inspect the app's in-app purchases (consumable, non-consumable, non-renewing subscriptions).",
        discussion: """
        Uses the App Store Connect API key (/v2/inAppPurchases). The products themselves are files of the appstore/ \
        manifest (appstore/iap/<productId>.yml: type, reference name, text per locale, App Review screenshot, price, \
        availability, family sharing): `xless store pull` writes them, `xless store push` creates and updates them, \
        `xless release submit` sends them to App Review with the version (docs/appstore-manifest.md).

          xless iap list --app com.example.app
          xless iap show com.example.coins100 --app com.example.app
          xless iap price-points com.example.coins100 --app com.example.app --price 0.99
        """,
        subcommands: [IAPListCommand.self, IAPShowCommand.self, IAPPricePointsCommand.self])
}

struct IAPListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the app's in-app purchases: product ID, type, reference name, state.")
    @OptionGroup var app: ProductAppOption
    @OptionGroup var account: AccountOptions
    func run() async throws { try await runProducts(account) { try await $0.iapList(app: app.app) } }
}

struct IAPShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one in-app purchase: its state, text, price, availability, screenshot and versions.")
    @Argument(help: ProductArgument.help) var product: String
    @OptionGroup var app: ProductAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { try ProductArgument.validate(product) }
    func run() async throws { try await runProducts(account) { try await $0.iapShow(product, app: app.app) } }
}

struct IAPPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "List an in-app purchase's price points in a territory, or show one price's point.",
        discussion: "The prices an iap/<productId>.yml `pricing` may name: `xless store push` sends the point with exactly that customer price.")
    @Argument(help: ProductArgument.help) var product: String
    @OptionGroup var app: ProductAppOption
    @OptionGroup var points: PricePointOptions
    @OptionGroup var account: AccountOptions
    func validate() throws { try ProductArgument.validate(product) }
    func run() async throws {
        try await runProducts(account) { try await $0.pricePoints(.iap, product, app: app.app, territory: points.territory.uppercased(), price: points.price) }
    }
}

// MARK: - xless subscriptions

struct SubscriptionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subscriptions",
        abstract: "List and inspect the app's auto-renewable subscriptions and their groups.",
        discussion: """
        Uses the App Store Connect API key (/v1/subscriptionGroups, /v1/subscriptions). Groups and subscriptions are \
        files of the appstore/ manifest (appstore/subscriptions/<group>/group.yml and <productId>.yml): `xless store \
        pull` writes them, `xless store push` creates and updates them (prices per territory: existing subscribers keep \
        theirs unless the file says otherwise), `xless release submit` sends them to App Review with the version.

          xless subscriptions list --app com.example.app
          xless subscriptions show com.example.premium.monthly --app com.example.app
          xless subscriptions price-points com.example.premium.monthly --app com.example.app --price 4.99
        """,
        subcommands: [SubscriptionsListCommand.self, SubscriptionsShowCommand.self, SubscriptionsPricePointsCommand.self])
}

struct SubscriptionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the app's subscription groups and their subscriptions.")
    @OptionGroup var app: ProductAppOption
    @OptionGroup var account: AccountOptions
    func run() async throws { try await runProducts(account) { try await $0.subscriptionsList(app: app.app) } }
}

struct SubscriptionsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one subscription: its group, period, state, text, prices, availability, screenshot and versions.")
    @Argument(help: ProductArgument.help) var product: String
    @OptionGroup var app: ProductAppOption
    @OptionGroup var account: AccountOptions
    func validate() throws { try ProductArgument.validate(product) }
    func run() async throws { try await runProducts(account) { try await $0.subscriptionShow(product, app: app.app) } }
}

struct SubscriptionsPricePointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "price-points",
        abstract: "List a subscription's price points in a territory, or show one price's point and its equivalent in every territory.",
        discussion: "A subscription has a price per territory: `xless store push` sets the base price's equivalent wherever the file gives no price of its own.")
    @Argument(help: ProductArgument.help) var product: String
    @OptionGroup var app: ProductAppOption
    @OptionGroup var points: PricePointOptions
    @OptionGroup var account: AccountOptions
    func validate() throws { try ProductArgument.validate(product) }
    func run() async throws {
        try await runProducts(account) { try await $0.pricePoints(.subscription, product, app: app.app, territory: points.territory.uppercased(), price: points.price) }
    }
}

// MARK: - xless sandbox-testers

struct SandboxTestersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox-testers",
        abstract: "List the team's sandbox testers, or clear their purchase history.",
        discussion: """
        Uses the App Store Connect API key (/v2/sandboxTesters). Sandbox testers buy in-app purchases in development \
        and TestFlight builds without being charged. Apple's API lists and updates them but does not create them: \
        App Store Connect does (Users and Access, Sandbox). Clearing a tester's purchase history lets them buy \
        non-consumables and start introductory offers again.

          xless sandbox-testers list
          xless sandbox-testers clear-history tester@example.com
        """,
        subcommands: [SandboxTestersListCommand.self, SandboxTestersClearCommand.self])
}

struct SandboxTestersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the team's sandbox testers: account, name, territory, renewal rate.")
    @OptionGroup var account: AccountOptions
    func run() async throws { try await runProducts(account) { try await $0.sandboxList() } }
}

struct SandboxTestersClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-history",
        abstract: "Clear the purchase history of sandbox testers (asks first).")
    @Argument(help: ArgumentHelp("A tester's account (email address) or ID; several may be given.", valueName: "tester")) var testers: [String] = []
    @Flag(help: "Every sandbox tester of the team.") var all = false
    @OptionGroup var account: AccountOptions

    func validate() throws {
        if all, !testers.isEmpty { throw ValidationError("--all and tester names exclude each other") }
        if !all, testers.isEmpty { throw ValidationError("name the testers (account or ID), or pass --all") }
    }

    func run() async throws {
        try await runProducts(account) { try await $0.sandboxClear(testers.map { $0.trimmingCharacters(in: .whitespaces) }, all: all, yes: account.confirmation.yes) }
    }
}
