import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore

// `xless app-groups` and `xless icloud-containers`: one set of commands for both, through the Apple ID web session (the
// App Store Connect API can neither create nor assign them). After an assignment changes, the bundle ID's provisioning
// profiles are regenerated through the API key (`ProfileCLI.renewed`): a profile lists the groups and containers of
// the moment it was made.

/// Which of the two a command handles.
protocol LinkedKindCommand { static var kind: PortalLinkedKind { get } }
enum AppGroupKind: LinkedKindCommand { static let kind = PortalLinkedKind.appGroup }
enum CloudContainerKind: LinkedKindCommand { static let kind = PortalLinkedKind.cloudContainer }

struct AppGroupsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-groups",
        abstract: "List, register, assign and unassign app groups (shared containers of an app and its extensions).",
        discussion: AppleWebHelp.note + """


        A group is named by its identifier (group.com.example.shared) or its ID (`xless app-groups list`). Assigning one \
        to a bundle ID enables the bundle ID's App Groups capability if needed, then regenerates the bundle ID's \
        provisioning profiles through the App Store Connect API key (asks first, or --yes): a profile lists the groups \
        of the moment it was made.

          xless app-groups list
          xless app-groups create group.com.example.shared
          xless app-groups assign com.example.app group.com.example.shared
          xless app-groups assign com.example.app.widget group.com.example.shared
          xless app-groups unassign com.example.app group.com.example.shared
        """,
        subcommands: [LinkedListCommand<AppGroupKind>.self, LinkedCreateCommand<AppGroupKind>.self, LinkedAssignCommand<AppGroupKind>.self,
                      LinkedUnassignCommand<AppGroupKind>.self])
}

struct ICloudContainersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icloud-containers",
        abstract: "List, register, assign and unassign iCloud containers (CloudKit and iCloud Documents).",
        discussion: AppleWebHelp.note + """


        A container is named by its identifier (iCloud.com.example.app) or its ID (`xless icloud-containers list`; hidden \
        ones too). Apple cannot delete a container once registered. Assigning one needs the bundle ID's iCloud \
        capability (`xless bundle-ids capabilities <bundle-id> enable ICLOUD`, which `xless sign` also does), then \
        regenerates the bundle ID's provisioning profiles through the App Store Connect API key (asks first, or --yes).

          xless icloud-containers list
          xless icloud-containers create iCloud.com.example.app
          xless icloud-containers assign com.example.app iCloud.com.example.app
          xless icloud-containers unassign com.example.app iCloud.com.example.app
        """,
        subcommands: [LinkedListCommand<CloudContainerKind>.self, LinkedCreateCommand<CloudContainerKind>.self,
                      LinkedAssignCommand<CloudContainerKind>.self, LinkedUnassignCommand<CloudContainerKind>.self])
}

/// Signs in, selects the team, runs `body` with the operations and prints what it returns.
private func runLinked(_ kind: PortalLinkedKind, team: String?, verbose: Bool, json: Bool,
                       _ body: (LinkedIdentifierCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let (session, transport) = try await AppleWebCLI.open(verbose: verbose)
        defer { transport.invalidate() }
        let selected = try await session.selectTeam(AccountSession.resolveTeam(flag: team, saved: AccountSession.savedTeam()))
        let cli = LinkedIdentifierCLI(kind: kind, portal: WebLinkedIdentifiers(kind: kind, portal: session.portal),
                                      regeneration: { APIProfileRegeneration(cli: ProfileCLI(client: try AccountSession.open(team: selected.teamId, verbose: verbose).client),
                                                                             team: selected.teamId) },
                                      json: json)
        let out = try await body(cli)
        await session.end()
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct LinkedListCommand<K: LinkedKindCommand>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "list", abstract: "List the team's \(K.kind.noun)s: ID, identifier and name.", discussion: AppleWebHelp.note)
    }

    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runLinked(K.kind, team: team.team, verbose: trace.verbose, json: output.json) { try await $0.list() }
    }
}

