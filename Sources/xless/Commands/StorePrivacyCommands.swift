import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessStore

struct StorePrivacyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privacy",
        abstract: "Pull and push the app's App Privacy answers (app.yml's privacy:).",
        discussion: AppleWebHelp.note + """


        App Privacy (what data the app collects, what for, whether it is linked to the user and used to track them) has \
        no App Store Connect API: xless reads and sends it as App Store Connect's own App Privacy page does. An app \
        cannot be submitted until its answers are published. The format is in docs/appstore-manifest.md.

          xless store privacy pull --app com.example.app
          xless store privacy push --dry-run
        """,
        subcommands: [StorePrivacyPullCommand.self, StorePrivacyPushCommand.self])
}

struct StorePrivacyPullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Write the app's App Privacy answers, as App Store Connect has them, into app.yml's privacy:.",
        discussion: AppleWebHelp.note + """


        Rewrites app.yml only (the rest of the directory is left as it is), creating the directory and an app.yml with \
        the bundle ID when there is none. An app whose questions were never answered leaves app.yml unchanged.
        """)

    @OptionGroup var directory: StoreDirOption
    @Option(help: ArgumentHelp("The app: its app ID or bundle identifier (default: app.yml's bundleID, else xless.yml's).", valueName: "app"))
    var app: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { if let app { try AppArgumentHelp.validate(app) } }

    func run() async throws {
        let dir = directory.url
        try await AccountSession.run {
            let wanted = try StorePrivacyCLI.wantedApp(app, dir: dir)
            let (session, transport, _) = try await APIKeyWebCLI.open(team: AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam()), verbose: trace.verbose)
            defer { transport.invalidate() }
            let target = try await StorePrivacyCLI.resolve(wanted, apps: ASCWebApps(asc: session.asc))
            let cli = StorePrivacyCLI(remote: ASCWebPrivacy(asc: session.asc), json: output.json, say: StorePushCLI.standardError)
            let text = try await cli.pull(app: target, dir: dir)
            await session.end()
            print(text, terminator: "")
        }
    }
}

struct StorePrivacyPushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Make App Store Connect's App Privacy answers match app.yml's privacy:, then publish them.",
        discussion: AppleWebHelp.note + """


        Checks app.yml's privacy section and every ID in it against App Store Connect's own lists, prints the plan and \
        sends only the answers that differ (each changed answer is deleted and created again; App Store Connect has \
        no edit), then publishes. Switching to or from "Data Not Collected" deletes the old answers first: App Store \
        Connect refuses the two together. --dry-run stops after the plan. Re-running after a failure sends only what \
        still differs. `xless store push` sends the same part (privacy) with the rest of the listing.
        """)

    @OptionGroup var directory: StoreDirOption
    @Option(help: ArgumentHelp("The app: its app ID or bundle identifier (default: app.yml's bundleID, else xless.yml's).", valueName: "app"))
    var app: String?
    @Flag(help: "Print the plan and stop: nothing is sent.") var dryRun = false
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func validate() throws { if let app { try AppArgumentHelp.validate(app) } }

    func run() async throws {
        let dir = directory.url
        try await AccountSession.run {
            let privacy = try StorePrivacyCLI.check(dir: dir, say: StorePushCLI.standardError)
            let wanted = try StorePrivacyCLI.wantedApp(app, dir: dir)
            let (session, transport, _) = try await APIKeyWebCLI.open(team: AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam()), verbose: trace.verbose)
            defer { transport.invalidate() }
            let target = try await StorePrivacyCLI.resolve(wanted, apps: ASCWebApps(asc: session.asc))
            let cli = StorePrivacyCLI(remote: ASCWebPrivacy(asc: session.asc), json: output.json, say: StorePushCLI.standardError)
            let text = try await cli.push(privacy, app: target, dryRun: dryRun)
            await session.end()
            print(text, terminator: "")
        }
    }
}

