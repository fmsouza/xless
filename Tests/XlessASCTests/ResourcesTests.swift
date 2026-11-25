import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC

private func resources(_ t: MockTransport) -> ASCResources {
    ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
}
private func query(_ r: URLRequest, _ name: String) -> String? {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}
private struct AppAttributes: Codable, Sendable, Equatable { var name: String?; var bundleId: String? }

@Test func queryRendersFiltersFieldsIncludeSortAndLimit() {
    let q = ASCQuery(filters: [("bundleId", "a.b")], fields: [("apps", ["name", "bundleId"])], include: ["builds", "appInfos"],
                     sort: ["-name"], limit: 50, extra: [("exists[builds]", "true")])
    let items = q.items
    #expect(items.map(\.0) == ["filter[bundleId]", "fields[apps]", "include", "sort", "exists[builds]", "limit"])
    #expect(items.map(\.1) == ["a.b", "name,bundleId", "builds,appInfos", "-name", "true", "50"])
}

@Test func listFollowsNextLinksAndKeepsTheQuery() async throws {
    let page1 = #"{"data":[{"type":"apps","id":"1","attributes":{"name":"A"}}],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=AB%2BC&filter%5BbundleId%5D=a.b&limit=200"}}"#
    let page2 = #"{"data":[{"type":"apps","id":"2","attributes":{"name":"B"}}],"links":{"self":"x"}}"#
    let t = MockTransport([(200, page1), (200, page2)])
    let listing = try await resources(t).list("/v1/apps", query: ASCQuery(filters: [("bundleId", "a.b")]), as: ASCResource<AppAttributes>.self)
    #expect(listing.items.map(\.id) == ["1", "2"])
    #expect(t.requests.count == 2)
    #expect(query(t.requests[0], "limit") == "200")
    #expect(query(t.requests[0], "filter[bundleId]") == "a.b")
    #expect(query(t.requests[1], "cursor") == "AB+C")
    #expect(t.requests[1].url!.absoluteString.contains("cursor=AB%2BC"))
}

@Test func listStopsAtMaxItems() async throws {
    let page1 = #"{"data":[{"type":"apps","id":"1"},{"type":"apps","id":"2"}],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=C"}}"#
    let t = MockTransport([(200, page1)])
    let listing = try await resources(t).list("/v1/apps", query: ASCQuery(limit: 2), as: ASCRef.self, maxItems: 1)
    #expect(listing.items.map(\.id) == ["1"])
    #expect(t.requests.count == 1)
}

@Test func listThatNeverEndsThrowsInsteadOfTruncating() async throws {
    let looping = #"{"data":[],"links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=again"}}"#
    let t = MockTransport(Array(repeating: (200, looping), count: ASCPaging.maxPages))
    do {
        _ = try await resources(t).list("/v1/apps", as: ASCRef.self)
        Issue.record("expected throw")
    } catch let e as ASCPagingError {
        #expect(e == .didNotTerminate(path: "/v1/apps"))
    }
    #expect(t.requests.count == ASCPaging.maxPages)
}

@Test func includedResourcesAreCollectedOnceAndDecodeTyped() async throws {
    let build = #"{"type":"builds","id":"B1","attributes":{"version":"42"}}"#
    let page1 = #"{"data":[{"type":"apps","id":"1"}],"included":[\#(build)],"links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=2"}}"#
    let page2 = #"{"data":[{"type":"apps","id":"2"}],"included":[\#(build),{"type":"builds","id":"B2","attributes":{"version":"43"}}]}"#
    let t = MockTransport([(200, page1), (200, page2)])
    let listing = try await resources(t).list("/v1/apps", query: ASCQuery(include: ["builds"]), as: ASCRef.self)
    #expect(listing.included.map(\.id) == ["B1", "B2"])
    struct BuildAttributes: Codable, Sendable { var version: String? }
    let b2 = try listing.included(ASCRef(type: "builds", id: "B2"), as: BuildAttributes.self)
    #expect(b2?.attributes.version == "43")
    #expect(try listing.included(ASCRef(type: "builds", id: "nope"), as: BuildAttributes.self) == nil)
    #expect(query(t.requests[0], "include") == "builds")
}

