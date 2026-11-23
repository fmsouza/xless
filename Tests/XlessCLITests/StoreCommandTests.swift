import ArgumentParser
import XlessAppleID
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
    #expect(try StorePushCommand.parse(["--only", "privacy"]).options.parts == [.privacy])
    #expect(throws: (any Error).self) { try StorePushCommand.parse(["--only", "listing"]) }
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

// MARK: - App Privacy

/// App Store Connect's App Privacy, in memory.
private final class MemoryPrivacy: PrivacyRemote, @unchecked Sendable {
    let lock = NSLock()
    var stored: [WebDataUsage]
    var published: Bool?
    var sent: [String] = []

    init(_ stored: [WebDataUsage], published: Bool? = true) { self.stored = stored; self.published = published }

    func usages(app: String) async throws -> [WebDataUsage] { lock.withLock { stored } }
    func catalog() async throws -> WebPrivacyCatalog { WebPrivacyCatalog() }
    func publishState(app: String) async throws -> WebPrivacyPublishState? { lock.withLock { published.map { WebPrivacyPublishState(id: "PS", published: $0) } } }
    func create(app: String, category: String?, purpose: String?, protection: String) async throws -> String? {
        lock.withLock {
            sent.append("POST \(category ?? "-") \(purpose ?? "-") \(protection)")
            stored.append(WebDataUsage(id: "n\(stored.count)", category: category, purpose: purpose, protection: protection))
            published = false
            return "n"
        }
    }
    func delete(id: String) async throws { lock.withLock { sent.append("DELETE \(id)"); stored.removeAll { $0.id == id }; published = false } }
    func publish(stateID: String) async throws { lock.withLock { sent.append("PATCH \(stateID)"); published = true } }
}

private let emailAnswers = [WebDataUsage(id: "u1", category: "EMAIL_ADDRESS", purpose: "APP_FUNCTIONALITY", protection: "DATA_LINKED_TO_YOU")]
private let target = StorePrivacyCLI.Target(id: "123", name: "com.example.app")

