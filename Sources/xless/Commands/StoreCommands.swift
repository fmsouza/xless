import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessAppleID
import XlessASC
import XlessCore
import XlessStore

struct StoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "Keep the App Store listing in an appstore/ directory: pull it from App Store Connect, validate it, push it back.",
        discussion: """
        The listing (text per locale, screenshots, previews, categories, age rating, review contact, licence agreement, \
        price and availability, App Privacy) lives in appstore/ next to the project, reviewed like code: \
        docs/appstore-manifest.md. pull reads an existing app's listing with the App Store Connect API key; validate \
        checks the directory offline; push sends what differs. App Privacy has no API: `store privacy pull` reads it with \
        the Apple ID web session, and push sends it the same way.

          xless store pull --app com.example.app
          xless store privacy pull
          xless store validate
          xless store push --dry-run
        """,
        subcommands: [StorePullCommand.self, StoreValidateCommand.self, StorePushCommand.self, StorePrivacyCommand.self])
}

/// `--dir` and `--config` shared by the store and release commands.
struct StoreDirOption: ParsableArguments {
    @Option(help: ArgumentHelp("The manifest directory (default: appstore/ next to --config, else ./appstore).", valueName: "dir"))
    var dir: String?
    @Option(help: ArgumentHelp("The app's overlay (type: tauri, cargo or react-native): its bundle ID and team are the default when app.yml has no bundleID and --team is not given (default: the xless.yml next to the manifest directory).",
                               valueName: "file"))
    var config: String?

    var configURL: URL? { config.map { URL(fileURLWithPath: $0).standardizedFileURL } }

    var url: URL {
        if let dir { return URL(fileURLWithPath: dir).standardizedFileURL }
        if let configURL { return configURL.deletingLastPathComponent().appendingPathComponent("appstore") }
        return URL(fileURLWithPath: "appstore").standardizedFileURL
    }

    /// How messages name the directory.
    var name: String { dir ?? (config == nil ? "appstore" : url.path) }

    /// The project configuration the manifest inherits from: the overlay (its errors stop the command), else the
    /// xless.yml next to the directory, else none.
    func project() throws -> StoreProject? {
        if let configURL { return try StoreProject.overlay(configURL) }
        return StoreProject.nextTo(manifestDir: url)
    }

    /// What to say when no app is known.
    var noConfig: String { config == nil ? "no xless.yml next to it" : "no bundle ID in \(config!) for this platform" }
}

enum StorePlatform {
    /// `ios`, `macos`, `tvos`, `visionos` (or the API value) → App Store Connect's platform.
    static func parse(_ text: String) -> String? {
        switch text.lowercased().replacingOccurrences(of: "_", with: "") {
        case "ios": "IOS"
        case "macos", "mac": "MAC_OS"
        case "tvos": "TV_OS"
        case "visionos": "VISION_OS"
        default: nil
        }
    }

}

