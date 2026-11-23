import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func users(_ t: MockTransport) -> ASCUsers {
    ASCUsers(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func queryItems(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

/// A user as App Store Connect returns it (shape of GET /v1/users?include=visibleApps).
func userJSON(_ id: String, _ email: String, roles: [String] = ["DEVELOPER"], allApps: Bool = true, provisioning: Bool = false,
              apps: [String]? = nil) -> String {
    let rel = apps.map { ids in #","relationships":{"visibleApps":{"data":[\#(ids.map { #"{"type":"apps","id":"\#($0)"}"# }.joined(separator: ","))]}}"# } ?? ""
    return #"{"type":"users","id":"\#(id)","attributes":{"username":"\#(email)","firstName":"Ada","lastName":"Lovelace","roles":[\#(roles.map { "\"\($0)\"" }.joined(separator: ","))],"allAppsVisible":\#(allApps),"provisioningAllowed":\#(provisioning)}\#(rel)}"#
}
func invitationJSON(_ id: String, _ email: String, roles: [String] = ["DEVELOPER"], allApps: Bool = true) -> String {
    #"{"type":"userInvitations","id":"\#(id)","attributes":{"email":"\#(email)","firstName":"Grace","lastName":"Hopper","expirationDate":"2026-12-23T10:00:00.000+0000","roles":[\#(roles.map { "\"\($0)\"" }.joined(separator: ","))],"allAppsVisible":\#(allApps),"provisioningAllowed":false}}"#
}
func usersListJSON(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"https://api.appstoreconnect.apple.com/v1/users"}}"#
}
func appRefJSON(_ id: String, _ bundleID: String) -> String {
    #"{"type":"apps","id":"\#(id)","attributes":{"bundleId":"\#(bundleID)","name":"App \#(id)"}}"#
}

// MARK: - Input

@Test func rolesAreParsedInAnySpelling() throws {
    #expect(try UserRole.parse(["app-manager", "Developer,ADMIN", "app manager"]) == [.appManager, .developer, .admin])
    #expect(try UserRole.parse([]) == [])
    #expect(throws: IdentifierInputError.self) { try UserRole.parse(["owner"]) }
    #expect(throws: IdentifierInputError.self) { try UserRole.parse(["account-holder"]) }
    #expect(try UserRole.parse(["account-holder"], allowAccountHolder: true) == [.accountHolder])
    #expect(UserRole.allCases.count == 13 && !UserRole.assignable.contains(.accountHolder))
    #expect(UserRole.display([]) == "-" && UserRole.display(["ADMIN", "SALES"]) == "ADMIN, SALES")
}

@Test func emailsAreCheckedLoosely() throws {
    #expect(try UserEmail.validate("  ada@example.com ") == "ada@example.com")
    for bad in ["", "ada", "ada@", "@example.com", "ada@example", "ada@@example.com", "a da@example.com", "ada@.com", "ada@example.com.",
                "ada@ex..com", "../v1/apps@x.com"] {
        #expect(throws: IdentifierInputError.self, "\(bad)") { try UserEmail.validate(bad) }
    }
    #expect(UserEmail.same("Ada@Example.com", "ada@example.COM"))
    #expect(UserEmail.isEmail("a@b.c") && !UserEmail.isEmail("6a7d-11"))
    #expect(ASCUsers.isID("6a7d7a9e-1c2f-4f1e-9a0b-1234567890ab") && !ASCUsers.isID("../apps") && !ASCUsers.isID(""))
}

@Test func personAttributesAreTyped() throws {
    let user = try JSONDecoder().decode(ASCUser.self, from: Data(userJSON("U1", "ada@example.com", roles: ["ACCOUNT_HOLDER", "ADMIN"], allApps: false, apps: ["1", "2"]).utf8))
    #expect(user.email == "ada@example.com" && user.fullName == "Ada Lovelace" && user.isAccountHolder)
    #expect(user.visibleAppIDs == ["1", "2"] && !user.allAppsVisible && !user.provisioningAllowed)
    let invitation = try JSONDecoder().decode(ASCUserInvitation.self, from: Data(invitationJSON("I1", "grace@example.com").utf8))
    #expect(invitation.email == "grace@example.com" && invitation.fullName == "Grace Hopper" && invitation.visibleAppIDs == nil)
    #expect(invitation.attributes.expirationDate?.hasPrefix("2026-12-23") == true)
}

// MARK: - Reads

@Test func listIncludesTheVisibleAppsAndFiltersByRole() async throws {
    let t = MockTransport([(200, usersListJSON([userJSON("U2", "zed@example.com"), userJSON("U1", "Ada@example.com", allApps: false, apps: ["1"])],
                                               included: [appRefJSON("1", "com.example.one")]))])
    let listing = try await users(t).list(roles: [.admin, .developer])
    #expect(listing.items.map(\.id) == ["U1", "U2"])
    #expect(listing.included.map(\.id) == ["1"])
    #expect(t.requests[0].url!.path == "/v1/users")
    #expect(queryItems(t.requests[0]) == ["filter[roles]=ADMIN,DEVELOPER", "fields[apps]=bundleId,name", "include=visibleApps",
                                          "limit[visibleApps]=50", "limit=200"])
}

