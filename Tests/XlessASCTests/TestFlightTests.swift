import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func testFlight(_ t: any HTTPTransport) -> ASCTestFlight {
    ASCTestFlight(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func call(_ r: URLRequest) -> String { r.httpMethod! + " " + r.url!.path }
private func q(_ r: URLRequest, _ name: String) -> String? {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

/// TestFlight fixtures (shapes of the App Store Connect API 4.6.1), module-internal for other tests.
func betaGroupJSON(_ id: String, _ name: String, internal isInternal: Bool = true, all: Bool = false, link: String? = nil, limit: Int? = nil,
                   feedback: Bool = true) -> String {
    let linkAttrs = link.map { #","publicLinkEnabled":true,"publicLink":"\#($0)""# } ?? #","publicLinkEnabled":false"#
    let limitAttrs = limit.map { #","publicLinkLimitEnabled":true,"publicLinkLimit":\#($0)"# } ?? #","publicLinkLimitEnabled":false"#
    return #"{"type":"betaGroups","id":"\#(id)","attributes":{"name":"\#(name)","isInternalGroup":\#(isInternal),"hasAccessToAllBuilds":\#(all),"feedbackEnabled":\#(feedback)\#(linkAttrs)\#(limitAttrs)}}"#
}
func betaTesterJSON(_ id: String, _ email: String, groups: [String]? = nil, state: String = "INVITED", invite: String = "EMAIL") -> String {
    let rel = groups.map { ids in #","relationships":{"betaGroups":{"data":[\#(ids.map { #"{"type":"betaGroups","id":"\#($0)"}"# }.joined(separator: ","))]}}"# } ?? ""
    return #"{"type":"betaTesters","id":"\#(id)","attributes":{"email":"\#(email)","firstName":"Ada","lastName":"Lovelace","state":"\#(state)","inviteType":"\#(invite)"}\#(rel)}"#
}
func tfList(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
func tfSingle(_ item: String) -> String { #"{"data":\#(item)}"# }
func reviewDetailJSON(name: String? = nil, required: Bool = false, contact: String? = "Ada") -> String {
    let n = name.map { #""\#($0)""# } ?? "null"
    let c = contact.map { #""\#($0)""# } ?? "null"
    return #"{"type":"betaAppReviewDetails","id":"R1","attributes":{"contactFirstName":\#(c),"demoAccountName":\#(n),"demoAccountRequired":\#(required)}}"#
}

// MARK: Groups

@Test func groupsAreListedForTheAppAndPickedByExactNameThenID() async throws {
    let t = MockTransport([(200, tfList([betaGroupJSON("G2", "QA, iOS"), betaGroupJSON("G1", "Beta", internal: false)]))])
    let groups = try await testFlight(t).groups(app: "APP1")
    #expect(groups.map(\.name) == ["Beta", "QA, iOS"])
    #expect(q(t.requests[0], "filter[app]") == "APP1" && q(t.requests[0], "filter[name]") == nil)
    #expect(ASCTestFlight.pick("QA, iOS", from: groups)?.id == "G2")
    #expect(ASCTestFlight.pick("G1", from: groups)?.id == "G1")
    #expect(ASCTestFlight.pick("beta", from: groups) == nil)          // case-sensitive
    let e = ASCTestFlight.noGroup("beta", app: "a.b", among: groups)
    #expect(e.cause == "a.b has no TestFlight group named beta" && e.fix.contains("Beta (external)"))
}

@Test func creatingAGroupThatExistsSendsNothing() async throws {
    let t = MockTransport([(200, tfList([betaGroupJSON("G1", "Beta", internal: false)]))])
    let outcome = try await testFlight(t).createGroup(name: "Beta", app: "APP1", external: true)
    guard case .unchanged(let g) = outcome else { Issue.record("expected unchanged"); return }
    #expect(g.id == "G1" && t.requests.count == 1)
}

@Test func creatingAGroupOfTheOtherKindIsRefused() async throws {
    let t = MockTransport([(200, tfList([betaGroupJSON("G1", "Beta", internal: true)]))])
    await #expect(throws: XlessError.self) { _ = try await testFlight(t).createGroup(name: "Beta", app: "APP1", external: true) }
    #expect(t.requests.count == 1)
}

@Test func anExternalGroupIsCreatedWithoutAutomaticDistribution() async throws {
    let t = MockTransport([(200, tfList([])), (201, tfSingle(betaGroupJSON("G9", "Beta", internal: false)))])
    let outcome = try await testFlight(t).createGroup(name: "Beta", app: "APP1", external: true, feedback: false)
    guard case .created(let g) = outcome else { Issue.record("expected created"); return }
    #expect(g.id == "G9" && call(t.requests[1]) == "POST /v1/betaGroups")
    let data = try body(t.requests[1])["data"]
    #expect(data?["attributes"] == .object(["name": .string("Beta"), "isInternalGroup": .bool(false), "feedbackEnabled": .bool(false)]))
    #expect(data?["relationships"]?["app"]?["data"]?["id"]?.string == "APP1")
}

@Test func aConflictOnCreateIsSettledByReadingAgainAndNeverRetried() async throws {
    let t = MockTransport([(200, tfList([])), (409, #"{"errors":[{"status":"409","title":"exists"}]}"#),
                           (200, tfList([betaGroupJSON("G3", "Internal", all: true)]))])
    let outcome = try await testFlight(t).createGroup(name: "Internal", app: "APP1", external: false, allBuilds: true)
    #expect(outcome.value.id == "G3")
    #expect(t.requests.map(call) == ["GET /v1/betaGroups", "POST /v1/betaGroups", "GET /v1/betaGroups"])
    #expect(try body(t.requests[1])["data"]?["attributes"]?["hasAccessToAllBuilds"] == .bool(true))
}

@Test func updatingAGroupSendsOnlyWhatDiffers() async throws {
    let group = ASCBetaGroup(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(betaGroupJSON("G1", "Beta", internal: false).utf8)))
    let none = MockTransport([])
    #expect(try await testFlight(none).updateGroup(group, .init(name: "Beta", feedback: true, publicLink: false, publicLinkLimit: .some(nil))) == nil)
    #expect(none.requests.isEmpty)

    let t = MockTransport([(200, tfSingle(betaGroupJSON("G1", "Beta", internal: false, link: "https://testflight.apple.com/join/abc", limit: 100)))])
    let updated = try await testFlight(t).updateGroup(group, .init(publicLink: true, publicLinkLimit: .some(100)))
    #expect(updated?.publicLink == "https://testflight.apple.com/join/abc" && updated?.publicLinkLimit == 100)
    #expect(call(t.requests[0]) == "PATCH /v1/betaGroups/G1")
    #expect(try body(t.requests[0])["data"]?["attributes"] == .object(["publicLinkEnabled": .bool(true), "publicLinkLimitEnabled": .bool(true), "publicLinkLimit": .int(100)]))
}

// MARK: Testers

private func group(_ json: String) throws -> ASCBetaGroup {
    ASCBetaGroup(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(json.utf8)))
}
private func tester(_ json: String) throws -> ASCBetaTester {
    ASCBetaTester(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(json.utf8)))
}

@Test func someoneAlreadyInTheGroupIsNotAddedAgainWhateverTheCase() async throws {
    let t = MockTransport([])
    let member = try tester(betaTesterJSON("T1", "Ada@Example.com"))
    let result = try await testFlight(t).add(BetaTesterRequest(email: "ada@example.com"), to: try group(betaGroupJSON("G1", "Beta", internal: false)),
                                             app: "APP1", members: [member], users: nil)
    guard case .alreadyInGroup(let found) = result else { Issue.record("expected alreadyInGroup"); return }
    #expect(found.id == "T1" && t.requests.isEmpty)
}

@Test func anExistingTesterIsLinkedToTheGroup() async throws {
    let t = MockTransport([(200, tfList([betaTesterJSON("T7", "ADA@example.com")])), (204, "")])
    let result = try await testFlight(t).add(BetaTesterRequest(email: "ada@example.com"), to: try group(betaGroupJSON("G1", "Beta", internal: false)),
                                             app: "APP1", members: [], users: nil)
    guard case .added(let found) = result else { Issue.record("expected added"); return }
    #expect(found.id == "T7")
    #expect(t.requests.map(call) == ["GET /v1/betaTesters", "POST /v1/betaGroups/G1/relationships/betaTesters"])
    #expect(q(t.requests[0], "filter[email]") == "ada@example.com")
    #expect(q(t.requests[0], "filter[apps]") == "APP1", "another app's tester record cannot be in this app's groups")
    #expect(try body(t.requests[1])["data"] == .array([.object(["type": .string("betaTesters"), "id": .string("T7")])]))
}

@Test func aNewTesterIsCreatedWithTheGroupOnce() async throws {
    let t = MockTransport([(200, tfList([])), (201, tfSingle(betaTesterJSON("T9", "new@example.com")))])
    let result = try await testFlight(t).add(BetaTesterRequest(email: "new@example.com", firstName: "New", lastName: "Person"),
                                             to: try group(betaGroupJSON("G1", "Beta", internal: false)), app: "APP1", members: [], users: nil)
    guard case .created(let created) = result else { Issue.record("expected created"); return }
    #expect(created.id == "T9")
    #expect(call(t.requests[1]) == "POST /v1/betaTesters")
    let data = try body(t.requests[1])["data"]
    #expect(data?["attributes"] == .object(["email": .string("new@example.com"), "firstName": .string("New"), "lastName": .string("Person")]))
    #expect(data?["relationships"]?["betaGroups"]?["data"]?[0]?["id"]?.string == "G1")
}

@Test func aTesterOfOtherAppsOnlyIsCreatedForThisApp() async throws {
    // App Store Connect has one tester record per app: linking another app's record answered 409 "Tester(s) cannot be
    // assigned" (#105).
    final class PerApp: HTTPTransport, @unchecked Sendable {
        var sent: [String] = []
        func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.append(call(r))
            func answer(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            switch call(r) {
            case "GET /v1/betaTesters": return answer(200, tfList(q(r, "filter[apps]") == "APP1" ? [] : [betaTesterJSON("T-OTHER-APP", "ada@example.com")]))
            case "POST /v1/betaTesters": return answer(201, tfSingle(betaTesterJSON("T9", "ada@example.com")))
            default: return answer(409, #"{"errors":[{"status":"409","code":"STATE_ERROR","title":"x","detail":"Tester(s) cannot be assigned"}]}"#)
            }
        }
    }
    let t = PerApp()
    let result = try await testFlight(t).add(BetaTesterRequest(email: "ada@example.com"), to: try group(betaGroupJSON("G1", "Internal")),
                                             app: "APP1", members: [], users: ["ada@example.com"])
    guard case .created(let made) = result else { Issue.record("expected created: \(result)"); return }
    #expect(made.id == "T9" && t.sent == ["GET /v1/betaTesters", "POST /v1/betaTesters"])
}

@Test func anInternalGroupTakesOnlyUsersOfTheTeam() async throws {
    let t = MockTransport([])
    do {
        _ = try await testFlight(t).add(BetaTesterRequest(email: "stranger@example.com"), to: try group(betaGroupJSON("G1", "Internal")),
                                        app: "APP1", members: [], users: ["ada@example.com"])
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause.contains("not an App Store Connect user") && e.fix.contains("xless users invite stranger@example.com"))
    }
    #expect(t.requests.isEmpty)
}

@Test func userEmailsAreNilWhenTheKeyMayNotReadUsers() async throws {
    let t = MockTransport([(403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR"}]}"#)])
    #expect(try await testFlight(t).userEmails() == nil)
    let u = MockTransport([(200, usersListJSON([userJSON("U1", "Ada@Example.com")]))])
    #expect(try await testFlight(u).userEmails() == ["ada@example.com"])
}

@Test func testersAreRemovedFromAGroupOrFromTheApp() async throws {
    let t = MockTransport([(204, ""), (204, "")])
    let tf = testFlight(t)
    let ada = try tester(betaTesterJSON("T1", "ada@example.com"))
    try await tf.remove([ada], from: try group(betaGroupJSON("G1", "Beta")))
    try await tf.remove([ada], fromApp: "APP1")
    #expect(t.requests.map(call) == ["DELETE /v1/betaGroups/G1/relationships/betaTesters", "DELETE /v1/apps/APP1/relationships/betaTesters"])
    #expect(try body(t.requests[1])["data"]?[0]?["id"]?.string == "T1")
}

@Test func anInvitationIsSentOnceWithTheTesterAndTheApp() async throws {
    let t = MockTransport([(201, tfSingle(#"{"type":"betaTesterInvitations","id":"I1"}"#))])
    let id = try await testFlight(t).invite(try tester(betaTesterJSON("T1", "ada@example.com")), app: "APP1")
    #expect(id == "I1" && call(t.requests[0]) == "POST /v1/betaTesterInvitations")
    let rel = try body(t.requests[0])["data"]?["relationships"]
    #expect(rel?["betaTester"]?["data"]?["id"]?.string == "T1" && rel?["app"]?["data"]?["id"]?.string == "APP1")

    let failing = MockTransport([(500, "{}")])
    await #expect(throws: ASCError.self) { _ = try await testFlight(failing).invite(try tester(betaTesterJSON("T1", "a@b.c")), app: "APP1") }
    #expect(failing.requests.count == 1)
}

// MARK: Builds and What to Test

@Test func buildMembershipIsReadWithTheBuildFilter() async throws {
    let t = MockTransport([(200, tfList([#"{"type":"betaGroups","id":"G1"}"#])), (204, "")])
    let tf = testFlight(t)
    #expect(try await tf.groupIDs(with: "B1", app: "APP1") == ["G1"])
    #expect(q(t.requests[0], "filter[builds]") == "B1" && q(t.requests[0], "filter[app]") == "APP1")
    try await tf.removeBuild("B1", from: [try group(betaGroupJSON("G2", "Beta"))])
    #expect(call(t.requests[1]) == "DELETE /v1/builds/B1/relationships/betaGroups")
}

private func betaGroup(_ id: String, automatic: Bool) throws -> ASCBetaGroup {
    try group(#"{"type":"betaGroups","id":"\#(id)","attributes":{"name":"Beta","isInternalGroup":true,"hasAccessToAllBuilds":\#(automatic)}}"#)
}

@Test func aBuildIsAddedThroughTheGroupAndOnlyWhenItIsNotThere() async throws {
    let t = MockTransport([(204, "")])
    guard case .alreadyInGroup = try await testFlight(t).addBuild("B1", to: betaGroup("G1", automatic: false), app: "APP1", current: ["G1"]) else {
        Issue.record("expected alreadyInGroup"); return
    }
    #expect(t.requests.isEmpty)
    let outcome = try await testFlight(t).addBuild("B1", to: betaGroup("G1", automatic: false), app: "APP1", current: ["G2"])
    guard case .added = outcome else { Issue.record("expected added"); return }
    #expect(outcome.note(build: "B1", group: "Beta") == nil)
    #expect(t.requests.map(call) == ["POST /v1/betaGroups/G1/relationships/builds"])
    #expect(try body(t.requests[0])["data"] == .array([.object(["type": .string("builds"), "id": .string("B1")])]))
}

@Test func aRefusalOfAnAutomaticGroupIsSettledByReadingOrIsANote() async throws {
    for status in [409, 422] {
        let refused = (status, #"{"errors":[{"status":"\#(status)","code":"STATE_ERROR","detail":"cannot add"}]}"#)
        let there = MockTransport([refused, (200, tfList([#"{"type":"betaGroups","id":"G1"}"#]))])
        guard case .alreadyInGroup = try await testFlight(there).addBuild("B1", to: betaGroup("G1", automatic: true), app: "APP1", current: []) else {
            Issue.record("expected alreadyInGroup"); return
        }
        for answer in [(200, tfList([])), (400, "{}")] {
            let unknown = MockTransport([refused, answer])
            let outcome = try await testFlight(unknown).addBuild("B1", to: betaGroup("G1", automatic: true), app: "APP1", current: [])
            let note = try #require(outcome.note(build: "B1", group: "Beta"))
            #expect(note.hasPrefix("warning: could not confirm that build B1 is in group Beta (adding the build to group Beta: ") && note.contains("cannot add")
                    && note.contains("automatic distribution"))
        }
        let manual = MockTransport([refused])
        await #expect(throws: ASCError.self) { _ = try await testFlight(manual).addBuild("B1", to: betaGroup("G1", automatic: false), app: "APP1", current: []) }
        #expect(manual.requests.count == 1)
    }
}

@Test func theTestersOfAGroupAreCountedFromTheTotalOrTheWholeList() async throws {
    let total = MockTransport([(200, #"{"data":[],"meta":{"paging":{"total":7,"limit":1}}}"#)])
    #expect(try await testFlight(total).testerCount(group: "G1") == 7)
    #expect(call(total.requests[0]) == "GET /v1/betaGroups/G1/betaTesters" && q(total.requests[0], "limit") == "1")
    let one = #"{"data":[{"type":"betaTesters","id":"T1"}]}"#
    let listed = MockTransport([(200, one), (200, #"{"data":[{"type":"betaTesters","id":"T1"},{"type":"betaTesters","id":"T2"}]}"#)])
    #expect(try await testFlight(listed).testerCount(group: "G1") == 2)
}

@Test func whatToTestIsCreatedUpdatedOrLeftAlone() async throws {
    let loc = #"{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"old"}}"#
    let same = MockTransport([(200, tfList([loc]))])
    guard case .unchanged = try await testFlight(same).setWhatsNew(build: "B1", locale: "en-US", text: "old") else { Issue.record("expected unchanged"); return }
    #expect(same.requests.count == 1)

    let update = MockTransport([(200, tfList([loc])), (200, tfSingle(loc))])
    guard case .updated = try await testFlight(update).setWhatsNew(build: "B1", locale: "en-US", text: "new") else { Issue.record("expected updated"); return }
    #expect(call(update.requests[1]) == "PATCH /v1/betaBuildLocalizations/L1")

    let create = MockTransport([(200, tfList([])), (201, tfSingle(loc))])
    guard case .created = try await testFlight(create).setWhatsNew(build: "B1", locale: "fr-FR", text: "nouveau") else { Issue.record("expected created"); return }
    #expect(try body(create.requests[1])["data"]?["attributes"] == .object(["locale": .string("fr-FR"), "whatsNew": .string("nouveau")]))
}

/// Every create of a delivery that can be found again: sent again after a failure only when reading shows nothing was made.
@Test func aCreateOfADeliveryIsSettledByReading() async throws {
    let text = #"{"type":"betaAppLocalizations","id":"BL1","attributes":{"locale":"fr-FR","description":"Bonjour"}}"#
    let info = MockTransport([(200, tfList([])), (503, ""), (200, tfList([])), (201, tfSingle(text))])
    _ = try await testFlight(info).setLocalization(app: "APP1", locale: "fr-FR", BetaInfoText(description: "Bonjour"))
    #expect(info.requests.map(call).filter { $0 == "POST /v1/betaAppLocalizations" }.count == 2)
    let lostInfo = MockTransport([(200, tfList([])), (503, ""), (200, tfList([text]))])
    guard case .created? = try await testFlight(lostInfo).setLocalization(app: "APP1", locale: "fr-FR", BetaInfoText(description: "Bonjour")) else { Issue.record("expected created"); return }

    let submission = #"{"type":"betaAppReviewSubmissions","id":"B1","attributes":{"betaReviewState":"WAITING_FOR_REVIEW"}}"#
    let submit = MockTransport([(200, tfList([])), (503, ""), (200, tfList([])), (201, tfSingle(submission))])
    guard case .created = try await testFlight(submit).submit(build: "B1") else { Issue.record("expected created"); return }
    let lostSubmit = MockTransport([(200, tfList([])), (503, ""), (200, tfList([submission]))])
    guard case .created = try await testFlight(lostSubmit).submit(build: "B1") else { Issue.record("expected created"); return }
    #expect(lostSubmit.requests.filter { $0.httpMethod == "POST" }.count == 1)

    let group = try JSONDecoder().decode(ASCBetaGroup.self, from: Data(#"{"type":"betaGroups","id":"G1","attributes":{"name":"Beta","isInternalGroup":false}}"#.utf8))
    let tester = #"{"type":"betaTesters","id":"T1","attributes":{"email":"a@example.com"}}"#
    let request = BetaTesterRequest(email: "a@example.com", firstName: nil, lastName: nil)
    let add = MockTransport([(200, tfList([])), (503, ""), (200, tfList([])), (201, tfSingle(tester))])
    guard case .created = try await testFlight(add).add(request, to: group, app: "APP1", members: [], users: nil) else { Issue.record("expected created"); return }
    // Made by the request whose answer was lost, in the group: nothing more is sent.
    let lostAdd = MockTransport([(200, tfList([])), (503, ""), (200, tfList([tester])), (200, tfList([tester]))])
    guard case .created = try await testFlight(lostAdd).add(request, to: group, app: "APP1", members: [], users: nil) else { Issue.record("expected created"); return }
    #expect(lostAdd.requests.filter { $0.httpMethod == "POST" }.count == 1)
}

// MARK: Beta information

@Test func betaTextsSendOnlyWhatDiffersAndCreateAMissingLocale() async throws {
    let loc = #"{"type":"betaAppLocalizations","id":"BL1","attributes":{"locale":"en-US","description":"Hello","feedbackEmail":"beta@example.com"}}"#
    let same = MockTransport([(200, tfList([loc]))])
    let unchanged = try await testFlight(same).setLocalization(app: "APP1", locale: "en-US", BetaInfoText(description: " Hello ", feedbackEmail: "beta@example.com"))
    guard case .unchanged? = unchanged else { Issue.record("expected unchanged"); return }

    let update = MockTransport([(200, tfList([loc])), (200, tfSingle(loc))])
    _ = try await testFlight(update).setLocalization(app: "APP1", locale: "en-US", BetaInfoText(description: "Hello", privacyPolicyURL: "https://x.example/p"))
    #expect(call(update.requests[1]) == "PATCH /v1/betaAppLocalizations/BL1")
    #expect(try body(update.requests[1])["data"]?["attributes"] == .object(["privacyPolicyUrl": .string("https://x.example/p")]))

    let create = MockTransport([(200, tfList([loc])), (201, tfSingle(loc))])
    _ = try await testFlight(create).setLocalization(app: "APP1", locale: "fr-FR", BetaInfoText(description: "Bonjour"))
    #expect(call(create.requests[1]) == "POST /v1/betaAppLocalizations")
    #expect(try body(create.requests[1])["data"]?["attributes"] == .object(["description": .string("Bonjour"), "locale": .string("fr-FR")]))
}

@Test func theReviewDetailIsReadWithoutThePassword() async throws {
    let t = MockTransport([(200, tfSingle(reviewDetailJSON()))])
    _ = try await testFlight(t).reviewDetail(app: "APP1")
    #expect(call(t.requests[0]) == "GET /v1/apps/APP1/betaAppReviewDetail")
    let fields = q(t.requests[0], "fields[betaAppReviewDetails]") ?? ""
    #expect(!fields.contains("demoAccountPassword") && fields.contains("demoAccountName"))
}

@Test func theDemoPasswordGoesOnlyWhenItMust() {
    let named = ASCBetaReviewDetailAttributes.with(name: "demo", required: true)
    // Nothing about the account changes: no password.
    #expect(BetaReviewChange(demoAccountName: "demo", demoAccountRequired: true).diff(from: named).password == false)
    // A new name, newly required, no name before, or asked: the password goes (with the name).
    #expect(BetaReviewChange(demoAccountName: "other").diff(from: named).password)
    let off = ASCBetaReviewDetailAttributes.with(name: "demo", required: false)
    #expect(BetaReviewChange(demoAccountRequired: true).diff(from: off).password)
    let resend = BetaReviewChange(resendDemoAccount: true).diff(from: named)
    #expect(resend.password && resend.attributes["demoAccountName"] == .string("demo"))
    // Not required: never.
    #expect(BetaReviewChange(demoAccountName: "x", demoAccountRequired: false, resendDemoAccount: true).diff(from: named).password == false)
    // A change that says nothing about the demo account never sends the password, whatever Apple holds.
    let requiredNoName = ASCBetaReviewDetailAttributes.with(name: nil, required: true)
    #expect(BetaReviewChange(notes: "hi").diff(from: requiredNoName).password == false)
    #expect(BetaReviewChange(demoAccountName: "demo").diff(from: requiredNoName).password)
    // Other fields alone.
    let contact = BetaReviewChange(contactEmail: "r@example.com").diff(from: named)
    #expect(contact.fields == ["contactEmail"] && !contact.password)
}

@Test func thePasswordIsHiddenSentOnceAndScrubbedFromErrors() async throws {
    let secret = "s3cr3t-demo-pw"
    let t = MockTransport([(422, #"{"errors":[{"status":"422","title":"Invalid","detail":"password s3cr3t-demo-pw is too short"}]}"#)])
    let detail = ASCBetaReviewDetail(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(reviewDetailJSON().utf8)))
    var asked: [String] = []
    do {
        _ = try await testFlight(t).updateReviewDetail(detail, BetaReviewChange(demoAccountName: "demo", demoAccountRequired: true, passwordSecret: "MY_DEMO")) { name in
            asked.append(name); return secret
        }
        Issue.record("expected throw")
    } catch let e as ASCError {
        #expect(!e.description.contains(secret) && e.description.contains(HTTPTrace.placeholder))
    }
    #expect(asked == ["MY_DEMO"] && t.requests.count == 1)
    #expect(try body(t.requests[0])["data"]?["attributes"]?["demoAccountPassword"]?.string == secret)
}

@Test func thePasswordInApplesAnswerIsNeverKept() async throws {
    let answer = #"{"data":{"type":"betaAppReviewDetails","id":"R1","attributes":{"demoAccountName":"demo","demoAccountRequired":true,"demoAccountPassword":"stored-pw"}}}"#
    let t = MockTransport([(200, answer), (200, answer)])
    let tf = testFlight(t)
    let read = try await tf.reviewDetail(app: "APP1")
    #expect(read.resource.attributes?["demoAccountPassword"] == nil)
    let detail = ASCBetaReviewDetail(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(reviewDetailJSON().utf8)))
    let updated = try await tf.updateReviewDetail(detail, BetaReviewChange(notes: "new")) { _ in "" }
    #expect(updated?.resource.attributes?["demoAccountPassword"] == nil)
    #expect(!(try ASCOutput.json(updated)).contains("stored-pw"))
}

@Test func nothingDifferingSendsNoReviewDetails() async throws {
    let t = MockTransport([])
    let detail = ASCBetaReviewDetail(resource: try JSONDecoder().decode(ASCAnyResource.self, from: Data(reviewDetailJSON(name: "demo", required: true).utf8)))
    let result = try await testFlight(t).updateReviewDetail(detail, BetaReviewChange(contactFirstName: "Ada", demoAccountName: "demo")) { _ in
        Issue.record("password read"); return ""
    }
    #expect(result == nil && t.requests.isEmpty)
}

// MARK: Beta app review

@Test func aBuildAlreadySubmittedIsNotSubmittedAgain() async throws {
    let sub = #"{"type":"betaAppReviewSubmissions","id":"S1","attributes":{"betaReviewState":"IN_REVIEW"}}"#
    let t = MockTransport([(200, tfList([sub]))])
    guard case .unchanged(let s) = try await testFlight(t).submit(build: "B1") else { Issue.record("expected unchanged"); return }
    #expect(s.attributes.betaReviewState == "IN_REVIEW" && q(t.requests[0], "filter[build]") == "B1" && t.requests.count == 1)

    let fresh = MockTransport([(200, tfList([])), (201, tfSingle(#"{"type":"betaAppReviewSubmissions","id":"S2","attributes":{"betaReviewState":"WAITING_FOR_REVIEW"}}"#))])
    guard case .created(let created) = try await testFlight(fresh).submit(build: "B1") else { Issue.record("expected created"); return }
    #expect(created.id == "S2" && call(fresh.requests[1]) == "POST /v1/betaAppReviewSubmissions")
    #expect(try body(fresh.requests[1])["data"]?["relationships"]?["build"]?["data"]?["id"]?.string == "B1")

    // Not knowing whether it was submitted, nothing is sent again.
    let failing = MockTransport([(200, tfList([])), (500, "{}"), (403, "{}")])
    do { _ = try await testFlight(failing).submit(build: "B1"); Issue.record("expected throw") } catch let e as ASCError { #expect(e.status == 500) }
    #expect(failing.requests.count == 3)
}

@Test func testerEmailsRefuseCommas() throws {
    #expect(throws: IdentifierInputError.self) { try BetaTesterEmail.validate("a,b@example.com") }
    #expect(try BetaTesterEmail.validate(" ada@example.com ") == "ada@example.com")
}

extension ASCBetaReviewDetailAttributes {
    static func with(name: String?, required: Bool) -> Self {
        var a = Self(); a.demoAccountName = name; a.demoAccountRequired = required; return a
    }
}
