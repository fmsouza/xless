import Foundation
import Testing
@testable import XlessCore

private func config(_ text: String?) throws -> ([String: String], URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-userconfig-\(UUID().uuidString)")
    let env = ["XDG_CONFIG_HOME": dir.path, "HOME": dir.path]
    if let text {
        let file = UserConfig.file(env: env)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    return (env, dir)
}

@Test func theSecretsBackendIsTheVaultByDefault() throws {
    for text in [nil, "", "team: ABCDE12345\n", "secrets:\n  backend: vault\n"] {
        let (env, dir) = try config(text)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try UserConfig.secretsBackend(env: env) == .vault, "\(text ?? "no file")")
    }
}

@Test func aHelperBackendNamesItsHelper() throws {
    let (env, dir) = try config("secrets:\n  backend: helper\n  helper: secret-tool\n")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try UserConfig.secretsBackend(env: env) == .helper("secret-tool"))
    #expect(try UserConfig.load(env: env).team == nil)
}

@Test func aBadSecretsSettingIsAConfigErrorThatNamesTheFix() throws {
    let bad = [
        "secrets: 3\n",
        "secrets:\n  backend: keychain\n",
        "secrets:\n  backend: helper\n",
        "secrets:\n  backend: helper\n  helper: ../../bin/sh\n",
        "secrets:\n  backend: helper\n  helper: /usr/bin/pass\n",
        "secrets:\n  backend: helper\n  helper: Pass\n",
        "secrets:\n  backend: vault\n  helper: pass\n",
        "secrets:\n  backend: helper\n  helper: pass\n  timeout: 3\n",
    ]
    for text in bad {
        let (env, dir) = try config(text)
        defer { try? FileManager.default.removeItem(at: dir) }
        let error = #expect(throws: XlessError.self, "\(text)") { try UserConfig.secretsBackend(env: env) }
        #expect(error?.stage == .config)
        #expect(error?.fix.contains("secrets:") == true, "\(text): \(error?.fix ?? "")")
    }
}

@Test func savingTheTeamKeepsTheSecretsSetting() throws {
    let (env, dir) = try config("secrets:\n  backend: helper\n  helper: pass\n")
    defer { try? FileManager.default.removeItem(at: dir) }
    try UserConfig.update(env: env) { $0.team = "ABCDE12345" }
    #expect(try UserConfig.secretsBackend(env: env) == .helper("pass"))
    #expect(try UserConfig.load(env: env).team == "ABCDE12345")
}

@Test func helperNamesAreShort() {
    #expect(SecretsBackend.isValidHelperName("pass"))
    #expect(SecretsBackend.isValidHelperName("secret-tool"))
    #expect(SecretsBackend.isValidHelperName("1password.cli_2"))
    #expect(!SecretsBackend.isValidHelperName(""))
    #expect(!SecretsBackend.isValidHelperName("-pass"))
    #expect(!SecretsBackend.isValidHelperName("a/b"))
    #expect(!SecretsBackend.isValidHelperName(String(repeating: "a", count: 65)))
}
