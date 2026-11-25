import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
@testable import XlessCore
@testable import xless

/// Scripted App Store Connect responses; records the requests.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct FakeTerminal: Confirming {
    var answer: Bool
    func confirm(_ question: String) throws -> Bool { answer }
}

let fakeKeyEnv = ["ASC_KEY_ID": "KEY123", "ASC_ISSUER_ID": "iss-1", "ASC_KEY_P8": P256.Signing.PrivateKey().pemRepresentation]

@Test func confirmPassesWithYesWithoutAskingAnyone() throws {
    #expect(try AccountConfirm.confirm("Delete?", action: "deleting X", yes: true, terminal: { Issue.record("asked"); return nil }))
}

@Test func confirmRefusesWithoutATerminal() throws {
    do { _ = try AccountConfirm.confirm("Delete?", action: "deleting device D1", yes: false, terminal: { nil }); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause == "deleting device D1 needs a confirmation and there is no terminal")
        #expect(e.fix == "re-run with --yes")
    }
}

@Test func withoutInputAConfirmationIsRefusedWithItsOwnExitCodeUnlessYesIsGiven() throws {
    let error = #expect(throws: XlessError.self) {
        try InputGate.$forced.withValue(true) {
            try AccountConfirm.confirm("Delete?", action: "deleting device D1", yes: false, terminal: { Issue.record("asked"); return nil })
        }
    }
    #expect(error?.stage == .input)
    #expect(error?.cause.contains("deleting device D1") == true)
    #expect(error?.fix == "re-run with --yes")
    #expect(try InputGate.$forced.withValue(true) { try AccountConfirm.confirm("Delete?", action: "x", yes: true, terminal: { nil }) })
}

@Test func withoutInputNoTerminalIsOpened() throws {
    for open in [{ _ = try TerminalPrompter() }, { _ = try TerminalPrompter.forSecretStore() }, { _ = try TerminalPrompter.forAccount() },
                 { _ = try AppleWebCLI.prompter() }] as [() throws -> Void] {
        let error = #expect(throws: XlessError.self) { try InputGate.$forced.withValue(true) { try open() } }
        #expect(error?.stage == .input)
    }
}

@Test func confirmReturnsTheAnswer() throws {
    #expect(try AccountConfirm.confirm("Delete?", action: "x", yes: false, terminal: { FakeTerminal(answer: true) }))
    #expect(try !AccountConfirm.confirm("Delete?", action: "x", yes: false, terminal: { FakeTerminal(answer: false) }))
}

@Test func theTeamFlagWinsOverTheSavedTeam() {
    #expect(AccountSession.resolveTeam(flag: "ABCDE12345", saved: "ZZZZZ99999") == "ABCDE12345")
    #expect(AccountSession.resolveTeam(flag: nil, saved: "ZZZZZ99999") == "ZZZZZ99999")
    #expect(AccountSession.resolveTeam(flag: nil, saved: nil) == nil)
}

@Test func teamMustBeATeamID() throws {
    #expect(throws: (any Error).self) { try APICommand.parse(["GET", "/v1/apps", "--team", "abc"]) }
    let ok = try APICommand.parse(["GET", "/v1/apps", "--team", "ABCDE12345"])
    #expect(ok.team.team == "ABCDE12345")
}

@Test func theSharedOptionsParseTogether() throws {
    struct Probe: ParsableCommand { @OptionGroup var account: AccountOptions }
    let p = try Probe.parse(["--team", "ABCDE12345", "--json", "--yes", "--verbose"])
    #expect(p.account.team.team == "ABCDE12345" && p.account.output.json && p.account.confirmation.yes && p.account.trace.verbose)
}

@Test func helpGroupsTheAppleAccountCommands() {
    let help = Xless.helpMessage()
    let group = try? #require(help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive))
    #expect(group != nil, "\(help)")
    if let group {
        let tail = help[group.upperBound...]
        #expect(tail.contains("secrets") && tail.contains("api"))
    }
}

@Test func aSessionNeedsTheAPIKeyAndFailsAsAccount() throws {
    do { _ = try AccountSession.open(team: nil, verbose: false, env: [:], fallback: { _ in nil }); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.contains("ASC_KEY_ID"))
    }
}

@Test func aSessionAsksTheStoreForItsTeam() throws {
    final class Seen: @unchecked Sendable { var team: String?? }
    let seen = Seen()
    let session = try AccountSession.open(team: "ABCDE12345", verbose: true, env: fakeKeyEnv, fallback: { seen.team = .some($0); return nil })
    #expect(seen.team == .some("ABCDE12345"))
    #expect(session.team == "ABCDE12345")
}
