import Foundation
import Testing
import XlessAgent
import XlessASC
import XlessCore
@testable import XlessAppleID
@testable import XlessVault
@testable import xless

// The one question after a passphrase or a sign-in: keep both for this terminal?

/// Answers questions from a script; keeps what was asked and said.
final class ScriptedTerminal: PassphrasePrompter, Confirming, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var log: (questions: [String], secrets: [String], said: [String]) = ([], [], [])

    init(_ answers: [String] = []) { self.answers = answers }

    var questions: [String] { lock.withLock { log.questions } }
    var secrets: [String] { lock.withLock { log.secrets } }
    var said: [String] { lock.withLock { log.said } }

    private func next(_ prompt: String) throws -> String {
        guard !answers.isEmpty else { throw XlessError(.config, "nobody answers \(prompt)", fix: "-") }
        return answers.removeFirst()
    }
    func ask(_ prompt: String) throws -> String { try lock.withLock { log.questions.append(prompt); return try next(prompt) } }
    func askSecret(_ prompt: String) throws -> SecretBytes { try lock.withLock { log.secrets.append(prompt); return SecretBytes(utf8: try next(prompt)) } }
    func confirm(_ question: String) throws -> Bool { try ask("\(question) [y/N] ") == "y" }
    func say(_ line: String) { lock.withLock { log.said.append(line) } }
}

private func offer(_ agents: FakeAgents, _ keep: KeepAnswer = .ask, isOff: Bool = false, keyring: FakeKeyring = FakeKeyring(available: false)) -> KeepOffer {
    KeepOffer(agents: agents, cache: HeldKeyCache(agents: agents, keyring: keyring, isOff: false, maximum: 7 * 86400, say: { _ in }),
              settings: UnlockSettings(keep: keep), isOff: isOff, command: "xless certs create")
}

extension KeepOffer {
    /// What is agreed to is held, as the unlock or the sign-in does after the question.
    fileprivate func keep(store terminal: ScriptedTerminal) -> SecretHold? { made(offer(terminal), terminal) }
    fileprivate func keep(session terminal: ScriptedTerminal) -> SecretHold? { made(session(terminal), terminal) }
    private func made(_ hold: SecretHold?, _ terminal: ScriptedTerminal) -> SecretHold? {
        if hold != nil { kept(true, terminal) }
        return hold
    }
}

private let standard = SecretHold(seconds: 8 * 3600, idle: 2 * 3600, maximum: 7 * 86400)

