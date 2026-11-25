import Foundation
import XlessAgent
import XlessAppleID
import XlessCore
import XlessVault

/// What is said before the passphrase's question and asked after it, or after a sign-in: one question per command, at
/// most, whether to keep both the store's unlock and the Apple ID session for this terminal (`xless unlock`,
/// `xless auth login --keep` without the commands). Enter is no; `unlock.keep` in config.yml answers it. A yes is
/// remembered by the terminal's agent, with no secret in it, for as long as it was given for.
final class KeepOffer: UnlockManner, @unchecked Sendable {
    enum Kind { case store, session }

    /// The item a yes is held as.
    static let consent = "xless-keep"
    /// A yes with less left is asked for again.
    private static let least = 60

    private let agents: any AgentHolding
    private let cache: HeldKeyCache
    private let settings: UnlockSettings?
    private let off: Bool
    private let name: @Sendable () -> String
    private var command: String { name() }
    private let lock = NSLock()
    /// What this process was answered; nil: nothing yet.
    private var answer: Answer?
    private var script: String?

    private enum Answer { case no, yes(SecretHold) }

    /// - Parameters:
    ///   - settings: nil when they cannot be read: nothing is kept.
    ///   - isOff: nothing may be asked or kept here.
    ///   - command: the command that asks, e.g. `xless certs create`.
    init(agents: any AgentHolding = HeldSecrets.agents, cache: HeldKeyCache = SecretStoreCLI.cache, settings: UnlockSettings? = try? HeldSecrets.settings.get(),
         isOff: Bool = KeepOffer.isOff(env: ProcessInfo.processInfo.environment, inSession: XlessSession.agent != nil), command: @escaping @autoclosure @Sendable () -> String = RunningCommand.name) {
        self.agents = agents
        self.cache = cache
        self.settings = settings
        off = isOff
        name = command
    }

    /// This process's.
    static let shared = KeepOffer()

    /// CI, `--no-input`, inside `xless session` (which keeps what its script needs, for as long as it runs) and the
    /// environment of build code.
    static func isOff(env: [String: String], inSession: Bool) -> Bool {
        func on(_ name: String) -> Bool { !["", "0", "false"].contains(env[name] ?? "") }
        return on("CI") || on(InputGate.variable) || on("XLESS_NO_SECRET_STORE") || inSession
    }

    /// `xless session`: what is typed is kept while `name` runs, and nothing is offered.
    func keeps(whileRunning name: String) { lock.withLock { script = name } }

    private var whileRunning: String? { lock.withLock { script } }

    // MARK: before

    func announcement(reason: String, remember: SecretHold?) -> String? {
        let what = reason == "unlocking" ? "\(command) unlocks the secret store" : "\(command) opens the secret store (\(reason))"
        if let script = whileRunning {
            return "\(command) unlocks the secret store for the xless commands of \(script). The passphrase is asked once, and the store stays unlocked for them until \(script) ends\(atMost) (`xless lock` ends it sooner)."
        }
        if let remember { return "\(what) and keeps it unlocked for the commands of this terminal, \(text(remember)); `xless lock` ends it." }
        return "\(what). The passphrase is asked once for this command, and forgotten when it ends\(canOffer ? " unless you keep it" : "")."
    }

    /// The line before a sign-in.
    /// - Parameter offering: false when the command itself says how long it is kept.
    func signInAnnouncement(offering: Bool) -> String {
        if let script = whileRunning {
            return "\(command) signs in to Apple for the xless commands of \(script). Asked once, and kept for them until \(script) ends\(atMost) (`xless lock` ends it sooner)."
        }
        guard offering else { return "\(command) signs in to Apple." }
        return "\(command) signs in to Apple: Apple's documented API does not cover what it does. Asked once for this command, and forgotten when it ends\(canOffer ? " unless you keep it" : "")."
    }

    /// The longest a script has it.
    private var atMost: String { settings.map { ", for \(HoldDuration.text($0.duration)) at most" } ?? "" }

    private var canOffer: Bool { !off && whileRunning == nil && cache.isAvailable && settings.map { $0.keep != .never } == true }

    /// "for 8 h (2 h without use)", as it can be kept here.
    private func text(_ hold: SecretHold) -> String {
        let plan = cache.plan(hold)
        return "for \(HoldDuration.text(plan.seconds))\(plan.idle.map { " (\(HoldDuration.text($0)) without use)" } ?? "")"
    }

    // MARK: after

