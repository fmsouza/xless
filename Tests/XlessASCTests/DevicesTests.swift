import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func devices(_ t: MockTransport) -> ASCDevices {
    ASCDevices(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func queryItems(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

/// A device as App Store Connect returns it (recorded shape of GET /v1/devices).
func deviceJSON(_ id: String, _ name: String, _ udid: String, platform: String = "IOS", deviceClass: String = "IPHONE",
                status: String = "ENABLED") -> String {
    #"{"type":"devices","id":"\#(id)","attributes":{"addedDate":"2026-03-01T10:00:00.000+0000","name":"\#(name)","deviceClass":"\#(deviceClass)","model":"iPhone 15","udid":"\#(udid)","platform":"\#(platform)","status":"\#(status)"},"links":{"self":"https://api.appstoreconnect.apple.com/v1/devices/\#(id)"}}"#
}
func listJSON(_ items: [String], next: String? = nil) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"https://api.appstoreconnect.apple.com/v1/devices"\#(next.map { #","next":"\#($0)""# } ?? "")},"meta":{"paging":{"total":\#(items.count),"limit":200}}}"#
}

let legacyUDID = "00008030001a35e80c42802e1234567890abcdef"
let modernUDID = "00008030-001A35E80C42802E"
let macUUID = "12345678-1234-1234-1234-123456789ABC"

// MARK: - UDIDs

@Test func udidShapesAreRecognised() {
    #expect(DeviceUDID.kind(legacyUDID) == .legacy40)
    #expect(DeviceUDID.kind(legacyUDID.uppercased()) == .legacy40)
    #expect(DeviceUDID.kind(modernUDID) == .modern25)
    #expect(DeviceUDID.kind(macUUID) == .macUUID)
    for bad in ["", String(legacyUDID.dropLast()), legacyUDID + "0", "g" + legacyUDID.dropFirst(), "00008030-001A35E80C42802", "0000803-0001A35E80C42802E",
                "12345678-1234-1234-1234-123456789AB", "12345678_1234_1234_1234_123456789ABC", "00008030--001A35E80C42802E", "ABCDE12345"] {
        #expect(DeviceUDID.kind(bad) == nil, "\(bad)")
    }
}

@Test func thePlatformFollowsTheUDIDUnlessGiven() throws {
    #expect(try DeviceUDID.validate("  \(legacyUDID) ", platform: nil) == (legacyUDID, .ios))
    #expect(try DeviceUDID.validate(modernUDID, platform: nil).platform == .ios)
    #expect(try DeviceUDID.validate(modernUDID, platform: .macOS).platform == .macOS)
    #expect(try DeviceUDID.validate(macUUID, platform: nil).platform == .macOS)
    #expect(throws: DeviceInputError.self) { try DeviceUDID.validate(macUUID, platform: .ios) }
    #expect(throws: DeviceInputError.self) { try DeviceUDID.validate(legacyUDID, platform: .macOS) }
    do { _ = try DeviceUDID.validate("nope", platform: nil); Issue.record("expected throw") }
    catch let e as DeviceInputError { #expect(e.messages.count == 1 && e.description.hasPrefix("nope is not a device UDID")) }
}

@Test func platformAndStatusArguments() {
    #expect(DevicePlatform(argument: "iOS") == .ios)
    #expect(DevicePlatform(argument: "mac") == .macOS && DevicePlatform(argument: "MACOS") == .macOS)
    #expect(DevicePlatform(argument: "tvos") == nil)
    #expect(DeviceStatus(argument: "disabled") == .disabled && DeviceStatus(argument: "gone") == nil)
    #expect(DevicePlatform.display("MAC_OS") == "macos" && DevicePlatform.display("UNIVERSAL") == "UNIVERSAL")
}

// MARK: - Device file

@Test func appleDeviceFilesAreRead() throws {
    let text = "\u{FEFF}Device ID\tDevice Name\tDevice Platform\r\n\(legacyUDID)\tFred's iPhone\tios\r\n\r\n# a comment\r\n\(macUUID)\tStudio\tmac\r\n\(modernUDID)\tiPad Pro\r\n"
    let entries = try DeviceFile.parse(text)
    #expect(entries == [
        DeviceFileEntry(line: 2, udid: legacyUDID, name: "Fred's iPhone", platform: .ios),
        DeviceFileEntry(line: 5, udid: macUUID, name: "Studio", platform: .macOS),
        DeviceFileEntry(line: 6, udid: modernUDID, name: "iPad Pro", platform: .ios),
    ])
    #expect(try DeviceFile.parse("\(legacyUDID)\tNo header").map(\.name) == ["No header"])
}

@Test func everyBadLineIsReportedAndNothingIsReturned() {
    let text = """
    Device ID\tDevice Name
    \(legacyUDID)\tOne
    nothex\tTwo
    \(legacyUDID.uppercased())\tOne again
    \(macUUID)\tMac\tios
    \(modernUDID)\tTV\ttvos
    \(modernUDID) Spaces instead of tabs
    \(modernUDID)\t
    """
    do { _ = try DeviceFile.parse(text); Issue.record("expected throw") }
    catch let e as DeviceInputError {
        #expect(e.messages.count == 6, "\(e.messages)")
        #expect(e.messages[0].hasPrefix("line 3: nothex is not a device UDID"))
        #expect(e.messages[1] == "line 4: \(legacyUDID.uppercased()) is already on line 2")
        #expect(e.messages[2].hasPrefix("line 5: \(macUUID) is a Mac hardware UUID"))
        #expect(e.messages[3] == "line 6: unknown platform \"tvos\" (ios or mac)")
        #expect(e.messages[4].hasPrefix("line 7: expected <UDID><tab><name>"))
        #expect(e.messages[5].hasPrefix("line 8: expected"))
    } catch { Issue.record("\(error)") }
    #expect(throws: DeviceInputError(["the file lists no device"])) { try DeviceFile.parse("Device ID\tDevice Name\n\n") }
}

// MARK: - API

@Test func listAsksForTheFiltersAndFollowsPages() async throws {
    let t = MockTransport([
        (200, listJSON([deviceJSON("D2", "zed", legacyUDID)], next: "https://api.appstoreconnect.apple.com/v1/devices?cursor=Mg&limit=200")),
        (200, listJSON([deviceJSON("D1", "Alpha", modernUDID)])),
    ])
    let list = try await devices(t).list(platform: .ios, status: .enabled)
    #expect(list.map(\.id) == ["D1", "D2"])
    #expect(list[0].attributes == ASCDeviceAttributes(name: "Alpha", platform: "IOS", udid: modernUDID, deviceClass: "IPHONE", model: "iPhone 15",
                                                      status: "ENABLED", addedDate: "2026-03-01T10:00:00.000+0000"))
    #expect(queryItems(t.requests[0]) == ["filter[platform]=IOS", "filter[status]=ENABLED", "limit=200"])
    #expect(t.requests[0].url!.path == "/v1/devices")
    #expect(queryItems(t.requests[1]).contains("cursor=Mg"))
}

