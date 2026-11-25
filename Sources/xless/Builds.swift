import Foundation
import XlessASC
import XlessCore

/// What the build commands do once their arguments are valid; returns what goes to standard output and says the rest
/// (progress, notes, cancellations) on standard error.
struct BuildCLI {
    let builds: ASCBuilds
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var interval: Duration = .seconds(30)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func with(json: Bool) -> BuildCLI { var copy = self; copy.json = json; return copy }

    /// The app ID of `--app` (an app ID, or a bundle identifier looked up); nil without one.
    func appID(_ argument: String?) async throws -> String? {
        guard let argument else { return nil }
        if AppArgument.isAppID(argument) { return argument }
        return try await ASCApps(resources: builds.resources).resolve(argument).id
    }

    struct Listed: Encodable { var data: [ASCBuild]; var included: [ASCAnyResource] }
    struct Shown: Encodable { var data: ASCBuild; var included: [ASCAnyResource] }

    func list(app: String?, filter: BuildFilter, limit: Int) async throws -> String {
        var filter = filter
        filter.appID = try await appID(app)
        let listing = try await builds.list(filter, limit: limit)
        if listing.builds.count >= limit {
            say("note: showing the \(limit) most recently uploaded builds; --limit shows more")
        }
        if json { return try ASCOutput.json(Listed(data: listing.builds.map(\.build), included: listing.included)) }
        if listing.builds.isEmpty { return "no build matches\(filter.expired == false ? " (expired builds are left out: --expired lists them)" : "")\n" }
        let showApp = filter.appID == nil
        let headers = ["ID"] + (showApp ? ["APP"] : []) + ["VERSION", "BUILD", "PLATFORM", "STATE", "NON-EXEMPT ENCRYPTION", "UPLOADED", "EXPIRES"]
        return TextTable(headers, listing.builds.map { b in
            [b.id] + (showApp ? [b.bundleID ?? b.appID ?? ""] : [])
                + [b.appVersion ?? "", b.number, BuildPlatform.display(b.platform), Self.state(b.build), Self.encryption(b.build),
                   String((b.build.attributes.uploadedDate ?? "").prefix(10)), String((b.build.attributes.expirationDate ?? "").prefix(10))]
        }).rendered
    }

    static func state(_ build: ASCBuild) -> String { build.isExpired ? "expired" : build.processingState.lowercased() }

    static func encryption(_ build: ASCBuild) -> String {
        switch build.attributes.usesNonExemptEncryption {
        case true?: "yes"
        case false?: "no"
        case nil: "not answered"
        }
    }

    /// The build a command names: `--app` and `--platform` narrow a `version+number`.
    /// A build named by its ID with `--app` must be that app's.
    func resolve(_ reference: BuildReference, app: String?, platform: BuildPlatform?) async throws -> ASCBuildDetail {
        let appID = try await appID(app)
        let b = try await builds.resolve(reference, appID: appID, platform: platform)
        if let app, let appID, let owner = b.appID, owner != appID {
            throw XlessError(.account, "build \(b.id) is a build of \(b.bundleID ?? owner), not of \(app)",
                             fix: "check the build ID with `xless builds list --app \(app)`")
        }
        return b
    }

