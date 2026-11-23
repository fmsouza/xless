import ArgumentParser
import Foundation
import Testing
import XlessAppleID
import XlessASC
import XlessCore
@testable import xless

private final class Said: @unchecked Sendable { var lines: [String] = [] }

/// A team with groups G1 (group.com.example.shared) and G2 (group.com.example.other), one bundle ID B1, and whatever
/// it links.
private final class FakePortal: LinkedIdentifierPortal, @unchecked Sendable {
    var items = [PortalIdentifier(id: "G1", identifier: "group.com.example.shared", name: "Shared"),
                 PortalIdentifier(id: "G2", identifier: "group.com.example.other", name: "Other")]
    var state = LinkedState(present: true, enabled: true, ids: ["G1"])
    var writes: [(ids: [String], enabled: Bool)] = []
    var created: [(String, String)] = []
    let bundle = PortalBundleID(id: "B1", identifier: "com.example.app", name: "Example")

    func list() async throws -> [PortalIdentifier] { items }
    func create(identifier: String, name: String) async throws -> PortalCreation {
        if let i = items.first(where: { $0.identifier == identifier }) { return .existing(i) }
        created.append((identifier, name))
        let i = PortalIdentifier(id: "N9", identifier: identifier, name: name)
        items.append(i)
        return .created(i)
    }
    func bundle(_ argument: String) async throws -> PortalBundleID {
        guard argument == "com.example.app" || argument == "B1" else { throw XlessError(.account, "the team has no bundle ID \(argument)", fix: "x") }
        return bundle
    }
    func linked(of bundle: PortalBundleID) async throws -> LinkedState { state }
    func setLinked(_ ids: [String], enabled: Bool, on bundle: PortalBundleID) async throws -> LinkedState {
        writes.append((ids, enabled))
        state = LinkedState(present: true, enabled: enabled, ids: ids)
        return state
    }
}