    func offer(_ prompter: any PassphrasePrompter) -> SecretHold? { hold(.store, prompter) }

    /// Signed in, on `prompter`: how long to keep the session, when the person agrees.
    func session(_ prompter: any PassphrasePrompter) -> SecretHold? { hold(.session, prompter) }

    private func hold(_ kind: Kind, _ prompter: any PassphrasePrompter) -> SecretHold? {
        guard canOffer, let settings, let standard = try? settings.hold(nil, option: "", stage: .config) else { return nil }
        return lock.withLock {
            switch answer {
            case .no: return nil
            case .yes(let hold):
                prompter.say(Self.kept(kind, text(hold)))
                return hold
            case nil: break
            }
            if let left = consented() {
                let hold = Self.within(left, standard)
                prompter.say(Self.kept(kind, text(hold)))
                answer = .yes(hold)
                return hold
            }
            if settings.keep == .always {
                prompter.say("Kept for the commands of this terminal, \(text(standard)), as `unlock: { keep: always }` in config.yml says: the secret store's unlock and the Apple ID session. `xless lock` ends it.")
            } else {
                prompter.say("The next commands of this terminal need not ask again: the secret store can stay unlocked, and the Apple ID session of a sign-in be kept, \(text(standard)). `xless lock` ends it.")
                guard yes("Keep both for this terminal? [y/N] ", prompter) else { return nil }
            }
            agree(standard)
            return standard
        }
    }

    /// What `xless unlock` and `xless auth login --keep` ask once they have kept theirs: whether the other is kept too, when
    /// a command asks for it.
    func also(_ kind: Kind, _ prompter: any PassphrasePrompter) {
        guard canOffer, let settings, let standard = try? settings.hold(nil, option: "", stage: .config) else { return }
        lock.withLock {
            guard answer == nil, consented() == nil else { return }
            if settings.keep == .ask {
                let what = kind == .session ? "Keep the Apple ID session too, once a command signs in" : "Keep the secret store unlocked too, once a command asks its passphrase"
                guard yes("\(what) (\(text(standard)))? [y/N] ", prompter) else { return }
            }
            agree(standard)
        }
    }

    /// Until when a yes given in this terminal lasts; nil: none was.
    func agreedUntil(now: Date = Date()) -> Date? { consented().map { now.addingTimeInterval(TimeInterval($0)) } }

    /// Forgets a yes, whichever terminal it was given in; why one may not be.
    @discardableResult func withdraw() -> AgentError? {
        lock.withLock { answer = nil }
        return agents.drop(prefix: Self.consent, label: "").unreached
    }

    /// Only a typed y or yes; a terminal that closes is a no.
    private func yes(_ question: String, _ prompter: any PassphrasePrompter) -> Bool {
        let typed = ((try? prompter.ask(question)) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard typed == "y" || typed == "yes" else {
            answer = .no
            prompter.say("Nothing is kept. (`unlock: { keep: never }` in config.yml: never asked.)")
            return false
        }
        prompter.say("Kept. (`unlock: { keep: always }` in config.yml: always, without the question.)")
        return true
    }

    private func agree(_ hold: SecretHold) {
        answer = .yes(hold)
        // It is only for the next commands: where no agent can run, the yes is for this one.
        let mark = AgentSeed(name: Self.consent, label: "", secret: SecretBytes(copying: [1]), hold: SecretHold(seconds: hold.seconds, idle: hold.seconds, maximum: hold.maximum))
        try? agents.put([mark]) { nil }
    }

    /// The seconds left of a yes given in this terminal: one that another terminal's agent holds is no answer here, also
    /// where that agent serves this one.
    private func consented() -> Int? {
        guard agents.get(Self.consent, using: false, witness: { nil }) != nil else { return nil }
        let left = agents.statuses().filter { $0.isGranted && $0.isSameSession }.flatMap(\.items).filter { $0.name == Self.consent }.map(\.remaining).max() ?? 0
        return left >= Self.least ? left : nil
    }

    private static func within(_ seconds: Int, _ hold: SecretHold) -> SecretHold {
        let n = min(seconds, hold.seconds)
        return SecretHold(seconds: n, idle: min(hold.idle, n), maximum: hold.maximum)
    }

    private static func kept(_ kind: Kind, _ time: String) -> String {
        kind == .store ? "The secret store stays unlocked for the commands of this terminal, \(time), as you agreed; `xless lock` ends it."
            : "The Apple ID session is kept for the commands of this terminal, \(time), as you agreed; `xless lock` ends it."
    }
}
