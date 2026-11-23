import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessASC
import XlessCore
import XlessStore

struct StoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store",
        abstract: "Keep the App Store listing in an appstore/ directory: pull it from App Store Connect, validate it.",
        discussion: """
        The listing (text per locale, screenshots, previews, categories, age rating, review contact, licence agreement, \
        price and availability) lives in appstore/ next to the project, reviewed like code: docs/appstore-manifest.md. \
        pull reads an existing app's listing with the App Store Connect API key; validate checks the directory offline.

          xless store pull --app com.example.app
          xless store validate
        """,
        subcommands: [StorePullCommand.self, StoreValidateCommand.self])
}

/// `--dir` shared by the store commands.
struct StoreDirOption: ParsableArguments {
    @Option(help: ArgumentHelp("The manifest directory.", valueName: "dir")) var dir: String = "appstore"

    var url: URL { URL(fileURLWithPath: dir).standardizedFileURL }
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

    /// The bundle ID of the xless.yml next to the manifest directory, for the manifest's platform; nil without one.
    static func inheritedBundleID(manifestDir: URL, platform: String?) -> String? {
        let file = manifestDir.deletingLastPathComponent().appendingPathComponent("xless.yml")
        guard FileManager.default.fileExists(atPath: file.path), let config = try? ProjectConfig.load(from: file) else { return nil }
        return config.bundleID(for: platform == "MAC_OS" ? .macos : .ios)
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
        does not own (a README, notes) and app.yml keys xless does not manage (privacy) are kept. Screenshots are \
        downloaded from App Store Connect, except those media.lock records as the local original of the same upload.
        """)

    @OptionGroup var directory: StoreDirOption
    @Option(help: ArgumentHelp("The app: its app ID or bundle identifier (default: app.yml's bundleID, else xless.yml's).", valueName: "app"))
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
            guard let wanted = app ?? existing.bundleID ?? StorePlatform.inheritedBundleID(manifestDir: dir, platform: platform ?? existing.platform) else {
                throw XlessError(.account, "no app to pull: no --app, no bundleID in \(directory.dir)/app.yml and no xless.yml next to it",
                                 fix: "pass --app <app ID or bundle ID> (see `xless apps list`)")
            }
            let session = try AccountSession.open(team: team.team, verbose: trace.verbose)
            let found = try await ASCApps(resources: session.resources).resolve(wanted)
            let client = session.client
            let pull = StorePull(resources: session.resources, download: { url in try await StoreDownload.fetch(url, client: client) },
                                 say: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
            let report = try await pull.run(app: found, platform: platform, selection: selection, into: dir)
            print(output.json ? try ASCOutput.json(report) : report.text, terminator: "")
        }
    }
}

enum StoreDownload {
    /// A media file from App Store Connect's delivery network: https only, no credentials sent, retried like API calls.
    static func fetch(_ url: URL, client: ASCClient) async throws -> Data {
        guard url.scheme == "https" else {
            throw XlessError(.account, "App Store Connect gave a media URL that is not https", fix: "re-run; if it persists, report it")
        }
        do {
            return try await client.raw(URLRequest(url: url)).0
        } catch let e as ASCError {
            throw XlessError(.account, "downloading \(url.lastPathComponent) from App Store Connect failed (HTTP \(e.status))",
                             fix: "re-run `xless store pull`; nothing was changed")
        }
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
        let result = StoreValidation.run(dir: directory.url, draft: draft, json: output.json)
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
        let read = ManifestReader.read(dir)
        let inherited = read.manifest.app.bundleID == nil ? StorePlatform.inheritedBundleID(manifestDir: dir, platform: read.manifest.app.platform) : nil
        let found = read.issues + (read.hasAppFile ? ManifestValidator.validate(read.manifest, at: dir, draft: draft, inheritedBundleID: inherited) : [])
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