/// `store privacy pull|push`, testable: the app found, app.yml read and written, the plan printed and sent.
struct StorePrivacyCLI {
    /// The app the answers belong to: its ID, and how to name it (its bundle ID when known).
    struct Target: Equatable {
        var id: String
        var name: String
    }

    /// What `pull` / `push` print with --json.
    struct Document: Encodable {
        struct Change: Encodable { var action: StoreChange.Action; var subject: String; var fields: [StoreFieldChange] }
        var appID: String
        var app: String
        var published: Bool?
        var privacy: AppYAML.Privacy?
        var dryRun: Bool?
        var applied: Int?
        var changes: [Change]?
        var notes: [String]
    }

    let remote: any PrivacyRemote
    let json: Bool
    let say: @Sendable (String) -> Void

    /// `--app`, else app.yml's bundleID, else xless.yml's.
    static func wantedApp(_ flag: String?, dir: URL) throws -> String {
        let existing = ManifestReader.read(dir).manifest.app
        guard let wanted = flag ?? existing.bundleID ?? StorePlatform.inheritedBundleID(manifestDir: dir, platform: existing.platform) else {
            throw XlessError(.account, "no app: no --app, no bundleID in \(dir.lastPathComponent)/app.yml and no xless.yml next to it",
                             fix: "pass --app <app ID or bundle ID> (see `xless apps list`)")
        }
        return wanted
    }

    /// An app ID as it is; a bundle ID looked up in App Store Connect (web session).
    static func resolve(_ wanted: String, apps: ASCWebApps) async throws -> Target {
        if AppArgument.isAppID(wanted) { return Target(id: wanted, name: wanted) }
        guard let app = try await apps.find(bundleID: wanted) else {
            throw XlessError(.account, "App Store Connect has no app with the bundle ID \(wanted) in this team",
                             fix: "check the bundle ID and --team (`xless apps list`), or create the app with `xless apps create`")
        }
        return Target(id: app.id, name: app.bundleID)
    }

    /// app.yml's privacy section, checked; its errors stop the push with nothing read or sent.
    static func check(dir: URL, say: (String) -> Void) throws -> AppYAML.Privacy {
        let read = ManifestReader.read(dir)
        let appPath = "\(dir.lastPathComponent)/\(ManifestReader.appFile)"
        let appIssues = read.issues.filter { $0.path == appPath && $0.severity == .error }
        let privacy = read.manifest.app.privacy
        let issues = appIssues + (privacy.map { ManifestValidator.privacyIssues($0, path: appPath) } ?? [])
        for issue in issues { say(issue.severity == .error ? "error: \(issue)" : "\(issue)") }
        let errors = issues.filter { $0.severity == .error }.count
        guard errors == 0 else {
            throw XlessError(.account, "\(appPath) has \(errors) error\(errors == 1 ? "" : "s"); nothing was sent",
                             fix: "fix \(errors == 1 ? "it" : "them") (`xless store validate --draft` lists them), then re-run")
        }
        guard let privacy else {
            throw XlessError(.account, "\(appPath) has no privacy section; nothing was sent",
                             fix: "write one (docs/appstore-manifest.md), or take App Store Connect's answers with `xless store privacy pull`")
        }
        return privacy
    }

