import ArgumentParser
import CXlessProcess
import Foundation
import XlessAgent
import XlessAppleID
import XlessCore
import XlessVault

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Run a script whose xless commands ask for nothing: one passphrase, for as long as the script runs.",
        discussion: """
        Asks the secret store's passphrase once (not at all when the store is unlocked already), then runs the command. The \
        xless commands it runs have the store unlocked; with --sign-in, an Apple ID session too (the kept one, else a \
        sign-in, before the command starts). When the command ends, or xless does, whatever ends them, what was typed for \
        it is dropped: it is in the memory of an xless agent that lives no longer than this command. `xless lock`, the \
        system going to sleep, (macOS) a locked screen and the end of `unlock.duration` (8 h, config.yml) end it sooner. \
        `xless auth status` shows it, in every terminal.

        The exit code is the command's. Ctrl-C reaches it as without xless; SIGTERM and SIGHUP are passed on to it.

        Who has it: the xless commands of the script and of what it starts, as in a terminal with the store unlocked. The \
        build tools that xless runs (compilers, SwiftPM plugins, npm, cargo) are in sessions of their own and refused; a \
        tool the script itself runs (npm install, make) is not, and could run xless: keep those out of the script \
        (docs/secrets.md#one-unlock-for-a-script).

          xless session -- ./release.sh
          xless session --sign-in -- sh -c 'xless provision apply --yes && xless run'
        """)

    @Flag(help: "Also have an Apple ID session for the script: the kept one when Apple still takes it, else a sign-in now.")
    var signIn = false
    /// `xless run`: the command that asks; what is typed is offered to be kept, as that command's.
    @Option(help: .hidden) var purpose: String?
    @Option(help: .hidden) var reason = "unlocking"
    /// `xless run`: where no agent can run, the command runs without one.
    @Flag(help: .hidden) var ifPossible = false
    @OptionGroup var trace: VerboseOption
    @Argument(parsing: .postTerminator, help: "The command, after --.") var command: [String] = []

    func validate() throws {
        guard let name = command.first, !name.isEmpty else { throw ValidationError("no command: xless session -- <command…>") }
    }

    func run() async throws {
        let script = ScriptProcess(command)
        // A command that is not there asks for nothing.
        guard let file = script.file else {
            HeldSecrets.say("xless session: \(command[0]): \(script.problem)")
            throw ExitCode(script.exitCode)
        }
        let lease = try await open(for: script.name)
        SecretStoreCLI.forgetUnlock()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ScriptProcess.path
        environment[XlessSession.variable] = lease?.path ?? XlessSession.agent
        let end = script.run(file, environment: environment)
        lease?.end()
        switch end {
        case .exit(let code): throw ExitCode(code)
        case .signal(let signal): // as the script ended
            if [SIGINT, SIGTERM, SIGHUP, SIGQUIT].contains(signal) { xless_end_by_signal(signal) }
            throw ExitCode(128 + signal)
        case .notStarted(let why):
            HeldSecrets.say("xless session: \(command[0]): \(why)")
            throw ExitCode(126)
        }
    }

    /// Unlocks, and signs in; nil: the script has nothing of its own held (there is no store, or an outer session has it).
    private func open(for name: String) async throws -> AgentLease? {
        if HeldSecrets.isOff {
            throw XlessError(.config, "XLESS_NO_SECRET_STORE=1 is set: nothing is unlocked for a script here", fix: "run the command without `xless session`")
        }
        SecretScope.enter()
        let settings = try HeldSecrets.settings.get()
        if let purpose { RunningCommand.set(purpose) } else { KeepOffer.shared.keeps(whileRunning: name) }
        // For as long as the script runs, and no longer than a hold is by default.
        let hold = SecretHold(seconds: settings.duration, idle: settings.duration, maximum: settings.maximum)
        let outer = XlessSession.agent != nil && HeldSecrets.agents.isInSession
        let client = outer ? HeldSecrets.agents : AgentClient(terms: HeldSecrets.terms)
        let store = try SecretStoreCLI.run { try store() }
        guard store != nil || signIn else { return nil }
        // The agent first, empty: where none can be, nothing is asked.
        var lease: AgentLease?
        do {
            if !outer {
                if let obstacle = client.leaseObstacle { throw obstacle }
                lease = try client.lease([], command: purpose ?? "xless session (\(name))", seconds: hold.seconds)
            }
            let session = lease.map { AgentClient(terms: HeldSecrets.terms, session: $0.path, isOwn: true) } ?? client
            if let (vault, file) = store { try session.put([try SecretStoreCLI.run { try seed(vault, file, hold) }]) }
            if signIn { try await signInNow(hold, in: session) }
            return lease
        } catch let e as AgentError {
            lease?.end()
            guard ifPossible else {
                throw XlessError(.config, "nothing can be held for a script here: \(e.cause)", fix: "run the command without `xless session` (each xless command asks by itself), or \(e.fix)")
            }
            HeldSecrets.say("note: each step asks by itself here: \(e.cause)")
            return nil
        } catch {
            lease?.end()
            throw error
        }
    }

    /// The store there is to unlock; nil: none, or a helper, which has its own lock.
    private func store() throws -> (VaultSecretStore, VaultFile)? {
        guard case .vault(let vault) = try SecretStoreCLI.backend() else { return nil }
        guard let file = try vault.vault.read() else {
            HeldSecrets.say("note: there is no secret store to unlock (\(vault.vault.location.file.path))")
            return nil
        }
        return (vault, file)
    }

    /// The store's key, as the session's agent holds it.
    private func seed(_ vault: VaultSecretStore, _ file: VaultFile, _ hold: SecretHold) throws -> AgentSeed {
        // Held already: for no longer than it may be since it was typed. Held since nobody knows when: typed again.
        try SecretStoreCLI.cache.forgetUndated(id: file.id, maximum: hold.maximum)
        let age = SecretStoreCLI.cache.held(id: file.id)?.typedAgo
        let key = try vault.key(for: file, remember: nil, reason: reason)
        return AgentSeed(name: HeldSecrets.name(ofVault: file.id), label: vault.vault.location.file.path, secret: VaultCrypto.keyBytes(key),
                         hold: hold, typedAgo: age.map { max($0, 1) } ?? 0)
    }

    private func signInNow(_ hold: SecretHold, in client: AgentClient) async throws {
        try await AccountSession.run {
            let (web, transport) = AppleWebCLI.client(verbose: trace.verbose)
            defer { transport.invalidate() }
            let (session, _) = try await AppleWebCLI.session(web, offering: purpose != nil) { try AppleWebCLI.prompter() }
            if session.kept == nil {
                let cache = AppleSessionCache(store: HeldSessionStore(agents: client, witness: { nil }), saved: nil, maximum: { HeldSecrets.maximum })
                do {
                    try await cache.keep(web, appleID: session.appleID, hold: hold)
                } catch {
                    guard ifPossible else { throw error }
                    HeldSecrets.say("note: each step signs in by itself here: \(XlessError.wrapping(error, stage: .account).cause)")
                }
            }
            await session.end()
        }
    }
}

