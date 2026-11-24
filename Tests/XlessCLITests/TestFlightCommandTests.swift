import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private let appID = "1234567890"
private let buildID = "2f1c7a9e-0b1d-4f7a-9c33-5b2d8e0f1a11"
private let appJSON = #"{"data":{"type":"apps","id":"1234567890","attributes":{"bundleId":"com.example.app","name":"Example"}}}"#
private let prv1 = #"{"type":"preReleaseVersions","id":"PRV1","attributes":{"version":"1.2.0","platform":"IOS"}}"#
private let appRes = #"{"type":"apps","id":"1234567890","attributes":{"bundleId":"com.example.app","name":"Example"}}"#

private func group(_ id: String, _ name: String, internal isInternal: Bool = true, link: String? = nil) -> String {
    let l = link.map { #","publicLinkEnabled":true,"publicLink":"\#($0)""# } ?? #","publicLinkEnabled":false"#
    return #"{"type":"betaGroups","id":"\#(id)","attributes":{"name":"\#(name)","isInternalGroup":\#(isInternal),"hasAccessToAllBuilds":false,"feedbackEnabled":true\#(l)}}"#
}
private func tester(_ id: String, _ email: String, groups: [String] = []) -> String {
    #"{"type":"betaTesters","id":"\#(id)","attributes":{"email":"\#(email)","firstName":"Ada","lastName":"Lovelace","state":"ACCEPTED","inviteType":"EMAIL"},"relationships":{"betaGroups":{"data":[\#(groups.map { #"{"type":"betaGroups","id":"\#($0)"}"# }.joined(separator: ","))]}}}"#
}
private func list(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
private func single(_ item: String) -> String { #"{"data":\#(item)}"# }
private func build(state: String = "VALID", expired: Bool = false) -> String {
    #"{"data":{"type":"builds","id":"\#(buildID)","attributes":{"version":"42","expired":\#(expired),"processingState":"\#(state)"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"PRV1"}},"app":{"data":{"type":"apps","id":"1234567890"}}}},"included":[\#(prv1),\#(appRes)]}"#
}

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> TestFlightCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return TestFlightCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json,
                         terminal: { terminal }, say: { said.lines.append($0) })
}
private func call(_ r: URLRequest) -> String { r.httpMethod! + " " + r.url!.path }
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

@Test func testflightIsInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("testflight") } == true, "\(help)")
}

@Test func badTestFlightArgumentsAreRefusedBeforeAnythingIsSent() throws {
    let app = ["--app", "com.example.app"]
    #expect(throws: (any Error).self) { try TestFlightGroupsListCommand.parse([]) }                                        // no --app
    #expect(throws: (any Error).self) { try TestFlightGroupsCreateCommand.parse(["Beta", "--internal", "--external"] + app) }
    #expect(throws: (any Error).self) { try TestFlightGroupsCreateCommand.parse(["Beta", "--external", "--all-builds"] + app) }
    #expect(throws: (any Error).self) { try TestFlightGroupsCreateCommand.parse([" "] + app) }
    #expect(throws: (any Error).self) { try TestFlightGroupsUpdateCommand.parse(["Beta"] + app) }                         // nothing to change
    #expect(throws: (any Error).self) { try TestFlightTestersAddCommand.parse(["ada@example.com"] + app) }                // no --group
    #expect(throws: (any Error).self) { try TestFlightTestersAddCommand.parse(["ada"] + ["--group", "Beta"] + app) }
    #expect(throws: (any Error).self) { try TestFlightTestersAddCommand.parse(["a,b@example.com", "--group", "Beta"] + app) }
    #expect(throws: (any Error).self) { try TestFlightTestersAddCommand.parse(["a@example.com", "b@example.com", "--group", "B", "--first-name", "A"] + app) }
    #expect(throws: (any Error).self) { try TestFlightBuildsAddCommand.parse(["1.2.0+42"] + app) }                         // no --group
    #expect(throws: (any Error).self) { try TestFlightWhatsNewSetCommand.parse(["1.2.0+42", "--text", "a", "--file", "f"]) }
    #expect(throws: (any Error).self) { try TestFlightWhatsNewSetCommand.parse(["1.2.0+42", "--text", " "]) }
    #expect(throws: (any Error).self) { try TestFlightWhatsNewSetCommand.parse(["1.2.0+42", "--text", String(repeating: "x", count: 4001)]) }
    #expect(throws: (any Error).self) { try TestFlightWhatsNewSetCommand.parse(["1.2.0+42", "--text", "a", "--locale", "en_US"]) }
    #expect(throws: (any Error).self) { try TestFlightBetaInfoSetCommand.parse(app) }                                      // nothing to set
    #expect(throws: (any Error).self) { try TestFlightBetaInfoSetCommand.parse(["--feedback-email", "nope"] + app) }
    #expect(throws: (any Error).self) { try TestFlightBetaInfoSetCommand.parse(["--privacy-policy-url", "ftp://x"] + app) }
    #expect(throws: (any Error).self) { try TestFlightBetaInfoSetCommand.parse(["--demo-password-secret-name", "ASC_KEY_P8"] + app) }
    #expect(throws: (any Error).self) { try TestFlightPublicLinkEnableCommand.parse(["Beta", "--limit", "0"] + app) }
    #expect(throws: (any Error).self) { try TestFlightPublicLinkEnableCommand.parse(["Beta", "--limit", "5", "--no-limit"] + app) }

    let add = try TestFlightTestersAddCommand.parse(["Ada@example.com", "ada@example.com", "grace@example.com", "--group", "Beta"] + app)
    #expect(try TesterEmails.validate(add.emails) == ["Ada@example.com", "grace@example.com"])
    let info = try TestFlightBetaInfoSetCommand.parse(["--demo-account-name", "demo", "--demo-required"] + app)
    #expect(info.reviewGiven && info.demoRequired == true)
}

