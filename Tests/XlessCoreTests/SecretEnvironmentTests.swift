import Testing
@testable import XlessCore

@Test func everyRegisteredSecretIsScrubbedWithItsFileVariant() {
    #expect(!SecretEnvironment.entries.isEmpty)
    for entry in SecretEnvironment.entries {
        #expect(Shell.scrubbedEnvironment.contains(entry.name))
        #expect(Shell.scrubbedEnvironment.contains("\(entry.name)_FILE"))
        #expect(SecretEnvironment.isSecret(entry.name))
        #expect(!entry.purpose.isEmpty)
    }
    #expect(Set(SecretEnvironment.entries.map(\.name)).count == SecretEnvironment.entries.count)
    #expect(!SecretEnvironment.isSecret("PATH"))
}

@Test func argumentNamesThatWouldCarryASecretAreRecognised() {
    for name in ["--password", "--apple-id-password", "password", "--passphrase", "--token", "--api-token", "--secret",
                 "--client-secret", "--cookie", "--private-key", "privateKey", "--api-key", "apiKey", "--key", "--p8",
                 "--otp", "--credentials", "--auth-key", "--signing-key", "--scnt", "--pem", "--jwt"] {
        #expect(SecretEnvironment.argumentLooksSecret(name), "\(name) should be refused")
    }
}

@Test func argumentNamesForPathsIdsAndOrdinaryOptionsAreAllowed() {
    for name in ["--key-id", "--key-file", "--private-key-file", "--api-key-id", "--out", "--file", "--kind", "--team",
                 "--keychain", "--keep", "--build-number", "--config", "--allow-new", "--csr-only", "--keyword", "--monkey",
                 "--passthrough", "--spin", "--pin", "--password-file", "--pem-path", "--type", "--input", "--json", "versions", "--output-dir", "--name"] {
        #expect(!SecretEnvironment.argumentLooksSecret(name), "\(name) should be allowed")
    }
}

@Test func argumentNamesSplitOnDashesUnderscoresAndCase() {
    #expect(SecretEnvironment.words(of: "--apple-id_password") == ["apple", "id", "password"])
    #expect(SecretEnvironment.words(of: "privateKeyFile") == ["private", "key", "file"])
    #expect(SecretEnvironment.words(of: "p8") == ["p8"])
}
