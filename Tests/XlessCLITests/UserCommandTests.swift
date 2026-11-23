import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private func user(_ id: String, _ email: String, roles: [String] = ["DEVELOPER"], allApps: Bool = true, provisioning: Bool = false,
                  apps: [String]? = nil) -> String {
    let rel = apps.map { ids in #","relationships":{"visibleApps":{"data":[\#(ids.map { #"{"type":"apps","id":"\#($0)"}"# }.joined(separator: ","))]}}"# } ?? ""
    return #"{"type":"users","id":"\#(id)","attributes":{"username":"\#(email)","firstName":"Ada","lastName":"Lovelace","roles":[\#(roles.map { "\"\($0)\"" }.joined(separator: ","))],"allAppsVisible":\#(allApps),"provisioningAllowed":\#(provisioning)}\#(rel)}"#
}
private func invitation(_ id: String, _ email: String, roles: [String] = ["DEVELOPER"]) -> String {
    #"{"type":"userInvitations","id":"\#(id)","attributes":{"email":"\#(email)","firstName":"Grace","lastName":"Hopper","expirationDate":"2026-12-23T10:00:00.000+0000","roles":[\#(roles.map { "\"\($0)\"" }.joined(separator: ","))],"allAppsVisible":true,"provisioningAllowed":false}}"#
}
private func app(_ id: String, _ bundleID: String) -> String {
    #"{"type":"apps","id":"\#(id)","attributes":{"bundleId":"\#(bundleID)","name":"App \#(id)"}}"#
}
private func listing(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
private func single(_ item: String) -> String { #"{"data":\#(item)}"# }

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> UserCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return UserCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json,
                   terminal: { terminal }, say: { said.lines.append($0) })
}

private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

@Test func usersAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("users") } == true, "\(help)")
}

@Test func badUserArgumentsAreRefusedBeforeAnythingIsSent() throws {
    let base = ["grace@example.com", "--first-name", "Grace", "--last-name", "Hopper"]
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--all-apps"]) }                       // no role
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "developer"]) }              // no app choice
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "owner", "--all-apps"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "account-holder", "--all-apps"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "admin", "--app", "com.example.app"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "developer", "--all-apps", "--app", "com.example.app"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(base + ["--role", "developer", "--app", "not an app"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(["grace", "--first-name", "G", "--last-name", "H", "--role", "developer", "--all-apps"]) }
    #expect(throws: (any Error).self) { try UsersInviteCommand.parse(["g@example.com", "--first-name", " ", "--last-name", "H", "--role", "developer", "--all-apps"]) }
    #expect(throws: (any Error).self) { try UsersUpdateCommand.parse(["grace@example.com"]) }                       // nothing to change
    #expect(throws: (any Error).self) { try UsersShowCommand.parse(["../v1/apps"]) }
    #expect(throws: (any Error).self) { try UsersRemoveCommand.parse(["a b"]) }
    #expect(throws: (any Error).self) { try UsersInvitationsCancelCommand.parse(["nope@"]) }
    #expect(throws: (any Error).self) { try UsersListCommand.parse(["--role", "owner"]) }

    let admin = try UsersInviteCommand.parse(base + ["--role", "admin"])                                             // all apps implied
    #expect(try admin.role.parsed() == [.admin])
    let dev = try UsersInviteCommand.parse(base + ["--role", "developer,marketing", "--app", "com.example.app", "--app", "123", "--provisioning", "--team", "ABCDE12345", "--json"])
    #expect(dev.visibility.apps == ["com.example.app", "123"] && dev.provisioning && dev.account.output.json && dev.account.team.team == "ABCDE12345")
    #expect(try UsersUpdateCommand.parse(["U-1", "--no-provisioning"]).provisioning == false)
    #expect(try UsersUpdateCommand.parse(["U-1", "--provisioning"]).provisioning == true)
    _ = try UsersListCommand.parse(["--role", "account-holder"])                                                      // a filter may name it
    _ = try UsersRemoveCommand.parse(["grace@example.com", "--yes"])
}

