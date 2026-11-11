import ArgumentParser
import Foundation
import XlessAppleID
import XlessCore
import XlessSDK

struct XcodeDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Sign in to Apple once and download one or more Xcode .xips (for xless setup --xcode).",
        discussion: """
        Asks for your Apple ID, its password and the two-factor code on the terminal, signs in to Apple directly (no \
        browser; the password itself is never sent, as in Apple's own sign-in), then downloads each requested Xcode in \
        that one session. Nothing of the sign-in is stored: no password, code, cookie or token is written to disk, \
        logged or passed to another program, and the session ends with the command.

        Versions are Apple's names without "Xcode": 26.2, 27 (or 27.0), "26 beta 3"; as separate arguments and/or \
        comma-separated (26.2,27.0). Every version is checked against Apple's list before anything downloads; --list \
        shows the names. Where Apple offers a Universal and an Apple silicon .xip, the Universal one is taken.

        Each .xip downloads to <output-dir>/<Apple's file name> through a .part file; an interrupted run resumes it, and \
        a file already there is kept. Afterwards each file's SHA-256 is checked against the Xcodes xless supports (and \
        recorded as <name>.sha256, so a re-run does not read the file again).
        """)

    @Argument(help: "Xcode versions, e.g. 26.2 27.0 or 26.2,27.0.") var versions: [String] = []
    @Option(help: "Directory the .xips go to (created if missing).") var outputDir = "."
    @Flag(help: "List the Xcode releases Apple offers, and download nothing.") var list = false

    func validate() throws {
        if !list && XcodeVersionMatch.tokens(versions).isEmpty {
            throw ValidationError("name at least one Xcode version (e.g. xless xcode download 26.2 27.0), or pass --list")
        }
    }

    func run() async throws {
        try await withStage(.sdk) {
            do {
                try await download()
            } catch let e as URLError {
                throw DownloadReport.networkError(e)
            }
        }
    }

    private func download() async throws {
        CoreDumps.disable()
        let env = ProcessInfo.processInfo.environment
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = XcodeSource.absolute(outputDir, cwd: cwd, home: home)
        if !list {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                throw XlessError(.sdk, "cannot create \(dir.path): \(error.localizedDescription)", fix: "pass a writable --output-dir")
            }
            guard FileManager.default.isWritableFile(atPath: dir.path) else {
                throw XlessError(.sdk, "\(dir.path) is not writable", fix: "pass a writable --output-dir")
            }
        }

        let prompter = try TerminalPrompter()
        let transport = URLSessionAppleTransport()
        defer { transport.invalidate() }
        let client = AppleWebClient(transport: transport, userAgent: "xless/\(XlessVersion.current)")
        try await AppleSignIn(client: client, prompter: prompter).run()
        prompter.say("Signed in to Apple.")
        let downloads = try await DeveloperDownloads.list(client: client)

        if list {
            for d in downloads {
                let xips = d.files.filter { $0.remotePath.lowercased().hasSuffix(".xip") }
                let files = xips.map { "\($0.name)\($0.fileSize.map { " (\(DownloadReport.size($0)))" } ?? "")" }
                print("\(d.name)\t\(files.isEmpty ? "no .xip" : files.joined(separator: ", "))")
            }
            await client.signOut()
            return
        }

        let resolved = try XcodeVersionMatch.resolve(XcodeVersionMatch.tokens(versions), in: downloads)
        try checkSpace(DownloadReport.bytesStillNeeded(resolved.map(\.file), in: dir), dir: dir)
        let known = (try? knownXcodes(env: env)) ?? []
        var done: [URL] = []
        var failed: [(name: String, error: any Error)] = []
        for (i, r) in resolved.enumerated() {
            let size = r.file.fileSize.map { ", \(DownloadReport.size($0))" } ?? ""
            FileHandle.standardError.write(Data("[\(i + 1)/\(resolved.count)] \(r.download.name): \(r.file.name)\(size)\n".utf8))
            let meter = ProgressMeter(total: r.file.fileSize)
            do {
                let result = try await DeveloperDownloads.download(r.file, into: dir, client: client, progress: meter.update)
                meter.finish(skipped: result.skipped)
                let sum = try XipDigest.sha256(of: result.url) { try XcodeSource.sha256(of: $0) }
                print("\(result.url.path)\t\(DownloadReport.identity(sha256: sum, known: known))")
                done.append(result.url)
            } catch {
                meter.abandon()
                FileHandle.standardError.write(Data("  failed: \(XlessError.wrapping(error, stage: .sdk).cause); going on with the next\n".utf8))
                failed.append((r.download.name, error))
            }
        }
        await client.signOut()
        if !done.isEmpty {
            FileHandle.standardError.write(Data("Next, for each Xcode: \(done.map { "xless setup --xcode \($0.path)" }.joined(separator: " ; "))\n".utf8))
        }
        if let error = DownloadReport.failures(failed, of: resolved.count) { throw error }
    }

    private func checkSpace(_ needed: Int64, dir: URL) throws {
        guard needed > 0, let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return }
        let margin: Int64 = 1_000_000_000
        if free < needed + margin {
            throw XlessError(.sdk, "\(DownloadReport.size(free)) free under \(dir.path); the downloads need about \(DownloadReport.size(needed + margin))",
                             fix: "free some space, pass another --output-dir, or download fewer versions at a time")
        }
    }

    private func knownXcodes(env: [String: String]) throws -> [KnownXcode] {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let share = try XlessShare.root(env: env, executable: exe)
        return try KnownXcodes.load(versionsEnv: share.appendingPathComponent("versions.env"))
    }
}

/// Download progress on stderr: one rewritten line on a terminal, a line per 10% otherwise.
final class ProgressMeter: @unchecked Sendable {
    private let total: Int64?
    private let tty = isatty(STDERR_FILENO) == 1
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastTenth = -1
    private var started = Date()
    private var startBytes: Int64 = -1
    private var bytes: Int64 = 0

    init(total: Int64?) { self.total = total }

    func update(_ done: Int64) {
        lock.withLock {
            if startBytes < 0 { startBytes = done; started = Date() }
            bytes = done
            let now = Date()
            if tty {
                guard now.timeIntervalSince(last) >= 0.5 else { return }
                last = now
                FileHandle.standardError.write(Data("\r\u{1B}[K  \(line(now))".utf8))
            } else if let total, total > 0 {
                let tenth = Int(done * 10 / total)
                guard tenth > lastTenth else { return }
                lastTenth = tenth
                FileHandle.standardError.write(Data("  \(line(now))\n".utf8))
            }
        }
    }

    func finish(skipped: Bool) {
        lock.withLock {
            let text = skipped ? "  already downloaded" : "  \(line(Date()))"
            FileHandle.standardError.write(Data(((tty ? "\r\u{1B}[K" : "") + text + "\n").utf8))
        }
    }

    /// Ends a rewritten progress line before a failure is printed.
    func abandon() {
        lock.withLock { if tty { FileHandle.standardError.write(Data("\n".utf8)) } }
    }

    private func line(_ now: Date) -> String {
        let elapsed = now.timeIntervalSince(started)
        let rate = elapsed > 1 ? Double(bytes - max(startBytes, 0)) / elapsed : 0
        var s = DownloadReport.size(bytes)
        if let total, total > 0 { s += " of \(DownloadReport.size(total)) (\(bytes * 100 / total)%)" }
        if rate > 0 { s += String(format: ", %.1f MB/s", rate / 1e6) }
        return s
    }
}