struct StorePullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Write an app's App Store listing, as App Store Connect has it, to the appstore/ directory.",
        discussion: """
        Reads, with the App Store Connect API key: the app record, its app info (categories, age rating, name, subtitle \
        and privacy URLs per locale), one App Store version (copyright, release type, phased release, App Review \
        contact and notes, description, keywords, what's new, promotional text, support and marketing URLs per locale, \
        screenshots and previews), the licence agreement, export compliance, accessibility, price and availability. \
        The demo account's password is never read: app.yml names the secret that holds it (passwordSecret).

        The version is the one being prepared if there is one, else the live one (--editable, --live or --app-version \
        to choose); the platform is the manifest's, else the only one the app has (--platform to choose).

        The directory is replaced as a whole once everything is read, so a failure leaves it as it was. Files the format \
        does not own (a README, notes), unknown app.yml keys and the App Privacy answers (privacy:, which `xless store \
        privacy pull` writes) are kept. Screenshots are \
        downloaded from App Store Connect, except those media.lock records as the local original of the same upload.
        """)

    @OptionGroup var directory: StoreDirOption
    @Option(help: ArgumentHelp("The app: its app ID or bundle identifier (default: app.yml's bundleID, else --config's or xless.yml's).", valueName: "app"))
    var app: String?
    @Option(help: ArgumentHelp("ios, macos, tvos or visionos.", valueName: "platform")) var platform: String?
    @Option(help: ArgumentHelp("The App Store version to read, e.g. 1.2.", valueName: "version")) var appVersion: String?
    @Flag(help: "Read the version on the App Store.") var live = false
    @Flag(help: "Read the version being prepared.") var editable = false
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        if [appVersion != nil, live, editable].filter({ $0 }).count > 1 { throw ValidationError("choose one of --app-version, --live and --editable") }
        if let platform, StorePlatform.parse(platform) == nil { throw ValidationError("--platform \(platform): use ios, macos, tvos or visionos") }
        if let app { try AppArgumentHelp.validate(app) }
    }

    var selection: StorePull.Selection {
        if let appVersion { return .version(appVersion) }
        return live ? .live : editable ? .editable : .automatic
    }

    func run() async throws {
        let dir = directory.url
        try await AccountSession.run {
            let existing = ManifestReader.read(dir).manifest.app
            let platform = self.platform.flatMap(StorePlatform.parse)
            let project = try directory.project()
            guard let wanted = app ?? existing.bundleID ?? project?.bundleID(for: platform ?? existing.platform) else {
                throw XlessError(.account, "no app to pull: no --app, no bundleID in \(directory.name)/app.yml and \(directory.noConfig)",
                                 fix: "pass --app <app ID or bundle ID> (see `xless apps list`)\(directory.config == nil ? ", or --config <overlay>" : "")")
            }
            // The project's team goes with the project's app, not with an app named by --app.
            let session = try AccountSession.open(team: team.team, project: app == nil ? project?.team : nil, verbose: trace.verbose)
            let found = try await ASCApps(resources: session.resources).resolve(wanted)
            let client = session.client
            let pull = StorePull(resources: session.resources, download: { url, file in try await StoreDownload.fetch(url, to: file, client: client) },
                                 say: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
            let report = try await pull.run(app: found, platform: platform, selection: selection, into: dir)
            print(output.json ? try ASCOutput.json(report) : report.text, terminator: "")
        }
    }
}

enum StoreDownload {
    /// A media file from App Store Connect's delivery network into a new file at `file`, written as it arrives (a
    /// preview can be large): https only, no credentials sent, retried like API calls, each attempt starting the file
    /// again.
    static func fetch(_ url: URL, to file: URL, client: ASCClient) async throws {
        guard url.scheme == "https" else {
            throw XlessError(.account, "App Store Connect gave a media URL that is not https", fix: "re-run; if it persists, report it")
        }
        var sink: FileSink?
        defer { sink?.close() }
        do {
            try await client.download(URLRequest(url: url)) {
                sink?.close()
                let fresh = try FileSink(file)
                sink = fresh
                return { try fresh.write($0) }
            }
        } catch let e as ASCError {
            throw XlessError(.account, "downloading \(url.lastPathComponent) from App Store Connect failed (HTTP \(e.status))",
                             fix: "re-run `xless store pull`; nothing was changed")
        } catch let e as FileSink.WriteError {
            throw XlessError(.account, "writing \(url.lastPathComponent) failed: \(e.description)", fix: "check the free space, then re-run `xless store pull`; nothing was changed")
        }
    }

    /// One download attempt's file: created empty (or emptied), written piece by piece.
    final class FileSink: @unchecked Sendable {
        struct WriteError: Error, CustomStringConvertible { let description: String }
        private let handle: FileHandle
        private let lock = NSLock()

        init(_ file: URL) throws {
            let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw WriteError(description: String(cString: strerror(errno))) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        func write(_ data: Data) throws {
            do { try lock.withLock { try handle.write(contentsOf: data) } } catch { throw WriteError(description: "\(error.localizedDescription)") }
        }

        func close() { lock.withLock { try? handle.close() } }
    }
}

struct StoreValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check the appstore/ directory offline: lengths, URLs, locales, screenshot sizes, what a submission needs.",
        discussion: """
        Never contacts Apple. Checks app.yml's values, every text file against Apple's limits (name and subtitle 30 \
        characters, keywords 100 bytes, promotional text 170, description and what's new 4000), URLs, locale codes, \
        screenshots (format, size for their display type, no transparency, at most 10 per set) and previews (format, \
        at most 3 per set), and what a submission needs (name, description, keywords and support URL per locale, a \
        privacy policy URL, categories, age rating, App Review contact, screenshots). --draft reports the missing parts \
        as warnings, for a listing still being written. Exits with 20 when anything is wrong.
        """)

    @OptionGroup var directory: StoreDirOption
    @Flag(help: "Report what a submission still needs as warnings, not errors.") var draft = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let result = StoreValidation.run(dir: directory.url, project: try directory.project(), draft: draft, json: output.json)
        FileHandle.standardError.write(Data(result.stderr.utf8))
        print(result.stdout, terminator: "")
        if result.failed { throw ExitCode(Stage.account.exitCode) }
    }
}

