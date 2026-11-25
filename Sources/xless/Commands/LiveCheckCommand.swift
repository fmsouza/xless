import ArgumentParser
import Foundation
import XlessAppleID
import XlessASC
import XlessCore

struct LiveCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live-check",
        abstract: "Read every App Store Connect and Apple ID web endpoint xless uses on a real account, and report each answer (maintainer tool).",
        discussion: """
        A read-only contract check for the maintainer (scripts/acceptance-m7.sh runs it first, before anything is \
        written): it calls the list and get endpoints the Apple account commands use (not the report downloads, nor \
        each in-app purchase's own reads), with xless's own readers, and \
        prints one line per endpoint: ok, warn (it decoded, but fields xless reads never came back: read them), FAIL \
        (an error or an answer xless cannot read) or skip. Nothing is written at Apple: both connections refuse to send \
        anything but a read.

        The documented API half uses the API key the other account commands would use (--team); without one it is \
        skipped. The web half uses only a session kept by `xless auth login --keep` (it never signs in); without one it \
        is skipped. App endpoints are read on --app (an app ID or a bundle ID), else on the account's first app.

        It talks to Apple only when XLESS_LIVE_APPLE=1 is set (as the live tests do). Exit codes: 0 no failure, 1 a \
        check failed, 20 it could not start.
        """,
        shouldDisplay: false)

    @Option(help: "The app whose endpoints are read: an app ID or a bundle ID (default: the account's first app).") var app: String?
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption

    func run() async throws {
        try await AccountSession.run {
            guard ProcessInfo.processInfo.environment["XLESS_LIVE_APPLE"] == "1" else {
                throw XlessError(.account, "live-check talks to Apple only with XLESS_LIVE_APPLE=1 set",
                                 fix: "XLESS_LIVE_APPLE=1 xless live-check (it only reads)")
            }
        }
        let verbose = trace.verbose
        var check = LiveCheck(app: app)
        do {
            // The guard outside the trace: a refused request never shows in a --verbose trace as if it had been sent.
            let wire: HTTPTransport = verbose ? TracingTransport(URLSessionTransport(), trace: .standardError) : URLSessionTransport()
            let session = try AccountSession.open(team: team.team, verbose: false, transport: ReadOnlyTransport(inner: wire))
            check.api = session.resources
        } catch {
            check.apiSkip = "no API key: " + XlessError.wrapping(error, stage: .account).cause
        }
        var transport: URLSessionAppleTransport?
        if AppleWebCLI.cache.info() != nil {
            do {
                let opened = try await LiveCheckWeb.kept(team: AccountSession.resolveTeam(flag: team.team, saved: AccountSession.savedTeam()), verbose: verbose)
                check.web = opened.session
                transport = opened.transport
            } catch {
                check.webSkip = "the kept session could not be used: " + XlessError.wrapping(error, stage: .account).cause
            }
        } else {
            check.webSkip = "no session kept by `xless auth login --keep`"
        }
        let lines = await check.run()
        if let web = check.web { await web.end() }
        transport?.invalidate()
        if output.json {
            let failed = lines.contains { $0.status == .fail }
            FileHandle.standardOutput.write(Data(try ASCOutput.json(LiveCheckReport(passed: !failed, checks: lines)).utf8))
        } else {
            FileHandle.standardOutput.write(Data(LiveCheck.text(lines).utf8))
        }
        if lines.contains(where: { $0.status == .fail }) { throw ExitCode(1) }
    }
}

struct LiveCheckReport: Encodable {
    var passed: Bool
    var checks: [LiveCheckLine]
}

/// The kept session behind the read-only guard (never a sign-in), its team selected.
enum LiveCheckWeb {
    static func kept(team: String?, verbose: Bool) async throws -> (session: AppleWebSession, transport: URLSessionAppleTransport) {
        SecretScope.enter()
        let transport = URLSessionAppleTransport()
        let traced: AppleTransport = verbose ? TracingAppleTransport(transport, trace: .standardError) : transport
        let web = AppleWebClient(transport: ReadOnlyAppleTransport(inner: traced), userAgent: "xless/\(XlessVersion.current)", stage: .account)
        do {
            let session = try await AppleWebSession.open(web: web, cache: AppleWebCLI.cache) {
                throw XlessError(.account, "the kept session has expired", fix: "`xless auth login --keep`")
            }
            let selected = try await session.selectTeam(team)
            try await session.useProvider(for: selected, choose: nil)
            return (session, transport)
        } catch {
            transport.invalidate()
            throw error
        }
    }
}