@Test func aDeviceKeepsEveryFieldAppleSentForJSON() throws {
    let device = try JSONDecoder().decode(ASCDevice.self, from: Data(#"{"type":"devices","id":"D1","attributes":{"name":"A","newField":7}}"#.utf8))
    let out = try ASCOutput.json(device)
    #expect(out.contains("\"newField\" : 7") && out.contains("\"type\" : \"devices\""))
    #expect(device.name == "A" && device.udid == "" && device.status == nil)
}

@Test func registerPostsOnceWithNameUDIDAndPlatform() async throws {
    let t = MockTransport([(201, #"{"data":\#(deviceJSON("NEW1", "Phone", legacyUDID))}"#)])
    let result = try await devices(t).register(name: "Phone", udid: legacyUDID, platform: .ios, existing: [])
    guard case .registered(let d) = result else { Issue.record("not registered"); return }
    #expect(d.id == "NEW1")
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "POST" && t.requests[0].url!.path == "/v1/devices")
    #expect(try body(t.requests[0]) == .object(["data": .object(["type": .string("devices"), "attributes": .object([
        "name": .string("Phone"), "udid": .string(legacyUDID), "platform": .string("IOS")])])]))
}

@Test func registeringAKnownUDIDSendsNothing() async throws {
    let existing = try JSONDecoder().decode(ASCDevice.self, from: Data(deviceJSON("D1", "Old name", legacyUDID).utf8))
    let t = MockTransport([])
    let result = try await devices(t).register(name: "New", udid: legacyUDID.uppercased(), platform: .ios, existing: [existing])
    guard case .existing(let d) = result else { Issue.record("registered twice"); return }
    #expect(d.id == "D1" && t.requests.isEmpty)
}

@Test func aDuplicateAppleRefusesIsReportedAsExisting() async throws {
    let t = MockTransport([
        (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR.ATTRIBUTE.INVALID","title":"An attribute value is invalid.","detail":"A device with number '\#(legacyUDID)' already exists on this team.","source":{"pointer":"/data/attributes/udid"}}]}"#),
        (200, listJSON([deviceJSON("D9", "Theirs", legacyUDID)])),
    ])
    let result = try await devices(t).register(name: "Mine", udid: legacyUDID, platform: .ios, existing: [])
    guard case .existing(let d) = result else { Issue.record("expected existing"); return }
    #expect(d.id == "D9" && t.requests.count == 2)
}

@Test func theDeviceLimitErrorSaysHowItResets() async throws {
    let t = MockTransport([(409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"There is a problem with the request entity","detail":"You have already reached the maximum number of devices allowed for the iPhone product family."}]}"#)])
    do { _ = try await devices(t).register(name: "P", udid: legacyUDID, platform: .ios, existing: []); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.hasPrefix("POST /v1/devices: the device limit is reached — App Store Connect HTTP 409"))
        #expect(e.fix == DeviceLimit.resetRule)
        #expect(e.fix.contains("a disabled device keeps its slot") && e.fix.contains("when the membership renews"))
    }
    #expect(t.requests.count == 1)
}

