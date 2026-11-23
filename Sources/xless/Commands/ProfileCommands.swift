import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessSign

struct ProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "List, create, download, renew and delete provisioning profiles of every type.",
        discussion: """
        Uses the App Store Connect API key (/v1/profiles; creating, renewing and deleting need the Admin role). Types are \
        App Store Connect's (IOS_APP_DEVELOPMENT, IOS_APP_STORE, IOS_APP_ADHOC, IOS_APP_INHOUSE, MAC_APP_DEVELOPMENT, \
        MAC_APP_STORE, MAC_APP_DIRECT, the TVOS_APP_… and MAC_CATALYST_APP_… ones), in any case and with dashes. A profile \
        cannot be edited: `renew` deletes it and creates it again with the same bundle ID, certificates and devices.

          xless profiles list --type ios-app-adhoc --expiring 30
          xless profiles create --type ios-app-development --bundle-id com.example.app
          xless profiles create --type ios-app-adhoc --bundle-id com.example.app --cert-type distribution --devices 00008030-001A35E80C42802E
          xless profiles download 8U3T4X5YZA --out app.mobileprovision
          xless profiles renew 8U3T4X5YZA
        """,
        subcommands: [ProfilesListCommand.self, ProfilesCreateCommand.self, ProfilesDownloadCommand.self, ProfilesRenewCommand.self,
                      ProfilesDeleteCommand.self])
}

/// A `--type` value: an App Store Connect profile type.
enum ProfileTypeArgument {
    static let names = ProfileType.allCases.map(\.argument).joined(separator: ", ")

    static func parse(_ text: String) throws -> ProfileType {
        guard let type = ProfileType(argument: text) else { throw ValidationError("--type \(text) is not a profile type: use one of \(names)") }
        return type
    }
}

/// A profile argument: its ID (`xless profiles list`).
enum ProfileArgument {
    static let help = ArgumentHelp("The profile's ID (see `xless profiles list`).", valueName: "profile-id")

    static func validate(_ text: String) throws {
        guard isASCResourceID(text) else { throw ValidationError("\(text) is not a profile ID (letters and digits, see `xless profiles list`)") }
    }
}

/// Which devices a development or ad hoc profile lists.
enum DeviceSelection: Equatable {
    /// Every enabled device of the profile's platform and kind.
    case all
    /// These devices, by UDID or device ID.
    case some([String])

    static func parse(_ text: String) throws -> DeviceSelection {
        if text.trimmingCharacters(in: .whitespaces).lowercased() == "all" { return .all }
        let items = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.isEmpty, items.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError("--devices takes all, or UDIDs or device IDs separated by commas")
        }
        for item in items where DeviceUDID.kind(item) == nil && !isASCResourceID(item) {
            throw ValidationError("--devices: \(item) is neither a UDID nor a device ID (see `xless devices list`)")
        }
        return .some(items)
    }
}

/// What `create` was asked for, once the arguments are valid.
struct ProfileRequest {
    var type: ProfileType
    var bundleID: String
    var certificateIDs: [String] = []
    var certificateTypes: [CertificateType] = []
    /// nil: every enabled device, for the types that list devices.
    var devices: DeviceSelection?
    var name: String?
}

/// Opens the account session and runs `body` with the profile operations; prints what it returns.
private func runProfiles(_ team: String?, verbose: Bool, _ body: (ProfileCLI, String?) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(ProfileCLI(client: session.client), session.team)
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct ProfilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List the team's profiles: ID, name, type, bundle ID, state and expiry.")

    @Option(name: .customLong("type"), help: ArgumentHelp("Only this type; repeatable.", valueName: "type"))
    var types: [String] = []
    @Option(name: .customLong("bundle-id"), help: ArgumentHelp("Only the profiles of this bundle ID: its identifier or ID.", valueName: "bundle-id"))
    var bundleID: String?
    @Option(help: ArgumentHelp("Only profiles that expire within this many days (or have expired).", valueName: "days"))
    var expiring: Int?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        for type in types { _ = try ProfileTypeArgument.parse(type) }
        if let expiring, expiring < 0 { throw ValidationError("--expiring takes a number of days, 0 or more") }
    }

    func run() async throws {
        var types: [ProfileType] = []
        for type in try self.types.map(ProfileTypeArgument.parse) where !types.contains(type) { types.append(type) }
        try await runProfiles(team.team, verbose: trace.verbose) { cli, _ in
            try await cli.with(json: output.json).list(types: types, bundleID: bundleID, expiringWithin: expiring)
        }
    }
}

