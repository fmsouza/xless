import ArgumentParser
import XlessASC
import XlessCore
import XlessStore
import Foundation
import Testing
@testable import xless

private func manifest(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-cli-\(UUID().uuidString)")
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return root
}

@Test func validatePrintsEachIssueAndFails() throws {
    let root = try manifest([
        "appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.0\"\n",
        "appstore/en-US/name.txt": "Example\n",
        "appstore/en-US/keywords.txt": String(repeating: "é", count: 56) + "\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let out = StoreValidation.run(dir: root.appendingPathComponent("appstore"), draft: true, json: false)
    #expect(out.failed && out.stdout.isEmpty)
    let lines = out.stderr.split(separator: "\n").map(String.init)
    #expect(lines.first == "error: [account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten the keywords (comma-separated, counted in UTF-8 bytes)")
    #expect(lines.dropFirst().dropLast().allSatisfy { $0.hasPrefix("warning: ") }, "--draft: what is missing only warns")
    #expect(lines.last == "appstore/: 1 error, 9 warnings")
}

@Test func validateSaysValidAndJSONIsAContract() throws {
    let root = try manifest(["appstore/app.yml": "primaryLocale: en-US\n", "xless.yml": "not: [valid\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let json = StoreValidation.run(dir: dir, draft: true, json: true)
    #expect(json.failed, "no bundleID and no usable xless.yml")
    #expect(json.stdout.hasPrefix("{\n  \"issues\" : [\n    {\n      \"fix\" : \"add `bundleID: com.example.app` to app.yml\",\n      \"message\" : \"no bundleID, and no usable xless.yml next to appstore/ to take it from\""))
    #expect(json.stdout.contains("\"valid\" : false"))
}

@Test func storeCommandsParse() throws {
    #expect(throws: (any Error).self) { try StorePullCommand.parse(["--live", "--editable"]) }
    #expect(throws: (any Error).self) { try StorePullCommand.parse(["--platform", "watchos"]) }
    let pull = try StorePullCommand.parse(["--app", "com.example.app", "--app-version", "1.2", "--dir", "listing"])
    #expect(pull.selection == .version("1.2") && pull.directory.dir == "listing")
    #expect(try StorePullCommand.parse([]).selection == .automatic)
    #expect(StorePlatform.parse("visionOS") == "VISION_OS" && StorePlatform.parse("mac") == "MAC_OS")
}

@Test func pushParsesItsOptions() throws {
    let push = try StorePushCommand.parse(["--dry-run", "--only", "review,text", "--prune", "--resend-demo-account", "--dir", "listing"])
    #expect(push.dryRun && push.prune && push.directory.dir == "listing")
    #expect(push.options.parts == [.text, .review] && push.options.prune && push.options.resendDemoAccount)
    #expect(try StorePushCommand.parse([]).options.parts == StorePushPart.allCases)
    #expect(try StorePushCommand.parse(["--only", "declarations", "--only", "text"]).options.parts == [.text, .declarations])
    #expect(try StorePushCommand.parse(["--only", "media"]).options.parts == [.media])
    #expect(try StorePushCommand.parse(["--only", "pricing"]).options.parts == [.pricing])
    #expect(throws: (any Error).self) { try StorePushCommand.parse(["--only", "privacy"]) }
}

@Test func pushStopsOnManifestErrorsBeforeContactingApple() throws {
    let root = try manifest([
        "appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.0\"\n",
        "appstore/en-US/name.txt": "Example\n",
        "appstore/en-US/keywords.txt": String(repeating: "é", count: 56) + "\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let said = Said()
    #expect {
        _ = try StorePushCLI.check(dir: root.appendingPathComponent("appstore"), say: { said.add($0) })
    } throws: { ($0 as? XlessError)?.cause == "appstore/ has 1 error; nothing was sent" }
    #expect(said.lines == ["error: [account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten the keywords (comma-separated, counted in UTF-8 bytes)"])

    let ok = try manifest(["appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.0\"\n", "appstore/en-US/name.txt": "Example\n"])
    defer { try? FileManager.default.removeItem(at: ok) }
    let (m, bundle) = try StorePushCLI.check(dir: ok.appendingPathComponent("appstore"), say: { _ in })
    #expect(bundle == "com.example.app" && m.locales["en-US"]?.name == "Example", "what a submission still needs does not stop a push")
}

@Test func theDemoPasswordComesFromItsSecret() throws {
    #expect(try StorePushCLI.demoPassword("XLESS_DEMO_PASSWORD", secrets: Secrets(env: ["XLESS_DEMO_PASSWORD": "pa ss\n"], fallback: nil)) == "pa ss")
    #expect {
        _ = try StorePushCLI.demoPassword("APP_REVIEW_PW", secrets: Secrets(env: [:], fallback: nil))
    } throws: { "\($0)".contains("xless secrets import APP_REVIEW_PW --file <file> --kind password") }
    #expect(SecretEnvironment.isSecret("XLESS_DEMO_PASSWORD") && SecretEnvironment.isSecret("XLESS_DEMO_PASSWORD_FILE"))
}

@Test func pushAsksBeforeDeleting() throws {
    let cli = StorePushCLI(client: ASCClient(credentials: ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: ""), transport: FakeTransport([])),
                           secrets: Secrets(env: [:], fallback: nil), json: false, terminal: { FakeTerminal(answer: false) }, say: { _ in })
    let delete = StoreChange(.delete, .text, "version text it-IT", requests: [.delete("appStoreVersionLocalizations", id: "X")])
    #expect(try cli.confirmDeletes(StorePlan(changes: [delete]), yes: false) == false)
    #expect(try cli.confirmDeletes(StorePlan(changes: [delete]), yes: true))
    #expect(try cli.confirmDeletes(StorePlan(), yes: false), "nothing to delete: nothing to ask")
    let noTerminal = StorePushCLI(client: cli.client, secrets: cli.secrets, json: false, terminal: { nil }, say: { _ in })
    #expect(throws: XlessError.self) { try noTerminal.confirmDeletes(StorePlan(changes: [delete]), yes: false) }
}

private final class Said: @unchecked Sendable {
    var lines: [String] = []
    func add(_ s: String) { lines.append(s) }
}
