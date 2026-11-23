import ArgumentParser
import Foundation
import XlessASC
import XlessCore

struct BundleIDsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-ids",
        abstract: "List, show, register and delete bundle IDs (App IDs), and enable or disable their capabilities.",
        discussion: """
        Uses the App Store Connect API key (/v1/bundleIds, /v1/bundleIdCapabilities; the key needs the Admin role). A \
        bundle ID is named by its ID (from `xless bundle-ids list`) or its identifier. The sign stage registers its \
        bundle IDs and enables the capabilities their entitlements need by itself; these commands are for everything else.

          xless bundle-ids list --platform ios
          xless bundle-ids create com.example.app --name "Example App"
          xless bundle-ids capabilities com.example.app list
          xless bundle-ids capabilities com.example.app enable ICLOUD --setting ICLOUD_VERSION=XCODE_6
          xless bundle-ids capabilities com.example.app disable GAME_CENTER
          xless bundle-ids delete com.example.app
        """,
        subcommands: [BundleIDsListCommand.self, BundleIDsShowCommand.self, BundleIDsCreateCommand.self, BundleIDsDeleteCommand.self,
                      BundleIDsCapabilitiesCommand.self])
}

/// A bundle-ID argument: its ID (`xless bundle-ids list`) or its identifier.
enum BundleIDArgument {
    static let help = ArgumentHelp("The bundle ID's ID (see `xless bundle-ids list`) or its identifier (com.example.app).", valueName: "bundle-id")

    static func validate(_ text: String) throws {
        if BundleIdentifier.isIdentifier(text) {
            do { _ = try BundleIdentifier.validate(text) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        } else if !isASCResourceID(text) {
            throw ValidationError("\(text) is neither a bundle ID's ID (letters and digits, see `xless bundle-ids list`) nor an identifier")
        }
    }
}

struct BundleIDPlatformOption: ParsableArguments {
    @Option(help: ArgumentHelp("universal, ios or macos.", valueName: "platform"))
    var platform: String?

    var value: BundleIDPlatform? { platform.flatMap(BundleIDPlatform.init(argument:)) }

    func validate() throws {
        if let platform, BundleIDPlatform(argument: platform) == nil { throw ValidationError("--platform \(platform): use universal, ios or macos") }
    }
}

/// Opens the account session and runs `body` with the bundle-ID operations; prints what it returns.
private func runBundleIDs(_ team: String?, verbose: Bool, _ body: (BundleIDCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(BundleIDCLI(bundleIDs: ASCBundleIDs(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct BundleIDsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's bundle IDs: ID, identifier, name, platform and seed ID.")

    @OptionGroup var platform: BundleIDPlatformOption
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runBundleIDs(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).list(platform: platform.value) }
    }
}

struct BundleIDsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one bundle ID and the capabilities enabled on it, with their settings.")

    @Argument(help: BundleIDArgument.help) var bundleID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try BundleIDArgument.validate(bundleID) }

    func run() async throws {
        try await runBundleIDs(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).show(bundleID) }
    }
}

struct BundleIDsCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Register a bundle ID; an identifier the team already has is reported, never registered twice.",
        discussion: """
        The identifier is reverse-DNS (com.example.app), or a wildcard ending in .* (com.example.*). Without --name, the \
        name is the identifier's words (com example app): Apple accepts only ASCII letters, digits and spaces in it. \
        Without --platform, the bundle ID is universal (iOS and macOS), as the sign stage registers its own.
        """)

    @Argument(help: ArgumentHelp("The bundle identifier.", valueName: "identifier")) var identifier: String
    @Option(help: ArgumentHelp("The name the portal shows: ASCII letters, digits and spaces (default: xless and the identifier's words, the name `sign` and `provision` give).", valueName: "name")) var name: String?
    @OptionGroup var platform: BundleIDPlatformOption
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do {
            _ = try BundleIdentifier.validate(identifier)
            if let name { try PortalName.validate(name) }
        } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let identifier = try BundleIdentifier.validate(identifier)
        let name = name?.trimmingCharacters(in: .whitespaces) ?? PortalName.bundleID(for: identifier)
        try await runBundleIDs(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).create(identifier: identifier, name: name, platform: platform.value ?? .universal)
        }
    }
}

struct BundleIDsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a bundle ID (asks first): the provisioning profiles that use it become invalid.")

    @Argument(help: BundleIDArgument.help) var bundleID: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try BundleIDArgument.validate(bundleID) }

    func run() async throws {
        try await runBundleIDs(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).delete(bundleID, yes: confirmation.yes) }
    }
}