struct LinkedCreateCommand<K: LinkedKindCommand>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "create",
            abstract: "Register \(K.kind == .appGroup ? "an app group" : "an iCloud container"); one the team has is reported, never registered twice.",
            discussion: AppleWebHelp.note + (K.kind == .cloudContainer ? "\n\nApple cannot delete an iCloud container once it is registered." : ""))
    }

    @Argument(help: ArgumentHelp("The identifier: \(K.kind.prefix) then reverse-DNS (\(K.kind.example)).", valueName: "identifier"))
    var identifier: String
    @Option(help: ArgumentHelp("The name the portal shows: ASCII letters, digits and spaces (default: the identifier's words).", valueName: "name"))
    var name: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do { _ = try K.kind.validate(identifier) } catch let e as PortalInputError { throw ValidationError(e.description) }
        if let name { do { try PortalName.validate(name) } catch let e as IdentifierInputError { throw ValidationError(e.description) } }
    }

    func run() async throws {
        let identifier = try K.kind.validate(identifier)
        try await runLinked(K.kind, team: team.team, verbose: trace.verbose, json: output.json) {
            try await $0.create(identifier: identifier, name: name?.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// The bundle-ID and identifier arguments of assign / unassign.
enum LinkedArguments {
    static func validate(bundle: String, items: [String], kind: PortalLinkedKind) throws {
        let b = bundle.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty, b.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.*".unicodeScalars.contains($0)) }) else {
            throw ValidationError("\(bundle) is neither a bundle identifier (com.example.app) nor a bundle ID's ID")
        }
        for item in items {
            if item.contains(".") {
                do { _ = try kind.validate(item) } catch let e as PortalInputError { throw ValidationError(e.description) }
            } else if !PortalIdentifiers.isResourceID(item.trimmingCharacters(in: .whitespaces)) {
                throw ValidationError("\(item) is neither an \(kind.noun) identifier (\(kind.example)) nor an ID from `xless \(kind.command) list`")
            }
        }
    }
}

struct LinkedAssignCommand<K: LinkedKindCommand>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "assign",
            abstract: "Assign \(K.kind.noun)s to a bundle ID, then regenerate its provisioning profiles (asks first, or --yes).",
            discussion: AppleWebHelp.note + """


            The bundle ID keeps the \(K.kind.noun)s it has. Its profiles are regenerated through the App Store Connect API key \
            (`xless profiles renew`); without one, xless says which commands to run (`xless sign` regenerates its own).
            """)
    }

    @Argument(help: ArgumentHelp("The bundle ID: its identifier (com.example.app) or ID.", valueName: "bundle-id")) var bundleID: String
    @Argument(help: ArgumentHelp("The \(K.kind.noun)s: identifiers (\(K.kind.example)) or IDs.", valueName: K.kind == .appGroup ? "group" : "container"))
    var items: [String]
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        guard !items.isEmpty else { throw ValidationError("name at least one \(K.kind.noun)") }
        try LinkedArguments.validate(bundle: bundleID, items: items, kind: K.kind)
    }

    func run() async throws {
        try await runLinked(K.kind, team: team.team, verbose: trace.verbose, json: output.json) {
            try await $0.assign(bundle: bundleID, items: items, yes: confirmation.yes)
        }
    }
}

struct LinkedUnassignCommand<K: LinkedKindCommand>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "unassign",
            abstract: "Take \(K.kind.noun)s away from a bundle ID (asks first), then regenerate its provisioning profiles.",
            discussion: AppleWebHelp.note + """


            The \(K.kind.capabilityName) capability stays enabled, even with nothing left in it (`xless bundle-ids capabilities \
            <bundle-id> disable \(K.kind.capability)` disables it).
            """)
    }

    @Argument(help: ArgumentHelp("The bundle ID: its identifier (com.example.app) or ID.", valueName: "bundle-id")) var bundleID: String
    @Argument(help: ArgumentHelp("The \(K.kind.noun)s: identifiers (\(K.kind.example)) or IDs.", valueName: K.kind == .appGroup ? "group" : "container"))
    var items: [String]
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        guard !items.isEmpty else { throw ValidationError("name at least one \(K.kind.noun)") }
        try LinkedArguments.validate(bundle: bundleID, items: items, kind: K.kind)
    }

    func run() async throws {
        try await runLinked(K.kind, team: team.team, verbose: trace.verbose, json: output.json) {
            try await $0.unassign(bundle: bundleID, items: items, yes: confirmation.yes)
        }
    }
}

// MARK: The operations

