import Foundation
import Testing
@testable import XlessCore

@Test func aVariableIsFoundInAnyCaseOnlyWhereItHasNone() {
    let env = ["Asc_Key_Id": "v", "Path": "p"]
    #expect(env.variable("ASC_KEY_ID", ignoreCase: true) == "v")
    #expect(env.variable("ASC_KEY_ID", ignoreCase: false) == nil)
    #expect(env.variable("Path", ignoreCase: false) == "p")
    #expect(env.variable("ASC_KEY", ignoreCase: true) == nil)
    // Of two, the one that has the name exactly; else always the same one.
    #expect(["A": "1", "a": "2"].variable("a", ignoreCase: true) == "2")
    #expect(["aB": "1", "Ab": "2"].variable("AB", ignoreCase: true) == "2")
    // Not by other letters' rules: U+0131 is not an I, U+017F is not an S.
    #expect(["ASC_KEY_\u{131}D": "v"].variable("ASC_KEY_ID", ignoreCase: true) == nil)
    #expect(["A\u{17f}C_KEY_ID": "v"].variable("ASC_KEY_ID", ignoreCase: true) == nil)
}

@Test func thisSystemsRuleIsWindowsOnlyOnWindows() throws {
    #if os(Windows)
    #expect(EnvironmentNames.ignoreCase)
    #expect(try Secrets(env: ["asc_key_id": "K"], fallback: nil).identifier("ASC_KEY_ID", stage: .upload) == "K")
    #expect(!InputGate.allows(env: ["xless_no_input": "1"]))
    #expect(SecretEnvironment.isSecret("asc_Key_p8_file"))
    #else
    #expect(!EnvironmentNames.ignoreCase)
    #expect(try Secrets(env: ["asc_key_id": "K"], fallback: nil).optional("ASC_KEY_ID") == nil)
    #expect(InputGate.allows(env: ["xless_no_input": "1"]))
    #expect(!SecretEnvironment.isSecret("asc_Key_p8_file"))
    #endif
}

@Test func secretsNamesAreKnownInAnyCaseWhereItDoesNotMatter() {
    #expect(SecretEnvironment.isSecret("xless_dist_key_File", ignoreCase: true))
    #expect(!SecretEnvironment.isSecret("xless_dist_key_File", ignoreCase: false))
    #expect(!SecretEnvironment.isSecret("xless_dist_key_", ignoreCase: true))
}

@Test func aRegisteredNameIsScrubbedInTheCaseThatCountsHere() {
    let name = "My_Review_Pw_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    SecretEnvironment.scrub(name)
    #if os(Windows)
    #expect(SecretEnvironment.scrubbed.contains(name.uppercased()) && SecretEnvironment.scrubbed.contains("\(name.uppercased())_FILE"))
    #expect(!SecretEnvironment.scrubbed.contains(name), "one variable, one entry")
    #else
    #expect(SecretEnvironment.scrubbed.contains(name) && SecretEnvironment.scrubbed.contains("\(name)_FILE"))
    #expect(!SecretEnvironment.scrubbed.contains(name.uppercased()))
    #endif
}

@Test(arguments: ["SystemRoot", "COMSPEC", "PATHEXT", "APPDATA", "LocalAppData", "USERPROFILE", "PSModulePath", "windir"])
func windowsOwnVariablesNameNoPasswordThere(_ name: String) {
    #expect(SecretEnvironment.passwordNameProblem(name, onWindows: true) != nil)
    #expect(SecretEnvironment.passwordNameProblem(name, onWindows: false) == nil)
}

@Test(arguments: ["TEMP", "tmp", "PATH", "xless_dist_key"]) func whatIsReservedEverywhereStaysSo(_ name: String) {
    for onWindows in [true, false] { #expect(SecretEnvironment.passwordNameProblem(name, onWindows: onWindows) != nil) }
}