struct BundleIDsCapabilitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List, enable or disable a bundle ID's capabilities: capabilities <bundle-id> list | enable <CAPABILITY> | disable <CAPABILITY>.",
        discussion: """
        CAPABILITY is the App Store Connect API's name, in any case: \(CapabilityType.list).

        Three take a setting, given as --setting KEY=OPTION; without it, a new capability gets the first option below \
        and an enabled one keeps its own. ICLOUD: \
        ICLOUD_VERSION=XCODE_6 (CloudKit) or XCODE_5. DATA_PROTECTION: DATA_PROTECTION_PERMISSION_LEVEL=COMPLETE_PROTECTION, \
        PROTECTED_UNLESS_OPEN or PROTECTED_UNTIL_FIRST_USER_AUTH. APPLE_ID_AUTH: APPLE_ID_AUTH_APP_CONSENT=PRIMARY_APP_CONSENT.

        Enabling a capability that is enabled already sends nothing, or changes its setting when --setting names another. \
        App Groups, iCloud and Apple Pay also need an app group, an iCloud container or a merchant ID assigned to the \
        bundle ID, which the API cannot do. Disabling asks first (or needs --yes). Provisioning profiles made before a \
        change keep the old entitlements until they are regenerated (the sign stage regenerates its own).
        """)

    @Argument(help: BundleIDArgument.help) var bundleID: String
    @Argument(help: ArgumentHelp("list, enable or disable.", valueName: "action")) var action: String
    @Argument(help: ArgumentHelp("The capability to enable or disable (ICLOUD, APPLE_ID_AUTH, …).", valueName: "capability")) var capability: String?
    @Option(name: .customLong("setting"), help: ArgumentHelp("A capability setting, KEY=OPTION (repeatable; enable only).", valueName: "KEY=OPTION"))
    var settings: [String] = []
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    enum Action: String { case list, enable, disable }

    /// The action, the capability and its settings, checked before anything is sent.
    func parsed() throws -> (action: Action, capability: CapabilityType?, settings: [CapabilitySetting]) {
        guard let action = Action(rawValue: action.lowercased()) else {
            throw ValidationError("\(action) is not an action: use list, enable or disable")
        }
        if action == .list {
            if let capability { throw ValidationError("list takes no capability (\(capability))") }
            if !settings.isEmpty { throw ValidationError("--setting goes with enable") }
            return (.list, nil, [])
        }
        guard let capability else { throw ValidationError("\(action.rawValue) needs a capability, e.g. \(action.rawValue) ICLOUD") }
        guard let type = CapabilityType(argument: capability) else {
            throw ValidationError("\(capability) is not a capability; the API knows \(CapabilityType.list)")
        }
        if action == .disable {
            if !settings.isEmpty { throw ValidationError("--setting goes with enable") }
            return (.disable, type, [])
        }
        do { return (.enable, type, try CapabilitySetting.parse(settings, for: type)) } catch let e as CapabilitySettingError {
            throw ValidationError(e.description)
        }
    }

    func validate() throws {
        try BundleIDArgument.validate(bundleID)
        _ = try parsed()
    }

    func run() async throws {
        let (action, type, settings) = try parsed()
        try await runBundleIDs(team.team, verbose: trace.verbose) {
            let cli = $0.with(json: output.json)
            switch action {
            case .list: return try await cli.capabilities(bundleID)
            case .enable: return try await cli.enable(type!, settings: settings, on: bundleID)
            case .disable: return try await cli.disable(type!, on: bundleID, yes: confirmation.yes)
            }
        }
    }
}

/// What the bundle-ID commands do once their arguments are valid; returns what goes to standard output and says the
/// rest (notes, cancellations) on standard error.
struct BundleIDCLI {
    let bundleIDs: ASCBundleIDs
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func with(json: Bool) -> BundleIDCLI { var copy = self; copy.json = json; return copy }

    func list(platform: BundleIDPlatform?) async throws -> String {
        let list = try await bundleIDs.list(platform: platform)
        if json { return try ASCOutput.json(["data": list]) }
        return TextTable(["ID", "IDENTIFIER", "NAME", "PLATFORM", "SEED ID"], list.map {
            [$0.id, $0.identifier, $0.name, BundleIDPlatform.display($0.attributes.platform), $0.attributes.seedId ?? ""]
        }).rendered
    }

    struct Shown: Encodable { var data: ASCBundleID; var capabilities: [ASCBundleIDCapability] }

    func show(_ argument: String) async throws -> String {
        let b = try await bundleIDs.resolve(argument)
        let caps = try await bundleIDs.capabilities(of: b.id)
        if json { return try ASCOutput.json(Shown(data: b, capabilities: caps)) }
        let head = TextTable(["ID", b.id], [["IDENTIFIER", b.identifier], ["NAME", b.name],
                                            ["PLATFORM", BundleIDPlatform.display(b.attributes.platform)], ["SEED ID", b.attributes.seedId ?? ""]]).rendered
        return head + "\n" + (caps.isEmpty ? "no capability is enabled\n" : Self.capabilityTable(caps))
    }

