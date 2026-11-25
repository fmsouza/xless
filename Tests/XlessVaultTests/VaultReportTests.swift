import Crypto
import _CryptoExtras
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

@Test func listAndStatusNeverPrintAValue() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (file, _) = try t.make(passphrase: "PASSPHRASE-VALUE", entries: [
        ("ASC_KEY_P8", .ascAPIKey, .init(teamID: "TEAMA", keyID: "KEYID12345", issuerID: "ISSUER", created: Date(timeIntervalSince1970: 1_790_000_000)), "P8-VALUE"),
        ("NOTE", .generic, .init(), "GENERIC-VALUE"),
    ])
    let list = VaultReport.list(file)
    let status = VaultReport.status(location: t.location, file: file, held: nil)
    for text in [list, status] {
        for value in ["P8-VALUE", "GENERIC-VALUE", "PASSPHRASE-VALUE"] { #expect(!text.contains(value)) }
    }
    #expect(list.contains("ASC_KEY_P8") && list.contains("asc-api-key") && list.contains("KEYID12345") && list.contains("2026-09-21"))
    #expect(status.contains("Entries:  2") && status.contains("scrypt"))
    #expect(VaultReport.status(location: t.location, file: nil, held: nil).contains("xless secrets init"))
}

@Test func statusSaysWhereAnUnlockIsHeldAndUntilWhen() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (file, _) = try t.make()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func unlocked(_ held: HeldUnlock?, canHold: Bool = true) -> String {
        VaultReport.status(location: t.location, file: file, held: held, canHold: canHold, now: now)
            .split(separator: "\n").first { $0.hasPrefix("Unlocked:") }.map(String.init) ?? ""
    }
    #expect(unlocked(nil).contains("no (`xless unlock`"))
    #expect(unlocked(nil, canHold: false).contains("cannot be kept unlocked here"))
    let agent = unlocked(HeldUnlock(backend: .agent, expires: now + 7200, idle: 1800, idleExpires: now + 600))
    #expect(agent.contains("yes, in the xless agent for 2 h more, or 30 min without use") && agent.contains("xless lock"))
    #expect(unlocked(HeldUnlock(backend: .keyring, expires: now + 1800)).contains("in the kernel keyring for 30 min more"))
    #expect(unlocked(HeldUnlock(backend: .keyring, expires: nil)).contains("in the kernel keyring until it expires"))
}

@Test func errorsNeverCarryTheSecret() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [("ASC_KEY_P8", .ascAPIKey, .init(), "P8-VALUE")])
    var json = try String(contentsOf: t.location.file, encoding: .utf8)
    json = json.replacingOccurrences(of: "asc-api-key", with: "generic")
    try Data(json.utf8).write(to: t.location.file)
    let secrets = Secrets(env: [:], fallback: VaultResolver(store: t.store, cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) }))
    do { _ = try secrets.required("ASC_KEY_P8", stage: .upload); Issue.record("read an altered entry") } catch let e as XlessError {
        #expect(e.cause.contains("integrity"))
        #expect(!e.description.contains("P8-VALUE") && !e.description.contains("correct horse"))
    }
}

@Test func importInfersKindsAndKeyIDs() {
    #expect(VaultImport.inferredKind(for: "ASC_KEY_P8") == .ascAPIKey)
    #expect(VaultImport.inferredKind(for: "ASC_KEY_P8@TEAMA") == .ascAPIKey)
    #expect(VaultImport.inferredKind(for: "XLESS_DEVID_KEY") == .signingKey)
    #expect(VaultImport.inferredKind(for: "XLESS_DEMO_PASSWORD") == .password)
    #expect(VaultImport.inferredKind(for: "something") == .generic)
    #expect(VaultImport.keyID(fromFileName: "AuthKey_ABC123DEFG.p8") == "ABC123DEFG")
    #expect(VaultImport.keyID(fromFileName: "key.p8") == nil)
    #expect(VaultImport.keyID(fromFileName: "AuthKey_.p8") == nil)
}

@Test func importChecksKeysAreWhatTheirKindSays() throws {
    let p8 = P256.Signing.PrivateKey().pemRepresentation
    try VaultImport.validate(SecretBytes(utf8: p8), kind: .ascAPIKey)
    try VaultImport.validate(SecretBytes(utf8: p8.replacingOccurrences(of: "\n", with: "\r\n")), kind: .authKey)
    #expect(throws: VaultError.self) { try VaultImport.validate(SecretBytes(utf8: "NOT A KEY"), kind: .ascAPIKey) }
    #expect(throws: VaultError.self) { try VaultImport.validate(SecretBytes(utf8: p8), kind: .signingKey) }
    let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
    try VaultImport.validate(SecretBytes(utf8: rsa), kind: .signingKey)
    #expect(throws: VaultError.self) { try VaultImport.validate(SecretBytes(count: 0), kind: .generic) }
    do { try VaultImport.validate(SecretBytes(utf8: "SECRET-JUNK"), kind: .ascAPIKey) } catch let e as VaultError {
        #expect(!e.description.contains("SECRET-JUNK"))
    }
}
