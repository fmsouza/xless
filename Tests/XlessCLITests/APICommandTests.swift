import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private func call(_ t: FakeTransport) -> APICall {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return APICall(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })))
}
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}

@Test(arguments: ["/v1/apps", "v1/apps", "/v2/inAppPurchases/123", "https://api.appstoreconnect.apple.com/v1/apps?cursor=AB%2BC&limit=200",
                  "HTTPS://API.APPSTORECONNECT.APPLE.COM/v1/apps"])
func documentedPathsAreAccepted(path: String) throws {
    let r = try APIRequest(method: "get", path: path)
    #expect(r.method == "GET")
    #expect(r.path.hasPrefix("/v"))
}

@Test(arguments: ["//evil.example/v1/apps", "https://evil.example/v1/apps", "https://api.appstoreconnect.apple.com.evil.example/v1/apps",
                  "https://user@api.appstoreconnect.apple.com/v1/apps", "https://api.appstoreconnect.apple.com:8443/v1/apps",
                  "http://api.appstoreconnect.apple.com/v1/apps", "/v1/../v1/apps", "/v1/apps/%2E%2E/x", "/v1//apps", "/apps", "/v1",
                  "/vx/apps", "apps", "/v1/apps/a b", "/v1/apps\\x"])
func otherPathsAreRefused(path: String) {
    #expect(throws: ValidationError.self) { try APIRequest(method: "GET", path: path) }
}

#if os(Windows) || XLESS_WINDOWS_TARGETS
@Test(arguments: ["C:/Program Files/Git/v1/apps", "C:\\msys64\\v1\\apps", "D:/a/v2/inAppPurchases/123"])
func aPathThatGitBashMadeOfTheAPIsIsNamedAsThat(path: String) throws {
    let e = #expect(throws: ValidationError.self) { try APIRequest(method: "GET", path: path) }
    #expect(e?.message.contains("MSYS_NO_PATHCONV=1") == true && e?.message.contains("v1/apps") == true)
}
#endif

@Test func methodsFieldsIncludeAndBodiesAreChecked() throws {
    #expect(throws: ValidationError.self) { try APIRequest(method: "PUT", path: "/v1/apps") }
    #expect(throws: ValidationError.self) { try APIRequest(method: "GET", path: "/v1/apps", fields: ["novalue"]) }
    #expect(throws: ValidationError.self) { try APIRequest(method: "GET", path: "/v1/apps", fields: ["=x"]) }
    #expect(throws: ValidationError.self) { try APIRequest(method: "GET", path: "/v1/apps", body: Data("{}".utf8)) }
    #expect(throws: ValidationError.self) { try APIRequest(method: "POST", path: "/v1/apps", paginate: true) }
    let r = try APIRequest(method: "GET", path: "/v1/apps?limit=2", fields: ["filter[bundleId]=a.b=c"], include: ["appInfos, builds", "betaGroups"])
    #expect(r.query.map { "\($0.0)=\($0.1)" } == ["limit=2", "filter[bundleId]=a.b=c", "include=appInfos,builds,betaGroups"])
    #expect(throws: (any Error).self) { try APICommand.parse(["GET", "/v1/apps", "--input", "body.json"]) }
    #expect(throws: (any Error).self) { try APICommand.parse(["DELETE", "/v1/apps/1", "--paginate"]) }
}

@Test func getPrintsTheBodyWithSortedKeys() async throws {
    let t = FakeTransport([(200, #"{"links":{"self":"https://api.appstoreconnect.apple.com/v1/apps"},"data":[{"type":"apps","id":"1"}]}"#)])
    let out = try await call(t).run(try APIRequest(method: "GET", path: "/v1/apps", fields: ["limit=1"]), yes: false, terminal: { nil })
    #expect(out == """
    {
      "data" : [
        {
          "id" : "1",
          "type" : "apps"
        }
      ],
      "links" : {
        "self" : "https://api.appstoreconnect.apple.com/v1/apps"
      }
    }

    """)
    #expect(query(t.requests[0]) == ["limit=1"])
    #expect(t.requests[0].httpMethod == "GET")
}

@Test func paginateMergesEveryPage() async throws {
    let t = FakeTransport([
        (200, #"{"data":[{"type":"apps","id":"1"}],"included":[{"type":"builds","id":"B1"}],"links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=2&limit=200"}}"#),
        (200, #"{"data":[{"type":"apps","id":"2"}],"included":[{"type":"builds","id":"B1"}]}"#),
    ])
    let out = try await call(t).run(try APIRequest(method: "GET", path: "/v1/apps", include: ["builds"], paginate: true), yes: false, terminal: { nil })
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    #expect(doc["data"] == .array([.object(["type": .string("apps"), "id": .string("1")]), .object(["type": .string("apps"), "id": .string("2")])]))
    #expect(doc["included"] == .array([.object(["type": .string("builds"), "id": .string("B1")])]))
    #expect(query(t.requests[0]).contains("include=builds") && query(t.requests[0]).contains("limit=200"))
    #expect(query(t.requests[1]).contains("cursor=2"))
}

@Test func aWriteNeedsAConfirmationAndAPostIsSentOnce() async throws {
    let request = try APIRequest(method: "POST", path: "/v1/devices", body: Data(#"{"data":{"type":"devices"}}"#.utf8))
    let refused = FakeTransport([])
    await #expect(throws: XlessError.self) { try await call(refused).run(request, yes: false, terminal: { nil }) }
    #expect(refused.requests.isEmpty)

    let declined = FakeTransport([])
    var said: [String] = []
    let none = try await call(declined).run(request, yes: false, terminal: { FakeTerminal(answer: false) }, say: { said.append($0) })
    #expect(none.isEmpty && declined.requests.isEmpty && said == ["cancelled; nothing was sent"])

    let failing = FakeTransport([(503, "{}"), (201, "{}")])
    await #expect(throws: ASCError.self) { try await call(failing).run(request, yes: true) }
    #expect(failing.requests.count == 1)
    #expect(failing.requests[0].httpBody == Data(#"{"data":{"type":"devices"}}"#.utf8))
}

@Test func anEmptyResponsePrintsNothing() async throws {
    let t = FakeTransport([(204, "")])
    #expect(try await call(t).run(try APIRequest(method: "DELETE", path: "/v1/devices/D1"), yes: true) == "")
    #expect(t.requests[0].httpMethod == "DELETE")
}

@Test func anAppleErrorBecomesAnAccountError() async throws {
    let t = FakeTransport([(404, #"{"errors":[{"status":"404","code":"NOT_FOUND","detail":"no app 9"}]}"#)])
    do {
        _ = try await AccountSession.run { try await call(t).run(try APIRequest(method: "GET", path: "/v1/apps/9"), yes: false) }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .account && e.stage.exitCode == 20)
        #expect(e.cause == "GET /v1/apps/9: App Store Connect HTTP 404 — NOT_FOUND: no app 9")
    }
}