@Suite struct KeepOfferTests {
    @Test func oneQuestionCoversTheStoreAndTheSignIn() {
        let agents = FakeAgents(), terminal = ScriptedTerminal(["y"])
        let o = offer(agents)
        #expect(o.keep(store: terminal) == standard)
        #expect(o.keep(session: terminal) == standard)
        #expect(terminal.questions.count == 1)
        #expect(terminal.questions.first?.hasSuffix("[y/N] ") == true)
        let said = terminal.said.joined(separator: "\n")
        for part in ["8 h", "2 h without use", "xless lock", "Apple ID", "secret store", "this terminal", "keep: always"] { #expect(said.contains(part), "\(part)") }
    }

    @Test(arguments: ["", "n", "no", "maybe", "Y E S"])
    func anythingButYesKeepsNothingAndIsNotAskedTwice(answer: String) {
        let agents = FakeAgents(), terminal = ScriptedTerminal([answer])
        let o = offer(agents)
        #expect(o.keep(session: terminal) == nil)
        #expect(o.keep(store: terminal) == nil)
        #expect(terminal.questions.count == 1)
        #expect(agents.names.isEmpty)
        #expect(terminal.said.contains { $0.contains("keep: never") })
    }

    @Test func aTerminalThatClosesKeepsNothing() {
        #expect(offer(FakeAgents()).keep(store: ScriptedTerminal([])) == nil)
    }

    @Test func theNextCommandOfTheTerminalIsNotAskedAgainAndSaysThatItKeeps() {
        let agents = FakeAgents()
        _ = offer(agents).keep(session: ScriptedTerminal(["yes"]))
        #expect(agents.names == ["xless-keep"])
        let terminal = ScriptedTerminal()
        #expect(offer(agents).keep(store: terminal) == standard)
        #expect(terminal.questions.isEmpty)
        #expect(terminal.said.contains { $0.contains("stays unlocked") && $0.contains("xless lock") })
    }

    @Test func aYesLastsNoLongerThanWhatItWasGivenFor() {
        let agents = FakeAgents()
        _ = offer(agents).keep(session: ScriptedTerminal(["y"]))
        agents.age(by: 7 * 3600)
        #expect(offer(agents).keep(store: ScriptedTerminal()) == SecretHold(seconds: 3600, idle: 3600, maximum: 7 * 86400))
        agents.age(by: 3600 - 30) // too little left to be worth holding: asked again
        #expect(offer(agents).keep(store: ScriptedTerminal(["n"])) == nil)
    }

    @Test func nothingIsSaidToBeKeptBeforeItIs() {
        for keep in [KeepAnswer.ask, .always] {
            let agents = FakeAgents(), terminal = ScriptedTerminal(["y"]), o = offer(agents, keep)
            #expect(o.offer(terminal) == standard)
            #expect(!terminal.said.contains { $0.contains("Kept") } && agents.names.isEmpty)
            o.kept(true, terminal)
            #expect(terminal.said.filter { $0.contains("Kept") }.count == 1 && agents.names == ["xless-keep"])
            // The sign-in that follows in the same command.
            #expect(o.session(terminal) == standard)
            #expect(!terminal.said.contains { $0.contains("as you agreed") })
            o.kept(true, terminal)
            #expect(terminal.said.last?.contains("Apple ID session is kept") == true)
        }
    }

    @Test func whatCouldNotBeHeldIsNotSaidToBeNorAskedForAgain() {
        for keep in [KeepAnswer.ask, .always] {
            let agents = FakeAgents(), terminal = ScriptedTerminal(["y"]), o = offer(agents, keep)
            #expect(o.offer(terminal) == standard)
            o.kept(false, terminal)
            #expect(!terminal.said.contains { $0.contains("Kept") } && agents.names.isEmpty)
            #expect(o.session(terminal) == nil && terminal.questions.count <= 1)
        }
    }

    @Test func aYesForLaterIsSaidToBeKeptOnlyWhenItIs() {
        let agents = FakeAgents(), terminal = ScriptedTerminal(["y"])
        agents.failure = AgentError(.failed, "the agent did not start", fix: "try again")
        offer(agents).also(.session, terminal)
        #expect(terminal.questions.count == 1 && !terminal.said.contains { $0.contains("Kept") })
        #expect(terminal.said.contains { $0.contains("not kept") && $0.contains("the agent did not start") }, "\(terminal.said)")
        // The keyring holds no yes: not asked.
        agents.failure = nil
        agents.obstacle = AgentError(.unavailable, "no session here", fix: "-")
        let none = ScriptedTerminal()
        offer(agents, keyring: FakeKeyring()).also(.session, none)
        #expect(none.questions.isEmpty && none.said.isEmpty)
    }

    @Test func aYesIsOfTheTerminalItWasGivenIn() {
        let agents = FakeAgents()
        _ = offer(agents).keep(session: ScriptedTerminal(["y"]))
        agents.needsWitness = true // they are another terminal's, which a command that has the store's key could use
        let no = ScriptedTerminal(["n"])
        #expect(offer(agents).keep(session: no) == nil)
        #expect(no.questions.count == 1)
        #expect(offer(agents).agreedUntil() == nil)
    }

    @Test func aYesOfThisTerminalLastsNoLongerForALongerOneOfAnother() {
        let agents = FakeAgents()
        _ = offer(agents).keep(session: ScriptedTerminal(["y"]))
        agents.age(by: 7 * 3600)
        let item = AgentItemStatus(name: "xless-keep", label: "", remaining: 8 * 3600, idle: 1, idleRemaining: 1)
        agents.elsewhere = [AgentStatus(isGranted: true, count: 1, remaining: 8 * 3600, sessions: 2, items: [item], isSameSession: false)]
        #expect(offer(agents).keep(session: ScriptedTerminal())?.seconds == 3600)
    }

    @Test func theConfigurationAnswersIt() {
        let agents = FakeAgents(), terminal = ScriptedTerminal()
        #expect(offer(agents, .always).keep(store: terminal) == standard)
        #expect(terminal.said.contains { $0.contains("8 h") && $0.contains("keep: always") }) // never silently
        #expect(offer(FakeAgents(), .never).keep(store: terminal) == nil)
        #expect(terminal.questions.isEmpty)
        // `never` is also the answer to an earlier yes.
        #expect(offer(agents, .never).keep(store: terminal) == nil)
    }

    @Test func whereNothingMayBeAskedNothingIsKept() {
        for keep in [KeepAnswer.ask, .always] {
            let agents = FakeAgents(), terminal = ScriptedTerminal()
            #expect(offer(agents, keep, isOff: true).keep(store: terminal) == nil)
            #expect(offer(agents, keep, isOff: true).keep(session: terminal) == nil)
            #expect(terminal.questions.isEmpty && terminal.said.isEmpty && agents.names.isEmpty)
        }
    }

    @Test func whereNothingCanBeHeldNothingIsOffered() {
        let agents = FakeAgents(), terminal = ScriptedTerminal()
        agents.obstacle = AgentError(.unavailable, "no leader", fix: "-")
        #expect(offer(agents).keep(store: terminal) == nil)
        #expect(terminal.questions.isEmpty)
        // The keyring holds for an hour, without an idle time: that is what the question says.
        let asked = ScriptedTerminal(["y"])
        #expect(offer(agents, keyring: FakeKeyring()).keep(store: asked)?.seconds == 8 * 3600)
        #expect(asked.said.contains { $0.contains("1 h") && !$0.contains("without use") })
    }

    @Test func itIsNotAskedInCINoInputASessionOrBuildCode() {
        #expect(!KeepOffer.isOff(env: [:], inSession: false))
        #expect(KeepOffer.isOff(env: [:], inSession: true))
        for env in [["CI": "true"], ["CI": "1"], ["XLESS_NO_INPUT": "1"], ["XLESS_NO_SECRET_STORE": "1"]] {
            #expect(KeepOffer.isOff(env: env, inSession: false), "\(env)")
        }
        #if !os(Windows) && !XLESS_WINDOWS_TARGETS // `xless run` says it, which is not on Windows
        #expect(KeepOffer.isOff(env: ["XLESS_RUN_KEEPS_NOTHING": "1"], inSession: false))
        #endif
        for env in [["CI": ""], ["CI": "false"], ["CI": "0"], ["XLESS_NO_INPUT": "0"]] { #expect(!KeepOffer.isOff(env: env, inSession: false), "\(env)") }
    }

    @Test func anUnlockOffersToKeepTheSignInTooAndTheOtherWayRound() {
        let agents = FakeAgents(), terminal = ScriptedTerminal(["y"])
        offer(agents).also(.session, terminal)
        #expect(terminal.questions.count == 1 && terminal.questions[0].contains("Apple ID"))
        #expect(offer(agents).keep(session: ScriptedTerminal()) == standard)
        // Already answered for this terminal.
        offer(agents).also(.store, ScriptedTerminal())
        let other = ScriptedTerminal(["n"])
        offer(FakeAgents()).also(.store, other)
        #expect(other.questions.first?.contains("secret store") == true)
    }

    @Test func theStatusShowsAYes() throws {
        let agents = FakeAgents(), now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(offer(agents).agreedUntil(now: now) == nil)
        _ = offer(agents).keep(session: ScriptedTerminal(["y"]))
        let until = try #require(offer(agents).agreedUntil(now: now))
        #expect(until == now.addingTimeInterval(8 * 3600))
        let r = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, agreedUntil: until, now: now)
        #expect(r.keepUntil == AuthStatusReport.iso(until))
        #expect(r.text.contains("until \(AuthStatusReport.iso(until))") && r.text.contains("as you agreed"))
        let none = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, now: now)
        #expect(none.keepUntil == nil && !none.text.contains("as you agreed"))
    }