/// The command of `xless session`, run as a shell runs it.
struct ScriptProcess {
    /// PATH as this process was started with: before xless puts its own tools first.
    nonisolated(unsafe) static var path: String?

    let command: [String]

    init(_ command: [String]) { self.command = command }

    /// As it is spoken of.
    var name: String { (command[0] as NSString).lastPathComponent }

    /// The program's file; nil when there is none that can be run (`exitCode`, `problem`).
    var file: String? {
        guard command[0].contains("/") else { return SetupCommand.which(command[0], path: Self.path) }
        return isFile && FileManager.default.isExecutableFile(atPath: command[0]) ? command[0] : nil
    }

    private var isFile: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: command[0], isDirectory: &directory) && !directory.boolValue
    }

    /// What a shell ends with when there is none.
    var exitCode: Int32 { command[0].contains("/") && FileManager.default.fileExists(atPath: command[0]) ? 126 : 127 }

    var problem: String { exitCode == 126 ? "is not a program that can be run" : "no such command" }

    enum End { case exit(Int32), signal(Int32), notStarted(String) }

    func run(_ file: String, environment: [String: String]) -> End {
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var status: Int32 = 0, bySignal: Int32 = 0
        func start(_ file: String, _ argv: [String]) -> Int32 {
            withCStrings(argv) { a in withCStrings(envp) { e in xless_run_foreground(file, a, e, &status, &bySignal) } }
        }
        var error = start(file, command)
        if error == ENOEXEC { error = start("/bin/sh", ["sh", file] + command.dropFirst()) } // a script with no #!, as shells do
        guard error == 0 else { return .notStarted(String(cString: strerror(error))) }
        return bySignal == 1 ? .signal(status) : .exit(status)
    }
}
