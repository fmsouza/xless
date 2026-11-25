import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC
@testable import XlessCore

private let appJSON = #"{"data":[{"type":"apps","id":"APP1","attributes":{"bundleId":"a.b"}}]}"#
private let noLocalizations = #"{"data":[],"meta":{"paging":{"total":0,"limit":200}}}"#
private let noGroups = #"{"data":[],"meta":{"paging":{"total":0,"limit":200}}}"#
private func group(_ id: String, _ name: String, internal isInternal: Bool = true, all: Bool = true) -> String {
    #"{"type":"betaGroups","id":"\#(id)","attributes":{"name":"\#(name)","isInternalGroup":\#(isInternal),"hasAccessToAllBuilds":\#(all)}}"#
}
private let nowhere = noGroups   // the groups that have the build: none
private func groups(_ items: String...) -> String { #"{"data":[\#(items.joined(separator: ","))],"meta":{"paging":{"total":\#(items.count),"limit":200}}}"# }
private func testers(_ total: Int) -> String {
    let data = (0..<min(total, 1)).map { #"{"type":"betaTesters","id":"T\#($0)","attributes":{}}"# }.joined(separator: ",")
    return #"{"data":[\#(data)],"meta":{"paging":{"total":\#(total),"limit":1}}}"#
}

private func publisher(_ t: MockTransport) -> TestFlightPublisher {
    TestFlightPublisher(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
}
private func body(_ r: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
}
private func path(_ r: URLRequest) -> String { r.httpMethod! + " " + r.url!.path }
private func query(_ r: URLRequest, _ name: String) -> String? {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Test func createsMissingInternalGroupAttachesBuildAndSetsWhatToTest() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, noLocalizations),
        (201, #"{"data":{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"hello"}}}"#),
        (200, noGroups),
        (201, #"{"data":\#(group("G1", "Internal"))}"#),
        (200, nowhere),
        (204, ""),
        (200, testers(3)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "29000000",
                                                config: TestFlightConfig(groups: ["Internal"], whatToTest: "hello"))
    #expect(t.requests.map(path) == [
        "GET /v1/apps", "GET /v1/builds/B1/betaBuildLocalizations", "POST /v1/betaBuildLocalizations",
        "GET /v1/betaGroups", "POST /v1/betaGroups", "GET /v1/betaGroups", "POST /v1/betaGroups/G1/relationships/builds", "GET /v1/betaGroups/G1/betaTesters",
    ])
    #expect(query(t.requests[5], "filter[builds]") == "B1" && query(t.requests[5], "filter[app]") == "APP1")
    // group lookup is scoped to the app; names are compared client-side (filter[name] splits on commas)
    #expect(query(t.requests[3], "filter[app]") == "APP1" && query(t.requests[3], "filter[name]") == nil && query(t.requests[3], "limit") == "200")
    // group create: internal + automatic distribution, related to the app
    let create = body(t.requests[4])["data"] as! [String: Any]
    let attrs = create["attributes"] as! [String: Any]
    #expect(create["type"] as? String == "betaGroups")
    #expect(attrs["name"] as? String == "Internal" && attrs["isInternalGroup"] as? Bool == true && attrs["hasAccessToAllBuilds"] as? Bool == true)
    let appRel = ((create["relationships"] as! [String: Any])["app"] as! [String: Any])["data"] as! [String: String]
    #expect(appRel == ["type": "apps", "id": "APP1"])
    // build attach: to-many linkage on the group
    let attach = body(t.requests[6])["data"] as! [[String: String]]
    #expect(attach == [["type": "builds", "id": "B1"]])
    // localization create
    let loc = body(t.requests[2])["data"] as! [String: Any]
    let locAttrs = loc["attributes"] as! [String: Any]
    #expect(locAttrs["locale"] as? String == "en-US" && locAttrs["whatsNew"] as? String == "hello")
    #expect((((loc["relationships"] as! [String: Any])["build"] as! [String: Any])["data"] as! [String: String]) == ["type": "builds", "id": "B1"])
    // tester count read with limit=1 (only meta.paging.total is needed)
    #expect(query(t.requests[7], "limit") == "1")

    #expect(result.buildID == "B1" && result.buildNumber == "29000000" && result.whatToTestSet)
    #expect(result.groups == [.init(name: "Internal", id: "G1", created: true, testerCount: 3)])
    #expect(result.summary == ["TestFlight: build 29000000 (B1)", "  group Internal (created) — available to 3 testers", "  what to test (en-US): set"])
}

@Test func reusesExistingGroupByExactNameAndNeverCreatesOrModifiesIt() async throws {
    let t = MockTransport([
        (200, appJSON),
        // the filter is a substring match server side: only the exact name may be reused
        (200, groups(group("G0", "Internal QA"), group("G1", "Internal"))),
        (200, nowhere),
        (204, ""),
        (200, testers(1)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(t.requests.map(path) == ["GET /v1/apps", "GET /v1/betaGroups", "GET /v1/betaGroups", "POST /v1/betaGroups/G1/relationships/builds", "GET /v1/betaGroups/G1/betaTesters"])
    #expect(result.groups == [.init(name: "Internal", id: "G1", created: false, testerCount: 1)])
    #expect(result.summary.contains("  group Internal — available to 1 tester"))
    #expect(!result.whatToTestSet)
}

@Test func existingLocalizationIsUpdated() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, #"{"data":[{"type":"betaBuildLocalizations","id":"L0","attributes":{"locale":"fr-FR","whatsNew":"x"}},{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"old"}}]}"#),
        (200, #"{"data":{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"new"}}}"#),
        (200, groups(group("G1", "Internal"))),
        (200, nowhere),
        (204, ""),
        (200, testers(2)),
    ])
    _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"], whatToTest: "new"))
    #expect(path(t.requests[2]) == "PATCH /v1/betaBuildLocalizations/L1")
    let data = body(t.requests[2])["data"] as! [String: Any]
    #expect(data["id"] as? String == "L1" && (data["attributes"] as! [String: Any])["whatsNew"] as? String == "new")
}

// MARK: - A create that fails, or whose answer is lost, does not lose the delivery

private let madeText = #"{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"hello"}}"#
private let afterText: [MockTransport.Step] = [.response(200, groups(group("G1", "Internal"))), .response(200, nowhere), .response(204, ""), .response(200, testers(1))]
private let textConfig = TestFlightConfig(groups: ["Internal"], whatToTest: "hello")

@Test func aFailedWhatToTestIsSentAgainOnceReadingShowsThatItWasNotMade() async throws {
    for failure: MockTransport.Step in [.response(503, ""), .response(429, ""), .response(500, ""), .failure(.networkConnectionLost)] {
        let t = MockTransport(steps: [.response(200, appJSON), .response(200, noLocalizations), failure, .response(200, noLocalizations),
                                      .response(201, #"{"data":\#(madeText)}"#)] + afterText)
        let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: textConfig)
        #expect(result.whatToTestSet && result.groups.map(\.id) == ["G1"])
        #expect(t.requests[1...4].map(path) == ["GET /v1/builds/B1/betaBuildLocalizations", "POST /v1/betaBuildLocalizations",
                                                "GET /v1/builds/B1/betaBuildLocalizations", "POST /v1/betaBuildLocalizations"])
    }
}

@Test func aWhatToTestMadeByTheRequestWhoseAnswerWasLostIsNotSentAgain() async throws {
    for failure: MockTransport.Step in [.response(503, ""), .failure(.timedOut), .response(201, "not json")] {
        let t = MockTransport(steps: [.response(200, appJSON), .response(200, noLocalizations), failure,
                                      .response(200, #"{"data":[\#(madeText)]}"#)] + afterText)
        let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: textConfig)
        #expect(result.whatToTestSet && t.steps.isEmpty)
        #expect(t.requests.filter { $0.httpMethod == "POST" }.map(path) == ["POST /v1/betaBuildLocalizations", "POST /v1/betaGroups/G1/relationships/builds"])
    }
}

/// What reading finds after a lost answer may be someone else's (or Apple's, empty): it gets the text.
@Test func aWhatToTestFoundWithAnotherTextIsUpdated() async throws {
    let other = #"{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US"}}"#
    let t = MockTransport(steps: [.response(200, appJSON), .response(200, noLocalizations), .response(503, ""),
                                  .response(200, #"{"data":[\#(other)]}"#), .response(200, #"{"data":\#(madeText)}"#)] + afterText)
    _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: textConfig)
    #expect(path(t.requests[4]) == "PATCH /v1/betaBuildLocalizations/L1" && t.steps.isEmpty)
}

@Test func aGroupWhoseCreateFailedIsLookedUpThenMade() async throws {
    let made = group("G1", "Internal")
    let again = MockTransport(steps: [.response(200, appJSON), .response(200, noGroups), .response(503, ""), .response(200, noGroups),
                                      .response(201, #"{"data":\#(made)}"#), .response(200, nowhere), .response(204, ""), .response(200, testers(1))])
    let config = TestFlightConfig(groups: ["Internal"])
    let result = try await publisher(again).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(result.groups.map(\.created) == [true] && again.steps.isEmpty)
    let lost = MockTransport(steps: [.response(200, appJSON), .response(200, noGroups), .failure(.networkConnectionLost), .response(200, groups(made)),
                                     .response(200, nowhere), .response(204, ""), .response(200, testers(1))])
    let found = try await publisher(lost).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(found.groups.map(\.created) == [true], "this run made it")
    #expect(lost.requests.filter { $0.httpMethod == "POST" }.map(path) == ["POST /v1/betaGroups", "POST /v1/betaGroups/G1/relationships/builds"])
}

@Test func localeComesFromConfig() async throws {
    let t = MockTransport([
        (200, appJSON), (200, noLocalizations),
        (201, #"{"data":{"type":"betaBuildLocalizations","id":"L1","attributes":{}}}"#),
        (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(1)),
    ])
    _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7",
                                       config: TestFlightConfig(groups: ["Internal"], whatToTest: "hola", locale: "es-ES"))
    let attrs = (body(t.requests[2])["data"] as! [String: Any])["attributes"] as! [String: Any]
    #expect(attrs["locale"] as? String == "es-ES")
}

@Test func zeroTestersWarns() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(0))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.groups.first?.testerCount == 0)
    #expect(result.summary.contains("  group Internal — available to 0 testers"))
    let warning = result.warnings.first ?? ""
    #expect(warning.contains("Internal") && warning.contains("0 testers") && warning.contains("xless users invite"))
}

@Test func multipleGroupsAreProcessedInOrder() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(2)),
        (201, #"{"data":\#(group("G2", "QA"))}"#), (204, ""), (200, testers(0)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal", "QA"]))
    // the groups, and which of them have the build, are read once
    #expect(t.requests.filter { $0.httpMethod == "GET" && $0.url!.path == "/v1/betaGroups" }.count == 2)
    #expect(result.groups.map(\.name) == ["Internal", "QA"])
    #expect(result.warnings.count == 1 && result.warnings[0].contains("QA"))
}

@Test func existingExternalGroupWithTheNameIsRefused() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Beta", internal: false, all: false)))])
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Beta"])); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .upload)
        #expect(e.cause.contains("Beta") && e.cause.contains("external"))
        #expect(e.fix.contains("testflight.groups") && e.fix.contains("already uploaded"))
    }
    #expect(t.requests.count == 2)   // nothing was created, attached or modified
}

@Test func alreadyAttachedBuildIsToleratedForAutomaticGroups() async throws {
    // an automatic-distribution group may already carry the build; ASC answers 409 (or 422) to the explicit add.
    for status in [409, 422] {
        let t = MockTransport([
            (200, appJSON), (200, groups(group("G1", "Internal"))), (200, nowhere),
            (status, #"{"errors":[{"status":"\#(status)","code":"ENTITY_ERROR","detail":"already there"}]}"#),
            (200, groups(group("G1", "Internal"))),
            (200, testers(1)),
        ])
        let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
        #expect(path(t.requests[4]) == "GET /v1/betaGroups")
        #expect(query(t.requests[4], "filter[app]") == "APP1" && query(t.requests[4], "filter[builds]") == "B1")
        #expect(result.groups.first?.testerCount == 1 && result.warnings.isEmpty)
    }
}

@Test func unconfirmedMembershipOnAutomaticGroupWarnsInsteadOfFailing() async throws {
    let t = MockTransport([
        (200, appJSON), (200, groups(group("G1", "Internal"))), (200, nowhere),
        (409, #"{"errors":[{"status":"409","code":"STATE_ERROR","detail":"cannot add"}]}"#),
        (200, noGroups),
        (200, testers(1)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.warnings.contains { $0.contains("Internal") && $0.contains("automatic distribution") })
}

@Test func failingMembershipCheckOnAutomaticGroupAlsoWarns() async throws {
    let t = MockTransport([
        (200, appJSON), (200, groups(group("G1", "Internal"))), (200, nowhere),
        (422, #"{"errors":[{"status":"422","code":"X","detail":"nope"}]}"#),
        (400, #"{"errors":[{"status":"400","code":"PARAMETER_ERROR.INVALID","detail":"bad filter"}]}"#),
        (200, testers(1)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.warnings.contains { $0.contains("automatic distribution") })
}

@Test func attachConflictOnNonAutomaticGroupIsAnError() async throws {
    for status in [409, 422] {
        let t = MockTransport([
            (200, appJSON), (200, groups(group("G1", "Internal", all: false))), (200, nowhere),
            (status, #"{"errors":[{"status":"\#(status)","code":"STATE_ERROR","detail":"cannot add"}]}"#),
        ])
        do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"])); Issue.record("expected throw") }
        catch let e as XlessError { #expect(e.stage == .upload && e.cause.contains("adding the build to group Internal") && e.cause.contains("cannot add")) }
        #expect(t.requests.count == 4)
    }
}

@Test func aBuildThatIsInTheGroupAlreadyIsNotAddedAgain() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Internal", all: false))), (200, groups(group("G1", "Internal", all: false))), (200, testers(2))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
    #expect(result.groups == [.init(name: "Internal", id: "G1", created: false, testerCount: 2)] && result.warnings.isEmpty)
}

@Test func aMembershipThatCannotBeReadDoesNotStopTheDelivery() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Internal"))),
                           (400, #"{"errors":[{"status":"400","code":"PARAMETER_ERROR.INVALID","detail":"bad filter"}]}"#), (204, ""), (200, testers(2))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(path(t.requests[3]) == "POST /v1/betaGroups/G1/relationships/builds" && result.warnings.isEmpty)
}

@Test func aGroupSomebodyElseCreatedMeanwhileIsUsed() async throws {
    let t = MockTransport([(200, appJSON), (200, noGroups), (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"name taken"}]}"#),
                           (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(2))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.groups == [.init(name: "Internal", id: "G1", created: false, testerCount: 2)])
}

@Test func theSameWhatToTestSendsNothing() async throws {
    let same = #"{"data":[{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"same"}}]}"#
    let t = MockTransport([(200, appJSON), (200, same), (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(1))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"], whatToTest: "same"))
    #expect(result.whatToTestSet && !t.requests.contains { $0.url!.path.hasPrefix("/v1/betaBuildLocalizations") })
}

@Test func groupNamesWithCommasAreMatchedExactly() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G0", "QA"), group("G1", "QA, iOS"))), (200, nowhere), (204, ""), (200, testers(1))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["QA, iOS"]))
    #expect(result.groups == [.init(name: "QA, iOS", id: "G1", created: false, testerCount: 1)])
    #expect(t.requests.map(path) == ["GET /v1/apps", "GET /v1/betaGroups", "GET /v1/betaGroups", "POST /v1/betaGroups/G1/relationships/builds", "GET /v1/betaGroups/G1/betaTesters"])
}

@Test func groupNamesDifferingOnlyInCaseAreDifferentGroups() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G0", "internal"))), (201, #"{"data":\#(group("G1", "Internal"))}"#), (200, nowhere), (204, ""), (200, testers(0))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.groups.first?.created == true && result.groups.first?.id == "G1")
}

@Test func groupListingFollowsNextLinks() async throws {
    let first = #"{"data":[\#(group("G0", "Other"))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/betaGroups?cursor=C2&filter%5Bapp%5D=APP1&limit=200"},"meta":{"paging":{"total":2,"limit":200}}}"#
    let t = MockTransport([(200, appJSON), (200, first), (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(1))])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.groups.first?.id == "G1" && result.groups.first?.created == false)
    #expect(t.requests[2].url!.path == "/v1/betaGroups" && query(t.requests[2], "cursor") == "C2")
}

@Test func groupListingNextLinkWithRawBracketsArrivesIntact() async throws {
    // Same link parsing as the dated build lookup (ASCPaging.parseLink): raw brackets and an encoded '+' survive.
    let first = #"{"data":[\#(group("G0", "Other"))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/betaGroups?filter[app]=APP1&limit=200&cursor=AB%2BC"}}"#
    let t = MockTransport([(200, appJSON), (200, first), (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(1))])
    _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(query(t.requests[2], "filter[app]") == "APP1" && query(t.requests[2], "cursor") == "AB+C", "\(t.requests[2].url!.absoluteString)")
    #expect(!t.requests[2].url!.absoluteString.contains("%255B"), "double-encoded")
}

@Test func groupListingThatNeverEndsIsAnUploadErrorNotATruncation() async throws {
    let page = #"{"data":[\#(group("G0", "Other"))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/betaGroups?filter%5Bapp%5D=APP1&cursor=C&limit=200"}}"#
    let t = MockTransport([(200, appJSON)] + Array(repeating: (200, page), count: ASCPaging.maxPages))
    do {
        _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .upload)
        #expect(e.cause.contains("pagination did not terminate"), "\(e.cause)")
        #expect(e.fix.contains("already uploaded and processed"))
    }
    // Never went on to create the group from a partial list.
    #expect(!t.requests.contains { $0.httpMethod == "POST" })
    #expect(t.requests.count == 1 + ASCPaging.maxPages)
}

@Test func whatToTestCreateConflictFallsBackToUpdate() async throws {
    let t = MockTransport([
        (200, appJSON), (200, noLocalizations),
        (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"locale exists"}]}"#),
        (200, #"{"data":[{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"old"}}]}"#),
        (200, #"{"data":{"type":"betaBuildLocalizations","id":"L1","attributes":{}}}"#),
        (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, testers(1)),
    ])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"], whatToTest: "new"))
    #expect(path(t.requests[4]) == "PATCH /v1/betaBuildLocalizations/L1" && result.whatToTestSet)
}

@Test func testerCountWithoutTotalPagesThroughTheListing() async throws {
    let probe = #"{"data":[{"type":"betaTesters","id":"T1"}]}"#   // no meta.paging.total
    let page1 = #"{"data":[{"type":"betaTesters","id":"T1"},{"type":"betaTesters","id":"T2"}],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/betaGroups/G1/betaTesters?cursor=N&limit=200"}}"#
    let page2 = #"{"data":[{"type":"betaTesters","id":"T3"}],"links":{"self":"x"}}"#
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Internal"))), (200, nowhere), (204, ""), (200, probe), (200, page1), (200, page2)])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"]))
    #expect(result.groups.first?.testerCount == 3)
    #expect(query(t.requests[4], "limit") == "1" && query(t.requests[5], "limit") == "200")
    #expect(query(t.requests[6], "cursor") == "N")
}

@Test func missingAppRecordIsAnUploadError() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#)])
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"])); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload && e.stage.exitCode == 17 && e.cause.contains("a.b")) }
}

@Test func ascErrorsMapToUploadStageWithContext() async throws {
    let t = MockTransport([(200, appJSON), (200, noGroups),
                           (403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"no"}]}"#)])
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"])); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .upload && e.stage.exitCode == 17)
        #expect(e.cause.contains("creating group Internal") && e.cause.contains("403"))
        #expect(e.fix.contains("Admin"))   // 401/403 get the key-role hint
        #expect(e.fix.contains("already uploaded"))   // and say the upload itself succeeded
    }
}

@Test func transportFailuresMapToUploadStage() async throws {
    let t = MockTransport(steps: [.response(200, appJSON)] + Array(repeating: .failure(.notConnectedToInternet), count: 5))
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"])); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload && e.cause.contains("looking up")) }
}

/// Two groups may have one name: a create whose answer is unclear is read for after the wait, and sent again once at most.
@Test func aGroupIsNotMadeASecondTime() async throws {
    func create(_ t: MockTransport, waits: (@Sendable () -> Void)? = nil) async throws -> ASCTestFlight.Outcome<ASCBetaGroup> {
        let client = ASCClient(credentials: testCreds, transport: t, sleep: { _ in waits?() })
        return try await ASCTestFlight(resources: ASCResources(client: client)).createGroup(name: "Internal", app: "1", external: false, existing: [])
    }
    // Apple finishes it during the wait.
    let late = MockTransport([(504, ""), (200, noGroups), (201, #"{"data":\#(group("G2", "Internal"))}"#)])
    guard case .created(let g) = try await create(late, waits: { late.steps[0] = .response(200, groups(group("G1", "Internal"))) }) else { Issue.record("expected created"); return }
    #expect(g.id == "G1" && late.requests.map(path) == ["POST /v1/betaGroups", "GET /v1/betaGroups"])
    let twice = MockTransport([(504, ""), (200, noGroups), (502, ""), (200, noGroups), (201, #"{"data":\#(group("G3", "Internal"))}"#)])
    do { _ = try await create(twice); Issue.record("expected throw") } catch let e as ASCError { #expect(e.status == 502) }
    #expect(twice.requests.map(path) == ["POST /v1/betaGroups", "GET /v1/betaGroups", "POST /v1/betaGroups", "GET /v1/betaGroups"])
}

/// Two groups may have one name: a create whose answer is lost is not sent again when the groups cannot be read.
@Test func aGroupCreateIsNotSentAgainWithoutReading() async throws {
    let t = MockTransport([(200, appJSON), (200, noGroups), (503, ""), (403, "{}")])
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: TestFlightConfig(groups: ["Internal"])); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause == "creating group Internal: App Store Connect HTTP 503") }
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 1 && t.steps.isEmpty)
}

// MARK: testers and external testing (#100)

private let emptyList = #"{"data":[],"links":{"self":"x"}}"#

@Test func addsTheConfiguredTestersToEachInternalGroup() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, usersListJSON([userJSON("U1", "ada@example.com")])),
        (200, groups(group("G1", "Internal"))),
        (200, nowhere),
        (204, ""),
        (200, emptyList),                                               // the group's testers
        (200, emptyList),                                               // no beta tester with that address yet
        (201, #"{"data":\#(betaTesterJSON("T1", "ada@example.com"))}"#),
        (200, testers(1)),
    ])
    let config = TestFlightConfig(groups: ["Internal"], testers: [TestFlightTester(email: "ada@example.com", firstName: "Ada")])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(t.requests.map(path) == ["GET /v1/apps", "GET /v1/users", "GET /v1/betaGroups", "GET /v1/betaGroups", "POST /v1/betaGroups/G1/relationships/builds",
                                     "GET /v1/betaTesters", "GET /v1/betaTesters", "POST /v1/betaTesters", "GET /v1/betaGroups/G1/betaTesters"])
    #expect(result.groups == [.init(name: "Internal", id: "G1", created: false, testerCount: 1, added: ["ada@example.com"])])
    #expect(result.summary.contains("    added: ada@example.com") && result.warnings.isEmpty)
}

@Test func anInternalTesterWhoIsNotAUserIsAWarningNotAFailure() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, usersListJSON([])),
        (200, groups(group("G1", "Internal"))),
        (200, nowhere),
        (204, ""),
        (200, emptyList),
        (200, testers(0)),
    ])
    let config = TestFlightConfig(groups: ["Internal"], testers: [TestFlightTester(email: "stranger@example.com")])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(!t.requests.contains { $0.httpMethod == "POST" && $0.url!.path == "/v1/betaTesters" })
    #expect(result.warnings.contains { $0.contains("stranger@example.com") && $0.contains("xless users invite") })
}

@Test func externalTestingCreatesTheGroupAddsTestersSetsTheInfoAndSubmits() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, noLocalizations),
        (201, #"{"data":{"type":"betaBuildLocalizations","id":"L1","attributes":{"locale":"en-US","whatsNew":"try it"}}}"#),
        (200, emptyList),                                                                          // beta localizations
        (201, #"{"data":{"type":"betaAppLocalizations","id":"BL1","attributes":{"locale":"en-US"}}}"#),
        (200, emptyList),                                                                          // groups
        (201, #"{"data":\#(group("G5", "Beta", internal: false, all: false))}"#),
        (200, nowhere),
        (204, ""),                                                                                 // build → group
        (200, emptyList),
        (200, emptyList),
        (201, #"{"data":\#(betaTesterJSON("T2", "ext@example.com"))}"#),
        (200, testers(1)),
        (200, emptyList),                                                                          // no submission yet
        (201, #"{"data":{"type":"betaAppReviewSubmissions","id":"S1","attributes":{"betaReviewState":"WAITING_FOR_REVIEW"}}}"#),
    ])
    let config = TestFlightConfig(groups: [], whatToTest: "try it",
                                  external: ExternalTestFlight(groups: ["Beta"], testers: [TestFlightTester(email: "ext@example.com")],
                                                               info: .init(description: "A beta", feedbackEmail: "beta@example.com")))
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(t.requests.map(path) == [
        "GET /v1/apps", "GET /v1/builds/B1/betaBuildLocalizations", "POST /v1/betaBuildLocalizations",
        "GET /v1/apps/APP1/betaAppLocalizations", "POST /v1/betaAppLocalizations", "GET /v1/betaGroups", "POST /v1/betaGroups",
        "GET /v1/betaGroups", "POST /v1/betaGroups/G5/relationships/builds", "GET /v1/betaTesters", "GET /v1/betaTesters", "POST /v1/betaTesters",
        "GET /v1/betaGroups/G5/betaTesters", "GET /v1/betaAppReviewSubmissions", "POST /v1/betaAppReviewSubmissions",
    ])
    let created = body(t.requests[6])["data"] as! [String: Any]
    #expect((created["attributes"] as! [String: Any])["isInternalGroup"] as? Bool == false)
    #expect(result.groups == [.init(name: "Beta", id: "G5", created: true, testerCount: 1, external: true, added: ["ext@example.com"])])
    #expect(result.betaReview?.hasPrefix("submitted (WAITING_FOR_REVIEW)") == true)
    #expect(result.summary.contains("  group Beta (external) (created) — available to 1 tester"))
}

@Test func anInternalGroupListedAsExternalIsAnUploadError() async throws {
    let t = MockTransport([(200, appJSON), (200, groups(group("G1", "Beta")))])
    let config = TestFlightConfig(groups: [], external: ExternalTestFlight(groups: ["Beta"], submit: false))
    do { _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .upload && e.cause.contains("internal group") && e.fix.contains("already uploaded"))
    }
}

@Test func theDemoPasswordIsReadOnlyWhenItMustBeSent() async throws {
    let t = MockTransport([
        (200, appJSON),
        (200, #"{"data":\#(reviewDetailJSON(name: "demo", required: true))}"#),
        (200, #"{"data":\#(reviewDetailJSON(name: "demo2", required: true))}"#),
        (200, emptyList),
        (201, #"{"data":\#(group("G5", "Beta", internal: false))}"#),
        (200, nowhere),
        (204, ""),
        (200, testers(0)),
    ])
    let review = ExternalTestFlight.Review(demoAccount: .init(name: "demo2", passwordSecret: "MY_DEMO", required: true))
    let config = TestFlightConfig(groups: [], external: ExternalTestFlight(groups: ["Beta"], submit: false, review: review))
    var asked: [String] = []
    _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config) { name in asked.append(name); return "pw-123456" }
    #expect(asked == ["MY_DEMO"])
    #expect(path(t.requests[2]) == "PATCH /v1/betaAppReviewDetails/R1")
    let attrs = (body(t.requests[2])["data"] as! [String: Any])["attributes"] as! [String: Any]
    #expect(attrs["demoAccountPassword"] as? String == "pw-123456" && attrs["demoAccountName"] as? String == "demo2")
}

@Test func aTesterAppleRefusesIsAWarningAndTheRunGoesOn() async throws {
    let t = MockTransport([
        (200, appJSON),
        (403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR"}]}"#),         // not an Admin key: no user check
        (200, groups(group("G1", "Internal"))),
        (200, nowhere),
        (204, ""),
        (200, emptyList),
        (200, emptyList),
        (422, #"{"errors":[{"status":"422","title":"Tester is not a user"}]}"#),
        (200, testers(0)),
    ])
    let config = TestFlightConfig(groups: ["Internal"], testers: [TestFlightTester(email: "stranger@example.com")])
    let result = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config)
    #expect(result.warnings.contains { $0.contains("stranger@example.com") && $0.contains("HTTP 422") })
    #expect(t.requests.count == 9)
}

@Test func aMissingDemoPasswordSaysTheBuildIsUploaded() async throws {
    let t = MockTransport([(200, appJSON), (200, #"{"data":\#(reviewDetailJSON())}"#)])
    let review = ExternalTestFlight.Review(demoAccount: .init(name: "demo", required: true))
    let config = TestFlightConfig(groups: [], external: ExternalTestFlight(groups: ["Beta"], submit: false, review: review))
    do {
        _ = try await publisher(t).publish(bundleID: "a.b", buildID: "B1", buildNumber: "7", config: config) { name in
            throw XlessError(.account, "missing secret \(name), the demo account's password (x); nothing was sent", fix: "store it")
        }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .upload && !e.cause.contains("nothing was sent") && e.fix.contains("already uploaded"))
    }
}
