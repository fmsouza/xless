import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
import XlessVault
@testable import xless

/// A store in a fresh 0700 directory, made with fast scrypt; removed by `cleanup()`.
private struct HookVault {
    let root: URL
    let store: VaultStore
    let file: VaultFile
    let key: SymmetricKey

    init(entries: [String] = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-webhook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
        var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"),
                                                   kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
        for name in entries {
            file.entries.append(try VaultCrypto.seal(name: name, kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "x"), dataKey: key))
        }
        try store.create(file)
        self.file = file
        self.key = key
    }

    var hookStore: WebhookSecretStore { WebhookSecretStore(store: store.secretStore, catalogID: file.id) }
    func read() throws -> VaultFile { try #require(try store.read()) }
    func secret(_ name: String) throws -> String { try VaultCrypto.open(try #require(try read().entry(named: name)), dataKey: key).utf8String() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let appJSON = #"{"data":{"type":"apps","id":"123","attributes":{"bundleId":"com.example.app","name":"Example"}}}"#
private func hook(_ id: String, url: String = "https://hooks.example.com/asc") -> String {
    #"{"type":"webhooks","id":"\#(id)","attributes":{"enabled":true,"eventTypes":["BUILD_UPLOAD_STATE_UPDATED"],"name":"hooks.example.com","url":"\#(url)"}}"#
}
private let fixedSecret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, vault: HookVault?, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said(),
                 unlock: (() throws -> WebhookSecretStore)? = nil) -> WebhookCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    var c = WebhookCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json, team: "ABCDE12345",
                       terminal: { terminal }, say: { said.lines.append($0) },
                       storeFile: { try? vault?.read() },
                       unlockStore: unlock ?? { try #require(vault).hookStore },
                       removeEntries: { id in try vault.map { try WebhookSecretStore.remove(id: id, from: $0.store.secretStore) } ?? [] })
    c.newSecret = { SecretBytes(utf8: fixedSecret) }
    c.now = { Date(timeIntervalSince1970: 1_800_000_000) }
    return c
}

@Test func badWebhookArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try WebhooksCreateCommand.parse(["--app", "123", "--url", "https://h.example.com"]) } // no events
    #expect(throws: (any Error).self) { try WebhooksCreateCommand.parse(["--app", "123", "--url", "http://h.example.com", "--events", "build-upload-state-updated"]) }
    #expect(throws: (any Error).self) { try WebhooksCreateCommand.parse(["--app", "123", "--url", "https://h.example.com", "--events", "a b"]) }
    #expect(throws: (any Error).self) { try WebhooksDeleteCommand.parse(["../x"]) }
    #expect(throws: (any Error).self) { try WebhooksListCommand.parse([]) }
    let ok = try WebhooksCreateCommand.parse(["--app", "com.example.app", "--url", "https://h.example.com", "--events", "build-upload-state-updated", "--disabled"])
    #expect(ok.disabled)
}

