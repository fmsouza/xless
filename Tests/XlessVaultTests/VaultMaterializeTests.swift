import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

private let entries: [(String, VaultEntry.Kind, VaultEntry.Metadata, String)] = [
    ("ASC_KEY_P8@TEAMA12345", .ascAPIKey, .init(teamID: "TEAMA12345", keyID: "KEYA", issuerID: "ISSUER-A"), "P8-A"),
    ("ASC_KEY_P8@TEAMB12345", .ascAPIKey, .init(teamID: "TEAMB12345", keyID: "KEYB", issuerID: "ISSUER-B"), "P8-B"),
    ("XLESS_DIST_KEY", .signingKey, .init(), "DIST-PEM\n"),
]

private func sets(_ texts: String...) throws -> [MaterializeSet] { try texts.map(MaterializeSet.parse) }

@Test func setsParseAndRefuseWhatXlessDoesNotRead() throws {
    #expect(try MaterializeSet.parse("sign=ASC_KEY_P8, XLESS_DIST_KEY,ASC_KEY_P8") == MaterializeSet(name: "sign", secrets: ["ASC_KEY_P8", "XLESS_DIST_KEY"]))
    for bad in ["sign", "Sign=ASC_KEY_P8", "sign=", "sign=ASC_KEY_P8_FILE", "sign=MY-PW", "../x=ASC_KEY_P8",
                "sign=?", "sign=MY_PW_FILE", "sign=MY_PW_FILE@ABCDE12345", "sign=MY_PW@abc", "sign=DEPLOY_TOKEN", "sign=?ASC_FOO", "sign=APP_KEY"] {
        #expect(throws: XlessError.self) { try MaterializeSet.parse(bad) }
    }
}

@Test func eachSetIsItsOwnDirectoryOfMode0600FilesWithOnePassphrase() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: entries)
    let prompter = ScriptedPrompter(["correct horse battery"])
    let m = VaultMaterializer(store: t.store, team: "TEAMA12345", cache: nil, prompter: { prompter })
    var announced: URL?
    let run = try m.write(try sets("next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID", "sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY"),
                          base: t.root.appendingPathComponent("runtime/xless")) { announced = $0 }
    #expect(announced == run)
    #expect(prompter.asked == 1)
    #expect(try mode(t.root.appendingPathComponent("runtime/xless").path) == 0o700)
    #expect(try mode(run.path) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.path).sorted() == ["next", "sign"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("next").path).sorted() == ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_P8"])
    func read(_ p: String) throws -> String { try String(contentsOf: run.appendingPathComponent(p), encoding: .utf8) }
    #expect(try read("sign/ASC_KEY_P8") == "P8-A")
    #expect(try read("sign/ASC_KEY_ID") == "KEYA")
    #expect(try read("next/ASC_ISSUER_ID") == "ISSUER-A")
    #expect(try read("sign/XLESS_DIST_KEY") == "DIST-PEM\n")
    #expect(try mode(run.appendingPathComponent("sign").path) == 0o700)
    #expect(try mode(run.appendingPathComponent("sign/XLESS_DIST_KEY").path) == 0o600)
}

@Test func aMissingSecretFailsBeforeThePassphraseAndBeforeAnyFile() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: entries)
    let prompter = ScriptedPrompter(["correct horse battery"])
    let m = VaultMaterializer(store: t.store, team: "TEAMC12345", cache: nil, prompter: { prompter })
    let base = t.root.appendingPathComponent("runtime/xless")
    do {
        _ = try m.write(try sets("sign=XLESS_DIST_KEY,ASC_KEY_P8"), base: base) { _ in Issue.record("nothing may be created") }
        Issue.record("expected a missing secret")
    } catch let e as XlessError {
        #expect(e.cause.contains("no ASC_KEY_P8 for team TEAMC12345"))
        #expect(e.fix.contains("xless secrets import ASC_KEY_P8"))
    }
    #expect(prompter.asked == 0)
    #expect(!FileManager.default.fileExists(atPath: base.path))
}