@Test func listPrintsTheAppsEachUserSees() async throws {
    let t = FakeTransport([(200, listing([user("U2", "zed@example.com", roles: ["ADMIN"], provisioning: true),
                                          user("U1", "ada@example.com", allApps: false, apps: ["1", "2"]),
                                          user("U3", "nobody@example.com", allApps: false, apps: [])],
                                         included: [app("1", "com.example.one")]))])
    let out = try await cli(t).list(roles: [])
    let lines = out.split(separator: "\n").map(String.init)
    #expect(lines[0].hasPrefix("ID  EMAIL") && lines[0].hasSuffix("PROVISIONING"))
    #expect(lines[1].hasPrefix("U1  ada@example.com") && lines[1].contains("DEVELOPER  com.example.one,2") && lines[1].hasSuffix("no"))
    #expect(lines[2].hasPrefix("U3") && lines[2].contains(" none "))
    #expect(lines[3].hasPrefix("U2") && lines[3].contains("ADMIN") && lines[3].contains(" all ") && lines[3].hasSuffix("yes"))

    let empty = FakeTransport([(200, listing([]))])
    #expect(try await cli(empty).list(roles: [.finance]) == "No user has FINANCE.\n")
}

@Test func usersListJSONKeepsAppleShape() async throws {
    let t = FakeTransport([(200, listing([user("U1", "ada@example.com", allApps: false, apps: ["1"])], included: [app("1", "com.example.one")]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(t, json: true).list(roles: []).utf8))
    #expect(doc["data"]?[0]?["attributes"]?["username"] == .string("ada@example.com"))
    #expect(doc["included"]?[0]?["attributes"]?["bundleId"] == .string("com.example.one"))
}

@Test func showListsEveryVisibleApp() async throws {
    let t = FakeTransport([(200, listing([user("U1", "ada@example.com", allApps: false)])),
                           (200, listing([app("1", "com.example.one"), app("2", "com.example.two")]))])
    let out = try await cli(t).show("ADA@example.com")
    #expect(out.contains("Email         ada@example.com\n") && out.contains("Apps          com.example.one (1), com.example.two (2)\n"))
    #expect(t.requests[1].url!.path == "/v1/users/U1/visibleApps")
}

@Test func inviteResolvesAppsAndSendsOnce() async throws {
    let t = FakeTransport([(200, listing([app("111", "com.example.app")])),           // apps?filter[bundleId]
                           (200, listing([])), (200, listing([])),                  // users, invitations
                           (201, single(invitation("I1", "grace@example.com")))])
    let out = try await cli(t).invite(email: "grace@example.com", firstName: "Grace", lastName: "Hopper", roles: [.developer],
                                      allApps: false, apps: ["com.example.app"], provisioning: false)
    #expect(out == "invited grace@example.com (Grace Hopper) as DEVELOPER, apps com.example.app: invitation I1, expires 2026-12-23; Apple emails them the link\n")
    let sent = try body(t.requests[3])
    #expect(sent["data"]?["relationships"]?["visibleApps"]?["data"]?[0]?["id"] == .string("111"))
    #expect(t.requests.map(\.httpMethod) == ["GET", "GET", "GET", "POST"])
}

@Test func inviteReportsAnExistingUserOrInvitation() async throws {
    let said = Said()
    let t = FakeTransport([(200, listing([user("U1", "Grace@example.com", roles: ["ADMIN"])]))])
    let out = try await cli(t, said: said).invite(email: "grace@example.com", firstName: "G", lastName: "H", roles: [.developer],
                                                  allApps: true, apps: [], provisioning: false)
    #expect(out == "Grace@example.com is already a user of this team (user U1, ADMIN); nothing was sent\n")
    #expect(said.lines == ["to change their roles: `xless users update Grace@example.com --role DEVELOPER`"])
    #expect(t.requests.count == 1)

    let quiet = Said()
    let i = FakeTransport([(200, listing([])), (200, listing([invitation("I1", "grace@example.com")]))])
    let json = try await cli(i, json: true, said: quiet).invite(email: "grace@example.com", firstName: "G", lastName: "H", roles: [.developer],
                                                                allApps: true, apps: [], provisioning: false)
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    #expect(doc["result"] == .string("existing-invitation") && doc["data"]?["id"] == .string("I1"))
    #expect(quiet.lines.isEmpty && i.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func updateSaysWhenNothingChanges() async throws {
    let t = FakeTransport([(200, listing([user("U1", "ada@example.com", roles: ["DEVELOPER"])]))])
    #expect(try await cli(t).update("ada@example.com", roles: [.developer], allApps: true, apps: nil, provisioning: nil)
        == "ada@example.com (user U1) already has these settings; nothing was sent\n")
    #expect(t.requests.count == 1)

    let change = FakeTransport([(200, single(user("U1", "ada@example.com"))),
                                (200, single(user("U1", "ada@example.com", roles: ["APP_MANAGER"], provisioning: true)))])
    let out = try await cli(change).update("U1", roles: [.appManager], allApps: false, apps: nil, provisioning: true)
    #expect(out == "updated ada@example.com (user U1): APP_MANAGER, all apps, provisioning yes\n")
    #expect(change.requests.map(\.httpMethod) == ["GET", "PATCH"])
}

@Test func removeAsksAndRefusesTheAccountHolder() async throws {
    let said = Said()
    let no = FakeTransport([(200, listing([user("U1", "ada@example.com")]))])
    #expect(try await cli(no, terminal: FakeTerminal(answer: false), said: said).remove("ada@example.com", yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"] && no.requests.count == 1)

    let noTTY = FakeTransport([(200, listing([user("U1", "ada@example.com")]))])
    await #expect(throws: XlessError.self) { try await cli(noTTY).remove("ada@example.com", yes: false) }

    let yes = FakeTransport([(200, listing([user("U1", "ada@example.com")])), (204, "")])
    #expect(try await cli(yes).remove("ada@example.com", yes: true) == "removed ada@example.com (user U1) from the team\n")
    #expect(yes.requests.last.map { "\($0.httpMethod!) \($0.url!.path)" } == "DELETE /v1/users/U1")

    let holder = FakeTransport([(200, listing([user("U1", "ada@example.com", roles: ["ACCOUNT_HOLDER", "ADMIN"])]))])
    do { _ = try await cli(holder).remove("ada@example.com", yes: true); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("Account Holder") && holder.requests.count == 1) }
}