@Test func privacyPullWritesOnlyAppYMLsPrivacy() async throws {
    let root = try manifest(["appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\n", "appstore/en-US/name.txt": "Example\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let said = Said()
    let cli = StorePrivacyCLI(remote: MemoryPrivacy(emailAnswers, published: false), json: false, say: { said.add($0) })
    #expect(try await cli.pull(app: target, dir: dir) == "wrote appstore/app.yml's privacy: 1 kind of data collected\n")
    let app = try String(contentsOf: dir.appendingPathComponent("app.yml"), encoding: .utf8)
    #expect(app.hasSuffix("bundleID: com.example.app\nprimaryLocale: en-US\nprivacy:\n  collectsData: true\n  data:\n  - category: EMAIL_ADDRESS\n    purposes:\n    - APP_FUNCTIONALITY\n    linkedToYou: true\n    tracking: false\n"))
    #expect(try String(contentsOf: dir.appendingPathComponent("en-US/name.txt"), encoding: .utf8) == "Example\n")
    #expect(said.lines == ["note: App Store Connect's answers are not published yet; `xless store privacy push` publishes them"])
    #expect(try await cli.pull(app: target, dir: dir) == "appstore/app.yml's privacy already matches App Store Connect (1 kind of data collected)\n")
}

@Test func privacyPullOfANewDirectoryAndOfAnAppNeverAnswered() async throws {
    let root = try manifest([:])
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let none = StorePrivacyCLI(remote: MemoryPrivacy([]), json: false, say: { _ in })
    #expect(try await none.pull(app: target, dir: dir) == "")
    #expect(!FileManager.default.fileExists(atPath: dir.path), "nothing answered: nothing written")
    let cli = StorePrivacyCLI(remote: MemoryPrivacy([WebDataUsage(id: "u", protection: "DATA_NOT_COLLECTED")]), json: true, say: { _ in })
    let json = try await cli.pull(app: target, dir: dir)
    #expect(json.contains("\"collectsData\" : false") && json.contains("\"appID\" : \"123\""))
    #expect(try String(contentsOf: dir.appendingPathComponent("app.yml"), encoding: .utf8).hasSuffix("bundleID: com.example.app\nprivacy:\n  collectsData: false\n"))
}

@Test func privacyPullRefusesAnUnreadableAppYML() async throws {
    let root = try manifest(["appstore/app.yml": "primaryLocale: [en-US\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = StorePrivacyCLI(remote: MemoryPrivacy(emailAnswers), json: false, say: { _ in })
    await #expect {
        _ = try await cli.pull(app: target, dir: root.appendingPathComponent("appstore"))
    } throws: { ($0 as? XlessError)?.cause.hasPrefix("appstore/app.yml cannot be read: is not valid YAML") == true }
}

@Test func privacyPushChecksTheSectionPlansSendsAndPublishes() async throws {
    let root = try manifest(["appstore/app.yml": "privacy:\n  collectsData: false\n", "bad/app.yml": "privacy:\n  collectsData: true\n", "none/app.yml": "bundleID: com.example.app\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect {
        _ = try StorePrivacyCLI.check(dir: root.appendingPathComponent("bad"), say: { _ in })
    } throws: { ($0 as? XlessError)?.cause == "bad/app.yml has 1 error; nothing was sent" }
    #expect {
        _ = try StorePrivacyCLI.check(dir: root.appendingPathComponent("none"), say: { _ in })
    } throws: { ($0 as? XlessError)?.cause == "none/app.yml has no privacy section; nothing was sent" }
    let want = try StorePrivacyCLI.check(dir: root.appendingPathComponent("appstore"), say: { _ in })

    let remote = MemoryPrivacy(emailAnswers)
    let cli = StorePrivacyCLI(remote: remote, json: false, say: { _ in })
    #expect(try await cli.push(want, app: target, dryRun: true) == """
        com.example.app App Privacy:
          - App Privacy EMAIL_ADDRESS
              purposes: "APP_FUNCTIONALITY" → (none)
              linkedToYou: "true" → (none)
              tracking: "false" → (none)
          + App Privacy: data not collected
          ~ publish the App Privacy answers of com.example.app
        3 changes: 1 to create, 1 to update, 1 to delete
        dry run: nothing was sent

        """)
    #expect(remote.sent.isEmpty)
    #expect(try await cli.push(want, app: target, dryRun: false) == "sent 3 changes to App Store Connect; the App Privacy answers are published\n")
    #expect(remote.sent == ["DELETE u1", "POST - - DATA_NOT_COLLECTED", "PATCH PS"])
    #expect(try await cli.push(want, app: target, dryRun: false).hasSuffix("nothing to push: App Store Connect already matches the manifest\n"))
}

@Test func storePushOpensTheWebSessionOnlyForPrivacyItCanSend() throws {
    var m = StoreManifest()
    #expect(try !StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: StorePushPart.allCases, explicit: false, kept: true, terminal: true), "no privacy in app.yml")
    m.app.privacy = AppYAML.Privacy(collectsData: false)
    #expect(try !StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: [.text], explicit: true, kept: true, terminal: true), "part not pushed")
    #expect(try StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: StorePushPart.allCases, explicit: false, kept: true, terminal: false))
    #expect(try StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: StorePushPart.allCases, explicit: false, kept: false, terminal: true))
    #expect(try !StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: StorePushPart.allCases, explicit: false, kept: false, terminal: false), "CI: noted, the rest goes")
    #expect(throws: XlessError.self) { try StorePrivacyCLI.storePushNeedsWeb(manifest: m, parts: [.privacy], explicit: true, kept: false, terminal: false) }
}

@Test func privacyCommandsParse() throws {
    let push = try StorePrivacyPushCommand.parse(["--dry-run", "--dir", "listing", "--app", "com.example.app"])
    #expect(push.dryRun && push.directory.dir == "listing" && push.app == "com.example.app")
    #expect(throws: (any Error).self) { try StorePrivacyPullCommand.parse(["--app", "not an app"]) }
}
