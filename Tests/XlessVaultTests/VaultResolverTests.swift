import Crypto
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

private let ascEntries: [(String, VaultEntry.Kind, VaultEntry.Metadata, String)] = [
    ("ASC_KEY_P8", .ascAPIKey, .init(teamID: "TEAMA", keyID: "KEYID12345", issuerID: "ISSUER-UUID"), "P8-CONTENT"),
    ("XLESS_DIST_KEY", .signingKey, .init(teamID: "TEAMA"), "DIST-PEM"),
]

/// A resolver whose prompter is counted: `made` is how often the terminal was asked for.
private final class Terminal: @unchecked Sendable {
    let prompter: ScriptedPrompter?
    private(set) var made = 0
    init(_ answers: [String]?) { prompter = answers.map(ScriptedPrompter.init) }
    func get() -> (any PassphrasePrompter)? { made += 1; return prompter }
}

@Test func noStoreMeansNoPromptAndNoValue() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let term = Terminal(["x"])
    let r = VaultResolver(store: t.store, cache: nil, prompter: term.get)
    #expect(try r.lookup("XLESS_DIST_KEY", stage: .sign) == nil)
    #expect(term.made == 0)
}

@Test func aNameTheStoreDoesNotHoldMeansNoPrompt() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: ascEntries)
    let term = Terminal(["correct horse battery"])
    let r = VaultResolver(store: t.store, cache: nil, prompter: term.get)
    #expect(try r.lookup("XLESS_DEVID_KEY", stage: .package) == nil)
    #expect(term.made == 0)
}

@Test func theStoreIsUnlockedOnceForTheWholeCommand() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: ascEntries)
    let term = Terminal(["correct horse battery"])
    let secrets = Secrets(env: [:], fallback: VaultResolver(store: t.store, cache: nil, prompter: term.get))
    #expect(try secrets.required("ASC_KEY_P8", stage: .upload) == "P8-CONTENT")
    #expect(try secrets.identifier("ASC_KEY_ID", stage: .upload) == "KEYID12345")
    #expect(try secrets.identifier("ASC_ISSUER_ID", stage: .upload) == "ISSUER-UUID")
    #expect(try secrets.required("XLESS_DIST_KEY", stage: .sign) == "DIST-PEM")
    #expect(term.prompter?.asked == 1)
}

@Test func aLockedStoreWithoutATerminalIsAClearStageError() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: ascEntries)
    let secrets = Secrets(env: [:], fallback: VaultResolver(store: t.store, cache: nil, prompter: { nil }))
    do { _ = try secrets.required("XLESS_DIST_KEY", stage: .sign); Issue.record("expected a locked store") } catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.cause.contains("locked"))
        #expect(e.fix.contains("xless secrets unlock"))
    }
}

@Test func aCachedKeyNeedsNoPassphraseAndAStaleOneIsDropped() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (file, key) = try t.make(entries: ascEntries)
    let cache = MemoryCache()
    try cache.store(id: file.id, key: VaultCrypto.keyBytes(key), seconds: 60)
    let term = Terminal([])
    #expect(try VaultResolver(store: t.store, cache: cache, prompter: term.get).lookup("XLESS_DIST_KEY", stage: .sign) == "DIST-PEM")
    #expect(term.made == 0)

    let stale = MemoryCache()
    try stale.store(id: file.id, key: SecretBytes(count: 32), seconds: 60)
    let term2 = Terminal(["correct horse battery"])
    #expect(try VaultResolver(store: t.store, cache: stale, prompter: term2.get).lookup("XLESS_DIST_KEY", stage: .sign) == "DIST-PEM")
    #expect(term2.prompter?.asked == 1)
    #expect(try stale.load(id: file.id) == nil)
}

@Test func threeWrongPassphrasesFailAndOneTypoIsForgiven() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: ascEntries)
    let typo = Terminal(["typo", "correct horse battery"])
    #expect(try VaultResolver(store: t.store, cache: nil, prompter: typo.get).lookup("XLESS_DIST_KEY", stage: .sign) == "DIST-PEM")
    let wrong = Terminal(["a", "b", "c", "correct horse battery"])
    do {
        _ = try VaultResolver(store: t.store, cache: nil, prompter: wrong.get).lookup("XLESS_DIST_KEY", stage: .sign)
        Issue.record("expected a wrong passphrase")
    } catch let e as XlessError { #expect(e.cause.contains("wrong passphrase")) }
    #expect(wrong.prompter?.asked == 3)
}

@Test func entriesPerTeamAreChosenByTeamAndOtherwiseAmbiguous() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [
        ("XLESS_DIST_KEY@TEAMA", .signingKey, .init(teamID: "TEAMA"), "A-PEM"),
        ("XLESS_DIST_KEY@TEAMB", .signingKey, .init(teamID: "TEAMB"), "B-PEM"),
    ])
    let teamB = VaultResolver(store: t.store, team: "TEAMB", cache: nil, prompter: Terminal(["correct horse battery"]).get)
    #expect(try teamB.lookup("XLESS_DIST_KEY", stage: .sign) == "B-PEM")
    let noTeam = VaultResolver(store: t.store, cache: nil, prompter: Terminal(["correct horse battery"]).get)
    do { _ = try noTeam.lookup("XLESS_DIST_KEY", stage: .sign); Issue.record("expected ambiguity") } catch let e as XlessError {
        #expect(e.cause.contains("XLESS_DIST_KEY@TEAMA") && e.cause.contains("XLESS_DIST_KEY@TEAMB"))
    }
}

@Test func theUnlockCanBeRememberedForABoundedTime() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (file, key) = try t.make()
    let cache = MemoryCache()
    let got = try VaultUnlocker.dataKey(for: file, cache: cache, prompter: { ScriptedPrompter(["correct horse battery"]) }, remember: 1800, reason: "test")
    #expect(VaultCrypto.keyBytes(got) == VaultCrypto.keyBytes(key))
    #expect(cache.stored.map(\.1) == [1800])
}

@Test func rememberDurationsAreBoundedToAnHour() throws {
    #expect(try RememberDuration.seconds("30m") == 1800)
    #expect(try RememberDuration.seconds("1h") == 3600)
    #expect(try RememberDuration.seconds("90s") == 90)
    #expect(try RememberDuration.seconds("600") == 600)
    for bad in ["0", "61m", "2h", "3601", "abc", "", "-5m", "1d", "m"] {
        #expect(throws: VaultError.self, "\(bad)") { try RememberDuration.seconds(bad) }
    }
}

@Test func newPassphrasesAreConfirmedAndLongEnough() throws {
    #expect(try VaultUnlocker.newPassphrase(ScriptedPrompter(["long enough", "long enough"])).utf8String() == "long enough")
    #expect(throws: VaultError.self) { try VaultUnlocker.newPassphrase(ScriptedPrompter(["long enough", "long enougH"])) }
    #expect(throws: VaultError.self) { try VaultUnlocker.newPassphrase(ScriptedPrompter(["short", "short"])) }
}
