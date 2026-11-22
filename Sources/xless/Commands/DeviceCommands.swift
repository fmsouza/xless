import ArgumentParser
import Foundation
import XlessASC
import XlessCore

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List and register the devices that development and ad hoc profiles run on; rename, enable or disable them.",
        discussion: """
        Uses the App Store Connect API key (/v1/devices; the key needs the Admin role). Apple never deletes a device: \
        disable it instead. Apple allows 100 devices of each kind (iPhone, iPad, Apple Watch, Apple TV, Apple Vision Pro, \
        Mac) per membership year, and a disabled device keeps its slot until the list is reset when the membership renews.

          xless devices list --platform ios --status enabled
          xless devices register "Fred's iPhone" 00008030-001A35E80C42802E
          xless devices import devices.txt
          xless devices disable 00008030-001A35E80C42802E
        """,
        subcommands: [DevicesListCommand.self, DevicesRegisterCommand.self, DevicesImportCommand.self,
                      DevicesEnableCommand.self, DevicesDisableCommand.self, DevicesRenameCommand.self])
}

struct DevicePlatformOption: ParsableArguments {
    @Option(help: ArgumentHelp("ios (iPhone, iPad, Apple Watch, Apple TV, Apple Vision Pro) or macos.", valueName: "platform"))
    var platform: String?

    var value: DevicePlatform? { platform.flatMap(DevicePlatform.init(argument:)) }

    func validate() throws {
        if let platform, DevicePlatform(argument: platform) == nil { throw ValidationError("--platform \(platform): use ios or macos") }
    }
}

/// A device argument: its ID (`xless devices list`) or its UDID.
enum DeviceArgument {
    static let help = ArgumentHelp("The device's ID (see `xless devices list`) or its UDID.", valueName: "device")

    static func validate(_ text: String) throws {
        guard DeviceUDID.kind(text) != nil || ASCDevices.isDeviceID(text) else {
            throw ValidationError("\(text) is neither a device ID (letters and digits, see `xless devices list`) nor a UDID")
        }
    }
}

/// Opens the account session and runs `body` with the device operations; prints what it returns.
private func runDevices(_ team: String?, verbose: Bool, _ body: (DeviceCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(DeviceCLI(devices: ASCDevices(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct DevicesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's registered devices: ID, name, UDID, platform, kind, model, status and date added.",
        discussion: "Without --status, also warns (on standard error) about each kind of device that has 90 or more of its 100 yearly slots used.")

    @OptionGroup var platform: DevicePlatformOption
    @Option(help: ArgumentHelp("enabled or disabled.", valueName: "status"))
    var status: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if let status, DeviceStatus(argument: status) == nil { throw ValidationError("--status \(status): use enabled or disabled") }
    }

    func run() async throws {
        try await runDevices(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).list(platform: platform.value, status: status.flatMap(DeviceStatus.init(argument:)))
        }
    }
}

struct DevicesRegisterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Register a device by name and UDID; a UDID that is already registered is reported, never registered twice.",
        discussion: """
        The UDID is checked before anything is sent: 40 hex digits or 8-16 hex digits joined by a dash for an iPhone or \
        iPad, a hardware UUID (8-4-4-4-12) for a Mac. The platform follows from the UDID; an Apple-silicon Mac's \
        provisioning UDID (the 8-16 form) needs --platform macos.
        """)

    @Argument(help: "The device's name, as profiles and the portal will show it.")
    var name: String
    @Argument(help: "The device's UDID.")
    var udid: String
    @OptionGroup var platform: DevicePlatformOption
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("the device's name is empty") }
        do { _ = try DeviceUDID.validate(udid, platform: platform.value) } catch let e as DeviceInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let (udid, platform) = try DeviceUDID.validate(udid, platform: platform.value)
        try await runDevices(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).register(name: name.trimmingCharacters(in: .whitespaces), udid: udid, platform: platform)
        }
    }
}

struct DevicesImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Register every device of a device file (Apple's tab-separated format), skipping those already registered.",
        discussion: """
        The file is the developer portal's: one device per line, tab-separated `Device ID`, `Device Name` and optionally \
        `Device Platform` (ios or mac), with or without the header line. Every line is checked before anything is sent. \
        The new devices are listed and xless asks before registering them (or needs --yes), since each one uses a yearly \
        slot. A failure stops the import and says which devices were registered; re-running it skips them.
        """)

    @Argument(help: ArgumentHelp("The device file, or - for standard input.", valueName: "file"))
    var file: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            let entries = try DeviceCLI.readDeviceFile(file)
            let session = try AccountSession.open(team: team.team, verbose: trace.verbose)
            let out = try await DeviceCLI(devices: ASCDevices(resources: session.resources), json: output.json)
                .importDevices(entries, yes: confirmation.yes)
            FileHandle.standardOutput.write(Data(out.utf8))
        }
    }
}

struct DevicesEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a disabled device, so that new development and ad hoc profiles can include it.")

    @Argument(help: DeviceArgument.help) var device: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try DeviceArgument.validate(device) }

    func run() async throws {
        try await runDevices(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).setStatus(device, to: .enabled, yes: true) }
    }
}

struct DevicesDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a device (asks first): profiles stop including it. Apple has no delete, and the device keeps its yearly slot.")

    @Argument(help: DeviceArgument.help) var device: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { try DeviceArgument.validate(device) }

    func run() async throws {
        try await runDevices(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).setStatus(device, to: .disabled, yes: confirmation.yes)
        }
    }
}

