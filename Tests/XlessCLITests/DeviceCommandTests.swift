import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private let iphone = "00008030-001A35E80C42802E"
private let mac = "12345678-1234-1234-1234-123456789ABC"

private func device(_ id: String, _ name: String, _ udid: String, platform: String = "IOS", deviceClass: String = "IPHONE", status: String = "ENABLED") -> String {
    #"{"type":"devices","id":"\#(id)","attributes":{"addedDate":"2026-03-01T10:00:00.000+0000","name":"\#(name)","deviceClass":"\#(deviceClass)","model":"iPhone 15","udid":"\#(udid)","platform":"\#(platform)","status":"\#(status)"}}"#
}
private func listing(_ items: [String]) -> String { #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"}}"# }

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> DeviceCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return DeviceCLI(devices: ASCDevices(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))),
                     json: json, terminal: { terminal }, say: { said.lines.append($0) })
}

@Test func devicesAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("devices") } == true, "\(help)")
}

@Test func badArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try DevicesRegisterCommand.parse(["Phone", "not-a-udid"]) }
    #expect(throws: (any Error).self) { try DevicesRegisterCommand.parse(["Phone", mac, "--platform", "ios"]) }
    #expect(throws: (any Error).self) { try DevicesRegisterCommand.parse(["Phone", iphone, "--platform", "tvos"]) }
    #expect(throws: (any Error).self) { try DevicesRegisterCommand.parse(["  ", iphone]) }
    #expect(throws: (any Error).self) { try DevicesListCommand.parse(["--status", "gone"]) }
    #expect(throws: (any Error).self) { try DevicesDisableCommand.parse(["../v1/apps"]) }
    #expect(throws: (any Error).self) { try DevicesRenameCommand.parse(["D1", " "]) }
    let ok = try DevicesRegisterCommand.parse(["Phone", iphone, "--platform", "macos", "--team", "ABCDE12345", "--json"])
    #expect(ok.platform.value == .macOS && ok.team.team == "ABCDE12345" && ok.output.json)
    _ = try DevicesDisableCommand.parse([mac, "--yes"])
    _ = try DevicesEnableCommand.parse(["8U3T4X5YZA"])
}

@Test func listPrintsATableAndWarnsNearTheLimit() async throws {
    let many = (0..<91).map { device("P\($0)", "phone \($0)", iphone) }
    let t = FakeTransport([(200, listing([device("M1", "Studio", mac, platform: "MAC_OS", deviceClass: "MAC")] + many))])
    let said = Said()
    let out = try await cli(t, said: said).list(platform: nil, status: nil)
    let lines = out.split(separator: "\n")
    #expect(lines[0].hasPrefix("ID   NAME      UDID") && lines[0].hasSuffix("STATUS   ADDED"))
    #expect(lines.contains { $0.hasPrefix("M1   Studio    \(mac)  macos     MAC") && $0.hasSuffix("enabled  2026-03-01") })
    #expect(said.lines.count == 1 && said.lines[0].hasPrefix("warning: 91 iPhone devices are registered"))

    let filtered = FakeTransport([(200, listing(many))])
    let quiet = Said()
    _ = try await cli(filtered, said: quiet).list(platform: .ios, status: .enabled)
    #expect(quiet.lines.isEmpty)
}

@Test func listJSONKeepsAppleShape() async throws {
    let t = FakeTransport([(200, listing([device("D1", "A", iphone)]))])
    let out = try await cli(t, json: true).list(platform: nil, status: nil)
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    #expect(doc["data"]?[0]?["id"] == .string("D1"))
    #expect(doc["data"]?[0]?["attributes"]?["udid"] == .string(iphone))
}