    func show(_ reference: BuildReference, app: String?, platform: BuildPlatform?) async throws -> String {
        let b = try await resolve(reference, app: app, platform: platform)
        if json { return try ASCOutput.json(Shown(data: b.build, included: b.included)) }
        let a = b.build.attributes
        let appText = [b.appName, b.bundleID.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let declaration = b.encryptionDeclarationID.map { id in
            id + (b.encryptionDeclaration?.attributes?["appEncryptionDeclarationState"]?.string.map { " (\($0.lowercased()))" } ?? "")
        } ?? "none"
        var rows = [["APP", appText.isEmpty ? (b.appID ?? "") : appText], ["VERSION", b.appVersion ?? ""], ["BUILD", b.number],
                    ["PLATFORM", BuildPlatform.display(b.platform)], ["STATE", b.build.processingState.lowercased() + (b.build.isExpired ? ", expired" : "")],
                    ["UPLOADED", a.uploadedDate ?? ""], ["EXPIRES", a.expirationDate ?? ""], ["MINIMUM OS", a.minOsVersion ?? ""],
                    ["AUDIENCE", a.buildAudienceType ?? ""], ["NON-EXEMPT ENCRYPTION", Self.encryption(b.build)], ["ENCRYPTION DECLARATION", declaration]]
        if let s = b.internalBetaState { rows.append(["TESTFLIGHT (INTERNAL)", s.lowercased()]) }
        if let s = b.externalBetaState { rows.append(["TESTFLIGHT (EXTERNAL)", s.lowercased()]) }
        var out = TextTable(["ID", b.id], rows).rendered
        if a.usesNonExemptEncryption == nil, b.encryptionDeclarationID == nil, !b.build.isExpired, a.processingState == "VALID" {
            out += "\nexport compliance is not answered: `xless builds update \(b.id) --uses-non-exempt-encryption false` "
                + "(or true, or attach a declaration with --encryption-declaration)\n"
        }
        return out
    }

    /// - Parameter appID: `--app` already resolved (`appID(_:)`), so that nothing but the poll runs once Ctrl-C is armed.
    func wait(_ reference: BuildReference, appID: String?, platform: BuildPlatform?, timeout seconds: Int) async throws -> String {
        var lastState: String??
        let waited = try await builds.wait(reference, appID: appID, platform: platform, interval: interval, timeout: .seconds(seconds), sleep: sleep) { b in
            let state = b?.build.attributes.processingState
            guard lastState != .some(state) else { return }
            lastState = .some(state)
            if let b { say("build \(b.name) (\(b.id)): \(b.build.processingState.lowercased())") } else { say("waiting for build \(reference) to appear…") }
        }
        let name = waited.build.map { "\($0.name) (\($0.id))" } ?? reference.description
        switch waited.end {
        case .finished("VALID"):
            if json, let b = waited.build { return try ASCOutput.json(Shown(data: b.build, included: b.included)) }
            return "build \(name) is valid\n"
        case .finished(let state):
            throw XlessError(.account, "build \(name) processing ended \(state.lowercased())",
                             fix: "Apple emails the reasons to the account holder and the uploader; fix the build and upload it again with a higher build number")
        case .timedOut where waited.build == nil:
            throw XlessError(.account, "build \(reference) did not appear within \(WaitTimeout.display(seconds))",
                             fix: "check that the upload went through (`xless upload`, upload.json) and `xless builds list`; re-run `xless builds wait \(reference)`")
        case .timedOut:
            throw XlessError(.account, "build \(name) is still processing after \(WaitTimeout.display(seconds))",
                             fix: "processing can take over an hour; re-run `xless builds wait \(waited.build?.id ?? reference.description)` (--timeout waits longer)")
        }
    }

    func expire(_ reference: BuildReference, app: String?, platform: BuildPlatform?, yes: Bool) async throws -> String {
        let b = try await resolve(reference, app: app, platform: platform)
        if b.build.isExpired {
            if json { return try ASCOutput.json(Shown(data: b.build, included: b.included)) }
            return "build \(b.name) (\(b.id)) is already expired; nothing was sent\n"
        }
        let of = b.bundleID.map { " of \($0)" } ?? ""
        let question = "Expire build \(b.name)\(of) (\(b.id))? Testers can no longer install it, and it cannot be undone."
        guard try AccountConfirm.confirm(question, action: "expiring build \(b.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        let updated = try await builds.expire(b.id)
        return json ? try ASCOutput.json(Shown(data: updated, included: b.included)) : "expired build \(b.name) (\(b.id))\n"
    }

    func update(_ reference: BuildReference, app: String?, platform: BuildPlatform?, usesNonExemptEncryption: Bool?, declaration: String?) async throws -> String {
        let b = try await resolve(reference, app: app, platform: platform)
        // Everything is checked before the first request that changes the build.
        let attach = declaration.flatMap { $0 == b.encryptionDeclarationID ? nil : $0 }
        if let attach {
            guard let appID = b.appID else {
                throw XlessError(.account, "App Store Connect did not say which app build \(b.id) belongs to; nothing was sent",
                                 fix: "re-run; if it persists, report it as an xless bug")
            }
            let known = try await builds.declarations(appID: appID)
            guard known.contains(where: { $0.id == attach }) else {
                let list = known.map { "\($0.id) (\(($0.attributes.appEncryptionDeclarationState ?? "state unknown").lowercased()), \(String(($0.attributes.createdDate ?? "").prefix(10))))" }
                throw XlessError(.account, "\(attach) is not an encryption declaration of \(b.bundleID ?? appID); nothing was sent",
                                 fix: known.isEmpty ? "the app has none: answer with --uses-non-exempt-encryption, or declare it in app.yml (encryption) and run `xless store push`"
                                                    : "use one of the app's: \(list.joined(separator: ", "))")
            }
        }
        var changes: [String] = []
        if let usesNonExemptEncryption, usesNonExemptEncryption != b.build.attributes.usesNonExemptEncryption {
            _ = try await builds.setUsesNonExemptEncryption(b.id, usesNonExemptEncryption)
            changes.append("uses non-exempt encryption \(Self.encryption(b.build)) → \(usesNonExemptEncryption ? "yes" : "no")")
        }
        if let attach {
            try await builds.attach(declaration: attach, to: b.id)
            changes.append("encryption declaration \(b.encryptionDeclarationID ?? "none") → \(attach)")
        }
        if json {
            let now = changes.isEmpty ? b : try await builds.get(id: b.id)
            return try ASCOutput.json(Shown(data: now.build, included: now.included))
        }
        if changes.isEmpty { return "build \(b.name) (\(b.id)) already has these values; nothing was sent\n" }
        return "updated build \(b.name) (\(b.id)): \(changes.joined(separator: ", "))\n"
    }
}

/// `--timeout` durations: `90s`, `30m`, `2h` or bare seconds; 1 s … 24 h.
enum WaitTimeout {
    static let maximum = 24 * 3600

    static func seconds(_ text: String) throws -> Int {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
        var digits = Substring(t)
        var unit = 1
        if let last = t.last, let u = units[last] { digits = t.dropLast(); unit = u }
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n > 0, n * unit <= maximum else {
            throw IdentifierInputError("--timeout \(text) is not a duration between 1s and 24h (e.g. 90s, 30m, 2h)")
        }
        return n * unit
    }

    static func display(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

/// Runs `body` in a task that a signal (Ctrl-C by default) cancels. Throws what `body` throws; `flag` says whether the
/// signal arrived, so the caller can tell a cancellation from a failure. The handler only writes a byte to a pipe
/// (async-signal-safe); a dispatch source reading the pipe cancels the task.
enum Interrupt {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        func raise() { lock.lock(); raised = true; lock.unlock() }
    }

    nonisolated(unsafe) static var pipeWrite: Int32 = -1

    static func cancelling<T: Sendable>(on sig: Int32 = SIGINT, flag: Flag, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return try await task.value }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: .global())
        source.setEventHandler {
            var byte: UInt8 = 0
            _ = read(readEnd, &byte, 1)
            flag.raise()
            task.cancel()
        }
        source.setCancelHandler { close(readEnd); close(writeEnd) }
        source.resume()
        pipeWrite = writeEnd
        // Whole: the mask and the flags of what passes signals on to the tools (`xless_spawn_session`) are part of it.
        var previous = sigaction()
        sigaction(sig, nil, &previous)
        signal(sig) { _ in
            var byte: UInt8 = 1
            _ = write(Interrupt.pipeWrite, &byte, 1)
        }
        defer {
            sigaction(sig, &previous, nil)
            pipeWrite = -1
            source.cancel()
        }
        return try await task.value
    }
}