/// The portal operations the commands use (`WebLinkedIdentifiers`; a fake in tests).
protocol LinkedIdentifierPortal: Sendable {
    func list() async throws -> [PortalIdentifier]
    func create(identifier: String, name: String) async throws -> PortalCreation
    func bundle(_ argument: String) async throws -> PortalBundleID
    func linked(of bundle: PortalBundleID) async throws -> LinkedState
    func setLinked(_ ids: [String], enabled: Bool, on bundle: PortalBundleID) async throws -> LinkedState
}

struct WebLinkedIdentifiers: LinkedIdentifierPortal {
    let kind: PortalLinkedKind
    let portal: PortalWebClient

    func list() async throws -> [PortalIdentifier] {
        switch kind {
        case .appGroup: try await PortalAppGroups(portal: portal).list()
        case .cloudContainer: try await PortalCloudContainers(portal: portal).list()
        }
    }

    func create(identifier: String, name: String) async throws -> PortalCreation {
        switch kind {
        case .appGroup: try await PortalAppGroups(portal: portal).create(identifier: identifier, name: name)
        case .cloudContainer: try await PortalCloudContainers(portal: portal).create(identifier: identifier, name: name)
        }
    }

    func bundle(_ argument: String) async throws -> PortalBundleID { try await PortalBundleIDs(portal: portal).resolve(argument) }

    func linked(of bundle: PortalBundleID) async throws -> LinkedState { try await PortalBundleIDs(portal: portal).linked(kind, of: bundle) }

    func setLinked(_ ids: [String], enabled: Bool, on bundle: PortalBundleID) async throws -> LinkedState {
        try await PortalBundleIDs(portal: portal).setLinked(kind, ids: ids, enabled: enabled, on: bundle)
    }
}

/// Regenerating a bundle ID's profiles through the API key (`APIProfileRegeneration`; a fake in tests).
protocol ProfileRegenerating {
    /// The profiles of the bundle identifier.
    func profiles(of identifier: String) async throws -> [ASCProfile]
    /// Deletes the profile and creates it again (no question: the caller asked).
    func renew(_ id: String) async throws -> ProfileCreated
}

struct APIProfileRegeneration: ProfileRegenerating {
    let cli: ProfileCLI
    let team: String?

    func profiles(of identifier: String) async throws -> [ASCProfile] {
        let bundle = try await ASCBundleIDs(resources: cli.resources).resolve(identifier)
        return try await cli.profiles.list(types: []).profiles.filter { $0.bundleIDResourceID == bundle.id }
    }

    func renew(_ id: String) async throws -> ProfileCreated {
        guard let created = try await cli.renewed(id, yes: true, team: team) else {
            throw XlessError(.account, "profile \(id) was not renewed", fix: "renew it with `xless profiles renew \(id)`")
        }
        return created
    }
}

/// What assign / unassign did, for `--json`.
struct LinkedChange: Encodable {
    let bundleId: String
    /// The identifiers this run assigned (or unassigned).
    let changed: [String]
    /// The ones asked for that needed no change.
    let unchanged: [String]
    /// What the capability lists now (identifiers; an ID when the team's listing does not have it).
    let linked: [String]
    let regeneratedProfiles: [ProfileCreated]
}

/// What the commands do once their arguments are valid; returns what goes to standard output and says notes on
/// standard error.
struct LinkedIdentifierCLI {
    let kind: PortalLinkedKind
    let portal: any LinkedIdentifierPortal
    /// The API-key side, for the profiles; throws when there is no usable key.
    var regeneration: () throws -> any ProfileRegenerating
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func list() async throws -> String {
        let items = try await portal.list()
        if json { return try ASCOutput.json(["data": items]) }
        if items.isEmpty { return "This team has no \(kind.noun)s (register one with `xless \(kind.command) create \(kind.example)`).\n" }
        if kind == .cloudContainer {
            return TextTable(["ID", "IDENTIFIER", "NAME", "HIDDEN"], items.map { [$0.id, $0.identifier, $0.name, $0.hidden == true ? "yes" : ""] }).rendered
        }
        return TextTable(["ID", "IDENTIFIER", "NAME"], items.map { [$0.id, $0.identifier, $0.name] }).rendered
    }

