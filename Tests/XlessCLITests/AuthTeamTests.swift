import ArgumentParser
import Foundation
import Testing
import XlessAppleID
import XlessCore
@testable import XlessVault
@testable import xless

private func tempEnv() throws -> ([String: String], URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (["XDG_CONFIG_HOME": dir.path, "HOME": "/nonexistent"], dir)
}

@Test func theConfigFileFollowsXDGElseHome() {
    #expect(UserConfig.file(env: ["XDG_CONFIG_HOME": "/x/cfg", "HOME": "/home/u"]).path == "/x/cfg/xless/config.yml")
    #expect(UserConfig.file(env: ["XDG_CONFIG_HOME": "relative", "HOME": "/home/u"]).path == "/home/u/.config/xless/config.yml")
    #expect(UserConfig.file(env: ["HOME": "/home/u"]).path == "/home/u/.config/xless/config.yml")
}

@Test func theSavedTeamRoundTripsAndKeepsOtherKeys() throws {
    let (env, dir) = try tempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try UserConfig.load(env: env).team == nil)
    #expect(AccountSession.savedTeam(env: env) == nil)
    let file = UserConfig.file(env: env)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("theme: dark\n".utf8).write(to: file)
    try UserConfig.update(env: env) { $0.team = "ABCDE12345" }
    #expect(AccountSession.savedTeam(env: env) == "ABCDE12345")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("theme: dark") && text.contains("team: ABCDE12345"), "\(text)")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o644)
    try UserConfig.update(env: env) { $0.team = nil }
    #expect(try UserConfig.load(env: env).team == nil)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("theme: dark"))
}

@Test func aSavedValueThatIsNotATeamIDIsIgnored() throws {
    let (env, dir) = try tempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }
    try UserConfig.update(env: env) { $0.team = "nope" }
    #expect(AccountSession.savedTeam(env: env) == nil)
}

@Test func aBrokenConfigIsAConfigError() throws {
    let (env, dir) = try tempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = UserConfig.file(env: env)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("- a\n- b\n".utf8).write(to: file)
    #expect(throws: XlessError.self) { try UserConfig.load(env: env) }
    #expect(AccountSession.savedTeam(env: env) == nil)
}

@Test func teamUseValidatesItsArguments() throws {
    #expect(throws: (any Error).self) { try TeamUseCommand.parse([]) }
    #expect(throws: (any Error).self) { try TeamUseCommand.parse(["abcde12345"]) }
    #expect(throws: (any Error).self) { try TeamUseCommand.parse(["ABCDE12345", "--clear"]) }
    #expect(try TeamUseCommand.parse(["ABCDE12345"]).teamID == "ABCDE12345")
    #expect(try TeamUseCommand.parse(["--clear"]).clear)
}

@Test func keepIsParsed() throws {
    #expect(try AuthLoginCommand.parse(["--keep", "30m"]).keep == "30m")
    #expect(try AuthLoginCommand.parse([]).keep == nil)
}

// MARK: auth status

private let kept = KeptSessionInfo(appleID: "me@example.com", created: Date(timeIntervalSince1970: 1_000_000),
                                   expires: Date(timeIntervalSince1970: 1_000_000 + 1800))

@Test func statusSaysWhereEachCredentialComesFromAndNeverItsValue() throws {
    let env = ["ASC_KEY_ID": "KEYSECRETISH", "ASC_ISSUER_ID_FILE": "/run/secrets/issuer", "ASC_KEY_P8": ""]
    let store = AuthStatusReport.StoreKey(name: "ASC_KEY_P8@ABCDE12345", teamID: "ABCDE12345", hasKeyID: true, hasIssuerID: true)
    let r = AuthStatusReport.build(env: env, storeKey: .success(store), teamFlag: nil, savedTeam: "ABCDE12345", canKeep: true,
                                   session: kept, now: Date(timeIntervalSince1970: 1_000_000 + 600))
    #expect(r.apiKey.map(\.source) == ["environment", "file", "store"])
    #expect(r.apiKey[1].detail == "$ASC_ISSUER_ID_FILE: /run/secrets/issuer")
    #expect(r.apiKey[2].detail == "ASC_KEY_P8@ABCDE12345")
    #expect(r.team == "ABCDE12345" && r.teamSource == "saved" && r.keyTeam == "ABCDE12345")
    #expect(r.session.state == "kept" && r.session.remainingSeconds == 1200)
    let text = r.text
    #expect(!text.contains("KEYSECRETISH"))
    #expect(text.contains("saved by `xless team use`"))
    #expect(text.contains("kept for me@example.com"))
    #expect(text.contains("20 min left"))
    #expect(text.contains("key's role     unknown"))
    #expect(!(try ASCOutputJSON(r)).contains("KEYSECRETISH"))
}

