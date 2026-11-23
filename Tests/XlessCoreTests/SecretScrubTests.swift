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