private final class FakeRegeneration: ProfileRegenerating, @unchecked Sendable {
    var renewed: [String] = []
    let profiles: [ASCProfile]
    init(_ ids: [String]) {
        profiles = ids.map { id in
            try! JSONDecoder().decode(ASCProfile.self, from: Data(#"{"type":"profiles","id":"\#(id)","attributes":{"name":"xless com.example.app IOS_APP_STORE","profileType":"IOS_APP_STORE"}}"#.utf8))
        }
    }
    func profiles(of identifier: String) async throws -> [ASCProfile] { profiles }
    func renew(_ id: String) async throws -> ProfileCreated {
        renewed.append(id)
        let p = try JSONDecoder().decode(ASCProfile.self, from: Data(#"{"type":"profiles","id":"NEW\#(id)","attributes":{"name":"xless com.example.app IOS_APP_STORE","profileType":"IOS_APP_STORE"}}"#.utf8))
        return ProfileCreated(profile: p, bundleId: "com.example.app", certificates: ["C1"], devices: [], replaced: id)
    }
}

private func cli(_ portal: FakePortal, kind: PortalLinkedKind = .appGroup, regen: FakeRegeneration? = FakeRegeneration(["P1"]),
                 terminal: (any Confirming)? = nil, json: Bool = false, said: Said = Said()) -> LinkedIdentifierCLI {
    LinkedIdentifierCLI(kind: kind, portal: portal,
                        regeneration: {
                            guard let regen else { throw XlessError(.account, "no App Store Connect API key", fix: "set one") }
                            return regen
                        },
                        json: json, terminal: { terminal }, say: { said.lines.append($0) })
}

@Test func listsTheTeamsGroups() async throws {
    let out = try await cli(FakePortal()).list()
    #expect(out.contains("ID") && out.contains("IDENTIFIER"))
    #expect(out.contains("G1") && out.contains("group.com.example.shared") && out.contains("Shared"))
    let json = try await cli(FakePortal(), json: true).list()
    #expect(json.contains(#""identifier" : "group.com.example.other""#))
}

@Test func createsAGroupWithANameFromItsIdentifierAndReportsOneThatExists() async throws {
    let portal = FakePortal()
    let out = try await cli(portal).create(identifier: "group.com.example.new", name: nil)
    #expect(out.hasPrefix("registered group.com.example.new as app group N9\n"))
    #expect(portal.created.map(\.1) == ["group com example new"])
    let again = try await cli(portal).create(identifier: "group.com.example.shared", name: "X")
    #expect(again == "group.com.example.shared is already registered as app group G1 (Shared); nothing was sent\n")
    #expect(portal.created.count == 1)
}

@Test func assignsAddingToWhatTheBundleHasAndRegeneratesItsProfilesWithYes() async throws {
    let portal = FakePortal()
    let regen = FakeRegeneration(["P1", "P2"])
    let out = try await cli(portal, regen: regen).assign(bundle: "com.example.app", items: ["group.com.example.other", "G1"], yes: true)
    #expect(portal.writes.count == 1)
    #expect(portal.writes[0].ids == ["G1", "G2"] && portal.writes[0].enabled)
    #expect(regen.renewed == ["P1", "P2"])
    #expect(out.hasPrefix("assigned group.com.example.other to com.example.app (App Groups: group.com.example.shared, group.com.example.other)\n"))
    #expect(out.contains("regenerated profile xless com.example.app IOS_APP_STORE: P1 → NEWP1"))
}

@Test func anAssignmentThatIsThereAlreadySendsNothing() async throws {
    let portal = FakePortal()
    let regen = FakeRegeneration(["P1"])
    let out = try await cli(portal, regen: regen).assign(bundle: "com.example.app", items: ["group.com.example.shared"], yes: true)
    #expect(out == "group.com.example.shared is already assigned to com.example.app; nothing was sent\n")
    #expect(portal.writes.isEmpty && regen.renewed.isEmpty)
}

@Test func anUnknownGroupIsRefusedBeforeAnythingIsSent() async throws {
    let portal = FakePortal()
    do { _ = try await cli(portal).assign(bundle: "com.example.app", items: ["group.com.example.missing"], yes: true); Issue.record("expected an error") }
    catch let e as XlessError {
        #expect(e.cause == "the team has no app group group.com.example.missing")
        #expect(e.fix.contains("xless app-groups create group.com.example.missing"))
    }
    #expect(portal.writes.isEmpty)
}

@Test func withoutATerminalOrYesTheProfilesAreLeftWithTheCommandsToRun() async throws {
    let portal = FakePortal()
    let regen = FakeRegeneration(["P1"])
    let said = Said()
    let out = try await cli(portal, regen: regen, said: said).assign(bundle: "B1", items: ["G2"], yes: false)
    #expect(portal.writes.count == 1)
    #expect(regen.renewed.isEmpty)
    #expect(out.hasPrefix("assigned group.com.example.other to com.example.app"))
    #expect(said.lines.contains { $0.contains("P1 (xless com.example.app IOS_APP_STORE)") && $0.contains("xless profiles renew <id>") && $0.contains("--yes") })
}

@Test func withoutAnAPIKeyTheAssignmentStandsAndANoteSaysWhatToRun() async throws {
    let portal = FakePortal()
    let said = Said()
    _ = try await cli(portal, regen: nil, said: said).assign(bundle: "B1", items: ["G2"], yes: true)
    #expect(portal.writes.count == 1)
    #expect(said.lines.contains { $0.contains("were not regenerated (no App Store Connect API key)") && $0.contains("xless profiles list --bundle-id com.example.app") })
}

@Test func unassignAsksAndKeepsTheCapabilityAsItWas() async throws {
    let portal = FakePortal()
    portal.state = LinkedState(present: true, enabled: true, ids: ["G1", "G2"])
    let said = Said()
    let cancelled = try await cli(portal, terminal: FakeTerminal(answer: false), said: said).unassign(bundle: "com.example.app", items: ["G1"], yes: false)
    #expect(cancelled == "" && portal.writes.isEmpty && said.lines == ["cancelled; nothing was sent"])
    let regen = FakeRegeneration(["P1"])
    let out = try await cli(portal, regen: regen, terminal: FakeTerminal(answer: true)).unassign(bundle: "com.example.app", items: ["G1", "G2"], yes: false)
    #expect(portal.writes.map(\.ids) == [[]] && portal.writes[0].enabled)
    #expect(out.hasPrefix("unassigned group.com.example.shared, group.com.example.other from com.example.app (App Groups: none)\n"))
    #expect(regen.renewed == ["P1"])
}

@Test func unassigningWhatIsNotAssignedSendsNothing() async throws {
    let portal = FakePortal()
    let out = try await cli(portal).unassign(bundle: "com.example.app", items: ["G2"], yes: true)
    #expect(out == "group.com.example.other is not assigned to com.example.app; nothing was sent\n")
    #expect(portal.writes.isEmpty)
}

@Test func aContainerNeedsTheICloudCapabilityFirst() async throws {
    let portal = FakePortal()
    portal.items = [PortalIdentifier(id: "C1", identifier: "iCloud.com.example.app", name: "App", hidden: false)]
    portal.state = LinkedState(present: false, enabled: false, ids: [])
    do { _ = try await cli(portal, kind: .cloudContainer).assign(bundle: "com.example.app", items: ["iCloud.com.example.app"], yes: true); Issue.record("expected an error") }
    catch let e as XlessError { #expect(e.fix.contains("xless bundle-ids capabilities com.example.app enable ICLOUD")) }
    #expect(portal.writes.isEmpty)
}

@Test func theJSONOfAnAssignmentListsWhatChangedAndTheProfiles() async throws {
    let portal = FakePortal()
    let out = try await cli(portal, json: true).assign(bundle: "com.example.app", items: ["G2"], yes: true)
    let object = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    #expect(object["bundleId"] as? String == "com.example.app")
    #expect(object["changed"] as? [String] == ["group.com.example.other"])
    #expect(object["linked"] as? [String] == ["group.com.example.shared", "group.com.example.other"])
    #expect((object["regeneratedProfiles"] as? [[String: Any]])?.first?["replaced"] as? String == "P1")
}

@Test func theArgumentsAreCheckedBeforeSigningIn() throws {
    #expect(throws: (any Error).self) { try LinkedCreateCommand<AppGroupKind>.parse(["com.example.shared"]) }
    #expect(throws: (any Error).self) { try LinkedCreateCommand<CloudContainerKind>.parse(["icloud.com.example"]) }
    #expect(throws: (any Error).self) { try LinkedCreateCommand<AppGroupKind>.parse(["group.com.example", "--name", "bad.name"]) }
    #expect(throws: (any Error).self) { try LinkedAssignCommand<AppGroupKind>.parse(["com.example.app"]) }
    #expect(throws: (any Error).self) { try LinkedAssignCommand<AppGroupKind>.parse(["com.example.app", "iCloud.com.example"]) }
    _ = try LinkedAssignCommand<AppGroupKind>.parse(["com.example.app", "group.com.example.a", "G1"])
    _ = try LinkedUnassignCommand<CloudContainerKind>.parse(["B1", "iCloud.com.example.app", "--yes"])
}

@Test func theAppleAccountGroupListsAppGroupsAndContainers() {
    let help = Xless.helpMessage()
    #expect(help.contains("app-groups") && help.contains("icloud-containers"))
}