/// `xless store validate`'s output: issues one per line, errors first, on standard error (`error: [account] path: … — fix` /
/// `warning: …`) and a summary, or with `json` a document on standard output.
enum StoreValidation {
    struct Document: Encodable {
        struct Issue: Encodable { var severity: String; var path: String; var message: String; var fix: String }
        var valid: Bool
        var issues: [Issue]
    }

    static func run(dir: URL, draft: Bool, json: Bool) -> (stdout: String, stderr: String, failed: Bool) {
        run(dir: dir, project: StoreProject.nextTo(manifestDir: dir), draft: draft, json: json)
    }

    /// - Parameter project: where app.yml's missing bundleID comes from.
    static func run(dir: URL, project: StoreProject?, draft: Bool, json: Bool) -> (stdout: String, stderr: String, failed: Bool) {
        let read = ManifestReader.read(dir)
        let inherited = read.manifest.app.bundleID == nil ? project?.bundleID(for: read.manifest.app.platform) : nil
        let exists = FileManager.default.fileExists(atPath: dir.path)
        let found = read.issues + (!exists ? [] : ManifestValidator.validate(read.manifest, at: dir, draft: draft, inheritedBundleID: inherited, checkApp: read.appReadable))
        // Errors first, each kind in the order found.
        let issues = found.filter { $0.severity == .error } + found.filter { $0.severity != .error }
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        if json {
            let doc = Document(valid: errors == 0, issues: issues.map { .init(severity: $0.severity.rawValue, path: $0.path, message: $0.message, fix: $0.fix) })
            return ((try? ASCOutput.json(doc)) ?? "", "", errors > 0)
        }
        let lines = issues.map { $0.severity == .error ? "error: \($0.description)\n" : "\($0.description)\n" }.joined()
        let plural = { (n: Int, word: String) in "\(n) \(word)\(n == 1 ? "" : "s")" }
        let summary = errors == 0
            ? "\(dir.lastPathComponent)/ is valid\(warnings == 0 ? "" : " (\(plural(warnings, "warning")))")\n"
            : "\(dir.lastPathComponent)/: \(plural(errors, "error"))\(warnings == 0 ? "" : ", \(plural(warnings, "warning"))")\n"
        return (errors == 0 ? summary : "", lines + (errors == 0 ? "" : summary), errors > 0)
    }
}

