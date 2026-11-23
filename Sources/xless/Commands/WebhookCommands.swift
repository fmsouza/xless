import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless webhooks`: an app's App Store Connect webhooks, their signing secrets in the secret store
// (docs/apple-account.md#xless-webhooks).

struct WebhooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webhooks",
        abstract: "List, create and delete an app's App Store Connect webhooks; their signing secrets go into the secret store.",
        discussion: """
        Uses the App Store Connect API key (/v1/apps/{id}/webhooks, /v1/webhooks). `create` makes the signing secret \
        itself and stores it as XLESS_WEBHOOK_SECRET.<webhook ID>[@TEAM]; it is never printed. Hand it to the server \
        that receives the events with `xless secrets export <entry> --out <file>`.

          xless webhooks list --app com.example.app
          xless webhooks create --app com.example.app --url https://hooks.example.com/asc --events build-upload-state-updated,app-store-version-app-version-state-updated
          xless webhooks delete 6f1c0c3e-1e45-4c83-9b55-7d1f3a0e1b2c
        """,
        subcommands: [WebhooksListCommand.self, WebhooksCreateCommand.self, WebhooksDeleteCommand.self])
}

/// Opens the account session and runs `body` with the webhook operations; prints what it returns.
private func runWebhooks(_ account: AccountOptions, _ body: (WebhookCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: account.team.team, verbose: account.trace.verbose)
        let cli = WebhookCLI(
            resources: session.resources, json: account.output.json, team: session.team,
            storeFile: { try? APIKeyWebCLI.store().catalog() },
            unlockStore: { try APIKeyWebCLI.unlocked(reason: "storing the webhook's signing secret") { WebhookSecretStore(store: $0, catalogID: $1.id) } },
            removeEntries: { try WebhookSecretStore.remove(id: $0, from: APIKeyWebCLI.store()) })
        let out = try await body(cli)
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct WebhooksListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List an app's webhooks: ID, name, URL, whether enabled, events, and the store entry holding the secret.")

    @OptionGroup var app: ProductAppOption
    @OptionGroup var account: AccountOptions

    func run() async throws {
        try await runWebhooks(account) { try await $0.list(app: app.app) }
    }
}

struct WebhooksCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a webhook with a new signing secret, kept in the secret store (never printed).",
        discussion: """
        The secret store is opened (and unlocked) before anything is sent. An app that already has a webhook for the \
        URL is reported, and nothing is sent. Events: \(WebhookEvents.known.joined(separator: ", ")) (any case, - or _; \
        a name Apple added since is sent as given, with a warning).
        """)

    @OptionGroup var app: ProductAppOption
    @Option(help: ArgumentHelp("The https address App Store Connect sends the events to.", valueName: "url")) var url: String
    @Option(name: .customLong("events"), help: ArgumentHelp("The events to send; repeatable or comma-separated.", valueName: "event"))
    var events: [String] = []
    @Option(help: ArgumentHelp("The webhook's name. Default: the URL's host.", valueName: "name")) var name: String?
    @Flag(help: "Create it disabled (App Store Connect sends nothing until it is enabled).") var disabled = false
    @OptionGroup var account: AccountOptions

    func validate() throws {
        do {
            _ = try WebhookInput.url(url)
            _ = try WebhookEvents.parse(events)
            if let name { _ = try WebhookInput.name(name) }
        } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        SecretScope.enter()
        let url = try WebhookInput.url(url)
        let name = try name.map(WebhookInput.name)
        try await runWebhooks(account) { try await $0.create(app: app.app, name: name, url: url, events: events, enabled: !disabled) }
    }
}

struct WebhooksDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a webhook (asks first) and remove its secret from the secret store.")

    @Argument(help: ArgumentHelp("The webhook's ID (see `xless webhooks list`).", valueName: "webhook-id")) var webhook: String
    @OptionGroup var account: AccountOptions

    func validate() throws {
        guard WebhookInput.isWebhookID(webhook) else { throw ValidationError("\(webhook) is not a webhook ID (letters, digits and dashes)") }
    }

    func run() async throws {
        try await runWebhooks(account) { try await $0.delete(webhook, yes: account.confirmation.yes) }
    }
}