    func create(identifier: String, name: String?) async throws -> String {
        let result = try await portal.create(identifier: identifier, name: name ?? PortalName.from(identifier: identifier))
        if json {
            switch result {
            case .created(let i): return try ASCOutput.json(["registered": [i], "existing": []])
            case .existing(let i): return try ASCOutput.json(["registered": [], "existing": [i]])
            }
        }
        let i = result.item
        switch result {
        case .created:
            return "registered \(i.identifier) as \(kind.noun) \(i.id)\nassign it with `xless \(kind.command) assign <bundle-id> \(i.identifier)`\n"
        case .existing:
            return "\(i.identifier) is already registered as \(kind.noun) \(i.id)\(i.name.isEmpty ? "" : " (\(i.name))"); nothing was sent\n"
        }
    }

    /// The team's items and the ones the arguments name (each once).
    func resolve(_ arguments: [String]) async throws -> (all: [PortalIdentifier], wanted: [PortalIdentifier]) {
        let all = try await portal.list()
        var wanted: [PortalIdentifier] = []
        for a in arguments {
            let i = try PortalIdentifiers.resolve(a, in: all, kind: kind)
            if !wanted.contains(where: { $0.id == i.id }) { wanted.append(i) }
        }
        return (all, wanted)
    }

    func assign(bundle argument: String, items: [String], yes: Bool) async throws -> String {
        let (all, wanted) = try await resolve(items)
        let bundle = try await portal.bundle(argument)
        let state = try await portal.linked(of: bundle)
        if kind == .cloudContainer, !state.present || !state.enabled {
            throw XlessError(.account, "\(bundle.identifier) does not have the iCloud capability enabled, so no iCloud container can be assigned to it; nothing was sent",
                             fix: "enable it first with `xless bundle-ids capabilities \(bundle.identifier) enable ICLOUD` (or let `xless sign` enable it), then re-run")
        }
        let adding = wanted.filter { !state.ids.contains($0.id) }
        let unchanged = wanted.filter { state.ids.contains($0.id) }
        if adding.isEmpty, state.enabled {
            if json { return try ASCOutput.json(LinkedChange(bundleId: bundle.identifier, changed: [], unchanged: unchanged.map(\.identifier),
                                                             linked: names(state.ids, all), regeneratedProfiles: [])) }
            return "\(list(unchanged)) \(unchanged.count == 1 ? "is" : "are") already assigned to \(bundle.identifier); nothing was sent\n"
        }
        let after = try await portal.setLinked(state.ids + adding.map(\.id), enabled: true, on: bundle)
        // Nothing to add: the capability lists them already but is disabled, and this run enables it.
        let done = adding.isEmpty ? "enabled \(kind.capabilityName) on \(bundle.identifier), which lists \(list(wanted))"
            : "assigned \(list(adding)) to \(bundle.identifier)"
        let profiles = try await regenerate(bundle.identifier, yes: yes, done: done)
        return try report(done, bundle: bundle, changed: adding.isEmpty ? wanted : adding, unchanged: adding.isEmpty ? [] : unchanged,
                          linked: after.ids, all: all, profiles: profiles)
    }