struct StorePushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Make App Store Connect's listing match the appstore/ directory, sending only what differs.",
        discussion: """
        Checks the directory (as `store validate --draft`), reads the listing with the App Store Connect API key, prints \
        the plan (+ create, ~ update, - delete) and sends it; --dry-run stops after the plan. A push that finds nothing \
        to change sends nothing.

        Parts, in this order (--only text,review,… to choose): text (the version: created when App Store Connect has \
        none for app.yml's version, version string, copyright, release type and date, phased release; the primary \
        locale; categories; per locale name, subtitle, privacy URLs and text, description, keywords, what's new, \
        promotional text, support and marketing URLs), review (App Review contact, notes, demo account and \
        attachments), declarations (age rating, content rights, licence agreement, export compliance and its \
        document, accessibility), pricing (the price schedule: base territory and price, manual prices in other \
        territories, scheduled changes; and the territories the app is available in; it needs no version), privacy \
        (the App Privacy answers, then published; it needs no version), iap and subscriptions (iap/ and \
        subscriptions/: products and groups created, then their text, App Review screenshot, prices and availability; \
        nothing is ever deleted; they need no version), media (per locale and display type, the screenshot and \
        preview sets).

        App Privacy has no App Store Connect API: when app.yml has privacy:, push uses the Apple ID web session for it \
        (a session kept by `xless auth login --keep`, else a sign-in on the terminal). Without either, the privacy part \
        is skipped with a note (an error with --only privacy) and the rest is pushed with the API key; `xless store \
        privacy push` sends it alone. Only the answers that differ are deleted and created again.

        Prices are customer prices (`free`, "0.99"): each must be one of the app's price points in its territory \
        (`xless apps price-points`), else push stops before sending anything and names the nearest ones. A changed \
        schedule is sent whole (App Store Connect replaces it), keeping the manual prices and changes app.yml does not \
        manage.

        Files (screenshots, previews, attachments, the compliance document) are compared with App Store Connect's by \
        MD5, so an unchanged file is never uploaded again; a changed one replaces its upload, sets are put in the \
        directory's order, and media.lock records what each file is. Uploads go through App Store Connect's upload \
        operations, read from disk part by part.

        app.yml keys that are absent are left as App Store Connect has them; in a locale directory, a missing text file \
        clears the field. Locales, sets and files App Store Connect has and the directory does not are reported; \
        --prune deletes them. Deleting anything asks first (or needs --yes).

        The demo account's password comes from the secret app.yml's review.demoAccount.passwordSecret names (secret \
        store, NAME or NAME_FILE). App Store Connect never gives it back, so it is sent only when the review details \
        are created, when the demo account becomes required or changes name, or with --resend-demo-account; it is never \
        printed, traced or written.
        """)

    @OptionGroup var directory: StoreDirOption
    @Flag(help: "Print the plan and stop: nothing is sent.") var dryRun = false
    @Option(help: ArgumentHelp("Push only these parts: text, review, declarations, pricing, privacy, iap, subscriptions, media (comma-separated, or repeated).", valueName: "parts"))
    var only: [String] = []
    @Flag(help: "Delete the localizations, media sets and files App Store Connect has and the directory does not (never the primary locale).")
    var prune = false
    @Flag(help: "Send the demo account's name and password even if they look unchanged (after changing the password).")
    var resendDemoAccount = false
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        do { _ = try StorePushPart.parse(only) } catch let e as XlessError { throw ValidationError("\(e.cause): \(e.fix)") }
    }

    var options: StorePush.Options {
        StorePush.Options(parts: only.isEmpty ? StorePushPart.allCases : ((try? StorePushPart.parse(only)) ?? []), prune: prune,
                          resendDemoAccount: resendDemoAccount)
    }

    func run() async throws {
        let dir = directory.url
        try await AccountSession.run {
            let project = try directory.project()
            let (manifest, bundleID) = try StorePushCLI.check(dir: dir, project: project, say: StorePushCLI.standardError)
            let session = try AccountSession.open(team: team.team, project: project?.team, verbose: trace.verbose)
            // App Privacy has no API: it goes through the Apple ID web session, opened only when app.yml has answers.
            var web: (session: AppleWebSession, transport: URLSessionAppleTransport)?
            if try StorePrivacyCLI.storePushNeedsWeb(manifest: manifest, parts: options.parts, explicit: !only.isEmpty,
                                                     kept: AppleWebCLI.cache.info() != nil, terminal: !InputGate.isOff && (try? AppleWebCLI.prompter()) != nil) {
                web = try await StorePrivacyCLI.webForStorePush(explicit: !only.isEmpty, say: StorePushCLI.standardError) {
                    let (s, t, _) = try await APIKeyWebCLI.open(team: session.team, verbose: trace.verbose)
                    return (session: s, transport: t)
                }
            }
            defer { web?.transport.invalidate() }
            let cli = StorePushCLI(client: session.client, secrets: session.secrets, privacy: web.map { ASCWebPrivacy(asc: $0.session.asc) },
                                   json: output.json, say: StorePushCLI.standardError)
            let text = try await cli.run(manifest: manifest, bundleID: bundleID, dir: dir, options: options, dryRun: dryRun, yes: confirmation.yes)
            if let web { await web.session.end() }
            print(text, terminator: "")
        }
    }
}

/// `store push`'s sequence, testable: the manifest checked before anything is read from Apple, the plan printed, the
/// deletions confirmed, the changes sent.
struct StorePushCLI {
    let client: ASCClient
    let secrets: Secrets
    /// App Privacy through the Apple ID web session; nil: the privacy part is only noted.
    var privacy: (any PrivacyRemote)? = nil
    let json: Bool
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    let say: @Sendable (String) -> Void