struct ProfilesCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a profile of any type for a bundle ID, with certificates and (development, ad hoc) devices.",
        discussion: """
        Certificates: --cert names them by ID, --cert-type takes every unexpired certificate of a type; without either, \
        every unexpired certificate of the types that fit the profile (Apple Development and iOS App Development for an \
        iOS development profile, Apple Distribution and iOS Distribution for App Store, ad hoc and in-house ones, \
        Developer ID Application for MAC_APP_DIRECT…).

        Devices: development and ad hoc profiles list devices. --devices all (the default) takes every enabled device of \
        the profile's platform (Apple TVs for tvOS, the other iOS devices for iOS, Macs for macOS and Mac Catalyst); \
        --devices with UDIDs or device IDs takes those, which must be registered (`xless devices register`) and enabled.

        The name defaults to `xless <identifier> <TYPE>`, the name `sign` uses. A profile of that name must not exist \
        (renew it instead). The create request is sent once, never retried.
        """)

    @Option(help: ArgumentHelp("The profile type (see `xless profiles --help`).", valueName: "type"))
    var type: String
    @Option(name: .customLong("bundle-id"), help: ArgumentHelp("The bundle ID: its identifier (com.example.app) or ID.", valueName: "bundle-id"))
    var bundleID: String
    @Option(name: .customLong("cert"), help: ArgumentHelp("A certificate to include, by ID; repeatable.", valueName: "certificate-id"))
    var certs: [String] = []
    @Option(name: .customLong("cert-type"), help: ArgumentHelp("Include every unexpired certificate of this type; repeatable.", valueName: "type"))
    var certTypes: [String] = []
    @Option(help: ArgumentHelp("all, or UDIDs or device IDs separated by commas (development and ad hoc profiles).", valueName: "all|udid,…"))
    var devices: String?
    @Option(help: ArgumentHelp("The profile's name (default: xless <identifier> <TYPE>).", valueName: "name"))
    var name: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func request() throws -> ProfileRequest {
        let type = try ProfileTypeArgument.parse(type)
        for cert in certs where !isASCResourceID(cert) { throw ValidationError("--cert \(cert) is not a certificate ID (see `xless certs list`)") }
        var types: [CertificateType] = []
        for text in certTypes {
            let certType = try CertificateTypeArgument.parse(text)
            guard type.certificateTypes.contains(certType) else {
                throw ValidationError("a \(type.argument) profile takes \(type.certificateTypes.map(\.argument).joined(separator: " or ")) certificates, not \(certType.argument)")
            }
            if !types.contains(certType) { types.append(certType) }
        }
        if devices != nil, !type.usesDevices { throw ValidationError("a \(type.argument) profile lists no devices: drop --devices") }
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty || name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw ValidationError("--name must not be empty or contain control characters")
        }
        return ProfileRequest(type: type, bundleID: bundleID.trimmingCharacters(in: .whitespaces), certificateIDs: certs, certificateTypes: types,
                              devices: try devices.map(DeviceSelection.parse), name: name)
    }

    func validate() throws { _ = try request() }

    func run() async throws {
        let request = try request()
        try await runProfiles(team.team, verbose: trace.verbose) { cli, _ in try await cli.with(json: output.json).create(request) }
    }
}