@Test func groupsAreListedInATable() async throws {
    let t = FakeTransport([(200, appJSON), (200, list([group("G1", "Internal"), group("G2", "Public Beta", internal: false, link: "https://testflight.apple.com/join/abc")]))])
    let out = try await cli(t).groups(app: appID)
    #expect(out.contains("Public Beta") && out.contains("external") && out.contains("https://testflight.apple.com/join/abc"))
    #expect(t.requests.map(call) == ["GET /v1/apps/\(appID)", "GET /v1/betaGroups"])
}

@Test func creatingAGroupThatExistsSendsNothing() async throws {
    let t = FakeTransport([(200, appJSON), (200, list([group("G1", "Beta", internal: false)]))])
    let out = try await cli(t).createGroup("Beta", app: appID, external: true, allBuilds: false, feedback: nil)
    #expect(out == "com.example.app already has the external group Beta (G1); nothing was sent\n")
    #expect(t.requests.count == 2)
}

@Test func deletingAGroupAsksAndNoSendsNothing() async throws {
    let said = Said()
    let t = FakeTransport([(200, appJSON), (200, list([group("G1", "Beta")]))])
    #expect(try await cli(t, terminal: FakeTerminal(answer: false), said: said).deleteGroup("Beta", app: appID, yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"] && t.requests.count == 2)
    let yes = FakeTransport([(200, appJSON), (200, list([group("G1", "Beta")])), (204, "")])
    #expect(try await cli(yes).deleteGroup("Beta", app: appID, yes: true).contains("deleted group Beta"))
    #expect(call(yes.requests[2]) == "DELETE /v1/betaGroups/G1")
}

