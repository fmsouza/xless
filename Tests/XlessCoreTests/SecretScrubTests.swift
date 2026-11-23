import Foundation
import Testing
@testable import XlessCore

private func unique(_ prefix: String) -> String { "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" }

@Test func aRegisteredNameIsAbsentFromAChildsEnvironment() throws {
    let name = unique("MY_REVIEW_PASSWORD")
    let base = ["PATH": "/usr/bin:/bin", name: "hunter2", "\(name)_FILE": "/run/pw", "OTHER": "kept"]
    // Before it is registered, a variable of the user's own reaches the tools like any other.
    #expect(try Shell.run("env", [], baseEnvironment: base, stage: .build).stdout.contains("\(name)=hunter2"))
    SecretEnvironment.scrub(name)
    let out = try Shell.run("env", [], baseEnvironment: base, stage: .build).stdout
    #expect(!out.contains(name))
    #expect(!out.contains("hunter2"))
    #expect(out.contains("OTHER=kept"))
}

@Test func secretsRegisterEveryNameTheyAreAskedFor() throws {
    let found = unique("MY_PW"), missing = unique("NOT_SET")
    let secrets = Secrets(env: [found: "pw"], fallback: nil)
    #expect(try secrets.optional(found) == "pw")
    #expect(try secrets.optional(missing) == nil)
    #expect(SecretEnvironment.scrubbed.contains(found) && SecretEnvironment.scrubbed.contains("\(found)_FILE"))
    #expect(SecretEnvironment.scrubbed.contains(missing))
}

@Test func aStoreEntrysTeamIsDroppedAndNamesThatAreNoVariablesAreIgnored() {
    let name = unique("TEAM_PW")
    SecretEnvironment.scrub("\(name)@ABCDE12345")
    #expect(SecretEnvironment.scrubbed.contains(name))
    for bad in ["", "1ABC", "A B", "A=B", "ÄPW", "-x", "@TEAM"] {
        SecretEnvironment.scrub(bad)
        #expect(!SecretEnvironment.scrubbed.contains(bad))
    }
}

@Test func theBuiltInSecretsStayFirstAndAreNotRepeated() {
    SecretEnvironment.scrub("ASC_KEY_P8")
    #expect(Array(SecretEnvironment.scrubbed.prefix(SecretEnvironment.names.count)) == SecretEnvironment.names)
    #expect(SecretEnvironment.scrubbed.filter { $0 == "ASC_KEY_P8" }.count == 1)
}

@Test func projectConfigNamesTheDemoPasswordSecret() throws {
    let c = try ProjectConfig.parse(yaml: validYAML + """

    testflight:
      whatToTest: Try it
      external:
        groups: [Beta]
        info: {description: A beta, feedbackEmail: beta@example.com}
        review:
          contact: {firstName: Ada, lastName: Lovelace, phone: "+1 555 0100", email: review@example.com}
          demoAccount: {name: demo, passwordSecret: MY_REVIEW_PW, required: true}
    """)
    #expect(c.secretNames == ["MY_REVIEW_PW"])
    #expect(try ProjectConfig.parse(yaml: validYAML).secretNames == [])
}