@Test func checkingNeedsNoPassphraseAndNamesAMissingStore() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let none = VaultMaterializer(store: t.store, team: nil, cache: nil, prompter: { nil })
    do { try none.check(try sets("sign=XLESS_DIST_KEY")); Issue.record("expected no store") } catch let e as XlessError {
        #expect(e.cause.contains("there is no secret store"))
        #expect(e.cause.contains("XLESS_DIST_KEY_FILE"))
    }
    try t.make(entries: entries)
    let prompter = ScriptedPrompter([])
    let m = VaultMaterializer(store: t.store, team: "TEAMB12345", cache: nil, prompter: { prompter })
    try m.check(try sets("sign=ASC_KEY_P8,ASC_KEY_ID,XLESS_DIST_KEY"))
    #expect(prompter.asked == 0)
    // Without a team, two API keys are ambiguous.
    #expect(throws: XlessError.self) { try VaultMaterializer(store: t.store, team: nil, cache: nil, prompter: { nil }).check(try sets("next=ASC_KEY_P8")) }
}

@Test func aSetGivenTwiceIsRefusedAndNothingIsLeft() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: entries)
    let base = t.root.appendingPathComponent("runtime/xless")
    let m = VaultMaterializer(store: t.store, team: "TEAMA12345", cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) })
    #expect(throws: XlessError.self) { _ = try m.write(try sets("sign=XLESS_DIST_KEY", "sign=ASC_KEY_P8"), base: base) { _ in } }
    #expect(!FileManager.default.fileExists(atPath: base.path))
}

@Test func aFailureHalfWayRemovesTheRunDirectory() throws {
    guard geteuid() != 0 else { return } // root ignores the permission the failure is made of
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: entries)
    let base = t.root.appendingPathComponent("runtime/xless")
    let m = VaultMaterializer(store: t.store, team: "TEAMA12345", cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) })
    // The announced run directory is made read-only before the sets are written: the first set cannot be created.
    #expect(throws: XlessError.self) {
        _ = try m.write(try sets("sign=XLESS_DIST_KEY"), base: base) { chmod($0.path, 0o500) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
}

@Test func aBaseOthersCanReadIsRefused() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: entries)
    let base = t.root.appendingPathComponent("wide")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let m = VaultMaterializer(store: t.store, team: "TEAMA12345", cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) })
    #expect(throws: XlessError.self) { _ = try m.write(try sets("sign=XLESS_DIST_KEY"), base: base) { _ in } }
    #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
}

