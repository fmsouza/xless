import ArgumentParser
import Foundation
import XlessASC
import XlessCore

struct BuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builds",
        abstract: "List and inspect uploaded builds, wait for their processing, answer export compliance and expire them.",
        discussion: """
        Uses the App Store Connect API key (/v1/builds). A build is named by its ID (from `xless builds list`) or by \
        its version and build number, `<version>+<build number>` (e.g. 1.2.0+42); --app and --platform narrow that \
        lookup when two apps or two platforms have the same numbers.

          xless builds list --app com.example.app
          xless builds show 1.2.0+42 --app com.example.app
          xless builds wait 1.2.0+42 --app com.example.app --timeout 2h
          xless builds update 1.2.0+42 --app com.example.app --uses-non-exempt-encryption false
          xless builds expire 1.1.0+17 --app com.example.app
        """,
        subcommands: [BuildsListCommand.self, BuildsShowCommand.self, BuildsWaitCommand.self, BuildsUpdateCommand.self, BuildsExpireCommand.self])
}

/// The build argument and what narrows its lookup.
struct BuildSelection: ParsableArguments {
    @Argument(help: ArgumentHelp("The build's ID (see `xless builds list`) or <version>+<build number>, e.g. 1.2.0+42.", valueName: "build"))
    var build: String
    @Option(help: ArgumentHelp("The app (app ID or bundle identifier) whose build it is.", valueName: "app")) var app: String?
    @OptionGroup var platform: BuildPlatformOption

    var reference: BuildReference { (try? BuildReference.parse(build)) ?? .id(build) }

    func validate() throws {
        do { _ = try BuildReference.parse(build) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        if let app { try AppArgumentHelp.validate(app) }
    }
}

struct BuildPlatformOption: ParsableArguments {
    @Option(help: ArgumentHelp("ios, macos, tvos or visionos.", valueName: "platform")) var platform: String?

    var value: BuildPlatform? { platform.flatMap(BuildPlatform.init(argument:)) }

    func validate() throws {
        if let platform, BuildPlatform(argument: platform) == nil { throw ValidationError("--platform \(platform): use ios, macos, tvos or visionos") }
    }
}

/// Opens the account session and runs `body` with the build operations; prints what it returns.
private func runBuilds(_ team: String?, verbose: Bool, _ body: (BuildCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team, verbose: verbose)
        let out = try await body(BuildCLI(builds: ASCBuilds(resources: session.resources)))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct BuildsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List builds, most recently uploaded first: version, build number, platform, processing state and export compliance.",
        discussion: "Expired builds are left out unless --expired is given, which lists only them.")

    @Option(help: ArgumentHelp("Only this app's builds (app ID or bundle identifier).", valueName: "app")) var app: String?
    @Option(help: ArgumentHelp("Only builds of this version (CFBundleShortVersionString), e.g. 1.2.0.", valueName: "version")) var appVersion: String?
    @Option(help: ArgumentHelp("Only builds with this build number (CFBundleVersion).", valueName: "number")) var buildNumber: String?
    @OptionGroup var platform: BuildPlatformOption
    @Option(name: .customLong("state"), help: ArgumentHelp("processing, valid, invalid or failed; repeatable or comma-separated.", valueName: "state"))
    var states: [String] = []
    @Flag(help: "List only the expired builds.") var expired = false
    @Option(help: ArgumentHelp("At most this many builds.", valueName: "n")) var limit: Int = 50
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if let app { try AppArgumentHelp.validate(app) }
        _ = try parsedStates()
        guard (1...10_000).contains(limit) else { throw ValidationError("--limit \(limit): use 1 to 10000") }
        for (name, value) in [("--app-version", appVersion), ("--build-number", buildNumber)] {
            if let value, value.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) == nil {
                throw ValidationError("\(name) \(value): use numbers separated by dots, e.g. 1.2.0")
            }
        }
    }

    func parsedStates() throws -> [BuildState] {
        var out: [BuildState] = []
        for text in states.flatMap({ $0.split(separator: ",").map(String.init) }) {
            guard let s = BuildState(argument: text) else { throw ValidationError("--state \(text): use processing, valid, invalid or failed") }
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    func run() async throws {
        let filter = BuildFilter(appVersion: appVersion, number: buildNumber, platform: platform.value, states: try parsedStates(), expired: expired)
        try await runBuilds(team.team, verbose: trace.verbose) { try await $0.with(json: output.json).list(app: app, filter: filter, limit: limit) }
    }
}

struct BuildsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one build: version, processing state, expiry, export compliance, encryption declaration and TestFlight states.")

    @OptionGroup var selection: BuildSelection
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runBuilds(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).show(selection.reference, app: selection.app, platform: selection.platform.value)
        }
    }
}