struct ProfilesDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Write a profile to a new file, mode 0644, once it is checked to be the team's profile for its bundle ID; never overwrites.",
        discussion: """
        The file must parse as a CMS envelope around a property list whose TeamIdentifier is the team (--team, else the \
        bundle ID's App ID prefix) and whose application-identifier is <prefix>.<bundle identifier>; otherwise nothing \
        is written.
        """)

    @Argument(help: ProfileArgument.help) var profile: String
    @Option(help: ArgumentHelp("The file to create (e.g. app.mobileprovision, app.provisionprofile).", valueName: "file")) var out: String
    @OptionGroup var team: TeamOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try ProfileArgument.validate(profile) }

    func run() async throws {
        try await runProfiles(team.team, verbose: trace.verbose) { cli, team in try await cli.download(profile, to: out, team: team) }
    }
}

struct ProfilesRenewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renew",
        abstract: "Delete a profile and create it again with the same name, type, bundle ID, certificates and devices (asks first).",
        discussion: """
        Profiles cannot be edited, so a new expiry, or a capability enabled on the bundle ID since, needs a new profile. \
        If creating it again fails after the delete, the error gives the `xless profiles create` command that recreates it.
        """)

    @Argument(help: ProfileArgument.help) var profile: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try ProfileArgument.validate(profile) }

    func run() async throws {
        try await runProfiles(team.team, verbose: trace.verbose) { cli, team in try await cli.with(json: output.json).renew(profile, yes: confirmation.yes, team: team) }
    }
}

struct ProfilesDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a profile (asks first). Apple has no undo.")

    @Argument(help: ProfileArgument.help) var profile: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try ProfileArgument.validate(profile) }

    func run() async throws {
        try await runProfiles(team.team, verbose: trace.verbose) { cli, _ in try await cli.with(json: output.json).delete(profile, yes: confirmation.yes) }
    }
}

/// A created (or renewed) profile, for `--json`.
struct ProfileCreated: Encodable {
    let profile: ASCProfile
    let bundleId: String
    let certificates: [String]
    let devices: [String]
    /// The profile `renew` deleted.
    let replaced: String?
}

/// What the profile commands do once their arguments are valid; returns what goes to standard output and says the rest
/// (cancellations) on standard error.
struct ProfileCLI {
    let client: ASCClient
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var now: () -> Date = { Date() }

    var resources: ASCResources { ASCResources(client: client) }
    var profiles: ASCProfiles { ASCProfiles(resources: resources) }

    func with(json: Bool) -> ProfileCLI { var copy = self; copy.json = json; return copy }

    func list(types: [ProfileType], bundleID: String?, expiringWithin days: Int?) async throws -> String {
        var bundle: ASCBundleID?
        if let bundleID { bundle = try await ASCBundleIDs(resources: resources).resolve(bundleID) }
        let listing = try await profiles.list(types: types)
        var list = listing.profiles
        if let bundle { list = list.filter { $0.bundleIDResourceID == bundle.id } }
        if let days {
            let limit = now().addingTimeInterval(Double(days) * 86400)
            list = list.filter { ($0.expires ?? .distantFuture) <= limit }
        }
        if json { return try ASCOutput.json(["data": list]) }
        if list.isEmpty {
            if let days { return "No profile expires within \(days) days.\n" }
            return "This team has no\(types.isEmpty && bundle == nil ? "" : " such") profiles (create one with `xless profiles create --type <type> --bundle-id <identifier>`).\n"
        }
        return TextTable(["ID", "NAME", "TYPE", "BUNDLE ID", "STATE", "EXPIRES"], list.map { p in
            [p.id, p.name, ProfileType(rawValue: p.profileType)?.argument ?? p.profileType, listing.bundleID(of: p)?.identifier ?? "",
             p.attributes.profileState?.lowercased() ?? "", p.expires.map(CertTable.day) ?? ""]
        }).rendered
    }

