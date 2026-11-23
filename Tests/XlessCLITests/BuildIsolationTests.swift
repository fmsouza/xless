import Foundation
import Testing
import XlessASC
import XlessCore
@testable import xless

/// A secret store that has the API key only for team ABCDE12345, as the store does for a key recorded `@ABCDE12345`
/// when another team's key is there too.
private struct TeamStore: SecretFallback {
    var team: String? = nil
    func lookup(_ name: String, stage: Stage) throws -> String? { team == "ABCDE12345" ? fakeKeyEnv[name] : nil }
    func preferring(team: String) -> any SecretFallback { TeamStore(team: team) }
}

@Test func inspectAsksForTheNextBuildWithTheProjectsTeam() async throws {
    let secrets = Secrets(env: [:], fallback: TeamStore())
    let next = try await InspectNextBuild.query(dated: true, team: "ABCDE12345", secrets: secrets) { secrets in
        // The query gets the team's key.
        try ASCCredentials.fromSecrets(secrets, stage: .config).keyID == "KEY123" ? "20261123.1" : "wrong key"
    }
    #expect(next == "20261123.1")
    // Another team's run finds no key: no query.
    let none = try await InspectNextBuild.query(dated: true, team: "ZZZZZ99999", secrets: secrets) { _ in "queried" }
    #expect(none == nil)
}

@Test func inspectMakesNoQueryForAFixedBuildAndReportsAFailedOne() async throws {
    let secrets = Secrets(env: fakeKeyEnv, fallback: nil)
    #expect(try await InspectNextBuild.query(dated: false, team: "ABCDE12345", secrets: secrets) { _ in "queried" } == nil)
    let failed = try await InspectNextBuild.query(dated: true, team: "ABCDE12345", secrets: secrets) { _ in
        throw XlessError(.config, "App Store Connect said no", fix: "x")
    }
    #expect(failed == "(App Store Connect query failed: App Store Connect said no)")
}

@Test func aRunRegistersTheDemoPasswordSecretOfItsConfigurationBeforeAnyToolRuns() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-isolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let name = "MY_REVIEW_PW_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    try """
    bundleID: app.example.helloship
    teamID: ABCDE12345
    version: 1.0.0
    build: 7
    platforms:
      ios: { minimumOS: "17.0", product: HelloShip }
    testflight:
      whatToTest: Try it
      external:
        groups: [Beta]
        info: {description: A beta, feedbackEmail: beta@example.com}
        review:
          contact: {firstName: Ada, lastName: Lovelace, phone: "+1 555 0100", email: review@example.com}
          demoAccount: {name: demo, passwordSecret: \(name), required: true}
    """.write(to: dir.appendingPathComponent("xless.yml"), atomically: true, encoding: .utf8)
    #expect(!SecretEnvironment.scrubbed.contains(name))
    let options = try ProjectOptions.parse(["--project", dir.path, "--platform", "ios"])
    _ = try await Context.load(options, env: ["PATH": "/usr/bin:/bin"])
    #expect(SecretEnvironment.scrubbed.contains(name))
    let out = try Shell.run("env", [], baseEnvironment: ["PATH": "/usr/bin:/bin", name: "hunter2"], stage: .build).stdout
    #expect(!out.contains("hunter2"))
}

@Test func ctrlCDuringTheInspectQueryIsNoFailedQuery() async {
    await #expect(throws: CancellationError.self) {
        _ = try await InspectNextBuild.query(dated: true, team: "ABCDE12345", secrets: Secrets(env: fakeKeyEnv, fallback: nil)) { _ in
            throw CancellationError()
        }
    }
}
