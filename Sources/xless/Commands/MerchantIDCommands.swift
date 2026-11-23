import ArgumentParser
import Foundation
import XlessASC
import XlessCore

struct MerchantIDsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merchant-ids",
        abstract: "List, register and delete the merchant IDs that Apple Pay payments are made to.",
        discussion: """
        Uses the App Store Connect API key (/v1/merchantIds; the key needs the Admin role). A merchant ID is named by its \
        ID (from `xless merchant-ids list`) or its identifier. An app uses one through the Apple Pay capability \
        (`xless bundle-ids capabilities <bundle-id> enable APPLE_PAY`); assigning the merchant ID to the bundle ID is not \
        in the API: do it at developer.apple.com/account/resources/identifiers.

          xless merchant-ids list
          xless merchant-ids create merchant.com.example.store --name "Example Store"
          xless merchant-ids delete merchant.com.example.store
        """,
        subcommands: [MerchantIDsListCommand.self, MerchantIDsCreateCommand.self, MerchantIDsDeleteCommand.self])
}

/// A merchant-ID argument: its ID (`xless merchant-ids list`) or its identifier.
enum MerchantIDArgument {
    static let help = ArgumentHelp("The merchant ID's ID (see `xless merchant-ids list`) or its identifier (merchant.com.example.store).", valueName: "merchant-id")

    static func validate(_ text: String) throws {
        if text.contains(".") {
            do { _ = try MerchantIdentifier.validate(text) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        } else if !isASCResourceID(text) {
            throw ValidationError("\(text) is neither a merchant ID's ID (letters and digits, see `xless merchant-ids list`) nor an identifier")
        }
    }
}

/// Opens the account session and runs `body` with the merchant-ID operations; prints what it returns.
private func runMerchantIDs(_ team: String?, verbose: Bool, _ body: (MerchantIDCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(MerchantIDCLI(merchantIDs: ASCMerchantIDs(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct MerchantIDsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the team's merchant IDs: ID, identifier and name.")

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runMerchantIDs(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).list() }
    }
}

struct MerchantIDsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Register a merchant ID; an identifier the team already has is reported, never registered twice.")

    @Argument(help: ArgumentHelp("The merchant identifier: merchant. then reverse-DNS (merchant.com.example.store).", valueName: "identifier"))
    var identifier: String
    @Option(help: ArgumentHelp("The name the portal shows: ASCII letters, digits and spaces.", valueName: "name")) var name: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do {
            _ = try MerchantIdentifier.validate(identifier)
            try PortalName.validate(name)
        } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let identifier = try MerchantIdentifier.validate(identifier)
        try await runMerchantIDs(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).create(identifier: identifier, name: name.trimmingCharacters(in: .whitespaces))
        }
    }
}

struct MerchantIDsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a merchant ID (asks first): apps can no longer take Apple Pay payments to it.")

    @Argument(help: MerchantIDArgument.help) var merchantID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try MerchantIDArgument.validate(merchantID) }

    func run() async throws {
        try await runMerchantIDs(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).delete(merchantID, yes: confirmation.yes) }
    }
}

/// What the merchant-ID commands do once their arguments are valid; returns what goes to standard output.
struct MerchantIDCLI {
    let merchantIDs: ASCMerchantIDs
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func with(json: Bool) -> MerchantIDCLI { var copy = self; copy.json = json; return copy }

    func list() async throws -> String {
        let list = try await merchantIDs.list()
        if json { return try ASCOutput.json(["data": list]) }
        return TextTable(["ID", "IDENTIFIER", "NAME"], list.map { [$0.id, $0.identifier, $0.name] }).rendered
    }

    func create(identifier: String, name: String) async throws -> String {
        let result = try await merchantIDs.create(identifier: identifier, name: name)
        if json {
            switch result {
            case .created(let m): return try ASCOutput.json(["registered": [m], "existing": []])
            case .existing(let m): return try ASCOutput.json(["registered": [], "existing": [m]])
            }
        }
        let m = result.merchantID
        switch result {
        case .created: return "registered \(m.identifier) as merchant ID \(m.id)\n"
        case .existing: return "\(m.identifier) is already registered as merchant ID \(m.id) (\(m.name)); nothing was sent\n"
        }
    }

    func delete(_ argument: String, yes: Bool) async throws -> String {
        let m = try await merchantIDs.resolve(argument)
        let question = "Delete merchant ID \(m.identifier) (\(m.id))? Apps can no longer take Apple Pay payments to it."
        guard try AccountConfirm.confirm(question, action: "deleting merchant ID \(m.identifier)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await merchantIDs.delete(m)
        return json ? try ASCOutput.json(["deleted": m]) : "deleted merchant ID \(m.identifier) (\(m.id))\n"
    }
}