@Test func addingTestersReportsEachOneAndSkipsMembers() async throws {
    let t = FakeTransport([
        (200, appJSON), (200, list([group("G2", "Beta", internal: false)])),
        (200, list([tester("T1", "ada@example.com")])),                         // members
        (200, list([])), (201, single(tester("T2", "grace@example.com"))),      // grace: new
    ])
    let out = try await cli(t).addTesters(["ADA@example.com", "grace@example.com"], app: appID, group: "Beta", firstName: nil, lastName: nil)
    #expect(out.contains("ADA@example.com") == false && out.contains("ada@example.com is already in group Beta"))
    #expect(out.contains("added grace@example.com to group Beta (new tester T2)"))
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func anInternalGroupRefusesSomeoneWhoIsNotAUser() async throws {
    let t = FakeTransport([
        (200, appJSON), (200, list([group("G1", "Internal")])), (200, list([])),
        (200, list([#"{"type":"users","id":"U1","attributes":{"username":"ada@example.com"}}"#])),
    ])
    do { _ = try await cli(t).addTesters(["stranger@example.com"], app: appID, group: "Internal", firstName: nil, lastName: nil); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix.contains("xless users invite stranger@example.com")) }
    #expect(!t.requests.contains { $0.httpMethod == "POST" })
}

@Test func removingSomeoneNotInTheGroupIsRefusedBeforeAsking() async throws {
    let t = FakeTransport([(200, appJSON), (200, list([group("G1", "Beta")])), (200, list([tester("T1", "ada@example.com")]))])
    do { _ = try await cli(t).removeTesters(["grace@example.com"], app: appID, group: "Beta", yes: true); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause == "grace@example.com is not a tester of group Beta; nothing was sent") }
    let ok = FakeTransport([(200, appJSON), (200, list([group("G1", "Beta")])), (200, list([tester("T1", "ada@example.com")])), (204, "")])
    _ = try await cli(ok).removeTesters(["Ada@example.com"], app: appID, group: "Beta", yes: true)
    #expect(call(ok.requests[3]) == "DELETE /v1/betaGroups/G1/relationships/betaTesters")
}

@Test func aBuildIsAddedOnlyToTheGroupsThatLackIt() async throws {
    let said = Said()
    let t = FakeTransport([
        (200, build()), (200, list([group("G1", "Internal"), group("G2", "Beta", internal: false)])),
        (200, list([#"{"type":"betaGroups","id":"G1"}"#])), (204, ""),
    ])
    let out = try await cli(t, said: said).buildGroups(add: true, .id(buildID), app: nil, platform: nil, groups: ["Internal", "Beta"], yes: false)
    #expect(out == "added build 1.2.0+42 (\(buildID)) to Beta\n")
    #expect(try body(t.requests[3])["data"] == .array([.object(["type": .string("betaGroups"), "id": .string("G2")])]))
    #expect(said.lines.contains { $0.contains("beta-review submit") })
}

@Test func anUnprocessedBuildIsNotSubmitted() async throws {
    let t = FakeTransport([(200, build(state: "PROCESSING"))])
    do { _ = try await cli(t).submit(.id(buildID), app: nil, platform: nil); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix.contains("xless builds wait")) }
    #expect(t.requests.count == 1)
}

@Test func theBetaReviewStatusSaysWhenNothingWasSubmitted() async throws {
    let t = FakeTransport([(200, build()), (200, list([]))])
    let out = try await cli(t).status(.id(buildID), app: nil, platform: nil)
    #expect(out.contains("not submitted") && out.contains("xless testflight beta-review submit \(buildID)"))
}

@Test func aRequiredDemoAccountNeedsAName() async throws {
    let t = FakeTransport([(200, appJSON), (200, single(#"{"type":"betaAppReviewDetails","id":"R1","attributes":{"demoAccountRequired":false}}"#))])
    do {
        _ = try await cli(t).setBetaInfo(app: appID, locale: "en-US", text: BetaInfoText(), review: BetaReviewChange(demoAccountRequired: true), license: nil) { _ in
            Issue.record("password read"); return ""
        }
        Issue.record("expected throw")
    } catch let e as XlessError { #expect(e.fix.contains("--demo-account-name")) }
    #expect(t.requests.count == 2)
}

@Test func betaInfoSetSendsThePasswordFromTheSecret() async throws {
    let t = FakeTransport([
        (200, appJSON), (200, single(#"{"type":"betaAppReviewDetails","id":"R1","attributes":{"demoAccountRequired":false}}"#)),
        (200, single(#"{"type":"betaAppReviewDetails","id":"R1","attributes":{"demoAccountName":"demo","demoAccountRequired":true}}"#)),
    ])
    var asked: [String] = []
    let out = try await cli(t).setBetaInfo(app: appID, locale: "en-US", text: BetaInfoText(),
                                           review: BetaReviewChange(demoAccountName: "demo", demoAccountRequired: true), license: nil) { name in
        asked.append(name); return "pw-1234"
    }
    #expect(asked == ["XLESS_DEMO_PASSWORD"])
    #expect(out.contains("demoAccountName, demoAccountRequired, demoAccountPassword"))
    #expect(try body(t.requests[2])["data"]?["attributes"]?["demoAccountPassword"]?.string == "pw-1234")
}

// A new app has no beta license agreement: App Store Connect answers `{"data": null}` (#105).

@Test func betaInfoOfAnAppWithoutALicenseAgreementIsShown() async throws {
    let responses = [(200, appJSON), (200, list([])), (200, single(#"{"type":"betaAppReviewDetails","id":"R1","attributes":{"demoAccountRequired":false}}"#)), (200, single("null"))]
    let shown = try await cli(FakeTransport(responses)).betaInfo(app: appID, locale: nil)
    #expect(shown.split(separator: "\n").contains { $0.hasPrefix("license agreement") && $0.hasSuffix("none") }, "\(shown)")
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(FakeTransport(responses), json: true).betaInfo(app: appID, locale: nil).utf8))
    #expect(doc["reviewDetail"]?["id"]?.string == "R1")
}

@Test func aLicenseForAnAppWithoutAnAgreementSendsNothing() async throws {
    let t = FakeTransport([(200, appJSON), (200, single("null"))])
    do {
        _ = try await cli(t).setBetaInfo(app: appID, locale: "en-US", text: BetaInfoText(), review: BetaReviewChange(demoAccountName: "demo"), license: "Be nice.") { _ in "" }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause.contains("has no beta license agreement") && e.cause.contains("nothing was sent"), "\(e.cause)")
    }
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func anInternalGroupHasNoPublicLink() async throws {
    let t = FakeTransport([(200, appJSON), (200, list([group("G1", "Internal")]))])
    await #expect(throws: XlessError.self) { _ = try await cli(t).publicLink(.enable, group: "Internal", app: appID, limit: nil, yes: true) }
    #expect(t.requests.count == 2)
}

@Test func enablingAPublicLinkPrintsIt() async throws {
    let t = FakeTransport([(200, appJSON), (200, list([group("G2", "Beta", internal: false)])),
                           (200, single(#"{"type":"betaGroups","id":"G2","attributes":{"name":"Beta","isInternalGroup":false,"publicLinkEnabled":true,"publicLink":"https://testflight.apple.com/join/xyz","publicLinkLimitEnabled":true,"publicLinkLimit":50}}"#))])
    let out = try await cli(t).publicLink(.enable, group: "Beta", app: appID, limit: .some(50), yes: false)
    #expect(out == "https://testflight.apple.com/join/xyz (at most 50 testers)\n")
    #expect(call(t.requests[2]) == "PATCH /v1/betaGroups/G2")
}
