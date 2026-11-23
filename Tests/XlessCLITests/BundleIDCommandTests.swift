import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private func bundle(_ id: String, _ identifier: String, name: String = "Example", platform: String = "UNIVERSAL") -> String {
    #"{"type":"bundleIds","id":"\#(id)","attributes":{"name":"\#(name)","identifier":"\#(identifier)","platform":"\#(platform)","seedId":"ABCDE12345"}}"#
}
private func capability(_ id: String, _ type: String, settings: String? = nil) -> String {
    #"{"type":"bundleIdCapabilities","id":"\#(id)","attributes":{"capabilityType":"\#(type)"\#(settings.map { #","settings":\#($0)"# } ?? "")}}"#
}
private func merchant(_ id: String, _ identifier: String, name: String = "Store") -> String {
    #"{"type":"merchantIds","id":"\#(id)","attributes":{"name":"\#(name)","identifier":"\#(identifier)"}}"#
}
private func listing(_ items: [String]) -> String { #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"}}"# }
private let iCloudXcode6 = #"[{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_5","enabled":false},{"key":"XCODE_6","enabled":true}]}]"#

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func resources(_ t: FakeTransport) -> ASCResources {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))
}
private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> BundleIDCLI {
    BundleIDCLI(bundleIDs: ASCBundleIDs(resources: resources(t)), json: json, terminal: { terminal }, say: { said.lines.append($0) })
}
private func merchants(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> MerchantIDCLI {
    MerchantIDCLI(merchantIDs: ASCMerchantIDs(resources: resources(t)), json: json, terminal: { terminal }, say: { said.lines.append($0) })
}
private func calls(_ t: FakeTransport) -> [String] { t.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" } }

@Test func bundleAndMerchantIDsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = try! #require(help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive))
    #expect(help[group.upperBound...].contains("bundle-ids") && help[group.upperBound...].contains("merchant-ids"), "\(help)")
}

@Test func bundleIDArgumentsAreCheckedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try BundleIDsCreateCommand.parse(["com.example.app."]) }
    #expect(throws: (any Error).self) { try BundleIDsCreateCommand.parse(["com.example.app", "--name", "Café"]) }
    #expect(throws: (any Error).self) { try BundleIDsCreateCommand.parse(["com.example.app", "--platform", "tvos"]) }
    #expect(throws: (any Error).self) { try BundleIDsShowCommand.parse(["../v1/apps"]) }
    #expect(throws: (any Error).self) { try BundleIDsDeleteCommand.parse(["com..example"]) }
    let ok = try BundleIDsCreateCommand.parse(["com.example.*", "--name", "Example 2", "--platform", "ios", "--team", "ABCDE12345", "--json"])
    #expect(ok.platform.value == .ios && ok.name == "Example 2" && ok.output.json)
    _ = try BundleIDsDeleteCommand.parse(["B1", "--yes"])
    _ = try BundleIDsListCommand.parse(["--platform", "universal"])
}

@Test func capabilityArgumentsAreCheckedBeforeAnythingIsSent() throws {
    func refused(_ args: [String]) -> String {
        do { _ = try BundleIDsCapabilitiesCommand.parse(args); return "" } catch { return BundleIDsCapabilitiesCommand.message(for: error) }
    }
    #expect(refused(["com.example.app", "toggle"]).contains("toggle is not an action"))
    #expect(refused(["com.example.app", "enable"]).contains("enable needs a capability"))
    #expect(refused(["com.example.app", "enable", "TELEPATHY"]).contains("TELEPATHY is not a capability; the API knows ICLOUD, "))
    #expect(refused(["com.example.app", "list", "ICLOUD"]).contains("list takes no capability"))
    #expect(refused(["com.example.app", "disable", "ICLOUD", "--setting", "ICLOUD_VERSION=XCODE_6"]).contains("--setting goes with enable"))
    #expect(refused(["com.example.app", "enable", "GAME_CENTER", "--setting", "ICLOUD_VERSION=XCODE_6"]).contains("GAME_CENTER takes no setting"))
    #expect(refused(["com.example.app", "enable", "icloud", "--setting", "ICLOUD_VERSION=XCODE_7"]).contains("ICLOUD_VERSION takes XCODE_5 or XCODE_6, not XCODE_7"))

    let enable = try BundleIDsCapabilitiesCommand.parse(["com.example.app", "enable", "data-protection", "--setting", "DATA_PROTECTION_PERMISSION_LEVEL=PROTECTED_UNLESS_OPEN"])
    let parsed = try enable.parsed()
    #expect(parsed.action == .enable && parsed.capability == .dataProtection)
    #expect(parsed.settings == [CapabilitySetting(.dataProtectionPermissionLevel, "PROTECTED_UNLESS_OPEN")])
    #expect(try BundleIDsCapabilitiesCommand.parse(["B1", "enable", "APPLE_ID_AUTH"]).parsed().settings == [CapabilitySetting(.appleIDAuthAppConsent, "PRIMARY_APP_CONSENT")])
    _ = try BundleIDsCapabilitiesCommand.parse(["B1", "LIST", "--json"])
    _ = try BundleIDsCapabilitiesCommand.parse(["com.example.app", "disable", "ICLOUD", "--yes"])
}