    static let standardError: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// The manifest and its app's bundle ID; its errors (as `store validate --draft` finds them) stop the push with
    /// nothing read or sent.
    /// - Parameter project: where app.yml's missing bundleID comes from (default: the xless.yml next to `dir`).
    static func check(dir: URL, project: StoreProject?? = nil, say: (String) -> Void) throws -> (StoreManifest, String) {
        let read = ManifestReader.read(dir)
        let project = project ?? StoreProject.nextTo(manifestDir: dir)
        let inherited = read.manifest.app.bundleID == nil ? project?.bundleID(for: read.manifest.app.platform) : nil
        let exists = FileManager.default.fileExists(atPath: dir.path)
        let found = read.issues + (!exists ? [] : ManifestValidator.validate(read.manifest, at: dir, draft: true, inheritedBundleID: inherited, checkApp: read.appReadable))
        let errors = found.filter { $0.severity == .error }
        for issue in errors { say("error: \(issue)") }
        guard errors.isEmpty else {
            throw XlessError(.account, "\(dir.lastPathComponent)/ has \(errors.count) error\(errors.count == 1 ? "" : "s"); nothing was sent",
                             fix: "fix \(errors.count == 1 ? "it" : "them") (`xless store validate --draft` lists them), then re-run")
        }
        guard let bundleID = read.manifest.app.bundleID ?? inherited else {
            throw XlessError(.account, "no app to push to: no bundleID in \(dir.lastPathComponent)/app.yml and \(project.map { "no bundle ID in \($0.name) for its platform" } ?? "no xless.yml next to it")",
                             fix: "add `bundleID: com.example.app` to app.yml (or pass the app's overlay with --config)")
        }
        return (read.manifest, bundleID)
    }

    /// The demo account's password, from the secret `name` (store, NAME or NAME_FILE), without a file's final line break.
    /// - Parameter source: where the secret's name comes from, for the message.
    static func demoPassword(_ name: String, secrets: Secrets, source: String = "app.yml's review.demoAccount.passwordSecret") throws -> String {
        if let problem = SecretEnvironment.passwordNameProblem(name) {
            throw XlessError(.account, "\(name) (\(source)) \(problem), so it is not the demo account's password; nothing was sent", fix: "keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD")
        }
        guard var value = try secrets.optional(name, stage: .account) else {
            throw XlessError(.account, "missing secret \(name), the demo account's password (\(source)); nothing was sent",
                             fix: "store it: `xless secrets import \(name) --file <file> --kind password` (or set \(name) or \(name)_FILE)")
        }
        while value.hasSuffix("\n") || value.hasSuffix("\r") { value.removeLast() }
        guard !value.isEmpty else {
            throw XlessError(.account, "the secret \(name) (the demo account's password) is empty; nothing was sent", fix: "store the password in it")
        }
        return value
    }

    /// Whether the plan may go ahead: deletions need a yes (or --yes).
    func confirmDeletes(_ plan: StorePlan, yes: Bool) throws -> Bool {
        let deletes = plan.deletes
        guard !deletes.isEmpty else { return true }
        let what = deletes.map(\.subject).joined(separator: ", ")
        return try AccountConfirm.confirm("Delete \(what) on App Store Connect?", action: "deleting \(what)", yes: yes, terminal: terminal)
    }

    func run(manifest: StoreManifest, bundleID: String, dir: URL, options: StorePush.Options, dryRun: Bool, yes: Bool) async throws -> String {
        let resources = ASCResources(client: client)
        let app = try await ASCApps(resources: resources).resolve(bundleID)
        let push = StorePush(resources: resources, privacy: privacy, say: say)
        var (plan, report) = try await push.plan(app: app, manifest: manifest, dir: dir, options: options)
        for note in plan.notes { say("note: \(note)") }
        if dryRun || plan.changes.isEmpty {
            return json ? try ASCOutput.json(report) : report.planText + (dryRun && !plan.changes.isEmpty ? "dry run: nothing was sent\n" : "")
        }
        if !json { print(report.planText, terminator: "") }
        guard try confirmDeletes(plan, yes: yes) else {
            say("cancelled; nothing was sent")
            return json ? try ASCOutput.json(report) : ""
        }
        let secrets = self.secrets
        let sender = StoreSender(client: client, secret: { try Self.demoPassword($0, secrets: secrets) })
        let json = self.json, say = self.say
        let result = try await push.apply(plan, app: app, manifest: manifest, dir: dir, options: options, sender: sender, show: { next in
            // Once the new version exists, the rest is planned again against it: shown before it is sent.
            for note in next.notes { say("note: \(note)") }
            if !json { print("planned again against the new version:\n" + next.text, terminator: "") }
        }, confirm: { try confirmDeletes($0, yes: yes) })
        report.record(result)
        return json ? try ASCOutput.json(report) : "sent \(report.applied) change\(report.applied == 1 ? "" : "s") to App Store Connect\n"
    }
}