    func create(identifier: String, name: String, platform: BundleIDPlatform) async throws -> String {
        let result = try await bundleIDs.create(identifier: identifier, name: name, platform: platform)
        if json {
            switch result {
            case .created(let b): return try ASCOutput.json(["registered": [b], "existing": []])
            case .existing(let b): return try ASCOutput.json(["registered": [], "existing": [b]])
            }
        }
        let b = result.bundleID
        switch result {
        case .created: return "registered \(b.identifier) as bundle ID \(b.id) (\(BundleIDPlatform.display(b.attributes.platform)))\n"
        case .existing:
            return "\(b.identifier) is already registered as bundle ID \(b.id) (\(b.name), \(BundleIDPlatform.display(b.attributes.platform))); nothing was sent\n"
        }
    }

    func delete(_ argument: String, yes: Bool) async throws -> String {
        let b = try await bundleIDs.resolve(argument)
        let question = "Delete bundle ID \(b.identifier) (\(b.id))? The provisioning profiles that use it become invalid."
        guard try AccountConfirm.confirm(question, action: "deleting bundle ID \(b.identifier)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await bundleIDs.delete(b)
        return json ? try ASCOutput.json(["deleted": b]) : "deleted bundle ID \(b.identifier) (\(b.id))\n"
    }

    func capabilities(_ argument: String) async throws -> String {
        let b = try await bundleIDs.resolve(argument)
        let caps = try await bundleIDs.capabilities(of: b.id)
        if json { return try ASCOutput.json(["data": caps]) }
        return caps.isEmpty ? "no capability is enabled on \(b.identifier)\n" : Self.capabilityTable(caps)
    }

    func enable(_ type: CapabilityType, settings: [CapabilitySetting], on argument: String) async throws -> String {
        let b = try await bundleIDs.resolve(argument)
        let result = try await bundleIDs.enable(type, settings: settings, on: b.id)
        // What was sent (the default setting when none was given), or what the capability has when nothing was sent.
        let with: String
        switch result {
        case .enabled: with = Self.describe(CapabilitySetting.chosen(settings.isEmpty ? CapabilitySetting.defaults(for: type) : settings))
        case .updated: with = Self.describe(CapabilitySetting.chosen(settings))
        case .unchanged(let c): with = Self.describe(c.chosenSettings)
        }
        if case .unchanged = result {} else {
            if let linked = type.linkedIdentifier {
                let how = switch type {
                case .appGroups: "assign it with `xless app-groups assign \(b.identifier) <group>`"
                case .icloud: "assign it with `xless icloud-containers assign \(b.identifier) <container>`"
                default: "assign it at https://developer.apple.com/account/resources/identifiers (\(b.identifier) → \(type.displayName) → Configure)"
                }
                say("note: \(type.displayName) also needs \(linked) assigned to \(b.identifier), which the App Store Connect API cannot do: \(how)")
            }
            say("note: provisioning profiles made before this do not carry it until they are regenerated (the sign stage regenerates its own)")
        }
        if json { return try ASCOutput.json(result.capability) }
        switch result {
        case .enabled: return "enabled \(type.rawValue) (\(type.displayName)) on \(b.identifier)\(with.isEmpty ? "" : " with \(with)")\n"
        case .updated: return "changed \(type.rawValue) (\(type.displayName)) on \(b.identifier) to \(with)\n"
        case .unchanged:
            return "\(type.rawValue) is already enabled on \(b.identifier)\(with.isEmpty ? "" : " with \(with)"); nothing was sent\n"
        }
    }

    func disable(_ type: CapabilityType, on argument: String, yes: Bool) async throws -> String {
        let b = try await bundleIDs.resolve(argument)
        guard let current = try await bundleIDs.capabilities(of: b.id).first(where: { $0.capabilityType == type.rawValue }) else {
            if json { return try ASCOutput.json(["disabled": [ASCBundleIDCapability]()]) }
            return "\(type.rawValue) is not enabled on \(b.identifier); nothing was sent\n"
        }
        let question = "Disable \(type.displayName) on \(b.identifier)? Provisioning profiles regenerated after this lose its entitlements."
        guard try AccountConfirm.confirm(question, action: "disabling \(type.rawValue) on \(b.identifier)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await bundleIDs.disable(current)
        return json ? try ASCOutput.json(["disabled": [current]]) : "disabled \(type.rawValue) (\(type.displayName)) on \(b.identifier)\n"
    }

    static func describe(_ chosen: [String: String]) -> String {
        chosen.keys.sorted().map { "\($0)=\(chosen[$0]!)" }.joined(separator: ", ")
    }

    static func capabilityTable(_ caps: [ASCBundleIDCapability]) -> String {
        let sorted = caps.sorted { $0.capabilityType < $1.capabilityType }
        return TextTable(["CAPABILITY", "NAME", "SETTINGS", "ID"], sorted.map {
            [$0.capabilityType, CapabilityType(rawValue: $0.capabilityType)?.displayName ?? "", describe($0.chosenSettings), $0.id]
        }).rendered
    }
}
