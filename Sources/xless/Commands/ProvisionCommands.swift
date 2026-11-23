import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore
import XlessStore
import XlessVault

struct ProvisionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision",
        abstract: "Set up everything the project needs on the Apple account, declared by xless.yml (or the overlay) and appstore/.",
        discussion: """
        Reads xless.yml (--project) or an overlay (--config): the team, the bundle ID of each platform, the \
        entitlements of the apps (a React Native app's from its last build), the distribution lanes and the TestFlight \
        groups; and appstore/ (--dir) when it exists. In dependency order: bundle IDs; the capabilities the \
        entitlements need; app groups and iCloud containers and their assignment; a certificate for each lane (a \
        stored key whose certificate exists is reused); an APNs key when the app uses push notifications and none is \
        stored; the profiles; the app record; the listing (text, media, price, availability); App Privacy; the \
        TestFlight groups.

        `plan` only reads. `apply` runs the plan in one process: the secret store's passphrase is asked once and the \
        Apple ID signs in at most once, only when a step needs the web session. A second apply finds nothing to do; one \
        that fails stops there, says what was done and what is left, and is safe to re-run. Nothing is ever deleted or \
        revoked: what differs that way (an extra capability, a stale profile, a screenshot to replace) is reported as \
        drift with the command that would change it.

        """ + AppleWebHelp.note + """
         Planning uses only a kept session (`xless auth login --keep 30m`); without one, the steps that need it are \
        listed as checked when applied.
        """,
        subcommands: [ProvisionPlanCommand.self, ProvisionApplyCommand.self])
}

/// Where the project is: xless.yml or an overlay, and the listing.
struct ProvisionInputOptions: ParsableArguments {
    @Option(help: "Project directory containing xless.yml.")
    var project: String = "."
    @Option(help: "Overlay file (type: tauri, type: react-native or type: cargo) instead of a project directory; cannot be combined with --project.")
    var config: String?
    @Option(help: "With --config: use this directory as the app source instead of the overlay's `source:`.")
    var source: String?
    @Option(help: ArgumentHelp("The appstore/ manifest directory (default: appstore/ next to xless.yml or the overlay).", valueName: "dir"))
    var dir: String?

    func validate() throws {
        if config != nil, project != "." { throw ValidationError("--config cannot be combined with --project") }
        if config == nil, source != nil { throw ValidationError("--source requires --config") }
    }

    var configURL: URL? { config.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var projectURL: URL { URL(fileURLWithPath: project).standardizedFileURL }
}

struct ProvisionPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show, by area, what `provision apply` would create or change; reads only.",
        discussion: "With --json, the plan as a stable document for review in CI: steps (area, action, subject, details, webSession, checked), drift, blockers, notes.")

    @OptionGroup var inputs: ProvisionInputOptions
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            let opened = try ProvisionCLI.open(inputs, verbose: trace.verbose)
            let kept = await ProvisionCLI.kept(team: opened.inputs.team, verbose: trace.verbose)
            defer { kept?.transport.invalidate() }
            let plan = try await opened.planner(web: kept.map { ProvisionWebSide(session: $0.session) }).plan()
            if let kept { await kept.session.end() }
            print(output.json ? try ASCOutput.json(plan) : plan.text, terminator: "")
        }
    }
}

struct ProvisionApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Do what `provision plan` shows, in dependency order; never deletes or revokes anything.",
        discussion: "Asks before it starts (or --yes). " + AppleWebHelp.note)

    @OptionGroup var inputs: ProvisionInputOptions
    @Option(help: ArgumentHelp("The seller name shown on the App Store, when the app record is the team's first app.", valueName: "company"))
    var companyName: String?
    @OptionGroup var output: JSONOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    struct Applied: Encodable { var plan: ProvisionPlan; var done: [ProvisionDone] }

    func run() async throws {
        try await AccountSession.run {
            let opened = try ProvisionCLI.open(inputs, verbose: trace.verbose)
            let held = WebHolder()
            defer { held.transport?.invalidate() }
            if let kept = await ProvisionCLI.kept(team: opened.inputs.team, verbose: trace.verbose) { (held.session, held.transport) = (kept.session, kept.transport) }
            var planner = opened.planner(web: held.session.map(ProvisionWebSide.init(session:)))
            planner.companyName = companyName?.trimmingCharacters(in: .whitespaces)
            let plan = try await planner.plan()
            if !output.json { print(plan.text, terminator: "") }
            try plan.requireUnblocked()
            guard !plan.steps.isEmpty else {
                if output.json { print(try ASCOutput.json(Applied(plan: plan, done: []))) }
                return
            }
            let question = "Apply these \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s") to team \(plan.team)'s account? [y/N] "
            guard try AccountConfirm.confirm(question, action: "applying the provisioning plan", yes: confirmation.yes) else {
                AppleWebCLI.say("cancelled; nothing was sent")
                return
            }
            let verbose = trace.verbose, team = opened.inputs.team
            let done = try await opened.applier(web: {
                if let session = held.session { return ProvisionWebSide(session: session) }
                let (session, transport, _) = try await APIKeyWebCLI.open(team: team, verbose: verbose)
                (held.session, held.transport) = (session, transport)
                await AppleWebCLI.warnAboutAgreements(session)
                return ProvisionWebSide(session: session)
            }).apply(plan)
            if let session = held.session { await session.end() }
            print(output.json ? try ASCOutput.json(Applied(plan: plan, done: done)) : "applied \(done.count) step\(done.count == 1 ? "" : "s"); `xless provision plan` now finds nothing to do\n",
                  terminator: output.json ? "\n" : "")
        }
    }
}