@Test func theRunBaseIsTheRuntimeTmpfsOrARefusal() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let runtime = t.root.path
    let memory = try SecretRunBase.choose(env: ["XDG_RUNTIME_DIR": runtime], allowDisk: false, isMemory: { _ in true })
    #expect(memory.path == runtime + "/xless")
    // On disk: refused, unless allowed.
    do { _ = try SecretRunBase.choose(env: ["XDG_RUNTIME_DIR": runtime], allowDisk: false, isMemory: { _ in false }); Issue.record("expected a refusal") }
    catch let e as XlessError {
        #expect(e.cause.contains("not a memory file system"))
        #expect(e.fix.contains("--allow-disk-secrets"))
    }
    #expect(try SecretRunBase.choose(env: ["XDG_RUNTIME_DIR": runtime], allowDisk: true, isMemory: { _ in false }).path == runtime + "/xless")
    // No XDG_RUNTIME_DIR (macOS): refused, unless allowed, then under the home directory's cache (Colima shares $HOME).
    do { _ = try SecretRunBase.choose(env: ["HOME": "/home/u"], allowDisk: false); Issue.record("expected a refusal") }
    catch let e as XlessError { #expect(e.cause.contains("XDG_RUNTIME_DIR is not set")) }
    do { _ = try SecretRunBase.choose(env: ["XDG_RUNTIME_DIR": "run/user"], allowDisk: false); Issue.record("expected a refusal") }
    catch let e as XlessError { #expect(e.cause.contains("XDG_RUNTIME_DIR (run/user) is not an absolute path")) }
    #expect(try SecretRunBase.choose(env: ["HOME": "/home/u"], allowDisk: true).path == "/home/u/.cache/xless/secrets")
    #expect(try SecretRunBase.choose(env: ["HOME": "/home/u", "XDG_RUNTIME_DIR": "relative"], allowDisk: true).path == "/home/u/.cache/xless/secrets")
    #expect(try SecretRunBase.choose(env: ["XDG_CACHE_HOME": "/c"], allowDisk: true).path == "/c/xless/secrets")
}

#if os(Linux)
@Test func devShmIsAMemoryFileSystemAndTheRootIsNot() {
    if FileManager.default.fileExists(atPath: "/dev/shm") { #expect(SecretRunBase.isMemoryFileSystem("/dev/shm")) }
    #expect(!SecretRunBase.isMemoryFileSystem("/nonexistent-\(UUID().uuidString)"))
}
#endif

@Test func optionalSecretsAndPasswordsUnderTheirOwnNamesParse() throws {
    #expect(try MaterializeSet.parse("sign=ASC_KEY_P8,?XLESS_DEMO_PASSWORD")
            == MaterializeSet(name: "sign", secrets: ["ASC_KEY_P8", "XLESS_DEMO_PASSWORD"], optional: ["XLESS_DEMO_PASSWORD"]))
    #expect(try MaterializeSet.parse("sign=?MY_REVIEW_PW@ABCDE12345").optional == ["MY_REVIEW_PW@ABCDE12345"])
    #expect(try MaterializeSet.parse("sign=MY_REVIEW_PW").optional == [])
    // named both ways: needed
    #expect(try MaterializeSet.parse("sign=?XLESS_DEMO_PASSWORD,XLESS_DEMO_PASSWORD").optional == [])
}

private let withPasswords = entries + [
    ("XLESS_DEMO_PASSWORD", VaultEntry.Kind.password, VaultEntry.Metadata(), "demo-pw"),
    ("MY_REVIEW_PW", .password, .init(), "my-pw"),
    ("MY_SIGNING_PW", .signingKey, .init(), "PEM"),
]

@Test func anOptionalSecretIsWrittenWhenTheStoreHasItAndLeftOutWhenNot() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: withPasswords)
    let m = VaultMaterializer(store: t.store, team: "TEAMA12345", cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) })
    try m.check(try sets("sign=XLESS_DIST_KEY,?NOT_STORED_PW,?MY_REVIEW_PW"))
    let run = try m.write(try sets("next=ASC_KEY_P8", "sign=XLESS_DIST_KEY,?NOT_STORED_PW,?MY_REVIEW_PW,?XLESS_DEMO_PASSWORD"),
                          base: t.root.appendingPathComponent("runtime/xless")) { _ in }
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("sign").path).sorted()
            == ["MY_REVIEW_PW", "XLESS_DEMO_PASSWORD", "XLESS_DIST_KEY"])
    #expect(try String(contentsOf: run.appendingPathComponent("sign/MY_REVIEW_PW"), encoding: .utf8) == "my-pw")
    #expect(try mode(run.appendingPathComponent("sign/XLESS_DEMO_PASSWORD").path) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("next").path) == ["ASC_KEY_P8"])
    // needed, it is a missing secret as before
    #expect(throws: XlessError.self) { try m.check(try sets("sign=NOT_STORED_PW")) }
}

@Test func onlyAPasswordLeavesTheStoreUnderANameOfTheUsersOwn() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: withPasswords)
    let m = VaultMaterializer(store: t.store, team: nil, cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) })
    for text in ["sign=MY_SIGNING_PW", "sign=?MY_SIGNING_PW"] {
        do { try m.check(try sets(text)); Issue.record("a signing key left as a password: \(text)") } catch let e as XlessError {
            #expect(e.cause.contains("MY_SIGNING_PW is a signing-key, not a password"))
        }
    }
    let base = t.root.appendingPathComponent("runtime/xless")
    #expect(throws: XlessError.self) { _ = try m.write(try sets("sign=?MY_SIGNING_PW"), base: base) { _ in Issue.record("nothing may be created") } }
    #expect(!FileManager.default.fileExists(atPath: base.path))
}

@Test func aStoreWithoutAnyOfTheOptionalSecretsAsksNoPassphrase() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let prompter = ScriptedPrompter([])
    let none = VaultMaterializer(store: t.store, team: nil, cache: nil, prompter: { prompter })
    try none.check(try sets("sign=?XLESS_DEMO_PASSWORD"))
    let run = try none.write(try sets("sign=?XLESS_DEMO_PASSWORD"), base: t.root.appendingPathComponent("runtime/xless")) { _ in }
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("sign").path) == [])
    #expect(prompter.asked == 0)
}
