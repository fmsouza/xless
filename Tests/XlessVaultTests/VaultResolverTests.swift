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

// A project's run prefers its team's secrets (`Secrets.preferring(team:)`, used by `ship` with the project's teamID).
private let twoTeams: [(String, VaultEntry.Kind, VaultEntry.Metadata, String)] = [
    ("ASC_KEY_P8@TEAMA12345", .ascAPIKey, .init(teamID: "TEAMA12345", keyID: "KEYA", issuerID: "ISSUER-A"), "P8-A"),
    ("ASC_KEY_P8@TEAMB12345", .ascAPIKey, .init(teamID: "TEAMB12345", keyID: "KEYB", issuerID: "ISSUER-B"), "P8-B"),
    ("XLESS_DIST_KEY@TEAMB12345", .signingKey, .init(teamID: "TEAMB12345"), "DIST-B"),
    ("XLESS_DIST_KEY", .signingKey, .init(), "DIST-ANY"),
    ("XLESS_DEVID_KEY@TEAMA12345", .signingKey, .init(), "DEVID-A"),
]

@Test func twoTeamsInTheStorePickTheProjectsTeam() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: twoTeams)
    let term = Terminal(["correct horse battery"])
    let base = Secrets(env: [:], fallback: VaultResolver(store: t.store, cache: nil, prompter: term.get))
    let a = base.preferring(team: "TEAMA12345"), b = base.preferring(team: "TEAMB12345")
    #expect(try a.required("ASC_KEY_P8", stage: .upload) == "P8-A")
    #expect(try a.identifier("ASC_KEY_ID", stage: .upload) == "KEYA")
    #expect(try b.identifier("ASC_ISSUER_ID", stage: .upload) == "ISSUER-B")
    #expect(try b.required("XLESS_DIST_KEY", stage: .sign) == "DIST-B")
    // Without the team, the same store is ambiguous.
    #expect(throws: XlessError.self) { try base.required("ASC_KEY_P8", stage: .upload) }
    // Both views share one unlock.
    #expect(term.prompter?.asked == 1)
}

@Test func anEntryOfNoTeamServesAnyTeamAndAnotherTeamsIsSkipped() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: twoTeams)
    let secrets = Secrets(env: [:], fallback: VaultResolver(store: t.store, cache: nil, prompter: { ScriptedPrompter(["correct horse battery"]) }))
    #expect(try secrets.preferring(team: "TEAMA12345").required("XLESS_DIST_KEY", stage: .sign) == "DIST-ANY")
    #expect(try secrets.preferring(team: "TEAMC12345").optional("ASC_KEY_P8", stage: .upload) == nil)
    #expect(try secrets.preferring(team: "TEAMB12345").optional("XLESS_DEVID_KEY", stage: .package) == nil)
    #expect(try secrets.preferring(team: "TEAMA12345").required("XLESS_DEVID_KEY", stage: .package) == "DEVID-A")
}

@Test func anEmptyTeamOrAMissingFallbackChangesNothing() throws {
    let secrets = Secrets(env: ["XLESS_DIST_KEY": "ENV"], fallback: nil)
    #expect(try secrets.preferring(team: "TEAMA12345").required("XLESS_DIST_KEY", stage: .sign) == "ENV")
    #expect(try Secrets(env: [:], fallback: nil).preferring(team: "").optional("XLESS_DIST_KEY") == nil)
}