private func testflight(_ demo: String?) throws -> TestFlightConfig {
    let review = demo.map { "\n    review:\n      demoAccount: \($0)" } ?? ""
    return try #require(try ProjectConfig.parse(yaml: validYAML + """

    testflight:
      whatToTest: Try it
      external:
        groups: [Beta]\(review)
    """).testflight)
}

@Test func theDemoPasswordSecretIsNamedOnlyWhenTheAccountMayNeedItsPassword() throws {
    #expect(try testflight("{name: demo, required: true}").demoPasswordSecret == "XLESS_DEMO_PASSWORD")
    #expect(try testflight("{name: demo, passwordSecret: MY_REVIEW_PW, required: true}").demoPasswordSecret == "MY_REVIEW_PW")
    #expect(try testflight("{name: demo, passwordSecret: MY_REVIEW_PW@ABCDE12345}").demoPasswordSecret == "MY_REVIEW_PW@ABCDE12345")   // Apple may still require it
    #expect(try testflight("{name: demo, passwordSecret: MY_REVIEW_PW, required: false}").demoPasswordSecret == nil)   // never sent
    #expect(try testflight("{passwordSecret: MY_REVIEW_PW}").demoPasswordSecret == nil)   // says nothing about the account
    #expect(try testflight(nil).demoPasswordSecret == nil)
    #expect(TestFlightConfig(groups: ["Internal"]).demoPasswordSecret == nil)
    // what is scrubbed stays the custom name, whether or not it may be sent
    #expect(try testflight("{name: demo, passwordSecret: MY_REVIEW_PW, required: false}").secretNames == ["MY_REVIEW_PW"])
}

@Test func loadingAnXlessYmlRegistersItsDemoPasswordSecret() throws {
    let name = unique("YML_REVIEW_PW")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-scrub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("xless.yml")
    try (validYAML + """

    testflight:
      whatToTest: Try it
      external:
        groups: [Beta]
        review:
          demoAccount: {name: demo, passwordSecret: \(name), required: true}
    """).write(to: file, atomically: true, encoding: .utf8)
    #expect(!SecretEnvironment.scrubbed.contains(name))
    _ = try ProjectConfig.load(from: file)
    #expect(SecretEnvironment.scrubbed.contains(name) && SecretEnvironment.scrubbed.contains("\(name)_FILE"))
}

// MARK: passwordSecret may not name a variable something else relies on

@Test func aPasswordsNameMayNotBeAVariableTheSystemOrXlessUses() {
    for name in ["PATH", "HOME", "ENV", "IFS", "path", "Home", "PATH@ABCDE12345", "LD_PRELOAD", "LC_ALL", "XDG_RUNTIME_DIR", "SSH_AUTH_SOCK",
                 "PASSWORD_STORE_DIR", "XLESS_NO_SECRET_STORE", "XLESS_USE_DOCKER", "xless_cache", "MY_PASSWORD_FILE", "SIM", "TEAM", "NAME"] {
        #expect(SecretEnvironment.passwordNameProblem(name) != nil, "\(name)")
    }
    #expect(SecretEnvironment.passwordNameProblem("ASC_KEY_P8") == "names a key or token, not a password")
    #expect(SecretEnvironment.passwordNameProblem("PATH")?.contains("the system, the shell or xless's scripts use (PATH)") == true)
    #expect(SecretEnvironment.passwordNameProblem("XLESS_RN_CLEAN")?.contains("xless's own variables") == true)
    for name in ["XLESS_DEMO_PASSWORD", "XLESS_DEMO_PASSWORD@ABCDE12345", "APP_REVIEW_PASSWORD", "MY_REVIEW_PW", "DEMO_LOGIN@ABCDE12345", "PATHWAY_PASSWORD"] {
        #expect(SecretEnvironment.passwordNameProblem(name) == nil, "\(name)")
    }
}

@Test func xlessYmlRefusesAReservedPasswordSecretAsAConfigError() throws {
    for name in ["PATH", "HOME", "ENV", "XLESS_NO_SECRET_STORE", "LD_PRELOAD"] {
        let e = #expect(throws: XlessError.self) { try testflight("{name: demo, passwordSecret: \(name), required: true}") }
        #expect(e?.stage == .config)
        #expect(e?.cause.contains("passwordSecret \(name) names") == true, "\(e?.cause ?? "")")
    }
    // Never registered for scrubbing, so the tools a loader starts before validating keep PATH.
    #expect(TestFlightConfig(groups: [], external: .init(groups: ["B"], review: .init(demoAccount: .init(name: "d", passwordSecret: "PATH")))).secretNames.isEmpty)
}

/// Every upper-case global scripts/testflight.sh assigns is a reserved name: it reads the password with `${!NAME}`, so
/// a passwordSecret naming one of its own variables would read that instead.
@Test func testflightShGlobalsAreReservedPasswordNames() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(contentsOf: root.appendingPathComponent("scripts/testflight.sh"), encoding: .utf8)
    let globals = Set(script.matches(of: /(?m)(?:^|[\s;(])([A-Z][A-Z0-9_]{2,})(?:\+)?=/).map { String($0.output.1) })
    #expect(globals.count > 10)
    for name in globals.sorted() where name != "XLESS_DEMO_PASSWORD" {
        #expect(SecretEnvironment.passwordNameProblem(name) != nil, "scripts/testflight.sh sets \(name): add it to SecretEnvironment.reservedVariables")
    }
}