    @Test func authStatusShowsTheSessionsThatRun() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func lease(_ command: String, _ names: [String], remaining: Int, here: Bool) -> AgentStatus {
            let items = names.map { AgentItemStatus(name: $0, label: "", remaining: remaining, idle: 1, idleRemaining: 1) }
            return AgentStatus(isGranted: here, count: names.count, remaining: remaining, sessions: 1, items: items, isSameSession: here,
                               lease: AgentLeaseStatus(command: command, remaining: remaining))
        }
        let leases = [lease("xless session (release.sh)", ["xless-vault:1", "xless-apple-session", "xless-apple-session-key"], remaining: 3600, here: true),
                      lease("xless run", ["xless-vault"], remaining: 60, here: false)]
        let r = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, leases: leases, now: now)
        #expect(r.sessions == [.init(command: "xless session (release.sh)", holds: ["store", "session"], expires: AuthStatusReport.iso(now + 3600), remainingSeconds: 3600, thisTerminal: true),
                               .init(command: "xless run", holds: ["store"], expires: AuthStatusReport.iso(now + 60), remainingSeconds: 60, thisTerminal: false)])
        #expect(r.text.contains("xless session (release.sh) in this terminal: the secret store's unlock and an Apple ID session, until it ends, \(AuthStatusReport.iso(now + 3600)) at the latest (1 h left)"), "\(r.text)")
        #expect(r.text.contains("xless run in another terminal: the secret store's unlock, until it ends"), "\(r.text)")
        #expect(try ASCOutput.json(r).contains("\"holds\""))
        let none = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, now: now)
        #expect(none.sessions.isEmpty && !none.text.contains("at the latest"))
    }

    @Test func aYesCanBeWithdrawn() {
        let agents = FakeAgents()
        _ = offer(agents).keep(session: ScriptedTerminal(["y"]))
        offer(agents).withdraw()
        #expect(agents.names.isEmpty)
    }

    @Test func theLineBeforeASignInSaysWhyAndHowLong() {
        #expect(offer(FakeAgents()).signInAnnouncement(offering: true)
            == "xless certs create signs in to Apple: Apple's documented API does not cover what it does. Asked once for this command, and forgotten when it ends unless you keep it.")
        #expect(offer(FakeAgents(), isOff: true).signInAnnouncement(offering: true).hasSuffix("and forgotten when it ends."))
        #expect(offer(FakeAgents()).signInAnnouncement(offering: false) == "xless certs create signs in to Apple.")
    }

    @Test func theLineBeforeThePassphraseSaysWhatWhyAndHowLong() {
        let agents = FakeAgents()
        let line = offer(agents).announcement(reason: "the secret ASC_KEY_P8", remember: nil)
        #expect(line == "xless certs create opens the secret store (the secret ASC_KEY_P8). The passphrase is asked once for this command, and forgotten when it ends unless you keep it.")
        #expect(offer(agents, .never).announcement(reason: "r", remember: nil)?.hasSuffix("and forgotten when it ends.") == true)
        let kept = offer(agents).announcement(reason: "unlocking", remember: SecretHold(seconds: 1800, idle: 600, maximum: 7200))
        #expect(kept?.contains("30 min") == true && kept?.contains("10 min without use") == true && kept?.contains("xless lock") == true)
    }
}

@Test func aCommandIsNamedByItsPath() {
    #expect(RunningCommand.path(of: CertsCreateCommand.self) == "xless certs create")
    #expect(RunningCommand.path(of: UnlockCommand.self) == "xless unlock")
    #expect(RunningCommand.path(of: Xless.self) == "xless")
}
