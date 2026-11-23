import ArgumentParser
import Crypto
import Foundation
import Testing
import XlessCore
import XlessStore
import XlessVault
@testable import xless

// The app an appstore/ manifest belongs to when app.yml has no bundleID: the overlay given with --config, else the
// xless.yml next to the manifest directory; its team is the default team.

private struct Project {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-project-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let cargo = """
type: cargo
source: app
bundleID: com.example.hello
teamID: ABCDE12345
version: "1.0.0"
build: dated
ios: { package: hello-mobile, product: Hello, minimumOS: "17.0", assets: Assets.xcassets, infoPlist: ios/Info.plist }
macos: { bundleID: com.example.hello.mac, package: hello, product: Hello, minimumOS: "11.0", icon: hello.icns }

"""

/// A listing whose app.yml names no app.
private let unnamed = "primaryLocale: en-US\nversion: \"1.0\"\n"

@Test func anOverlayGivesTheBundleIDPerPlatformAndTheTeam() throws {
    let p = try Project()
    defer { p.cleanup() }
    let project = try StoreProject.overlay(try p.write("hello.yml", cargo))
    #expect(project == StoreProject(bundleIDs: [.ios: "com.example.hello", .macos: "com.example.hello.mac"], team: "ABCDE12345", name: "overlay hello.yml"))
    #expect(project.bundleID(for: nil) == "com.example.hello")
    #expect(project.bundleID(for: "IOS") == "com.example.hello")
    #expect(project.bundleID(for: "MAC_OS") == "com.example.hello.mac")

    let tauri = try StoreProject.overlay(try p.write("tauri.yml", "type: tauri\nsource: app\nbundleID: com.example.app\nteamID: ZYXWV98765\nbuild: dated\n"))
    #expect(tauri.bundleIDs == [.ios: "com.example.app"] && tauri.team == "ZYXWV98765")
    #expect(tauri.bundleID(for: "MAC_OS") == nil, "no macos: block, no macOS app")

    let rn = try StoreProject.overlay(try p.write("rn.yml", "type: react-native\nscheme: App\nbundleIDs: { App: com.example.rn, Widget: com.example.rn.widget }\nteamID: ABCDE12345\nbuild: 7\n"))
    #expect(rn.bundleIDs == [.ios: "com.example.rn"], "the app target's, not its extension's")

    let macOnly = try StoreProject.overlay(try p.write("mac.yml", cargo.replacingOccurrences(of: #"ios: { package: hello-mobile, product: Hello, minimumOS: "17.0", assets: Assets.xcassets, infoPlist: ios/Info.plist }"#, with: "")))
    #expect(macOnly.bundleID(for: nil) == "com.example.hello.mac", "with no platform, the only app")

    #expect(throws: XlessError.self) { _ = try StoreProject.overlay(try p.write("bad.yml", "type: cargo\nsource: app\n")) }
}

@Test func withoutAnOverlayTheXlessYmlNextToTheManifestIsUsed() throws {
    let p = try Project()
    defer { p.cleanup() }
    try p.write("xless.yml", """
    bundleID: com.example.app
    teamID: ABCDE12345
    version: 1.2.0
    build: 7
    platforms:
      ios: { minimumOS: "17.0", product: App }
      macos: { minimumOS: "14.0", product: App, distribution: app-store, bundleID: com.example.mac }
    """)
    let project = StoreProject.nextTo(manifestDir: p.root.appendingPathComponent("appstore"))
    #expect(project == StoreProject(bundleIDs: [.ios: "com.example.app", .macos: "com.example.mac"], team: "ABCDE12345", name: "xless.yml"))
    #expect(StoreProject.nextTo(manifestDir: p.root.appendingPathComponent("nested/appstore")) == nil)
}

@Test func configPutsTheDefaultManifestNextToTheOverlay() throws {
    let pull = try StorePullCommand.parse(["--config", "/work/overlays/hello.yml"])
    #expect(pull.directory.url.path == "/work/overlays/appstore")
    #expect(try StorePullCommand.parse(["--config", "/work/overlays/hello.yml", "--dir", "/elsewhere/listing"]).directory.url.path == "/elsewhere/listing")
    #expect(try StorePushCommand.parse([]).directory.url.lastPathComponent == "appstore")
    #expect(try StorePrivacyPushCommand.parse(["--config", "o.yml"]).directory.config == "o.yml")
    #expect(try StoreValidateCommand.parse(["--config", "o.yml"]).directory.config == "o.yml")
    #expect(try ReleaseStatusCommand.parse(["--config", "o.yml"]).target.directory.config == "o.yml")
}

@Test func validateAndPushTakeTheBundleIDFromTheOverlay() throws {
    let p = try Project()
    defer { p.cleanup() }
    let overlay = try p.write("overlays/hello.yml", cargo)
    try p.write("overlays/appstore/app.yml", unnamed)
    try p.write("overlays/appstore/en-US/name.txt", "Hello\n")
    let options = try StoreValidateCommand.parse(["--config", overlay.path, "--draft"]).directory
    let dir = options.url
    #expect(dir.path == p.root.appendingPathComponent("overlays/appstore").path)

    let without = StoreValidation.run(dir: dir, draft: true, json: false)
    #expect(without.failed && without.stderr.contains("no bundleID"), "no overlay, no xless.yml: nothing to inherit")
    let with = StoreValidation.run(dir: dir, project: try options.project(), draft: true, json: false)
    #expect(!with.failed, "\(with.stderr)")

    let (_, bundle) = try StorePushCLI.check(dir: dir, project: try options.project(), say: { _ in })
    #expect(bundle == "com.example.hello")
    try p.write("overlays/appstore/app.yml", unnamed + "platform: MAC_OS\n")
    #expect(try StorePushCLI.check(dir: dir, project: try options.project(), say: { _ in }).1 == "com.example.hello.mac")
    try p.write("overlays/appstore/app.yml", unnamed + "bundleID: com.example.other\n")
    #expect(try StorePushCLI.check(dir: dir, project: try options.project(), say: { _ in }).1 == "com.example.other", "app.yml wins")

    #expect(try StorePrivacyCLI.wantedApp(nil, dir: dir, project: try options.project()) == "com.example.other")
    try p.write("overlays/appstore/app.yml", unnamed)
    #expect(try StorePrivacyCLI.wantedApp(nil, dir: dir, project: try options.project()) == "com.example.hello")
    #expect(try StorePrivacyCLI.wantedApp("com.example.flag", dir: dir, project: try options.project()) == "com.example.flag")
}

@Test func releaseTakesTheAppAndTeamFromTheOverlay() throws {
    let p = try Project()
    defer { p.cleanup() }
    let overlay = try p.write("hello.yml", cargo)
    try p.write("appstore/app.yml", unnamed)
    let wanted = try ReleaseStatusCommand.parse(["--config", overlay.path]).target.wanted()
    #expect(wanted == ReleaseWanted(app: "com.example.hello", platform: nil, version: "1.0", team: "ABCDE12345"))
    let mac = try ReleaseStatusCommand.parse(["--config", overlay.path, "--platform", "macos"]).target.wanted()
    #expect(mac.app == "com.example.hello.mac")
    #expect(throws: XlessError.self, "an overlay that cannot be read stops the command") {
        _ = try ReleaseStatusCommand.parse(["--config", p.root.appendingPathComponent("missing.yml").path]).target.wanted()
    }
}

private final class Passphrase: PassphrasePrompter, @unchecked Sendable {
    func askSecret(_ prompt: String) throws -> SecretBytes { SecretBytes(utf8: "correct horse battery") }
    func ask(_ prompt: String) throws -> String { "correct horse battery" }
    func say(_ line: String) {}
}

@Test func theProjectsTeamStillFindsAnAPIKeyStoredForNoTeam() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-team-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = VaultStore(location: VaultLocation(directory: root.appendingPathComponent("xless/vault")))
    var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1))
    file.entries.append(try VaultCrypto.seal(name: "ASC_KEY_P8", kind: .ascAPIKey,
                                             metadata: .init(keyID: "2X9R4HXF34", issuerID: "69a6de70-03db-47e3-e053-5b8c7c11a4d1"),
                                             secret: SecretBytes(utf8: P256.Signing.PrivateKey().pemRepresentation), dataKey: key))
    try vault.create(file)
    let store = VaultSecretStore(store: vault, cache: nil, prompter: { Passphrase() })
    let session = try AccountSession.open(team: nil, project: "ABCDE12345", verbose: false, env: [:], store: { store })
    #expect(session.team == "ABCDE12345")
    #expect(session.client.issuerID == "69a6de70-03db-47e3-e053-5b8c7c11a4d1", "the key stored for no team, as provision finds it")
}