@Test func createStoresTheSecretAndNeverPrintsIt() async throws {
    let vault = try HookVault(); defer { vault.cleanup() }
    let t = FakeTransport([(200, appJSON), (200, #"{"data":[]}"#), (201, #"{"data":\#(hook("W1"))}"#)])
    let said = Said()
    let out = try await cli(t, vault: vault, said: said).create(app: "123", name: nil, url: "https://hooks.example.com/asc",
                                                                 events: ["build-upload-state-updated"], enabled: true)
    #expect(out.contains("created webhook W1"))
    #expect(out.contains("XLESS_WEBHOOK_SECRET.W1@ABCDE12345"))
    #expect(!out.contains(fixedSecret) && !said.lines.joined().contains(fixedSecret))
    #expect(try vault.secret("XLESS_WEBHOOK_SECRET.W1@ABCDE12345") == fixedSecret)
    let entry = try #require(try vault.read().entry(named: "XLESS_WEBHOOK_SECRET.W1@ABCDE12345"))
    #expect(entry.kind == .generic && entry.metadata.teamID == "ABCDE12345")
    let body = try JSONDecoder().decode(JSONValue.self, from: t.requests[2].httpBody ?? Data())
    #expect(body["data"]?["attributes"]?["name"]?.string == "hooks.example.com")
    #expect(body["data"]?["attributes"]?["secret"]?.string == fixedSecret)
}

@Test func theStoreIsOpenedBeforeAnythingIsSent() async throws {
    let t = FakeTransport([])
    await #expect(throws: VaultError.self) {
        try await cli(t, vault: nil, unlock: { throw VaultError(.notInitialized, "there is no secret store", fix: "xless secrets init") })
            .create(app: "123", name: nil, url: "https://hooks.example.com/asc", events: ["BUILD_UPLOAD_STATE_UPDATED"], enabled: true)
    }
    #expect(t.requests.isEmpty)
}

@Test func aWebhookForTheSameURLIsNotMadeTwice() async throws {
    let vault = try HookVault(entries: ["XLESS_WEBHOOK_SECRET.W1@ABCDE12345"]); defer { vault.cleanup() }
    let t = FakeTransport([(200, appJSON), (200, #"{"data":[\#(hook("W1"))]}"#)])
    let out = try await cli(t, vault: vault).create(app: "123", name: nil, url: "https://hooks.example.com/asc", events: ["BUILD_UPLOAD_STATE_UPDATED"], enabled: true)
    #expect(out.hasPrefix("com.example.app already has webhook W1"))
    #expect(out.contains("XLESS_WEBHOOK_SECRET.W1@ABCDE12345"))
    #expect(t.requests.count == 2)
}

@Test func aSecretTheStoreRefusesTakesTheWebhookBack() async throws {
    let vault = try HookVault(entries: ["XLESS_WEBHOOK_SECRET.W1@ABCDE12345"]); defer { vault.cleanup() } // name taken: the add fails
    let t = FakeTransport([(200, appJSON), (200, #"{"data":[]}"#), (201, #"{"data":\#(hook("W1"))}"#), (204, "")])
    do {
        _ = try await cli(t, vault: vault).create(app: "123", name: nil, url: "https://hooks.example.com/asc", events: ["BUILD_UPLOAD_STATE_UPDATED"], enabled: true)
        Issue.record("expected an error")
    } catch let e as XlessError {
        #expect(e.cause.contains("the webhook was deleted again"))
        #expect(!e.description.contains(fixedSecret))
    }
    #expect(t.requests[3].httpMethod == "DELETE" && t.requests[3].url?.path == "/v1/webhooks/W1")
}

@Test func listShowsWhereEachSecretIs() async throws {
    let vault = try HookVault(entries: ["XLESS_WEBHOOK_SECRET.W1@ABCDE12345", "XLESS_WEBHOOK_SECRET.W10"]); defer { vault.cleanup() }
    let t = FakeTransport([(200, appJSON), (200, #"{"data":[\#(hook("W1")),\#(hook("W2", url: "https://b.example.com"))]}"#)])
    let out = try await cli(t, vault: vault).list(app: "123")
    let rows = out.split(separator: "\n")
    #expect(rows.count == 3)
    #expect(rows[1].hasPrefix("W1 ") && rows[1].hasSuffix("XLESS_WEBHOOK_SECRET.W1@ABCDE12345"))
    #expect(rows[2].hasPrefix("W2 ") && rows[2].hasSuffix("-"))
}

@Test func deleteAsksThenRemovesTheSecret() async throws {
    let vault = try HookVault(entries: ["XLESS_WEBHOOK_SECRET.W1@ABCDE12345", "XLESS_WEBHOOK_SECRET.W10"]); defer { vault.cleanup() }
    let refused = FakeTransport([(200, #"{"data":\#(hook("W1"))}"#)])
    await #expect(throws: XlessError.self) { try await cli(refused, vault: vault).delete("W1", yes: false) }
    #expect(refused.requests.count == 1)
    let t = FakeTransport([(200, #"{"data":\#(hook("W1"))}"#), (204, "")])
    let out = try await cli(t, vault: vault, terminal: FakeTerminal(answer: true)).delete("W1", yes: false)
    #expect(out == "deleted webhook W1 \"hooks.example.com\"; removed its secret from the store (XLESS_WEBHOOK_SECRET.W1@ABCDE12345)\n")
    #expect(try vault.read().entries.map(\.name) == ["XLESS_WEBHOOK_SECRET.W10"])
}

@Test func aDeletedWebhookWhoseSecretANewerStoreKeepsSaysToUpgrade() async throws {
    let vault = try HookVault(entries: ["XLESS_WEBHOOK_SECRET.W1@ABCDE12345"]); defer { vault.cleanup() }
    let said = Said()
    var c = cli(FakeTransport([(200, #"{"data":\#(hook("W1"))}"#), (204, "")]), vault: vault, said: said)
    c.removeEntries = { _ in throw VaultError(.newerFormat, "the secret store was written by a newer xless", fix: "upgrade xless (run the install line again: README.md#install); the store is unchanged") }
    let out = try await c.delete("W1", yes: true)
    #expect(out == "deleted webhook W1 \"hooks.example.com\"\n")
    #expect(said.lines.count == 1)
    #expect(said.lines[0].contains("the webhook is deleted at Apple already;") && said.lines[0].contains("upgrade xless")
            && said.lines[0].contains("XLESS_WEBHOOK_SECRET.W1@ABCDE12345"))
}