/// The web session `apply` opened (kept or signed in), to end it afterwards.
private final class WebHolder: @unchecked Sendable {
    var session: AppleWebSession?
    var transport: URLSessionAppleTransport?
}

/// What both commands open: the inputs, the API key (from the environment or the store, for the project's team), the
/// secret store sharing that unlock, and the manifest.
enum ProvisionCLI {
    struct Opened {
        var inputs: ProvisionInputs
        var account: APIProvisionAccount
        var vault: ProvisionVault
        var store: ProvisionStore?
        var storeBlocker: ProvisionBlocker?

        func planner(web: ProvisionWebSide?) -> ProvisionPlanner {
            ProvisionPlanner(inputs: inputs, account: account, web: web, vault: vault, store: store, storeBlocker: storeBlocker)
        }

        func applier(web: @escaping () async throws -> ProvisionWebSide) -> ProvisionApplier {
            ProvisionApplier(inputs: inputs, account: account, web: web, vault: vault, store: store, say: AppleWebCLI.say)
        }
    }

    static func open(_ options: ProvisionInputOptions, verbose: Bool, env: [String: String] = ProcessInfo.processInfo.environment) throws -> Opened {
        SecretScope.enter()
        let inputs = try ProvisionInputs.load(project: options.projectURL, config: options.configURL, source: options.source, storeDir: options.dir, env: env)
        let store = VaultStore(location: .standard())
        // One resolver for the API key and the new entries: the passphrase is asked once.
        let resolver = VaultResolver(store: store, team: nil, prompter: { try? TerminalPrompter.forSecretStore() })
        let session = try AccountSession.open(team: inputs.team, verbose: verbose, env: env, fallback: { _ in resolver.preferring(team: inputs.team) })
        let vault = ProvisionVault(store: store, env: env, unlock: { try resolver.dataKey(for: $0, reason: $1) })
        var opened = Opened(inputs: inputs, account: APIProvisionAccount(resources: session.resources), vault: vault)
        if let dir = inputs.storeDir, let bundle = inputs.appStoreBundleID {
            switch manifest(dir, bundleID: bundle) {
            case .success(let manifest):
                opened.store = ProvisionStore(manifest: manifest, listing: StorePushListing(client: session.client, manifest: manifest, dir: dir,
                                                                                           secrets: session.secrets, say: StorePushCLI.standardError))
            case .failure(let blocker):
                opened.storeBlocker = blocker
            }
        }
        return opened
    }

    /// The manifest, checked as `xless store validate --draft` checks it; its errors block the plan.
    static func manifest(_ dir: URL, bundleID: String) -> Result<StoreManifest, ProvisionBlocker> {
        let read = ManifestReader.read(dir)
        let issues = read.issues + ManifestValidator.validate(read.manifest, at: dir, draft: true, inheritedBundleID: bundleID, checkApp: read.appReadable)
        let errors = issues.filter { $0.severity == .error }
        for issue in errors { AppleWebCLI.say("error: \(issue)") }
        guard errors.isEmpty else {
            return .failure(ProvisionBlocker(area: .listing, message: "\(dir.lastPathComponent)/ has \(errors.count) error\(errors.count == 1 ? "" : "s")",
                                             fix: "fix \(errors.count == 1 ? "it" : "them") (`xless store validate --draft --dir \(dir.path)` lists them)"))
        }
        return .success(read.manifest)
    }

    /// The kept Apple ID session for the team, or nil (said once on standard error): planning never signs in.
    static func kept(team: String, verbose: Bool) async -> (session: AppleWebSession, transport: URLSessionAppleTransport)? {
        guard (await AppleWebCLI.cache.info()) != nil else { return nil }
        do { return try await ReleaseWeb.kept(team: team, verbose: verbose) } catch {
            AppleWebCLI.say("note: the kept Apple ID session cannot be used (\(XlessError.wrapping(error, stage: .account).cause)); the steps that need it are checked when applied")
            return nil
        }
    }
}
