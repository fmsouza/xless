import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func webhooks(_ t: MockTransport) -> ASCWebhooks {
    ASCWebhooks(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}

func webhookJSON(_ id: String, url: String = "https://hooks.example.com/asc", name: String = "hooks.example.com") -> String {
    #"{"type":"webhooks","id":"\#(id)","attributes":{"enabled":true,"eventTypes":["BUILD_UPLOAD_STATE_UPDATED"],"name":"\#(name)","url":"\#(url)"}}"#
}

@Test func webhookInputIsChecked() throws {
    let parsed = try WebhookEvents.parse(["build-upload-state-updated,BUILD_UPLOAD_STATE_UPDATED", "new_event_type"])
    #expect(parsed.events == ["BUILD_UPLOAD_STATE_UPDATED", "NEW_EVENT_TYPE"])
    #expect(parsed.unknown == ["NEW_EVENT_TYPE"])
    #expect(throws: IdentifierInputError.self) { try WebhookEvents.parse([]) }
    #expect(throws: IdentifierInputError.self) { try WebhookEvents.parse(["build upload"]) }
    #expect(try WebhookInput.url("https://hooks.example.com/asc") == "https://hooks.example.com/asc")
    #expect(throws: IdentifierInputError.self) { try WebhookInput.url("http://hooks.example.com/asc") }
    #expect(throws: IdentifierInputError.self) { try WebhookInput.url("https://user:pw@hooks.example.com/asc") }
    #expect(throws: IdentifierInputError.self) { try WebhookInput.url("hooks.example.com") }
    #expect(WebhookInput.defaultName(for: "https://hooks.example.com/asc") == "hooks.example.com")
    #expect(WebhookInput.isWebhookID("6f1c0c3e-1e45"))
    #expect(!WebhookInput.isWebhookID("a/b"))
}

@Test func newSecretsAreLongRandomHex() {
    let a = WebhookInput.newSecret().utf8String(), b = WebhookInput.newSecret().utf8String()
    #expect(a.count == 64 && a.allSatisfy(\.isHexDigit))
    #expect(a != b)
}

@Test func createSendsTheSecretOnceAndHidesItFromErrors() async throws {
    let secret = SecretBytes(utf8: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let request = WebhookRequest(appID: "123", name: "hooks", url: "https://hooks.example.com/asc", events: ["BUILD_UPLOAD_STATE_UPDATED"])
    let refused = MockTransport([(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"secret 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef is weak"}]}"#)])
    do {
        _ = try await webhooks(refused).create(request, secret: secret)
        Issue.record("expected an error")
    } catch let e as ASCError {
        #expect(!e.description.contains("0123456789abcdef0123456789abcdef"))
        #expect(e.description.contains(HTTPTrace.placeholder))
    }
    let failing = MockTransport([(500, "")])
    await #expect(throws: ASCError.self) { try await webhooks(failing).create(request, secret: secret) }
    #expect(failing.requests.count == 1) // never retried

    let ok = MockTransport([(201, #"{"data":\#(webhookJSON("W1"))}"#)])
    let created = try await webhooks(ok).create(request, secret: secret)
    #expect(created.id == "W1" && created.events == ["BUILD_UPLOAD_STATE_UPDATED"])
    let body = try JSONDecoder().decode(JSONValue.self, from: ok.requests[0].httpBody ?? Data())
    #expect(ok.requests[0].url?.path == "/v1/webhooks")
    #expect(body["data"]?["attributes"]?["secret"]?.string == secret.utf8String())
    #expect(body["data"]?["attributes"]?["enabled"] == .bool(true))
    #expect(body["data"]?["attributes"]?["eventTypes"] == .array([.string("BUILD_UPLOAD_STATE_UPDATED")]))
    #expect(body["data"]?["relationships"]?["app"]?["data"]?["id"]?.string == "123")
}

@Test func aTraceNeverShowsTheSecret() async throws {
    let lines = Lines()
    let secret = SecretBytes(utf8: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
    let t = TracingTransport(MockTransport([(201, #"{"data":\#(webhookJSON("W1"))}"#)]), trace: HTTPTrace(sink: lines.sink))
    let hooks = ASCWebhooks(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
    _ = try await hooks.create(WebhookRequest(appID: "1", name: "n", url: "https://h.example.com", events: ["BUILD_UPLOAD_STATE_UPDATED"]), secret: secret)
    #expect(!lines.all.joined().contains("fedcba9876543210"))
}