struct BuildsWaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until App Store Connect has processed a build; fails when processing ends invalid or failed.",
        discussion: """
        Reads the build every 30 seconds and says each state change on standard error. A <version>+<build number> that \
        is not visible yet (a build that was just uploaded) is looked up until it appears. Only reads: Ctrl-C stops \
        waiting (exit 130) and changes nothing. Exits 0 once the build is valid; an invalid or failed build, or the \
        timeout, is an error (exit 20).
        """)

    @OptionGroup var selection: BuildSelection
    @Option(help: ArgumentHelp("How long to wait: 90s, 30m, 2h or seconds (at most 24h).", valueName: "duration")) var timeout: String = "60m"
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do { _ = try WaitTimeout.seconds(timeout) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let seconds = try WaitTimeout.seconds(timeout)
        let (team, verbose, json) = (team.team, trace.verbose, output.json)
        let (reference, app, platform) = (selection.reference, selection.app, selection.platform.value)
        let flag = Interrupt.Flag()
        do {
            try await AccountSession.run {
                // The session (and a passphrase the secret store may ask) and --app come first: Ctrl-C covers the poll only.
                let session = try AccountSession.open(team: team, verbose: verbose)
                let builds = ASCBuilds(resources: session.resources)
                let appID = try await BuildCLI(builds: builds).appID(app)
                let out = try await Interrupt.cancelling(flag: flag) {
                    try await BuildCLI(builds: builds).with(json: json).wait(reference, appID: appID, platform: platform, timeout: seconds)
                }
                FileHandle.standardOutput.write(Data(out.utf8))
            }
        } catch where flag.interrupted {
            FileHandle.standardError.write(Data("stopped waiting for build \(reference); nothing was changed (Apple keeps processing it: re-run `xless builds wait \(reference)` to wait again)\n".utf8))
            throw ExitCode(130)
        }
    }
}

struct BuildsUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Answer a build's export compliance: whether it uses non-exempt encryption, or which encryption declaration covers it.",
        discussion: """
        For builds uploaded without ITSAppUsesNonExemptEncryption in their Info.plist (Apple refuses the answer when the \
        Info.plist gives it). --encryption-declaration attaches one of the app's existing encryption declarations (its \
        ID; `xless store push` creates them from app.yml). Only what differs from the build is sent.
        """)

    @OptionGroup var selection: BuildSelection
    @Option(help: ArgumentHelp("true or false: whether the build uses encryption that is not exempt from export rules.", valueName: "bool"))
    var usesNonExemptEncryption: String?
    @Option(help: ArgumentHelp("The ID of one of the app's encryption declarations to attach.", valueName: "id")) var encryptionDeclaration: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        guard usesNonExemptEncryption != nil || encryptionDeclaration != nil else {
            throw ValidationError("nothing to update: pass --uses-non-exempt-encryption or --encryption-declaration")
        }
        _ = try encryption()
        if let encryptionDeclaration, !isASCResourceID(encryptionDeclaration) {
            throw ValidationError("--encryption-declaration \(encryptionDeclaration) is not an App Store Connect ID (letters and digits)")
        }
    }

    func encryption() throws -> Bool? {
        guard let usesNonExemptEncryption else { return nil }
        switch usesNonExemptEncryption.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: throw ValidationError("--uses-non-exempt-encryption \(usesNonExemptEncryption): use true or false")
        }
    }

    func run() async throws {
        let value = try encryption()
        try await runBuilds(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).update(selection.reference, app: selection.app, platform: selection.platform.value,
                                                        usesNonExemptEncryption: value, declaration: encryptionDeclaration)
        }
    }
}

struct BuildsExpireCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expire",
        abstract: "Expire a build (asks first): testers can no longer install it. It cannot be undone.")

    @OptionGroup var selection: BuildSelection
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await runBuilds(team.team, verbose: trace.verbose) {
            try await $0.with(json: output.json).expire(selection.reference, app: selection.app, platform: selection.platform.value, yes: confirmation.yes)
        }
    }
}
