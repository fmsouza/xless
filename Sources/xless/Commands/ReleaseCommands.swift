import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessStore

struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Create the App Store version, attach its build, submit it for review and release it (manually, automatically, on a date, phased).",
        discussion: """
        Uses the App Store Connect API key. The app, platform and version default to the appstore/ manifest's \
        (app.yml's bundleID, platform and version; --dir to point elsewhere), else xless.yml's bundle ID and the app's \
        newest version. submit runs a pre-flight first and sends nothing until everything App Review needs is there; \
        run it again after a failure and it resumes where it stopped.

          xless release create 1.2 --app com.example.app
          xless release submit --build 1.2+42 --release manual --phased
          xless release status
          xless release publish
          xless release phased pause
        """,
        subcommands: [ReleaseCreateCommand.self, ReleaseAttachCommand.self, ReleaseSubmitCommand.self, ReleaseStatusCommand.self,
                      ReleaseCancelCommand.self, ReleasePublishCommand.self, ReleasePhasedCommand.self])
}

/// Which app, platform and version: options first, then the manifest, then xless.yml.
struct ReleaseTargetOptions: ParsableArguments {
    @Option(help: ArgumentHelp("The app: app ID or bundle identifier (default: app.yml's bundleID, else --config's or xless.yml's).", valueName: "app"))
    var app: String?
    @Option(help: ArgumentHelp("ios, macos, tvos or visionos (default: app.yml's, else the app's only platform).", valueName: "platform"))
    var platform: String?
    @Option(help: ArgumentHelp("The App Store version, e.g. 1.2 (default: app.yml's version, else the newest).", valueName: "version"))
    var appVersion: String?
    @OptionGroup var directory: StoreDirOption

    func validate() throws {
        if let app { try AppArgumentHelp.validate(app) }
        if let platform, StorePlatform.parse(platform) == nil { throw ValidationError("--platform \(platform): use ios, macos, tvos or visionos") }
        if let appVersion { try ReleaseVersionArgument.validate(appVersion, option: "--app-version") }
    }

    /// app.yml's values when it describes the app asked for (or no app is asked for).
    var manifest: AppYAML? {
        let dir = directory.url
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("app.yml").path) else { return nil }
        let m = ManifestReader.read(dir).manifest.app
        if let app, AppArgument.isAppID(app) || app != (m.bundleID ?? (try? directory.project())??.bundleID(for: m.platform)) { return nil }
        return m
    }

    /// - Parameter manifestVersion: whether app.yml's version is the default version.
    func wanted(manifestVersion: Bool = true) throws -> ReleaseWanted {
        let m = manifest
        let platform = self.platform.flatMap(StorePlatform.parse) ?? m?.platform
        let project = try directory.project()
        guard let app = app ?? m?.bundleID ?? project?.bundleID(for: platform) else {
            throw XlessError(.account, "no app: no --app, no bundleID in \(directory.name)/app.yml and \(directory.noConfig)",
                             fix: "pass --app <app ID or bundle ID> (see `xless apps list`)\(directory.config == nil ? ", or --config <overlay>" : "")")
        }
        let samePlatform = m.map { ($0.platform ?? "IOS") == (platform ?? $0.platform ?? "IOS") } ?? false
        return ReleaseWanted(app: app, platform: platform, version: appVersion ?? (manifestVersion && samePlatform ? m?.version : nil),
                             team: self.app == nil ? project?.team : nil)
    }
}

enum ReleaseVersionArgument {
    static func validate(_ text: String, option: String = "<version>") throws {
        guard text.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil else {
            throw ValidationError("\(option) \(text): use up to three numbers separated by dots, e.g. 1.2 or 1.2.3")
        }
    }
}

/// Opens the account session and runs `body` with the release operations; prints what it returns.
/// - Parameter wanted: its `team` (the project configuration's) is the default team.
private func runRelease(_ team: TeamOption, _ trace: VerboseOption, json: Bool, _ wanted: ReleaseWanted, _ body: (ReleaseCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: team.team, project: wanted.team, verbose: trace.verbose)
        let out = try await body(ReleaseCLI(resources: session.resources, json: json))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct ReleaseCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create the App Store version to submit (or give the version being prepared this version string).",
        discussion: """
        App Store Connect keeps one version in preparation per platform: when there is one, it is renamed to <version>; \
        when the version exists already, nothing is sent. `xless store push` creates the version from app.yml too.
        """)

    @Argument(help: ArgumentHelp("The version string (CFBundleShortVersionString), e.g. 1.2.", valueName: "version")) var version: String
    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        try ReleaseVersionArgument.validate(version)
        if target.appVersion != nil { throw ValidationError("--app-version: create takes the version as its argument") }
    }

    func run() async throws {
        let wanted = try target.wanted(manifestVersion: false)
        try await runRelease(team, trace, json: output.json, wanted) { try await $0.create(app: wanted.app, platform: wanted.platform, versionString: version) }
    }
}