private func ASCOutputJSON(_ r: AuthStatusReport) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return String(decoding: try e.encode(r), as: UTF8.self)
}

@Test func statusSaysWhatIsHeldWhereUntilWhenAndForHowLongUnused() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let held = HeldUnlock(backend: .agent, expires: now + 7200, idle: 1800, idleExpires: now + 900)
    let r = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: kept,
                                   sessionHeld: held, store: .unlocked(held, now: now), neededBy: ["apps create", "keys create"], now: now)
    #expect(r.store == .init(state: "unlocked", backend: "agent", expires: "1970-01-12T15:46:40Z", remainingSeconds: 7200, idleSeconds: 1800, idleRemainingSeconds: 900))
    #expect(r.session.backend == "agent" && r.session.idleSeconds == 1800 && r.session.idleRemainingSeconds == 900)
    #expect(r.session.neededBy == ["apps create", "keys create"])
    #expect(r.text.contains("unlocked in the xless agent until 1970-01-12T15:46:40Z (2 h left, or 30 min without use); `xless lock` ends it"), "\(r.text)")
    #expect(r.text.contains("kept for me@example.com in the xless agent until"), "\(r.text)")
    #expect(r.text.contains("needed by: apps create, keys create"))
    let json = try ASCOutputJSON(r)
    #expect(json.contains("\"store\":{") && json.contains("\"idleRemainingSeconds\":900") && json.contains("\"state\":\"unlocked\""), "\(json)")
    func text(_ store: AuthStatusReport.Store) -> String {
        AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, store: store, now: now).text
    }
    #expect(text(.init(state: "locked")).contains("xless unlock"))
    #expect(text(.init(state: "helper", detail: "xless-credential-pass")).contains("xless-credential-pass"))
    #expect(text(.init(state: "error", detail: "cannot read it")).contains("cannot read it"))
    #expect(text(.unlocked(HeldUnlock(backend: .keyring, expires: nil), now: now)).contains("unlocked in the kernel keyring"))
}

@Test func theCommandsThatNeedTheAppleIDSessionAreThoseWhoseHelpSaysSo() {
    let commands = AppleWebHelp.commands
    #expect(Set(commands).count == commands.count) // each once
    #expect(commands.contains("apps create"))
    #expect(commands.contains { $0.hasPrefix("keys ") })
    #expect(!commands.contains("devices list"))
    #expect(!commands.contains { $0.hasPrefix("secrets") })
}

@Test func statusReportsMissingErrorsAndNoSession() {
    struct Boom: Error {}
    let none = AuthStatusReport.build(env: [:], storeKey: .success(nil), teamFlag: "ZZZZZ99999", savedTeam: "ABCDE12345",
                                      canKeep: false, session: nil, now: Date())
    #expect(none.apiKey.map(\.source) == ["missing", "missing", "missing"])
    #expect(none.team == "ZZZZZ99999" && none.teamSource == "flag")
    #expect(none.session.state == "unavailable")
    let broken = AuthStatusReport.build(env: [:], storeKey: .failure(XlessError(.config, "several entries", fix: "x")), teamFlag: nil,
                                        savedTeam: nil, canKeep: true, session: nil, now: Date())
    #expect(broken.apiKey.allSatisfy { $0.source == "error" && $0.detail == "several entries" })
    #expect(broken.session.state == "none" && broken.teamSource == "none")
    let partial = AuthStatusReport.build(env: [:], storeKey: .success(.init(name: "ASC_KEY_P8", teamID: nil, hasKeyID: false, hasIssuerID: true)),
                                         teamFlag: nil, savedTeam: nil, canKeep: true, session: nil, now: Date())
    #expect(partial.apiKey.map(\.source) == ["missing", "store", "store"])
}

@Test func theTeamOfAStoreEntryComesFromItsName() {
    #expect(AuthStatusReport.team(fromName: "ASC_KEY_P8@ABCDE12345") == "ABCDE12345")
    #expect(AuthStatusReport.team(fromName: "ASC_KEY_P8@work") == nil)
    #expect(AuthStatusReport.team(fromName: "ASC_KEY_P8") == nil)
}