@Test func usersAreResolvedByEmailWithoutRegardToCase() async throws {
    let t = MockTransport([(200, usersListJSON([userJSON("U1", "Ada@Example.com")]))])
    #expect(try await users(t).resolve("ada@example.com").id == "U1")

    let byID = MockTransport([(200, #"{"data":\#(userJSON("U1", "ada@example.com"))}"#)])
    #expect(try await users(byID).resolve("U1").email == "ada@example.com")
    #expect(byID.requests[0].url!.path == "/v1/users/U1")
}

@Test func anInvitedAddressIsNotAUser() async throws {
    let t = MockTransport([(200, usersListJSON([])), (200, usersListJSON([invitationJSON("I1", "grace@example.com")]))])
    do { _ = try await users(t).resolve("Grace@example.com"); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.contains("has not accepted the invitation yet (invitation I1)"))
        #expect(e.fix.contains("xless users invitations cancel Grace@example.com"))
    }
    let none = MockTransport([(200, usersListJSON([])), (200, usersListJSON([]))])
    do { _ = try await users(none).resolve("nobody@example.com"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause == "no user of this team has the email address nobody@example.com" && e.fix.contains("xless users invite")) }
}

@Test func invitationsAreResolvedByEmailOrID() async throws {
    let t = MockTransport([(200, usersListJSON([invitationJSON("I1", "grace@example.com")]))])
    #expect(try await users(t).resolveInvitation("GRACE@example.com").id == "I1")
    #expect(t.requests[0].url!.path == "/v1/userInvitations")

    let accepted = MockTransport([(200, usersListJSON([])), (200, usersListJSON([userJSON("U1", "ada@example.com")]))])
    do { _ = try await users(accepted).resolveInvitation("ada@example.com"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("already a user of this team (user U1)") && e.fix.contains("xless users remove")) }

    let bad = MockTransport([])
    await #expect(throws: XlessError.self) { try await users(bad).resolveInvitation("../v1") }
    #expect(bad.requests.isEmpty)
}

// MARK: - Invite

private let request = UserInvitationRequest(email: "grace@example.com", firstName: "Grace", lastName: "Hopper", roles: [.developer, .marketing],
                                            allAppsVisible: false, appIDs: ["1", "2"], provisioningAllowed: true)

@Test func inviteSendsOnePostWithTheVisibleApps() async throws {
    let t = MockTransport([(200, usersListJSON([])), (200, usersListJSON([])), (201, #"{"data":\#(invitationJSON("I9", "grace@example.com"))}"#)])
    guard case .invited(let invitation) = try await users(t).invite(request) else { Issue.record("not invited"); return }
    #expect(invitation.id == "I9")
    #expect(t.requests.map(\.httpMethod) == ["GET", "GET", "POST"])
    let sent = try body(t.requests[2])
    #expect(sent["data"]?["type"] == .string("userInvitations"))
    #expect(sent["data"]?["attributes"]?["email"] == .string("grace@example.com"))
    #expect(sent["data"]?["attributes"]?["roles"] == .array([.string("DEVELOPER"), .string("MARKETING")]))
    #expect(sent["data"]?["attributes"]?["allAppsVisible"] == .bool(false))
    #expect(sent["data"]?["attributes"]?["provisioningAllowed"] == .bool(true))
    #expect(sent["data"]?["relationships"]?["visibleApps"]?["data"]?[1]?["id"] == .string("2"))

    var all = request
    all.allAppsVisible = true
    let t2 = MockTransport([(200, usersListJSON([])), (200, usersListJSON([])), (201, #"{"data":\#(invitationJSON("I9", "grace@example.com"))}"#)])
    _ = try await users(t2).invite(all)
    #expect(try body(t2.requests[2])["data"]?["relationships"] == nil)
}

@Test func inviteIsIdempotent() async throws {
    let user = MockTransport([(200, usersListJSON([userJSON("U1", "Grace@Example.com")]))])
    guard case .existingUser(let u) = try await users(user).invite(request) else { Issue.record("not existing user"); return }
    #expect(u.id == "U1" && user.requests.count == 1)

    let invited = MockTransport([(200, usersListJSON([])), (200, usersListJSON([invitationJSON("I1", "grace@EXAMPLE.com")]))])
    guard case .existingInvitation(let i) = try await users(invited).invite(request) else { Issue.record("not existing invitation"); return }
    #expect(i.id == "I1" && invited.requests.map(\.httpMethod) == ["GET", "GET"])
}

@Test func aConflictingInviteIsReadBack() async throws {
    let conflict = #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"already invited"}]}"#
    let t = MockTransport([(200, usersListJSON([])), (200, usersListJSON([])), (409, conflict),
                           (200, usersListJSON([])), (200, usersListJSON([invitationJSON("I1", "grace@example.com")]))])
    guard case .existingInvitation(let i) = try await users(t).invite(request) else { Issue.record("not existing"); return }
    #expect(i.id == "I1" && t.requests.filter { $0.httpMethod == "POST" }.count == 1)

    let lost = MockTransport([(200, usersListJSON([])), (200, usersListJSON([])), (409, conflict), (200, usersListJSON([])), (200, usersListJSON([]))])
    await #expect(throws: ASCError.self) { try await users(lost).invite(request) }
}

@Test func aFailedInviteIsNotRetried() async throws {
    let t = MockTransport([(200, usersListJSON([])), (200, usersListJSON([])), (500, #"{"errors":[]}"#)])
    await #expect(throws: (any Error).self) { try await users(t).invite(request) }
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 1)
}

// MARK: - Update, remove, cancel

private func user(_ json: String) throws -> ASCUser { try JSONDecoder().decode(ASCUser.self, from: Data(json.utf8)) }

@Test func updateSendsOnlyWhatDiffers() async throws {
    let ada = try user(userJSON("U1", "ada@example.com", roles: ["DEVELOPER"], allApps: true))
    let none = MockTransport([])
    #expect(try await users(none).update(ada, roles: [.developer], allApps: true, provisioning: false) == nil)
    #expect(none.requests.isEmpty)

    let t = MockTransport([(200, #"{"data":\#(userJSON("U1", "ada@example.com", roles: ["ADMIN"]))}"#)])
    let updated = try await users(t).update(ada, roles: [.admin], provisioning: true)
    #expect(updated?.roles == ["ADMIN"])
    #expect(t.requests[0].httpMethod == "PATCH" && t.requests[0].url!.path == "/v1/users/U1")
    let sent = try body(t.requests[0])
    #expect(sent["data"]?["id"] == .string("U1") && sent["data"]?["type"] == .string("users"))
    #expect(sent["data"]?["attributes"] == .object(["roles": .array([.string("ADMIN")]), "provisioningAllowed": .bool(true)]))
    #expect(sent["data"]?["relationships"] == nil)
}

@Test func updateNarrowsAnAllAppsUserToSomeApps() async throws {
    let ada = try user(userJSON("U1", "ada@example.com", allApps: true))
    let t = MockTransport([(200, #"{"data":\#(userJSON("U1", "ada@example.com", allApps: false))}"#)])
    _ = try await users(t).update(ada, appIDs: ["1"])
    let sent = try body(t.requests[0])
    #expect(sent["data"]?["attributes"] == .object(["allAppsVisible": .bool(false)]))
    #expect(sent["data"]?["relationships"]?["visibleApps"]?["data"] == .array([.object(["type": .string("apps"), "id": .string("1")])]))
}

@Test func updateComparesTheCurrentApps() async throws {
    let ada = try user(userJSON("U1", "ada@example.com", allApps: false))
    let same = MockTransport([(200, #"{"data":[{"type":"apps","id":"2"},{"type":"apps","id":"1"}],"links":{"self":"x"}}"#)])
    #expect(try await users(same).update(ada, appIDs: ["1", "2"]) == nil)
    #expect(same.requests.map { $0.url!.path } == ["/v1/users/U1/relationships/visibleApps"])

    let widen = MockTransport([(200, #"{"data":\#(userJSON("U1", "ada@example.com"))}"#)])
    _ = try await users(widen).update(ada, allApps: true)
    #expect(try body(widen.requests[0])["data"]?["attributes"] == .object(["allAppsVisible": .bool(true)]))
}

@Test func removeAndCancelDelete() async throws {
    let t = MockTransport([(204, ""), (204, "")])
    try await users(t).remove(try user(userJSON("U1", "ada@example.com")))
    try await users(t).cancel(try JSONDecoder().decode(ASCUserInvitation.self, from: Data(invitationJSON("I1", "g@example.com").utf8)))
    #expect(t.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == ["DELETE /v1/users/U1", "DELETE /v1/userInvitations/I1"])
}