    func create(_ request: ProfileRequest) async throws -> String {
        let type = request.type
        let bundle = try await ASCBundleIDs(resources: resources).resolve(request.bundleID)
        guard type.accepts(bundlePlatform: bundle.attributes.platform) else {
            throw XlessError(.account, "\(bundle.identifier) is registered for \(BundleIDPlatform.display(bundle.attributes.platform)), which has no \(type.argument) profiles",
                             fix: type.rawValue.hasPrefix("MAC_APP_") ? "use a macOS or universal bundle ID" : "use an iOS or universal bundle ID")
        }
        let certificates = try await pickCertificates(request)
        let devices = type.usesDevices ? try await pickDevices(request.devices ?? .all, for: type) : []
        let name = request.name ?? ProfileService.defaultName(bundleIdentifier: bundle.identifier, type: type)
        if let existing = try await profiles.find(name: name).first {
            throw XlessError(.account, "a profile named \(name) exists already (\(existing.id), \(existing.profileType))",
                             fix: "renew it with `xless profiles renew \(existing.id)`, or choose another --name")
        }
        let created = try await ProfileService(client: client).create(
            name: name, type: type, bundleIDResourceID: bundle.id, certificateIDs: certificates, deviceIDs: devices)
        return try report(ProfileCreated(profile: created, bundleId: bundle.identifier, certificates: certificates, devices: devices, replaced: nil))
    }

    /// The certificate IDs a new profile gets: the named ones (checked), every unexpired one of the asked types, or of
    /// the types that fit the profile.
    func pickCertificates(_ request: ProfileRequest) async throws -> [String] {
        let type = request.type
        let certs = ASCCertificates(resources: resources)
        let fits = type.certificateTypes.map(\.argument).joined(separator: " or ")
        var ids: [String] = []
        for id in request.certificateIDs where !ids.contains(id) {
            let c = try await certs.get(id: id)
            guard let certType = CertificateType(rawValue: c.certificateType), type.certificateTypes.contains(certType) else {
                throw XlessError(.account, "certificate \(id) is \(c.certificateType), which a \(type.argument) profile cannot contain",
                                 fix: "use a \(fits) certificate (`xless certs list`)")
            }
            if let expires = c.expires, expires <= now() {
                throw XlessError(.account, "certificate \(id) expired on \(CertTable.day(expires))", fix: "use another certificate (`xless certs list`)")
            }
            ids.append(id)
        }
        if request.certificateIDs.isEmpty || !request.certificateTypes.isEmpty {
            let types = request.certificateTypes.isEmpty ? type.certificateTypes : request.certificateTypes
            for c in try await certs.list(types: types) where (c.expires ?? .distantFuture) > now() && !ids.contains(c.id) { ids.append(c.id) }
        }
        guard !ids.isEmpty else {
            throw XlessError(.account, "the team has no unexpired \(fits) certificate for a \(type.argument) profile",
                             fix: "create one with `xless certs create --type \(type.certificateTypes[0].argument)`")
        }
        return ids
    }

    /// The device IDs a development or ad hoc profile gets.
    func pickDevices(_ selection: DeviceSelection, for type: ProfileType) async throws -> [String] {
        let registered = try await ASCDevices(resources: resources).list(platform: type.devicePlatform)
        let kind = type.devicePlatform == .macOS ? "Mac" : type.rawValue.hasPrefix("TVOS") ? "Apple TV" : "iOS device"
        switch selection {
        case .all:
            let ids = registered.filter { $0.status == .enabled && type.accepts(deviceClass: $0.attributes.deviceClass) }.map(\.id)
            guard !ids.isEmpty else {
                throw XlessError(.account, "the team has no enabled \(kind) for a \(type.argument) profile",
                                 fix: "register one with `xless devices register <name> <udid>\(type.devicePlatform == .macOS ? " --platform macos" : "")`")
            }
            return ids
        case .some(let items):
            var ids: [String] = []
            for item in items {
                guard let device = ASCDevices.find(udid: item, in: registered) ?? registered.first(where: { $0.id == item }) else {
                    throw XlessError(.account, "\(item) is not a registered \(kind) (\(type.devicePlatform.argument))",
                                     fix: "check `xless devices list --platform \(type.devicePlatform.argument)`, or register it with `xless devices register`")
                }
                guard device.status == .enabled else {
                    throw XlessError(.account, "device \(device.name) (\(device.id)) is disabled", fix: "enable it with `xless devices enable \(device.id)`, or leave it out")
                }
                guard type.accepts(deviceClass: device.attributes.deviceClass) else {
                    throw XlessError(.account, "device \(device.name) (\(device.id)) is \(device.attributes.deviceClass ?? "of another kind"), which a \(type.argument) profile cannot list",
                                     fix: "leave it out")
                }
                if !ids.contains(device.id) { ids.append(device.id) }
            }
            return ids
        }
    }