struct DevicesRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a registered device.")

    @Argument(help: DeviceArgument.help) var device: String
    @Argument(help: ArgumentHelp("The device's new name.", valueName: "new-name")) var newName: String
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        try DeviceArgument.validate(device)
        if newName.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("the new name is empty") }
    }

    func run() async throws {
        try await runDevices(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).rename(device, to: newName.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// What the device commands do once their arguments are valid; returns what goes to standard output and says the rest
/// (warnings, cancellations) on standard error.
struct DeviceCLI {
    let devices: ASCDevices
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func with(json: Bool) -> DeviceCLI { var copy = self; copy.json = json; return copy }

    func list(platform: DevicePlatform?, status: DeviceStatus?) async throws -> String {
        let list = try await devices.list(platform: platform, status: status)
        // A status filter hides devices that still use a slot, so the counts would be wrong.
        if status == nil { DeviceLimit.warnings(list).forEach(say) }
        return json ? try ASCOutput.json(["data": list]) : DeviceTable.render(list)
    }

    func register(name: String, udid: String, platform: DevicePlatform) async throws -> String {
        let existing = try await devices.list()
        let result = try await devices.register(name: name, udid: udid, platform: platform, existing: existing)
        var report = DeviceImport.Report()
        switch result {
        case .registered(let d):
            report.registered = [d]
            DeviceLimit.warnings(existing + [d]).forEach(say)
        case .existing(let d):
            report.existing = [d]
        }
        if json { return try ASCOutput.json(report) }
        let d = result.device
        switch result {
        case .registered:
            return "registered \(d.name) (\(d.udid)) as device \(d.id)\n"
        case .existing:
            var text = "already registered as \(d.name) (device \(d.id), \(d.attributes.status?.lowercased() ?? "status unknown")); nothing was sent\n"
            if d.status == .disabled { text += "it is disabled: enable it with `xless devices enable \(d.id)`\n" }
            return text
        }
    }

    func importDevices(_ entries: [DeviceFileEntry], yes: Bool) async throws -> String {
        let existing = try await devices.list()
        let (new, _) = DeviceImport.plan(entries, existing: existing)
        if !new.isEmpty {
            for entry in new { say("to register: \(entry.name)  \(entry.udid)  \(entry.platform.argument)") }
            let count = "\(new.count) device\(new.count == 1 ? "" : "s")"
            let question = "Register \(count)? Each uses one of the team's yearly device slots, even if disabled later."
            guard try AccountConfirm.confirm(question, action: "registering \(count)", yes: yes, terminal: terminal) else {
                say("cancelled; nothing was sent")
                return ""
            }
        }
        let report = try await DeviceImport.run(entries, existing: existing, devices: devices)
        DeviceLimit.warnings(existing + report.registered).forEach(say)
        if json { return try ASCOutput.json(report) }
        let rows = report.registered.map { ("registered", $0) } + report.existing.map { ("already registered", $0) }
        return TextTable(["RESULT", "ID", "NAME", "UDID", "PLATFORM"],
                         rows.map { [$0.0, $0.1.id, $0.1.name, $0.1.udid, DevicePlatform.display($0.1.attributes.platform)] }).rendered
    }

    func setStatus(_ argument: String, to status: DeviceStatus, yes: Bool) async throws -> String {
        let device = try await devices.resolve(argument)
        let verb = status == .enabled ? "enabled" : "disabled"
        if device.status == status {
            if json { return try ASCOutput.json(device) }
            return "\(device.name) (device \(device.id)) is already \(verb); nothing was sent\n"
        }
        if status == .disabled {
            let question = "Disable \(device.name) (\(device.udid))? Profiles stop including it, and it keeps its yearly device slot."
            guard try AccountConfirm.confirm(question, action: "disabling device \(device.id)", yes: yes, terminal: terminal) else {
                say("cancelled; nothing was sent")
                return ""
            }
        }
        let updated = try await devices.update(device, status: status)
        return json ? try ASCOutput.json(updated) : "\(verb) \(updated.name) (device \(updated.id))\n"
    }

    func rename(_ argument: String, to name: String) async throws -> String {
        let device = try await devices.resolve(argument)
        if device.name == name {
            if json { return try ASCOutput.json(device) }
            return "device \(device.id) is already named \(name); nothing was sent\n"
        }
        let updated = try await devices.update(device, name: name)
        return json ? try ASCOutput.json(updated) : "renamed device \(updated.id) from \(device.name) to \(updated.name)\n"
    }

    /// The devices of a device file (or standard input for `-`); a bad file is refused before anything is sent.
    static func readDeviceFile(_ path: String, stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) throws -> [DeviceFileEntry] {
        let data: Data
        if path == "-" { data = stdin() } else {
            guard let d = FileManager.default.contents(atPath: path) else {
                throw XlessError(.account, "cannot read \(path)", fix: "check the path of the device file")
            }
            data = d
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw XlessError(.account, "\(path) is not UTF-8 text", fix: "save the device file as UTF-8 (tab-separated: UDID, name, optional platform)")
        }
        do { return try DeviceFile.parse(text) } catch let e as DeviceInputError {
            throw XlessError(.account, "\(path == "-" ? "the device file" : path): \(e.messages.joined(separator: "; "))",
                             fix: "fix the file (one device per line: UDID<tab>name[<tab>ios|mac]) and re-run; nothing was sent")
        }
    }
}

enum DeviceTable {
    static func render(_ devices: [ASCDevice]) -> String {
        TextTable(["ID", "NAME", "UDID", "PLATFORM", "CLASS", "MODEL", "STATUS", "ADDED"], devices.map { d in
            [d.id, d.name, d.udid, DevicePlatform.display(d.attributes.platform), d.attributes.deviceClass ?? "", d.attributes.model ?? "",
             d.attributes.status?.lowercased() ?? "", String((d.attributes.addedDate ?? "").prefix(10))]
        }).rendered
    }
}