@Test func getDecodesTheResourceAndItsIncluded() async throws {
    let body = #"{"data":{"type":"apps","id":"1","attributes":{"name":"A","bundleId":"a.b"}},"included":[{"type":"builds","id":"B1"}]}"#
    let t = MockTransport([(200, body)])
    let single = try await resources(t).get("/v1/apps/1", query: ASCQuery(fields: [("apps", ["name", "bundleId"])]), as: ASCResource<AppAttributes>.self)
    #expect(single.data.attributes == AppAttributes(name: "A", bundleId: "a.b"))
    #expect(single.included.map(\.id) == ["B1"])
    #expect(query(t.requests[0], "fields[apps]") == "name,bundleId")
}

@Test func createPostsOnceAndIsNeverRetried() async throws {
    let t = MockTransport([(503, #"{"errors":[]}"#), (201, "{}")])
    struct Rels: Codable, Sendable { var app: ASCToOne }
    await #expect(throws: ASCError.self) {
        let _: ASCSingle<ASCRef> = try await resources(t).create("/v1/betaGroups", type: "betaGroups", attributes: AppAttributes(name: "G"),
                                                                relationships: Rels(app: .init(.init(type: "apps", id: "1"))))
    }
    #expect(t.requests.count == 1)
    let data = try #require((try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as? [String: Any])?["data"] as? [String: Any])
    #expect(data["type"] as? String == "betaGroups")
    #expect(((data["relationships"] as? [String: Any])?["app"] as? [String: Any]) != nil)
}

@Test func updatePatchesTheResourceWithItsID() async throws {
    let t = MockTransport([(200, #"{"data":{"type":"apps","id":"1","attributes":{"name":"New"}}}"#)])
    let single: ASCSingle<ASCResource<AppAttributes>> = try await resources(t).update("/v1/apps/1", type: "apps", id: "1", attributes: AppAttributes(name: "New"))
    #expect(single.data.attributes.name == "New")
    #expect(t.requests[0].httpMethod == "PATCH")
    let data = try #require((try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as? [String: Any])?["data"] as? [String: Any])
    #expect(data["id"] as? String == "1")
}

@Test func deleteSendsDelete() async throws {
    let t = MockTransport([(204, "")])
    try await resources(t).delete("/v1/devices/D1")
    #expect(t.requests[0].httpMethod == "DELETE")
    #expect(t.requests[0].url!.path == "/v1/devices/D1")
}

@Test func relationshipReadsArePagedAndWritesUseTheLinkageBody() async throws {
    let page1 = #"{"data":[{"type":"builds","id":"B1"}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/betaGroups/G1/relationships/builds?cursor=2"}}"#
    let page2 = #"{"data":[{"type":"builds","id":"B2"}]}"#
    let t = MockTransport([(200, page1), (200, page2), (204, ""), (204, ""), (204, ""), (200, #"{"data":{"type":"apps","id":"A1"}}"#), (204, "")])
    let r = resources(t)
    let refs = try await r.relationship("/v1/betaGroups/G1", "builds")
    #expect(refs.map(\.id) == ["B1", "B2"])
    #expect(t.requests[0].url!.path == "/v1/betaGroups/G1/relationships/builds")
    let b3 = [ASCRef(type: "builds", id: "B3")]
    try await r.addRelationship("/v1/betaGroups/G1", "builds", b3)
    try await r.removeRelationship("/v1/betaGroups/G1", "builds", b3)
    try await r.replaceRelationship("/v1/betaGroups/G1", "builds", b3)
    #expect(t.requests[2...4].map { $0.httpMethod ?? "" } == ["POST", "DELETE", "PATCH"])
    for request in t.requests[2...4] {
        #expect(request.url!.path == "/v1/betaGroups/G1/relationships/builds")
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((json["data"] as? [[String: Any]])?.first?["id"] as? String == "B3")
    }
    #expect(try await r.toOneRelationship("/v1/builds/B1", "app") == ASCRef(type: "apps", id: "A1"))
    try await r.replaceToOneRelationship("/v1/builds/B1", "app", ASCRef(type: "apps", id: "A2"))
    let toOne = try #require(try JSONSerialization.jsonObject(with: t.requests[6].httpBody!) as? [String: Any])
    #expect((toOne["data"] as? [String: Any])?["id"] as? String == "A2")
}

@Test func jsonValueRoundTripsAndEncodesStably() throws {
    let text = #"{"b":[1,2.5,"x",true,null],"a":{"z":1,"y":-3}}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(value["a"]?["y"] == .int(-3))
    #expect(value["b"]?[1] == .double(2.5))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(String(decoding: try encoder.encode(value), as: UTF8.self) == #"{"a":{"y":-3,"z":1},"b":[1,2.5,"x",true,null]}"#)
}

// MARK: - Creates whose answer may be lost

private struct Thing: Equatable, Sendable { var id: String }

/// Scripted lookups and creates, in order; what was asked is in `log`.
private final class Script: @unchecked Sendable {
    var log: [String] = []
    var lookups: [Result<Thing?, any Error>]
    var creates: [Result<Thing, any Error>]
    init(lookups: [Result<Thing?, any Error>] = [], creates: [Result<Thing, any Error>]) { self.lookups = lookups; self.creates = creates }
    /// What Apple finishes while the create is waited for: every reading after it finds it.
    var appears: Thing?
    func run(_ names: ASCNames = .unique) async throws -> Thing {
        let client = ASCClient(credentials: testCreds, transport: MockTransport([]), sleep: { [self] d in
            log.append("wait \(d.components.seconds)")
            if let appears { lookups = [.success(appears)] }
        })
        return try await ASCResources(client: client).settled(names,
            lookup: { self.log.append("look"); return try self.lookups.removeFirst().get() },
            create: { self.log.append("create"); return try self.creates.removeFirst().get() })
    }
}

@Test func aCreateThatAnswersIsSentOnceAndNotLookedUp() async throws {
    let s = Script(creates: [.success(Thing(id: "1"))])
    #expect(try await s.run() == Thing(id: "1"))
    #expect(s.log == ["create"])
}

/// The wait comes before the reading: what Apple finishes meanwhile is seen, and nothing lies between reading and sending.
@Test(arguments: [ASCNames.unique, .shared])
func whatAppearsDuringTheWaitIsNotMadeAgain(names: ASCNames) async throws {
    for failure in [URLError(.timedOut) as any Error, ASCError(status: 504, items: [])] {
        let s = Script(lookups: [.success(nil)], creates: [.failure(failure), .success(Thing(id: "second"))])
        s.appears = Thing(id: "1")
        #expect(try await s.run(names) == Thing(id: "1"))
        #expect(s.log == ["create", "wait 1", "look"])
    }
}

/// Where Apple would make a second one of the same name, a create whose answer is unclear is sent again once at most:
/// Apple may still be late with the first. A 429 is clear: it made nothing.
@Test func aCreateAppleWouldMakeTwiceIsSentAgainOnceAtMost() async throws {
    let unclear: [Result<Thing, any Error>] = [.failure(ASCError(status: 504, items: [])), .failure(URLError(.timedOut)), .success(Thing(id: "third"))]
    let s = Script(lookups: [.success(nil), .success(nil)], creates: unclear)
    await #expect(throws: URLError.self) { _ = try await s.run(.shared) }
    #expect(s.log == ["create", "wait 1", "look", "create", "wait 2", "look"])
    // The second is read for as well.
    let late = Script(lookups: [.success(nil), .success(Thing(id: "1"))], creates: unclear)
    #expect(try await late.run(.shared) == Thing(id: "1"))
    let once = Script(lookups: [.success(nil)], creates: [.failure(ASCError(status: 500, items: [])), .success(Thing(id: "2"))])
    #expect(try await once.run(.shared) == Thing(id: "2"))

    let limited = ASCError(status: 429, items: [])
    let clear = Script(lookups: [.success(nil), .success(nil)], creates: [.failure(limited), .failure(limited), .success(Thing(id: "3"))])
    #expect(try await clear.run(.shared) == Thing(id: "3"))
    let mixed = Script(lookups: [.success(nil), .success(nil)], creates: [.failure(ASCError(status: 502, items: [])), .failure(limited), .success(Thing(id: "3"))])
    await #expect(throws: ASCError.self) { _ = try await mixed.run(.shared) }
    #expect(mixed.log.filter { $0 == "create" }.count == 2)
}

@Test func aCreateWhoseAnswerWasLostIsLookedUpBeforeItIsSentAgain() async throws {
    for failure in [URLError(.networkConnectionLost) as any Error, ASCError(status: 500, items: []), ASCError(status: 429, items: [])] {
        let made = Script(lookups: [.success(Thing(id: "1"))], creates: [.failure(failure)])
        #expect(try await made.run() == Thing(id: "1"))
        #expect(made.log == ["create", "wait 1", "look"])
        let absent = Script(lookups: [.success(nil)], creates: [.failure(failure), .success(Thing(id: "2"))])
        #expect(try await absent.run() == Thing(id: "2"))
        #expect(absent.log == ["create", "wait 1", "look", "create"])
    }
}

@Test func aCreateRefusedBecauseItExistsTakesTheExistingOne() async throws {
    let exists = Script(lookups: [.success(Thing(id: "1"))], creates: [.failure(ASCError(status: 409, items: []))])
    #expect(try await exists.run() == Thing(id: "1"))
    // A 409 for another reason is the answer: never sent again.
    let refused = Script(lookups: [.success(nil)], creates: [.failure(ASCError(status: 409, items: []))])
    await #expect(throws: ASCError.self) { _ = try await refused.run() }
    #expect(refused.log == ["create", "look"])
}

@Test func aRefusedCreateOrAFailedLookupIsTheAnswer() async throws {
    let refused = Script(creates: [.failure(ASCError(status: 403, items: []))])
    await #expect(throws: ASCError.self) { _ = try await refused.run() }
    #expect(refused.log == ["create"])
    // Not knowing whether it exists, nothing is sent again; the create's own error is thrown.
    let blind = Script(lookups: [.failure(URLError(.notConnectedToInternet))], creates: [.failure(ASCError(status: 502, items: []))])
    do { _ = try await blind.run(); Issue.record("expected throw") } catch let e as ASCError { #expect(e.status == 502) }
    #expect(blind.log == ["create", "wait 1", "look"])
    let cancelled = Script(creates: [.failure(CancellationError())])
    await #expect(throws: CancellationError.self) { _ = try await cancelled.run() }
    #expect(cancelled.log == ["create"])
}

@Test func aCreateIsSentAtMostFiveTimes() async throws {
    let s = Script(lookups: Array(repeating: .success(nil), count: 5), creates: Array(repeating: .failure(ASCError(status: 500, items: [])), count: 5))
    await #expect(throws: ASCError.self) { _ = try await s.run() }
    #expect(s.log.filter { $0 == "create" }.count == 5)
    #expect(s.log.filter { $0.hasPrefix("wait") } == ["wait 1", "wait 2", "wait 4", "wait 8", "wait 16"])
    #expect(s.log.last == "look", "also after the last one")
    // A spent hourly budget is not waited for.
    let spent = Script(lookups: [.success(nil)], creates: [.failure(ASCError(status: 429, items: [], retryAfter: 3600))])
    await #expect(throws: ASCError.self) { _ = try await spent.run() }
    #expect(spent.log == ["create", "look"])
    let soon = Script(lookups: [.success(nil)], creates: [.failure(ASCError(status: 429, items: [], retryAfter: 7)), .success(Thing(id: "1"))])
    _ = try await soon.run()
    #expect(soon.log.contains("wait 7"))
}