    func download(_ id: String, to path: String, team: String?) async throws -> String {
        let (p, bundle) = try await profiles.get(id: id, withContent: true)
        guard let content = p.content, !content.isEmpty else {
            throw XlessError(.account, "App Store Connect sent profile \(id) without its content", fix: "re-run; if it persists, renew it with `xless profiles renew \(id)`")
        }
        guard let bundle, let prefix = bundle.attributes.seedId ?? team else {
            throw XlessError(.account, "App Store Connect did not say which bundle ID (and App ID prefix) profile \(id) is for",
                             fix: "re-run; if it persists, check it with `xless profiles list --json`")
        }
        let parsed = try ProvisioningProfile.parse(content)
        do {
            try parsed.verify(team: team ?? prefix, appIDPrefix: prefix, bundleIdentifier: bundle.identifier, uuid: p.attributes.uuid)
        } catch let e as XlessError where team == nil {
            throw XlessError(.account, e.cause, fix: e.fix + "; if the team's ID is not the App ID prefix \(prefix), pass --team <TEAM_ID>")
        }
        do { try SigningKey.writeExclusively(content, toPath: path, mode: 0o644) } catch let e as XlessError {
            throw XlessError(.account, e.cause, fix: "choose another path; xless never overwrites a file")
        }
        return "wrote profile \(p.name) (\(p.id), \(p.profileType)\(p.expires.map { ", expires \(CertTable.day($0))" } ?? "")) to \(path)\n"
    }

