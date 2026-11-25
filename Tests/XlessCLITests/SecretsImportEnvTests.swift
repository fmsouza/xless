import Foundation
import Testing
import XlessVault
@testable import xless

private func plan(_ text: [(String, String)], files: [String: String] = [:]) throws -> EnvImport {
    try EnvImport(text.map { (name: $0.0, value: $0.1) }) { try #require(files[$0]) }
}

@Test func theSecretsOfATestflightEnvAreFound() throws {
    let p = try plan([("ASC_KEY_ID", " KEY1 "), ("ASC_ISSUER_ID_FILE", "/k/issuer"), ("ASC_KEY_P8_FILE", "/k/a.p8"), ("XLESS_DIST_KEY_FILE", "/k/d.pem"),
                      ("XLESS_DEMO_PASSWORD", "pw"), ("XLESS_IMAGE", "img"), ("XLESS_DEVID_KEY_FILE", ""), ("OTHER_PASSWORD_FILE", "/k/o")], files: ["/k/issuer": "issuer\n"])
    #expect(p.items == [.init(base: "ASC_KEY_P8", source: .file("/k/a.p8"), keyID: "KEY1", issuerID: "issuer"), .init(base: "XLESS_DIST_KEY", source: .file("/k/d.pem")),
                        .init(base: "XLESS_DEMO_PASSWORD", source: .value("pw"))])
    #expect(p.moved == ["ASC_KEY_ID", "ASC_ISSUER_ID_FILE", "ASC_KEY_P8_FILE", "XLESS_DIST_KEY_FILE", "XLESS_DEMO_PASSWORD"])
    #expect(p.left == ["XLESS_IMAGE", "XLESS_DEVID_KEY_FILE", "OTHER_PASSWORD_FILE"])
}

@Test func anAPIKeyNeedsItsIDs() throws {
    #expect(try plan([("ASC_KEY_P8_FILE", "/k/AuthKey_ABC123DEFG.p8"), ("ASC_ISSUER_ID", "i")]).items[0].keyID == "ABC123DEFG")
    #expect(throws: VaultError.self) { try plan([("ASC_KEY_P8_FILE", "/k/AuthKey_ABC123DEFG.p8")]) }
    #expect(throws: VaultError.self) { try plan([("ASC_KEY_P8_FILE", "/k/a.p8"), ("ASC_ISSUER_ID", "i")]) }
    // without the key, its IDs stay where they are
    #expect(try plan([("ASC_KEY_ID", "k"), ("XLESS_DIST_KEY_FILE", "/d")]).left == ["ASC_KEY_ID"])
}

/// Errors name the variable: its value (a path, or a secret given for one by mistake) is in none.
@Test func aFileThatCannotBeReadIsNamedByItsVariable() throws {
    do {
        _ = try EnvImport([(name: "ASC_KEY_P8_FILE", value: "/k/AuthKey_ABC123DEFG.p8"), (name: "ASC_ISSUER_ID_FILE", value: "SecretTail")]) { try SecretsImportCommand.readFile($0).utf8String() }
        Issue.record("no error")
    } catch let e as VaultError {
        #expect(e.cause.contains("ASC_ISSUER_ID_FILE") && !"\(e)".contains("SecretTail") && !e.fix.contains("SecretTail"))
    }
}

/// A line of a value that reads as an assignment (of a wrapped key) is not said.
@Test func onlyNamesOfVariablesAreSaid() throws {
    let p = try plan([("XLESS_DIST_KEY_FILE", "/d"), ("MIGTAgEASecretTail", "="), ("XLESS_IMAGE", "x")])
    #expect(p.left == ["XLESS_IMAGE"] && p.others == 1)
}

/// The lines of what the store got are told from those of what it has of its own.
@Test func theLinesOfAnItem() throws {
    let p = try plan([("ASC_KEY_ID", "K"), ("XLESS_DIST_KEY", "x"), ("ASC_ISSUER_ID", "i"), ("ASC_KEY_P8_FILE", "/k"), ("XLESS_DIST_KEY_FILE", "/d"), ("XLESS_IMAGE", "x")])
    #expect(p.variables(of: [p.items[0]]) == ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8_FILE"])
    #expect(p.variables(of: [p.items[1]]) == ["XLESS_DIST_KEY", "XLESS_DIST_KEY_FILE"])
    #expect(p.variables(of: []).isEmpty && p.variables(of: p.items) == p.moved)
}

@Test func theLastLineOfANameCounts() throws {
    let p = try plan([("XLESS_DIST_KEY_FILE", "/old"), ("XLESS_DIST_KEY_FILE", "/new")])
    #expect(p.items == [.init(base: "XLESS_DIST_KEY", source: .file("/new"))] && p.moved == ["XLESS_DIST_KEY_FILE"])
}