struct ReleaseAttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach a build to the App Store version being prepared.",
        discussion: "The build must be the app's, of the same platform and version string, and not expired. `submit --build` attaches it too.")

    @Argument(help: ArgumentHelp("The build's ID (see `xless builds list`) or <version>+<build number>, e.g. 1.2.0+42.", valueName: "build"))
    var build: String
    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do { _ = try BuildReference.parse(build) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
    }

    func run() async throws {
        let wanted = try target.wanted()
        let reference = try BuildReference.parse(build)
        try await runRelease(team, trace, json: output.json, wanted) { try await $0.attach(wanted, build: reference) }
    }
}

struct ReleaseSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Check that everything App Review needs is there, then submit the version for review.",
        discussion: """
        The pre-flight reads, and reports every missing item at once: the appstore/ manifest valid and pushed (`store \
        push` would send nothing), name, description, keywords and support URL per locale, privacy policy URL, \
        category, content rights, screenshots for the required display types, App Privacy published, a price and \
        availability, the build valid with export compliance answered, the App Review contact. App Privacy has no \
        API: it is checked through an Apple ID web session kept by `xless auth login --keep`, else reported as not \
        checked.

        Then, sending only what App Store Connect does not have yet: the build (--build), the release (--release \
        manual: `xless release publish` releases it; auto: on approval; a date such as 2026-12-01 or \
        2026-12-01T09:00:00Z: not before then), the phased release (--phased, --no-phased), and the review submission \
        (created, the version added, submitted). The in-app purchases and subscriptions the manifest lists (iap/, \
        subscriptions/) go with the version: each one's version being prepared is added to the submission (one ready \
        to submit without such a version is submitted with the app's version); --no-products leaves them out. A \
        submission that stopped half-way is resumed. --dry-run runs the pre-flight and lists the steps.

        Exit codes: 0 submitted (or a dry run that passed), 21 the pre-flight failed (nothing was sent), 22 the version \
        is already in review (nothing was sent), 20 any other error.
        """)

    @OptionGroup var target: ReleaseTargetOptions
    @Option(help: ArgumentHelp("The build to submit: its ID or <version>+<build number> (default: the one attached).", valueName: "build"))
    var build: String?
    @Option(help: ArgumentHelp("manual, auto, or a date (2026-12-01, 2026-12-01T09:00:00Z): when the approved version is released.", valueName: "when"))
    var release: String?
    @Flag(inversion: .prefixedNo, help: "Release to users over 7 days (--no-phased removes a phased release that has not started).")
    var phased: Bool?
    @Flag(inversion: .prefixedNo, help: "Submit the manifest's in-app purchases and subscriptions with the version (default).")
    var products = true
    @Flag(help: "Run the pre-flight and list what would be sent; send nothing.") var dryRun = false
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if let build { do { _ = try BuildReference.parse(build) } catch let e as IdentifierInputError { throw ValidationError(e.description) } }
        if let release { do { _ = try ReleaseChoice.parse(release) } catch let e as IdentifierInputError { throw ValidationError(e.description) } }
    }

    func run() async throws {
        let wanted = try target.wanted()
        let dir = target.directory.url
        // The manifest is checked only when it describes this app and platform (else the pre-flight says it skipped it).
        let m = target.manifest
        let manifest: URL? = if let m, wanted.platform == nil || wanted.platform == (m.platform ?? "IOS") { dir } else if m == nil, !FileManager.default.fileExists(atPath: dir.path) { dir } else { nil }
        var options = ReleaseCLI.SubmitOptions(build: try build.map(BuildReference.parse), release: try release.map { try ReleaseChoice.parse($0) },
                                               phased: phased, manifestDir: manifest, dryRun: dryRun)
        options.products = products
        if manifest != nil, ManifestReader.read(dir).manifest.app.bundleID == nil {
            options.inheritedBundleID = try target.directory.project()?.bundleID(for: wanted.platform)
        }
        let (team, project, verbose, json) = (team.team, wanted.team, trace.verbose, output.json)
        let exit: Int32 = try await AccountSession.run {
            let session = try AccountSession.open(team: team, project: project, verbose: verbose)
            // App Privacy has no API: checked only through a session `xless auth login --keep` kept; never a sign-in here.
            var web: (session: AppleWebSession, transport: URLSessionAppleTransport)?
            if AppleWebCLI.cache.info() != nil {
                do { web = try await ReleaseWeb.kept(team: session.team, verbose: verbose) } catch {
                    StorePushCLI.standardError("note: the kept Apple ID web session could not be used (\(XlessError.wrapping(error, stage: .account).cause)); App Privacy is not checked")
                }
            }
            defer { web?.transport.invalidate() }
            let cli = ReleaseCLI(resources: session.resources, json: json)
            let (text, exit) = try await cli.submit(wanted, options: options, privacy: web.map { ASCWebPrivacy(asc: $0.session.asc) })
            if let web { await web.session.end() }
            FileHandle.standardOutput.write(Data(text.utf8))
            return exit
        }
        if exit != 0 { throw ExitCode(exit) }
    }
}