    /// Renews a profile: everything it lists that can still go into a profile (its certificates that exist and have
    /// not expired; its devices that are registered, enabled and of its kind) is checked before anything is deleted.
    func renew(_ id: String, yes: Bool, team: String? = nil) async throws -> String {
        let (p, bundle) = try await profiles.get(id: id)
        guard let type = ProfileType(rawValue: p.profileType) else {
            throw XlessError(.account, "profile \(id) has type \(p.profileType), which xless does not know", fix: "renew it at developer.apple.com/account/resources/profiles")
        }
        guard let bundle else {
            throw XlessError(.account, "App Store Connect did not say which bundle ID profile \(id) is for", fix: "re-run; if it persists, check it with `xless profiles list --json`")
        }
        let listedCertificates = try await profiles.certificateIDs(of: id)
        let usableCertificates = Set(try await ASCCertificates(resources: resources).list(types: type.certificateTypes)
            .filter { ($0.expires ?? .distantFuture) > now() }.map(\.id))
        let certificates = listedCertificates.filter(usableCertificates.contains)
        for c in listedCertificates where !usableCertificates.contains(c) { say("left out: certificate \(c) (expired or revoked)") }
        var devices: [String] = []
        var droppedDevices = 0
        if type.usesDevices {
            let listedDevices = try await profiles.deviceIDs(of: id)
            let usableDevices = Set(try await ASCDevices(resources: resources).list(platform: type.devicePlatform)
                .filter { $0.status == .enabled && type.accepts(deviceClass: $0.attributes.deviceClass) }.map(\.id))
            devices = listedDevices.filter(usableDevices.contains)
            droppedDevices = listedDevices.count - devices.count
            for d in listedDevices where !usableDevices.contains(d) { say("left out: device \(d) (disabled, or no longer registered)") }
        }
        let fresh = "create a new one with `xless profiles create --type \(type.argument) --bundle-id \(bundle.identifier)`, then delete this one"
        guard !certificates.isEmpty else {
            throw XlessError(.account, "profile \(p.name) (\(id)) has no unexpired certificate left, so it cannot be created again as it is; nothing was sent", fix: fresh)
        }
        if type.usesDevices, devices.isEmpty {
            throw XlessError(.account, "profile \(p.name) (\(id)) has no enabled device left, so it cannot be created again as it is; nothing was sent",
                             fix: "enable or register devices (`xless devices`) and renew it, or \(fresh)")
        }
        let recreate = Self.createCommand(type: type, bundle: bundle.identifier, certificates: certificates, devices: devices, name: p.name, team: team)
        var question = "Renew \(type.displayName) profile \(p.name) (\(id)) for \(bundle.identifier)? It is deleted and created again with "
        question += "\(certificates.count) certificate\(certificates.count == 1 ? "" : "s")"
        question += type.usesDevices ? " and \(devices.count) device\(devices.count == 1 ? "" : "s")" : ""
        if certificates.count < listedCertificates.count || droppedDevices > 0 {
            question += " (the ones that can no longer be in a profile are left out)"
        }
        question += ". Files of the old profile stop working."
        guard try AccountConfirm.confirm(question, action: "renewing profile \(id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await profiles.delete(id: id)
        let created: ASCProfile
        do {
            created = try await ProfileService(client: client).create(
                name: p.name, type: type, bundleIDResourceID: bundle.id, certificateIDs: certificates, deviceIDs: devices)
        } catch {
            let cause = (error as? XlessError)?.cause ?? (error as? any StageReportableError)?.stageError(.account).cause ?? "\(error)"
            throw XlessError(.account, "profile \(p.name) (\(id)) was deleted, but creating it again failed: \(cause)",
                             fix: "create it again with: \(recreate)")
        }
        return try report(ProfileCreated(profile: created, bundleId: bundle.identifier, certificates: certificates, devices: devices, replaced: id))
    }

    struct Deleted: Encodable { let deleted: String; let name: String; let profileType: String }

    func delete(_ id: String, yes: Bool) async throws -> String {
        let (p, bundle) = try await profiles.get(id: id)
        let type = ProfileType(rawValue: p.profileType)
        let question = "Delete \(type?.displayName ?? p.profileType) profile \(p.name) (\(id))\(bundle.map { " for \($0.identifier)" } ?? "")? Apple has no undo."
        guard try AccountConfirm.confirm(question, action: "deleting profile \(id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await profiles.delete(id: id)
        if json { return try ASCOutput.json(Deleted(deleted: id, name: p.name, profileType: p.profileType)) }
        return "deleted profile \(p.name) (\(id))\n"
    }

    func report(_ created: ProfileCreated) throws -> String {
        if json { return try ASCOutput.json(created) }
        let p = created.profile
        var text = created.replaced.map { "deleted profile \($0); " } ?? ""
        text += "created profile \(p.name) (\(p.id), \(ProfileType(rawValue: p.profileType)?.argument ?? p.profileType)) for \(created.bundleId): "
        text += "\(created.certificates.count) certificate\(created.certificates.count == 1 ? "" : "s")"
        if ProfileType(rawValue: p.profileType)?.usesDevices == true { text += ", \(created.devices.count) device\(created.devices.count == 1 ? "" : "s")" }
        text += p.expires.map { ", expires \(CertTable.day($0))" } ?? ""
        return text + "\ndownload it with `xless profiles download \(p.id) --out <file>`\n"
    }

    /// The `xless profiles create` command line that makes this profile again.
    static func createCommand(type: ProfileType, bundle: String, certificates: [String], devices: [String], name: String, team: String? = nil) -> String {
        var parts = ["xless profiles create", "--type \(type.argument)", "--bundle-id \(shellQuoted(bundle))"]
        parts += certificates.map { "--cert \($0)" }
        if type.usesDevices, !devices.isEmpty { parts.append("--devices \(devices.joined(separator: ","))") }
        // `--name=…` keeps a name that starts with `-` a value.
        parts.append("--name=\(shellQuoted(name))")
        if let team { parts.append("--team \(team)") }
        return parts.joined(separator: " ")
    }

    static func shellQuoted(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-*/".unicodeScalars.contains($0) }
        if plain, !text.isEmpty, !text.contains("*") { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