@Test func listPrintsATableOrAppleShape() async throws {
    let t = FakeTransport([(200, listing([bundle("B2", "com.example.zeta", platform: "IOS"), bundle("B1", "com.example.alpha", name: "Alpha")]))])
    let out = try await cli(t).list(platform: nil)
    #expect(out == """
    ID  IDENTIFIER         NAME     PLATFORM   SEED ID
    B1  com.example.alpha  Alpha    universal  ABCDE12345
    B2  com.example.zeta   Example  ios        ABCDE12345

    """)
    let j = FakeTransport([(200, listing([bundle("B1", "com.example.alpha")]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(j, json: true).list(platform: .ios).utf8))
    #expect(doc["data"]?[0]?["attributes"]?["identifier"] == .string("com.example.alpha"))
}

@Test func showListsTheCapabilitiesWithTheirSettings() async throws {
    let t = FakeTransport([(200, listing([bundle("B1", "com.example.app")])),
                           (200, listing([capability("C2", "PUSH_NOTIFICATIONS"), capability("C1", "ICLOUD", settings: iCloudXcode6)]))])
    let out = try await cli(t).show("com.example.app")
    #expect(out.contains("IDENTIFIER  com.example.app"))
    #expect(out.contains("ICLOUD              iCloud              ICLOUD_VERSION=XCODE_6  C1"))
    #expect(out.contains("PUSH_NOTIFICATIONS  Push Notifications                          C2"))
    #expect(calls(t) == ["GET /v1/bundleIds", "GET /v1/bundleIds/B1/bundleIdCapabilities"])

    let j = FakeTransport([(200, #"{"data":\#(bundle("B1", "com.example.app"))}"#), (200, listing([]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(j, json: true).show("B1").utf8))
    #expect(doc["data"]?["id"] == .string("B1") && doc["capabilities"] == .array([]))
}

@Test func createIsIdempotent() async throws {
    let known = FakeTransport([(200, listing([bundle("B1", "com.example.app", name: "Old")]))])
    #expect(try await cli(known).create(identifier: "com.example.app", name: "x", platform: .universal)
            == "com.example.app is already registered as bundle ID B1 (Old, universal); nothing was sent\n")
    #expect(calls(known) == ["GET /v1/bundleIds"])

    let fresh = FakeTransport([(200, listing([])), (201, #"{"data":\#(bundle("B9", "com.example.app", platform: "IOS"))}"#)])
    #expect(try await cli(fresh).create(identifier: "com.example.app", name: "com example app", platform: .ios)
            == "registered com.example.app as bundle ID B9 (ios)\n")
    let sent = try JSONDecoder().decode(JSONValue.self, from: fresh.requests[1].httpBody!)
    #expect(sent["data"]?["attributes"]?["platform"] == .string("IOS") && sent["data"]?["attributes"]?["name"] == .string("com example app"))

    let json = FakeTransport([(200, listing([bundle("B1", "com.example.app")]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(json, json: true).create(identifier: "com.example.app", name: "x", platform: .ios).utf8))
    #expect(doc["registered"] == .array([]) && doc["existing"]?[0]?["id"] == .string("B1"))
}

@Test func deleteAsksAndSaysProfilesBecomeInvalid() async throws {
    let declined = FakeTransport([(200, listing([bundle("B1", "com.example.app")]))])
    let said = Said()
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).delete("com.example.app", yes: false) == "")
    #expect(calls(declined) == ["GET /v1/bundleIds"] && said.lines == ["cancelled; nothing was sent"])

    let noTerminal = FakeTransport([(200, listing([bundle("B1", "com.example.app")]))])
    do { _ = try await cli(noTerminal).delete("com.example.app", yes: false); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix == "re-run with --yes") }

    let yes = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (204, "")])
    #expect(try await cli(yes).delete("com.example.app", yes: true) == "deleted bundle ID com.example.app (B1)\n")
    #expect(calls(yes) == ["GET /v1/bundleIds", "DELETE /v1/bundleIds/B1"])
}

@Test func capabilitiesListSaysWhenThereIsNone() async throws {
    let t = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([]))])
    #expect(try await cli(t).capabilities("com.example.app") == "no capability is enabled on com.example.app\n")
}

@Test func enableSendsTheSettingsAndNotesWhatIsLeft() async throws {
    let t = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([])),
                           (201, #"{"data":\#(capability("C1", "ICLOUD", settings: iCloudXcode6))}"#)])
    let said = Said()
    let out = try await cli(t, said: said).enable(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_6")], on: "com.example.app")
    #expect(out == "enabled ICLOUD (iCloud) on com.example.app with ICLOUD_VERSION=XCODE_6\n")
    #expect(calls(t) == ["GET /v1/bundleIds", "GET /v1/bundleIds/B1/bundleIdCapabilities", "POST /v1/bundleIdCapabilities"])
    #expect(said.lines.count == 2 && said.lines[0].hasPrefix("note: iCloud also needs an iCloud container assigned to com.example.app"))

    let same = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([capability("C1", "ICLOUD", settings: iCloudXcode6)]))])
    let quiet = Said()
    #expect(try await cli(same, said: quiet).enable(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_6")], on: "com.example.app")
            == "ICLOUD is already enabled on com.example.app with ICLOUD_VERSION=XCODE_6; nothing was sent\n")
    #expect(same.requests.count == 2 && quiet.lines.isEmpty)

    let change = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([capability("C1", "ICLOUD", settings: iCloudXcode6)])),
                                (200, #"{"data":\#(capability("C1", "ICLOUD"))}"#)])
    #expect(try await cli(change).enable(.icloud, settings: [CapabilitySetting(.icloudVersion, "XCODE_5")], on: "com.example.app")
            == "changed ICLOUD (iCloud) on com.example.app to ICLOUD_VERSION=XCODE_5\n")
    #expect(calls(change).last == "PATCH /v1/bundleIdCapabilities/C1")
}

@Test func disableAsksAndSendsNothingWhenNotEnabled() async throws {
    let absent = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([]))])
    #expect(try await cli(absent).disable(.gameCenter, on: "com.example.app", yes: false) == "GAME_CENTER is not enabled on com.example.app; nothing was sent\n")

    let declined = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([capability("C1", "GAME_CENTER")]))])
    let said = Said()
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).disable(.gameCenter, on: "com.example.app", yes: false) == "")
    #expect(declined.requests.count == 2 && said.lines == ["cancelled; nothing was sent"])

    let yes = FakeTransport([(200, listing([bundle("B1", "com.example.app")])), (200, listing([capability("C1", "GAME_CENTER")])), (204, "")])
    #expect(try await cli(yes, terminal: FakeTerminal(answer: true)).disable(.gameCenter, on: "com.example.app", yes: false)
            == "disabled GAME_CENTER (Game Center) on com.example.app\n")
    #expect(calls(yes).last == "DELETE /v1/bundleIdCapabilities/C1")
}

@Test func anUnknownIdentifierPointsToListAndCreate() async throws {
    let t = FakeTransport([(200, listing([]))])
    do { _ = try await cli(t).capabilities("com.example.app"); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account && e.cause == "no bundle ID com.example.app is registered on this team")
    }
}

@Test func theRoleFixNamesAdminForBundleAndMerchantIDs() {
    #expect(ASCRoles.needed(path: "/v1/bundleIdCapabilities") == "Admin")
    #expect(ASCRoles.needed(path: "/v1/bundleIds/B1/bundleIdCapabilities") == "Admin")
    #expect(ASCRoles.needed(path: "/v1/merchantIds") == "Admin")
}

// MARK: - Merchant IDs

@Test func merchantIDArgumentsAreCheckedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try MerchantIDsCreateCommand.parse(["com.example.store", "--name", "Store"]) }
    #expect(throws: (any Error).self) { try MerchantIDsCreateCommand.parse(["merchant.com.example.store"]) }
    #expect(throws: (any Error).self) { try MerchantIDsCreateCommand.parse(["merchant.com.example.store", "--name", "Store & Co"]) }
    #expect(throws: (any Error).self) { try MerchantIDsDeleteCommand.parse(["../v1"]) }
    _ = try MerchantIDsCreateCommand.parse(["merchant.com.example.store", "--name", "Example Store", "--json"])
    _ = try MerchantIDsDeleteCommand.parse(["merchant.com.example.store", "--yes"])
}

@Test func merchantIDsAreListedCreatedOnceAndDeletedAfterAsking() async throws {
    let list = FakeTransport([(200, listing([merchant("M1", "merchant.com.example.store", name: "Example Store")]))])
    #expect(try await merchants(list).list() == "ID  IDENTIFIER                  NAME\nM1  merchant.com.example.store  Example Store\n")

    let known = FakeTransport([(200, listing([merchant("M1", "merchant.com.example.store")]))])
    #expect(try await merchants(known).create(identifier: "merchant.com.example.store", name: "X")
            == "merchant.com.example.store is already registered as merchant ID M1 (Store); nothing was sent\n")
    let fresh = FakeTransport([(200, listing([])), (201, #"{"data":\#(merchant("M2", "merchant.com.example.new"))}"#)])
    #expect(try await merchants(fresh).create(identifier: "merchant.com.example.new", name: "New") == "registered merchant.com.example.new as merchant ID M2\n")
    #expect(calls(fresh) == ["GET /v1/merchantIds", "POST /v1/merchantIds"])

    let declined = FakeTransport([(200, listing([merchant("M1", "merchant.com.example.store")]))])
    let said = Said()
    #expect(try await merchants(declined, terminal: FakeTerminal(answer: false), said: said).delete("merchant.com.example.store", yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"] && declined.requests.count == 1)
    let yes = FakeTransport([(200, #"{"data":\#(merchant("M1", "merchant.com.example.store"))}"#), (204, "")])
    #expect(try await merchants(yes, json: true).delete("M1", yes: true).contains(#""deleted""#))
    #expect(calls(yes) == ["GET /v1/merchantIds/M1", "DELETE /v1/merchantIds/M1"])
}