@Test func registerIsIdempotent() async throws {
    let t = FakeTransport([(200, listing([device("D1", "Old", iphone.lowercased(), status: "DISABLED")]))])
    let out = try await cli(t).register(name: "New", udid: iphone, platform: .ios)
    #expect(out == "already registered as Old (device D1, disabled); nothing was sent\nit is disabled: enable it with `xless devices enable D1`\n")
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "GET")

    let fresh = FakeTransport([(200, listing([])), (201, #"{"data":\#(device("N1", "New", iphone))}"#)])
    #expect(try await cli(fresh).register(name: "New", udid: iphone, platform: .ios) == "registered New (\(iphone)) as device N1\n")
    #expect(fresh.requests.map(\.httpMethod) == ["GET", "POST"])

    let jsonT = FakeTransport([(200, listing([])), (201, #"{"data":\#(device("N1", "New", iphone))}"#)])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(jsonT, json: true).register(name: "New", udid: iphone, platform: .ios).utf8))
    #expect(doc["registered"]?[0]?["id"] == .string("N1") && doc["existing"] == .array([]))
}

@Test func importAsksFirstAndSkipsKnownDevices() async throws {
    let entries = try DeviceFile.parse("Device ID\tDevice Name\tDevice Platform\n\(iphone)\tPhone\tios\n\(mac)\tStudio\tmac\n")
    let declined = FakeTransport([(200, listing([]))])
    let said = Said()
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).importDevices(entries, yes: false) == "")
    #expect(declined.requests.count == 1)
    #expect(said.lines == ["to register: Phone  \(iphone)  ios", "to register: Studio  \(mac)  macos", "cancelled; nothing was sent"])

    let noTerminal = FakeTransport([(200, listing([]))])
    await #expect(throws: XlessError.self) { try await cli(noTerminal).importDevices(entries, yes: false) }
    #expect(noTerminal.requests.count == 1)

    let t = FakeTransport([(200, listing([device("D1", "Phone", iphone)])),
                           (201, #"{"data":\#(device("N2", "Studio", mac, platform: "MAC_OS", deviceClass: "MAC"))}"#)])
    let out = try await cli(t).importDevices(entries, yes: true)
    #expect(out == """
    RESULT              ID  NAME    UDID                                  PLATFORM
    registered          N2  Studio  \(mac)  macos
    already registered  D1  Phone   \(iphone)             ios

    """)
    #expect(t.requests.map(\.httpMethod) == ["GET", "POST"])

    let allKnown = FakeTransport([(200, listing([device("D1", "Phone", iphone), device("D2", "Studio", mac)]))])
    _ = try await cli(allKnown).importDevices(entries, yes: false)
    #expect(allKnown.requests.count == 1)
}

@Test func aBadDeviceFileIsRefusedWithEveryLine() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-devices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("devices.txt")
    try "\(iphone)\tPhone\nbad\tX\n\(mac)\n".write(to: file, atomically: true, encoding: .utf8)
    do { _ = try DeviceCLI.readDeviceFile(file.path); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.hasPrefix("\(file.path): line 2: bad is not a device UDID"))
        #expect(e.cause.contains("; line 3: expected <UDID><tab><name>"))
        #expect(e.fix.hasSuffix("nothing was sent"))
    }
    #expect(throws: XlessError.self) { try DeviceCLI.readDeviceFile(dir.appendingPathComponent("missing.txt").path) }
    #expect(try DeviceCLI.readDeviceFile("-", stdin: { Data("\(iphone)\tPhone\n".utf8) }).map(\.name) == ["Phone"])
}

@Test func disableAsksAndSkipsWhatIsAlreadyDone() async throws {
    let declined = FakeTransport([(200, #"{"data":\#(device("D1", "Phone", iphone))}"#)])
    let said = Said()
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).setStatus("D1", to: .disabled, yes: false) == "")
    #expect(declined.requests.count == 1 && said.lines == ["cancelled; nothing was sent"])

    let already = FakeTransport([(200, listing([device("D1", "Phone", iphone, status: "DISABLED")]))])
    #expect(try await cli(already).setStatus(iphone, to: .disabled, yes: true) == "Phone (device D1) is already disabled; nothing was sent\n")
    #expect(already.requests.count == 1)

    let t = FakeTransport([(200, #"{"data":\#(device("D1", "Phone", iphone))}"#), (200, #"{"data":\#(device("D1", "Phone", iphone, status: "DISABLED"))}"#)])
    #expect(try await cli(t).setStatus("D1", to: .disabled, yes: true) == "disabled Phone (device D1)\n")
    #expect(t.requests.map(\.httpMethod) == ["GET", "PATCH"])
}

@Test func enableNeedsNoConfirmationAndRenameSendsTheName() async throws {
    let t = FakeTransport([(200, #"{"data":\#(device("D1", "Phone", iphone, status: "DISABLED"))}"#), (200, #"{"data":\#(device("D1", "Phone", iphone))}"#)])
    #expect(try await cli(t).setStatus("D1", to: .enabled, yes: false) == "enabled Phone (device D1)\n")

    let r = FakeTransport([(200, #"{"data":\#(device("D1", "Phone", iphone))}"#), (200, #"{"data":\#(device("D1", "Work phone", iphone))}"#)])
    #expect(try await cli(r).rename("D1", to: "Work phone") == "renamed device D1 from Phone to Work phone\n")
    let body = try JSONDecoder().decode(JSONValue.self, from: r.requests[1].httpBody ?? Data())
    #expect(body["data"]?["attributes"] == .object(["name": .string("Work phone")]))

    let same = FakeTransport([(200, #"{"data":\#(device("D1", "Phone", iphone))}"#)])
    #expect(try await cli(same).rename("D1", to: "Phone") == "device D1 is already named Phone; nothing was sent\n")
    #expect(same.requests.count == 1)
}

@Test func anAppleErrorOnDevicesNamesTheAdminRole() async throws {
    let t = FakeTransport([(403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"not allowed"}]}"#)])
    do { _ = try await AccountSession.run { try await cli(t).list(platform: nil, status: nil) }; Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.hasPrefix("GET /v1/devices: App Store Connect HTTP 403"))
        #expect(e.fix.contains("Admin role"))
    }
}