@Test func updatePatchesOnlyWhatChanges() async throws {
    let device = try JSONDecoder().decode(ASCDevice.self, from: Data(deviceJSON("D1", "A", legacyUDID).utf8))
    let t = MockTransport([(200, #"{"data":\#(deviceJSON("D1", "A", legacyUDID, status: "DISABLED"))}"#)])
    let updated = try await devices(t).update(device, status: .disabled)
    #expect(updated.status == .disabled)
    #expect(t.requests[0].httpMethod == "PATCH" && t.requests[0].url!.path == "/v1/devices/D1")
    #expect(try body(t.requests[0]) == .object(["data": .object(["type": .string("devices"), "id": .string("D1"), "attributes": .object(["status": .string("DISABLED")])])]))
}

@Test func resolveTakesAnIDOrAUDID() async throws {
    let byID = MockTransport([(200, #"{"data":\#(deviceJSON("D1", "A", legacyUDID))}"#)])
    #expect(try await devices(byID).resolve("D1").id == "D1")
    #expect(byID.requests[0].url!.path == "/v1/devices/D1")

    let byUDID = MockTransport([(200, listJSON([deviceJSON("D1", "A", legacyUDID), deviceJSON("D2", "B", modernUDID)]))])
    #expect(try await devices(byUDID).resolve(modernUDID.lowercased()).id == "D2")

    let missing = MockTransport([(200, listJSON([]))])
    await #expect(throws: XlessError.self) { try await devices(missing).resolve(macUUID) }
    await #expect(throws: XlessError.self) { try await devices(MockTransport([])).resolve("../apps") }
}

// MARK: - Limit and import

private func family(_ deviceClass: String, _ n: Int, status: String = "ENABLED") throws -> [ASCDevice] {
    try (0..<n).map { try JSONDecoder().decode(ASCDevice.self, from: Data(deviceJSON("\(deviceClass)\($0)", "d\($0)", legacyUDID, deviceClass: deviceClass, status: status).utf8)) }
}

@Test func familiesNearTheLimitAreWarnedAbout() throws {
    let all = try family("IPHONE", 85) + family("IPHONE", 5, status: "DISABLED") + family("MAC", 12) + family("IPAD", 100)
    #expect(DeviceLimit.counts(all).map { "\($0.family)=\($0.count)" } == ["iPhone=90", "iPad=100", "Mac=12"])
    let warnings = DeviceLimit.warnings(all)
    #expect(warnings.count == 2)
    #expect(warnings[0].hasPrefix("warning: 90 iPhone devices are registered this membership year; 10 of Apple's 100 left"))
    #expect(warnings[1].contains("100 iPad devices") && warnings[1].contains("0 of Apple's 100 left"))
    #expect(DeviceLimit.warnings(try family("IPHONE", 89)).isEmpty)
}

@Test func importSkipsKnownDevicesAndRegistersTheRest() async throws {
    let entries = try DeviceFile.parse("\(legacyUDID)\tOne\n\(modernUDID)\tTwo\n\(macUUID)\tThree\n")
    let known = try JSONDecoder().decode(ASCDevice.self, from: Data(deviceJSON("D1", "One", legacyUDID.uppercased()).utf8))
    let t = MockTransport([
        (201, #"{"data":\#(deviceJSON("N2", "Two", modernUDID))}"#),
        (201, #"{"data":\#(deviceJSON("N3", "Three", macUUID, platform: "MAC_OS", deviceClass: "MAC"))}"#),
    ])
    var seen: [String] = []
    let report = try await DeviceImport.run(entries, existing: [known], devices: devices(t), registered: { seen.append($0.id) })
    #expect(report.registered.map(\.id) == ["N2", "N3"] && report.existing.map(\.id) == ["D1"] && seen == ["N2", "N3"])
    #expect(t.requests.count == 2)
    #expect(try body(t.requests[1])["data"]?["attributes"]?["platform"] == .string("MAC_OS"))
}

@Test func aFailedImportSaysWhatWasRegistered() async throws {
    let entries = try DeviceFile.parse("\(legacyUDID)\tOne\n\(modernUDID)\tTwo\n\(macUUID)\tThree\n")
    let t = MockTransport([
        (201, #"{"data":\#(deviceJSON("N1", "One", legacyUDID))}"#),
        (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"You have already reached the maximum number of devices allowed for the iPad product family."}]}"#),
    ])
    do { _ = try await DeviceImport.run(entries, existing: [], devices: devices(t)); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.hasPrefix("registering Two (\(modernUDID), line 2) failed: POST /v1/devices: the device limit is reached"))
        #expect(e.cause.hasSuffix("1 of 3 new devices were registered before it (One)"))
        #expect(e.fix.hasPrefix(DeviceLimit.resetRule) && e.fix.hasSuffix("re-run the import: devices already registered are skipped"))
    }
    #expect(t.requests.count == 2)
}