    func pull(app: Target, dir: URL) async throws -> String {
        let read = ManifestReader.read(dir)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(ManifestReader.appFile).path), !read.appReadable {
            let appPath = "\(dir.lastPathComponent)/\(ManifestReader.appFile)"
            let why = read.issues.first { $0.path == appPath && $0.severity == .error }.map { ": \($0.message)" } ?? ""
            throw XlessError(.account, "\(appPath) cannot be read\(why); nothing was written", fix: "fix it (its other keys would be lost), then re-run")
        }
        let privacy = StorePrivacy(remote: remote)
        let have = try await privacy.read(app: app.id)
        let (answers, notes) = StorePrivacy.declaration(from: have.usages)
        var allNotes = notes
        if answers != nil, have.published == false {
            allNotes.append("App Store Connect's answers are not published yet; `xless store privacy push` publishes them")
        }
        var wrote = false
        if let answers {
            var manifest = read.manifest
            if manifest.app.bundleID == nil, !AppArgument.isAppID(app.name) { manifest.app.bundleID = app.name }
            if manifest.app.privacy != answers || !read.hasAppFile {
                manifest.app.privacy = answers
                try Self.writeApp(manifest, to: dir)
                wrote = true
            }
        } else {
            allNotes.append("App Store Connect has no App Privacy answers for \(app.name) yet; \(dir.lastPathComponent)/app.yml is unchanged")
        }
        for note in allNotes { say("note: \(note)") }
        if json {
            return try ASCOutput.json(Document(appID: app.id, app: app.name, published: have.published, privacy: answers, notes: allNotes))
        }
        guard let answers else { return "" }
        let what = answers.collectsData == true ? "\(answers.data?.count ?? 0) kind\(answers.data?.count == 1 ? "" : "s") of data collected" : "data not collected"
        return wrote ? "wrote \(dir.lastPathComponent)/app.yml's privacy: \(what)\n" : "\(dir.lastPathComponent)/app.yml's privacy already matches App Store Connect (\(what))\n"
    }

    /// app.yml alone, replaced atomically (the directory is created when missing).
    static func writeApp(_ manifest: StoreManifest, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = try ManifestWriter.renderApp(manifest)
        try Data(text.utf8).write(to: dir.appendingPathComponent(ManifestReader.appFile), options: .atomic)
    }

    func push(_ want: AppYAML.Privacy, app: Target, dryRun: Bool) async throws -> String {
        let privacy = StorePrivacy(remote: remote)
        let changes = try await privacy.plan(want, app: app.id, appName: app.name)
        let plan = StorePlan(changes: changes)
        func document(applied: Int?) -> Document {
            Document(appID: app.id, app: app.name, published: nil, privacy: nil, dryRun: applied == nil, applied: applied,
                     changes: changes.map { .init(action: $0.action, subject: $0.subject, fields: $0.fields) }, notes: [])
        }
        let planText = "\(app.name) App Privacy:\n" + plan.text
        if dryRun || changes.isEmpty {
            return json ? try ASCOutput.json(document(applied: dryRun ? nil : 0)) : planText + (dryRun && !changes.isEmpty ? "dry run: nothing was sent\n" : "")
        }
        if !json { print(planText, terminator: "") }
        var sent = 0
        for change in changes {
            do { try await privacy.apply(change, app: app.id) } catch {
                say("note: \(sent) of \(changes.count) change\(changes.count == 1 ? "" : "s") \(sent == 1 ? "was" : "were") sent before this failure; re-run `xless store privacy push` to send the rest (it sends only what still differs)")
                throw error
            }
            sent += 1
        }
        return json ? try ASCOutput.json(document(applied: sent)) : "sent \(sent) change\(sent == 1 ? "" : "s") to App Store Connect; the App Privacy answers are published\n"
    }

    /// Whether `store push` opens the Apple ID web session for App Privacy: only when app.yml has `privacy` and the
    /// part is pushed; without a kept session and a terminal, a push that names the part (`--only privacy`) stops, any
    /// other goes on without it (the plan notes it).
    static func storePushNeedsWeb(manifest: StoreManifest, parts: [StorePushPart], explicit: Bool, kept: Bool, terminal: Bool) throws -> Bool {
        guard manifest.app.privacy != nil, parts.contains(.privacy) else { return false }
        if kept || terminal { return true }
        if explicit {
            throw XlessError(.account, "pushing App Privacy needs the Apple ID web session: no session is kept and there is no terminal to sign in on; nothing was sent",
                             fix: "keep a session first with `xless auth login --keep 30m` (in a terminal, in this login session), or push the other parts without privacy")
        }
        return false
    }
}