    func unassign(bundle argument: String, items: [String], yes: Bool) async throws -> String {
        let (all, wanted) = try await resolve(items)
        let bundle = try await portal.bundle(argument)
        let state = try await portal.linked(of: bundle)
        let removing = wanted.filter { state.ids.contains($0.id) }
        let unchanged = wanted.filter { !state.ids.contains($0.id) }
        guard !removing.isEmpty else {
            if json { return try ASCOutput.json(LinkedChange(bundleId: bundle.identifier, changed: [], unchanged: unchanged.map(\.identifier),
                                                             linked: names(state.ids, all), regeneratedProfiles: [])) }
            return "\(list(unchanged)) \(unchanged.count == 1 ? "is" : "are") not assigned to \(bundle.identifier); nothing was sent\n"
        }
        let question = "Unassign \(list(removing)) from \(bundle.identifier)? Apps signed with its profiles from now on lose access to \(removing.count == 1 ? "it" : "them")."
        guard try AccountConfirm.confirm(question, action: "unassigning from \(bundle.identifier)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        let after = try await portal.setLinked(state.ids.filter { id in !removing.contains { $0.id == id } }, enabled: state.enabled, on: bundle)
        let done = "unassigned \(list(removing)) from \(bundle.identifier)"
        let profiles = try await regenerate(bundle.identifier, yes: yes, done: done)
        return try report(done, bundle: bundle, changed: removing, unchanged: unchanged, linked: after.ids, all: all, profiles: profiles)
    }

    func list(_ items: [PortalIdentifier]) -> String { items.map(\.identifier).joined(separator: ", ") }

    func names(_ ids: [String], _ all: [PortalIdentifier]) -> [String] {
        ids.map { id in all.first { $0.id == id }?.identifier ?? id }
    }

    func report(_ done: String, bundle: PortalBundleID, changed: [PortalIdentifier], unchanged: [PortalIdentifier], linked: [String],
                all: [PortalIdentifier], profiles: [ProfileCreated]) throws -> String {
        let now = names(linked, all)
        if json {
            return try ASCOutput.json(LinkedChange(bundleId: bundle.identifier, changed: changed.map(\.identifier), unchanged: unchanged.map(\.identifier),
                                                   linked: now, regeneratedProfiles: profiles))
        }
        var text = "\(done) (\(kind.capabilityName): \(now.isEmpty ? "none" : now.joined(separator: ", ")))\n"
        for p in profiles {
            text += "regenerated profile \(p.profile.name): \(p.replaced ?? "?") → \(p.profile.id)\n"
        }
        if !profiles.isEmpty { text += "download them with `xless profiles download <id> --out <file>`\n" }
        return text
    }

    /// Regenerates the bundle ID's profiles once asked (or --yes). Without an API key, a terminal or a yes, it says what
    /// to run instead: the assignment itself is done either way.
    func regenerate(_ identifier: String, yes: Bool, done: String) async throws -> [ProfileCreated] {
        let later = "`xless sign` regenerates its own profiles; others: `xless profiles list --bundle-id \(identifier)`, then `xless profiles renew <id>`"
        let regen: any ProfileRegenerating
        let profiles: [ASCProfile]
        do {
            regen = try regeneration()
            profiles = try await regen.profiles(of: identifier)
        } catch {
            say("note: the provisioning profiles of \(identifier) were not regenerated (\(XlessError.wrapping(error, stage: .account).cause)); \(later)")
            return []
        }
        if profiles.isEmpty { return [] }
        let listed = profiles.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        let count = "\(profiles.count) provisioning profile\(profiles.count == 1 ? "" : "s")"
        if !yes, terminal() == nil {
            say("note: the \(count) of \(identifier) do not carry the change yet: \(listed); regenerate \(profiles.count == 1 ? "it" : "them") with `xless profiles renew <id>`, or re-run with --yes")
            return []
        }
        let question = "Regenerate the \(count) of \(identifier) (\(listed)) so they carry the change? Each is deleted and created again; files of the old ones stop working."
        guard try AccountConfirm.confirm(question, action: "regenerating profiles", yes: yes, terminal: terminal) else {
            say("profiles not regenerated: \(listed); regenerate them with `xless profiles renew <id>`")
            return []
        }
        // Every profile is tried: one that cannot be made again (no unexpired certificate left…) is left as it is with a
        // note, and a failure after a delete is reported at the end with what was regenerated before it.
        var out: [ProfileCreated] = []
        var failures: [XlessError] = []
        for p in profiles {
            do { out.append(try await regen.renew(p.id)) } catch {
                let e = XlessError.wrapping(error, stage: .account)
                if e.cause.contains("nothing was sent") {
                    say("note: profile \(p.name) (\(p.id)) was not regenerated: \(e.cause) — \(e.fix)")
                } else {
                    failures.append(XlessError(.account, "profile \(p.name) (\(p.id)): \(e.cause)", fix: e.fix))
                }
            }
        }
        guard failures.isEmpty else {
            let regenerated = out.map { "\($0.replaced ?? "?") → \($0.profile.id)" }
            throw XlessError(.account, "\(done)\(regenerated.isEmpty ? "" : " and regenerated profiles \(regenerated.joined(separator: ", "))"), but regenerating failed for "
                                 + failures.map(\.cause).joined(separator: "; "),
                             fix: failures.map(\.fix).joined(separator: "; "))
        }
        return out
    }
}