@Test func invitationsAreListedAndCancelled() async throws {
    let t = FakeTransport([(200, listing([invitation("I1", "grace@example.com")]))])
    let out = try await cli(t).invitations(roles: [])
    #expect(out.split(separator: "\n")[0].hasSuffix("EXPIRES") && out.contains("grace@example.com") && out.contains("2026-12-23"))
    #expect(try await cli(FakeTransport([(200, listing([]))])).invitations(roles: []) == "No invitation is pending.\n")

    let cancel = FakeTransport([(200, listing([invitation("I1", "grace@example.com")])), (204, "")])
    #expect(try await cli(cancel, terminal: FakeTerminal(answer: true)).cancel("grace@example.com", yes: false)
        == "cancelled the invitation of grace@example.com (invitation I1)\n")
    #expect(cancel.requests.last.map { "\($0.httpMethod!) \($0.url!.path)" } == "DELETE /v1/userInvitations/I1")
}

@Test func a403SaysAnAdminKeyIsNeeded() async throws {
    let t = FakeTransport([(403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"not allowed"}]}"#)])
    do { _ = try await AccountSession.run { try await cli(t).list(roles: []) }; Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.hasPrefix("GET /v1/users: App Store Connect HTTP 403"))
        #expect(e.fix.contains("Admin role") && e.fix.contains("`xless auth api-key create --role ADMIN`"))
    }
}