@Test func theTeamOfTheStoresAPIKeysServesWhenTheyAreAllOfOne() {
    func entry(_ name: String, _ team: String?, issuer: String? = "I", kind: VaultEntry.Kind = .ascAPIKey) -> VaultEntry {
        VaultEntry(name: name, kind: kind, metadata: .init(teamID: team, keyID: "K", issuerID: issuer), sealed: Data())
    }
    let one = [entry("ASC_KEY_P8@ABCDE12345", nil, issuer: "I1"), entry("ASC_KEY_P8@ABCDE12345.old", "ABCDE12345", issuer: "I2"), entry("XLESS_DIST_KEY", "ZZZZZ99999", kind: .signingKey)]
    #expect(AccountSession.keyTeam(of: one) == "ABCDE12345")
    #expect(AccountSession.keyIssuers(of: one, team: "ABCDE12345") == ["I1", "I2"])
    #expect(AccountSession.keyTeam(of: one + [entry("ASC_KEY_P8@ZZZZZ99999", nil)]) == nil, "of two")
    #expect(AccountSession.keyTeam(of: one + [entry("ASC_KEY_P8", nil)]) == nil, "of nobody knows which")
    #expect(AccountSession.keyTeam(of: []) == nil)
}

// MARK: team list

@Test func teamListMatchesProvidersByNameAndMarksTheDefault() {
    let teams = [PortalTeam(teamId: "ABCDE12345", name: "Example Ltd", type: "Company/Organization"),
                 PortalTeam(teamId: "ZZZZZ99999", name: "Jane Doe", type: "Individual"),
                 PortalTeam(teamId: "QQQQQ11111", name: "Twins")]
    let providers = [OlympusProvider(providerId: 7, name: "example ltd"), OlympusProvider(providerId: 8, name: "Twins"),
                     OlympusProvider(providerId: 9, name: "Twins")]
    let rows = TeamListing.rows(teams, providers: providers, saved: "ZZZZZ99999")
    #expect(rows.map(\.providerId) == [7, nil, nil])
    #expect(rows.map(\.providerMatch) == ["one", "none", "several"])
    #expect(rows.map(\.isDefault) == [false, true, false])
    let table = TeamListing.table(teams, providers: providers, saved: "ZZZZZ99999")
    #expect(table.contains("PROVIDER"))
    #expect(table.split(separator: "\n")[2].hasPrefix("*  ZZZZZ99999"))
    #expect(table.split(separator: "\n")[3].hasSuffix("?"))
    #expect(!TeamListing.table(teams, providers: nil, saved: nil).contains("PROVIDER"))
    #expect(TeamListing.rows(teams, providers: nil, saved: nil).allSatisfy { $0.providerMatch == "unknown" })
}

// MARK: help

@Test func everyCommandThatUsesTheWebSessionSaysSo() {
    for command in [AuthLoginCommand.self, TeamListCommand.self, AuthAPIKeyCreateCommand.self, AuthAPIKeyListCommand.self,
                    AuthAPIKeyRevokeCommand.self, AppGroupsCommand.self, ICloudContainersCommand.self,
                    LinkedListCommand<AppGroupKind>.self, LinkedCreateCommand<AppGroupKind>.self, LinkedAssignCommand<AppGroupKind>.self,
                    LinkedUnassignCommand<AppGroupKind>.self, LinkedListCommand<CloudContainerKind>.self, LinkedCreateCommand<CloudContainerKind>.self,
                    LinkedAssignCommand<CloudContainerKind>.self, LinkedUnassignCommand<CloudContainerKind>.self,
                    KeysCommand.self, KeysListCommand.self, KeysShowCommand.self, KeysCreateCommand.self, KeysRevokeCommand.self,
                    AppsCreateCommand.self, StorePrivacyCommand.self, StorePrivacyPullCommand.self, StorePrivacyPushCommand.self,
                    ProvisionCommand.self, ProvisionApplyCommand.self] as [any ParsableCommand.Type] {
        let help = command.helpMessage(columns: 10_000)
        #expect(help.contains("Uses the Apple ID web session, not the App Store Connect API"), "\(command)")
    }
    #expect(!AuthStatusCommand.helpMessage(columns: 10_000).contains("Uses the Apple ID web session"))
    #expect(!AuthAPIKeyImportCommand.helpMessage(columns: 10_000).contains("Uses the Apple ID web session"))
    for command in [AppsListCommand.self, AppsShowCommand.self, AppsUpdateCommand.self] as [any ParsableCommand.Type] {
        #expect(!command.helpMessage(columns: 10_000).contains("Uses the Apple ID web session"), "\(command)")
    }
}

@Test func theAppleAccountGroupListsAuthAndTeam() {
    let help = Xless.helpMessage()
    guard let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive) else { Issue.record("\(help)"); return }
    let tail = help[group.upperBound...]
    #expect(tail.contains("auth") && tail.contains("team"))
}