/// The Apple ID web session `xless auth login --keep` kept, for the privacy check; never a sign-in.
enum ReleaseWeb {
    static func kept(team: String?, verbose: Bool) async throws -> (session: AppleWebSession, transport: URLSessionAppleTransport) {
        SecretScope.enter()
        let (client, transport) = AppleWebCLI.client(verbose: verbose)
        do {
            let session = try await AppleWebSession.open(web: client, cache: AppleWebCLI.cache) {
                throw XlessError(.account, "the kept session has expired", fix: "`xless auth login --keep`")
            }
            let selected = try await session.selectTeam(team)
            try await session.useProvider(for: selected, choose: AppleWebCLI.chooser())
            return (session, transport)
        } catch {
            transport.invalidate()
            throw error
        }
    }
}

struct ReleaseStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the version's state, release type, build, phased release and review submissions.",
        discussion: """
        App Review's reasons for a rejection are not in the App Store Connect API: status says that the version was \
        rejected (and which items); Apple emails the reasons to the account holder and the admins.
        """)

    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        let wanted = try target.wanted()
        try await runRelease(team, trace, json: output.json, wanted) { try await $0.status(wanted) }
    }
}

struct ReleaseCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Withdraw the version from App Review (asks first): its review submission is canceled.",
        discussion: "The version can be changed and submitted again afterwards (`xless release submit`).")

    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var account: AccountOptions

    func run() async throws {
        let wanted = try target.wanted()
        let yes = account.confirmation.yes
        try await runRelease(account.team, account.trace, json: account.output.json, wanted) { try await $0.cancel(wanted, yes: yes) }
    }
}

struct ReleasePublishCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Release a version App Review approved and that waits for a manual release.",
        discussion: "Defaults to the version waiting for its release. A version already released is reported and nothing is sent.")

    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        let wanted = try target.wanted(manifestVersion: false)
        try await runRelease(team, trace, json: output.json, wanted) { try await $0.publish(wanted) }
    }
}

struct ReleasePhasedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phased",
        abstract: "Pause, resume or complete the phased release of the version on the App Store.",
        discussion: """
        A phased release gives the update to more users each day over 7 days. pause holds it (up to 30 days in all), \
        resume goes on, complete gives it to everyone now. Defaults to the newest released version.
        """,
        subcommands: [ReleasePhasedPauseCommand.self, ReleasePhasedResumeCommand.self, ReleasePhasedCompleteCommand.self])
}

/// The options of the three phased commands.
struct ReleasePhasedOptions: ParsableArguments {
    @OptionGroup var target: ReleaseTargetOptions
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run(_ action: ReleaseCLI.PhasedAction) async throws {
        let wanted = try target.wanted(manifestVersion: false)
        try await runRelease(team, trace, json: output.json, wanted) { try await $0.phased(action, wanted) }
    }
}

struct ReleasePhasedPauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause the phased release.")
    @OptionGroup var options: ReleasePhasedOptions
    func run() async throws { try await options.run(.pause) }
}

struct ReleasePhasedResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume a paused phased release.")
    @OptionGroup var options: ReleasePhasedOptions
    func run() async throws { try await options.run(.resume) }
}

struct ReleasePhasedCompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "complete", abstract: "Give the update to every user now.")
    @OptionGroup var options: ReleasePhasedOptions
    func run() async throws { try await options.run(.complete) }
}
