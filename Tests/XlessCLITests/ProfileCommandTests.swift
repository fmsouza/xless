import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftASN1
import Testing
import XlessASC
import XlessCore
@testable import xless

private let iphone = "00008030-001A35E80C42802E"
private let tv = "00008110-001A35E80C42802E"
private let mac = "12345678-1234-1234-1234-123456789ABC"
private let future = "2099-01-01T00:00:00.000+0000"

private func listing(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
private func bundle(_ id: String = "B1", _ identifier: String = "com.example.app", platform: String = "UNIVERSAL") -> String {
    #"{"type":"bundleIds","id":"\#(id)","attributes":{"identifier":"\#(identifier)","name":"Example","platform":"\#(platform)","seedId":"ABCDE12345"}}"#
}
private func cert(_ id: String, _ type: String = "DISTRIBUTION", expires: String = future) -> String {
    #"{"type":"certificates","id":"\#(id)","attributes":{"name":"n","certificateType":"\#(type)","expirationDate":"\#(expires)"}}"#
}
private func device(_ id: String, _ udid: String, platform: String = "IOS", deviceClass: String = "IPHONE", status: String = "ENABLED") -> String {
    #"{"type":"devices","id":"\#(id)","attributes":{"name":"dev \#(id)","deviceClass":"\#(deviceClass)","udid":"\#(udid)","platform":"\#(platform)","status":"\#(status)"}}"#
}
private func profile(_ id: String, name: String = "xless com.example.app IOS_APP_ADHOC", type: String = "IOS_APP_ADHOC", bundle: String = "B1",
                     expires: String = future, uuid: String = "11111111-2222-3333-4444-555555555555", content: Data? = nil) -> String {
    #"{"type":"profiles","id":"\#(id)","attributes":{"name":"\#(name)","profileType":"\#(type)","profileState":"ACTIVE","uuid":"\#(uuid)","expirationDate":"\#(expires)"\#(content.map { #","profileContent":"\#($0.base64EncodedString())""# } ?? "")},"relationships":{"bundleId":{"data":{"type":"bundleIds","id":"\#(bundle)"}}}}"#
}
private func refs(_ type: String, _ ids: [String]) -> String {
    #"{"data":[\#(ids.map { #"{"type":"\#(type)","id":"\#($0)"}"# }.joined(separator: ","))]}"#
}

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> ProfileCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ProfileCLI(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }), json: json, terminal: { terminal },
                      say: { said.lines.append($0) }, now: { ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z")! })
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }
private func ids(_ v: JSONValue?) -> [String] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { $0["id"]?.string }
}

/// A DER CMS SignedData envelope around a profile property list.
private func profileFile(team: String = "ABCDE12345", appID: String = "ABCDE12345.com.example.app",
                         uuid: String = "11111111-2222-3333-4444-555555555555") -> Data {
    let plist: [String: Any] = ["Name": "p", "UUID": uuid, "TeamIdentifier": [team], "Entitlements": ["application-identifier": appID]]
    let content = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var s = DER.Serializer()
    let ctx0 = ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
    try! s.appendConstructedNode(identifier: .sequence) { s in
        try s.serialize([1, 2, 840, 113549, 1, 7, 2] as ASN1ObjectIdentifier)
        try s.appendConstructedNode(identifier: ctx0) { s in
            try s.appendConstructedNode(identifier: .sequence) { s in
                try s.serialize(1)
                try s.appendConstructedNode(identifier: .set) { _ in }
                try s.appendConstructedNode(identifier: .sequence) { s in
                    try s.serialize([1, 2, 840, 113549, 1, 7, 1] as ASN1ObjectIdentifier)
                    try s.appendConstructedNode(identifier: ctx0) { s in try s.serialize(ASN1OctetString(contentBytes: Array(content)[...])) }
                }
                try s.appendConstructedNode(identifier: .set) { _ in }
            }
        }
    }
    return Data(s.serializedBytes)
}

private func tempPath(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-profiles-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name).path
}

// MARK: - Arguments

@Test func profilesAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("profiles") } == true, "\(help)")
}

@Test func badProfileArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "development", "--bundle-id", "com.example.app"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-store", "--bundle-id", "a.b", "--devices", "all"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-store", "--bundle-id", "a.b", "--cert", "../x"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-store", "--bundle-id", "a.b", "--cert-type", "development"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-adhoc", "--bundle-id", "a.b", "--devices", "not a udid"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-adhoc", "--bundle-id", "a.b", "--devices", "\(iphone),"]) }
    #expect(throws: (any Error).self) { try ProfilesCreateCommand.parse(["--type", "ios-app-store", "--bundle-id", "a.b", "--name", " "]) }
    #expect(throws: (any Error).self) { try ProfilesListCommand.parse(["--expiring", "-1"]) }
    #expect(throws: (any Error).self) { try ProfilesListCommand.parse(["--type", "adhoc"]) }
    #expect(throws: (any Error).self) { try ProfilesDownloadCommand.parse(["../v1/apps", "--out", "x"]) }
    #expect(throws: (any Error).self) { try ProfilesRenewCommand.parse(["a/b"]) }
    let ok = try ProfilesCreateCommand.parse(["--type", "IOS_APP_ADHOC", "--bundle-id", "com.example.app", "--cert", "C1", "--cert-type", "distribution",
                                               "--devices", "\(iphone), D2", "--name", "Ad hoc", "--team", "ABCDE12345"])
    let request = try ok.request()
    #expect(request.type == .iosAppAdHoc && request.certificateIDs == ["C1"] && request.certificateTypes == [.distribution])
    #expect(request.devices == .some([iphone, "D2"]) && request.name == "Ad hoc")
    #expect(try ProfilesCreateCommand.parse(["--type", "tvos-app-development", "--bundle-id", "a.b", "--devices", "ALL"]).request().devices == .all)
    _ = try ProfilesDeleteCommand.parse(["8U3T4X5YZA", "--yes"])
    // The recreate command `renew` prints spells the name `--name=…`, which keeps a leading dash a value.
    #expect(try ProfilesCreateCommand.parse(["--type", "ios-app-store", "--bundle-id", "a.b", "--name=-odd"]).name == "-odd")
}

// MARK: - list

@Test func listShowsBundleIDsAndFilters() async throws {
    let items = [profile("P1", name: "A", type: "IOS_APP_STORE", expires: "2026-12-01T00:00:00.000+0000"), profile("P2", name: "B", bundle: "B2")]
    let t = FakeTransport([(200, listing(items, included: [bundle(), bundle("B2", "com.example.other")]))])
    let out = try await cli(t).list(types: [], bundleID: nil, expiringWithin: nil)
    let lines = out.split(separator: "\n")
    #expect(lines[0].hasPrefix("ID  NAME  TYPE") && lines[0].hasSuffix("STATE   EXPIRES"))
    #expect(lines[1].hasPrefix("P1  A     ios-app-store  com.example.app") && lines[1].hasSuffix("active  2026-12-01"))
    #expect(lines[2].contains("com.example.other"))

    let filtered = FakeTransport([(200, listing([bundle()])), (200, listing(items, included: [bundle(), bundle("B2", "com.example.other")]))])
    let only = try await cli(filtered).list(types: [], bundleID: "com.example.app", expiringWithin: 30)
    #expect(only.contains("P1") && !only.contains("P2"))
    #expect(filtered.requests[0].url!.path == "/v1/bundleIds")

    let none = FakeTransport([(200, listing(items, included: [bundle()]))])
    #expect(try await cli(none).list(types: [], bundleID: nil, expiringWithin: 1) == "No profile expires within 1 days.\n")
}

@Test func profileListJSONKeepsAppleShape() async throws {
    let t = FakeTransport([(200, listing([profile("P1")], included: [bundle()]))])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(t, json: true).list(types: [.iosAppAdHoc], bundleID: nil, expiringWithin: nil).utf8))
    #expect(doc["data"]?[0]?["id"] == .string("P1"))
    #expect(doc["data"]?[0]?["relationships"]?["bundleId"]?["data"]?["id"] == .string("B1"))
}

// MARK: - create

@Test func createAdHocTakesFittingCertificatesAndEveryEnabledDeviceByDefault() async throws {
    let t = FakeTransport([
        (200, listing([bundle()])),
        (200, listing([cert("C1"), cert("C2", "IOS_DISTRIBUTION"), cert("OLD", expires: "2026-01-01T00:00:00.000+0000")])),
        (200, listing([device("D1", iphone), device("D2", tv, deviceClass: "APPLE_TV"), device("D3", "00008030-001A35E80C428000", status: "DISABLED")])),
        (200, listing([])),
        (201, #"{"data":\#(profile("P9"))}"#),
    ])
    let out = try await cli(t).create(ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app"))
    #expect(out == "created profile xless com.example.app IOS_APP_ADHOC (P9, ios-app-adhoc) for com.example.app: 2 certificates, 1 device, expires 2099-01-01\ndownload it with `xless profiles download P9 --out <file>`\n")
    let certQuery = t.requests[1].url!.query ?? ""
    #expect(certQuery.contains("DISTRIBUTION,IOS_DISTRIBUTION"))
    #expect(t.requests[2].url!.query?.contains("filter%5Bplatform%5D=IOS") == true || t.requests[2].url!.query?.contains("filter[platform]=IOS") == true)
    let sent = try body(t.requests[4])
    #expect(sent["data"]?["attributes"]?["name"] == .string("xless com.example.app IOS_APP_ADHOC"))
    #expect(ids(sent["data"]?["relationships"]?["certificates"]?["data"]) == ["C1", "C2"])
    #expect(ids(sent["data"]?["relationships"]?["devices"]?["data"]) == ["D1"])
    #expect(t.requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET", "POST"])
}

@Test(arguments: [ProfileType.iosAppStore, .macAppStore, .macAppDirect, .tvosAppStore, .iosAppInHouse, .tvosAppInHouse, .macCatalystAppStore,
                  .macCatalystAppDirect])
func createWithoutDevices(type: ProfileType) async throws {
    let certType = type.certificateTypes[0].rawValue
    let t = FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1", certType)])), (200, listing([])),
                           (201, #"{"data":\#(profile("P9", type: type.rawValue))}"#)])
    _ = try await cli(t).create(ProfileRequest(type: type, bundleID: "com.example.app"))
    let sent = try body(t.requests[3])
    #expect(sent["data"]?["attributes"]?["profileType"] == .string(type.rawValue))
    #expect(sent["data"]?["relationships"]?["devices"] == nil)
    #expect(!t.requests.contains { $0.url!.path == "/v1/devices" })
}

@Test(arguments: [(ProfileType.iosAppDevelopment, "IPHONE", "IOS"), (.tvosAppDevelopment, "APPLE_TV", "IOS"), (.tvosAppAdHoc, "APPLE_TV", "IOS"),
                  (.macAppDevelopment, "MAC", "MAC_OS"), (.macCatalystAppDevelopment, "MAC", "MAC_OS")])
func createWithDevicesOfTheRightKind(type: ProfileType, deviceClass: String, platform: String) async throws {
    let t = FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1", type.certificateTypes[1].rawValue)])),
                           (200, listing([device("D1", platform == "IOS" ? iphone : mac, platform: platform, deviceClass: deviceClass)])),
                           (200, listing([])), (201, #"{"data":\#(profile("P9", type: type.rawValue))}"#)])
    _ = try await cli(t).create(ProfileRequest(type: type, bundleID: "com.example.app"))
    #expect(ids(try body(t.requests[4])["data"]?["relationships"]?["devices"]?["data"]) == ["D1"])
    #expect(t.requests[2].url!.absoluteString.contains(platform))
}

@Test func createWithNamedCertificatesAndDevices() async throws {
    let t = FakeTransport([
        (200, listing([bundle()])),
        (200, #"{"data":\#(cert("C7", "DEVELOPMENT"))}"#),
        (200, listing([device("D1", iphone), device("D2", "00008030-001A35E80C428000")])),
        (200, listing([])),
        (201, #"{"data":\#(profile("P9", type: "IOS_APP_DEVELOPMENT"))}"#),
    ])
    let request = ProfileRequest(type: .iosAppDevelopment, bundleID: "com.example.app", certificateIDs: ["C7"],
                                 devices: .some([iphone.lowercased(), "D2"]), name: "Dev")
    _ = try await cli(t).create(request)
    let sent = try body(t.requests[4])
    #expect(ids(sent["data"]?["relationships"]?["certificates"]?["data"]) == ["C7"])
    #expect(ids(sent["data"]?["relationships"]?["devices"]?["data"]) == ["D1", "D2"])
    #expect(sent["data"]?["attributes"]?["name"] == .string("Dev"))
}

private func refused(_ t: FakeTransport, _ request: ProfileRequest, _ cause: String) async {
    do { _ = try await cli(t).create(request); Issue.record("expected a refusal: \(cause)") } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.contains(cause), "\(e.cause)")
    } catch { Issue.record("\(error)") }
    #expect(!t.requests.contains { $0.httpMethod == "POST" })
}

@Test func createRefusesBeforeSending() async throws {
    let adhoc = ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app")
    await refused(FakeTransport([(200, listing([bundle(platform: "MAC_OS")]))]), adhoc, "registered for macos")
    await refused(FakeTransport([(200, listing([bundle(platform: "IOS")]))]), ProfileRequest(type: .macAppStore, bundleID: "com.example.app"), "registered for ios")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("OLD", expires: "2026-01-01T00:00:00.000+0000")]))]), adhoc, "no unexpired")
    await refused(FakeTransport([(200, listing([bundle()])), (200, #"{"data":\#(cert("C7", "DEVELOPMENT"))}"#)]),
                  ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app", certificateIDs: ["C7"]), "cannot contain")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1")])), (200, listing([device("D1", tv, deviceClass: "APPLE_TV")]))]),
                  adhoc, "no enabled iOS device")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1")])), (200, listing([device("D1", iphone, status: "DISABLED")]))]),
                  ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app", devices: .some([iphone])), "is disabled")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1")])), (200, listing([device("D1", iphone)]))]),
                  ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app", devices: .some([tv])), "is not a registered iOS device")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1")])), (200, listing([device("D1", tv, deviceClass: "APPLE_TV")]))]),
                  ProfileRequest(type: .iosAppAdHoc, bundleID: "com.example.app", devices: .some([tv])), "cannot list")
    await refused(FakeTransport([(200, listing([bundle()])), (200, listing([cert("C1")])), (200, listing([device("D1", iphone)])), (200, listing([profile("P1")]))]),
                  adhoc, "exists already (P1")
}

// MARK: - download

@Test func downloadWritesAVerifiedProfile() async throws {
    let file = profileFile()
    let t = FakeTransport([(200, #"{"data":\#(profile("P1", content: file)),"included":[\#(bundle())]}"#)])
    let path = tempPath("app.mobileprovision")
    let out = try await cli(t).download("P1", to: path, team: "ABCDE12345")
    #expect(out == "wrote profile xless com.example.app IOS_APP_ADHOC (P1, IOS_APP_ADHOC, expires 2099-01-01) to \(path)\n")
    #expect(FileManager.default.contents(atPath: path) == file)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o644)
    #expect(t.requests[0].url!.query?.contains("profileContent") == true)

    // Never overwrites.
    let again = FakeTransport([(200, #"{"data":\#(profile("P1", content: file)),"included":[\#(bundle())]}"#)])
    await #expect(throws: XlessError.self) { _ = try await cli(again).download("P1", to: path, team: nil) }
}

@Test func downloadRefusesAProfileThatDoesNotMatch() async throws {
    let cases: [(Data, String?)] = [
        (profileFile(team: "ZZZZZ99999"), "ABCDE12345"),
        (profileFile(appID: "ABCDE12345.com.example.other"), nil),
        (profileFile(uuid: "99999999-2222-3333-4444-555555555555"), nil),
        (Data("<?xml version=\"1.0\"?><plist></plist>".utf8), nil),
    ]
    for (file, team) in cases {
        let t = FakeTransport([(200, #"{"data":\#(profile("P1", content: file)),"included":[\#(bundle())]}"#)])
        let path = tempPath("bad.mobileprovision")
        await #expect(throws: XlessError.self) { _ = try await cli(t).download("P1", to: path, team: team) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    // Without a team, the check uses the App ID prefix, and says how to name the team when they differ.
    let other = FakeTransport([(200, #"{"data":\#(profile("P1", content: profileFile(team: "ZZZZZ99999"))),"included":[\#(bundle())]}"#)])
    do { _ = try await cli(other).download("P1", to: tempPath("x.mobileprovision"), team: nil); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.fix.hasSuffix("pass --team <TEAM_ID>"))
    }
}

// MARK: - renew

private func renewing(_ p: String, certs: [String], usableCerts: [String], devices: [String]? = nil, usableDevices: [String] = [],
                      then more: [(Int, String)] = []) -> FakeTransport {
    var steps: [(Int, String)] = [(200, #"{"data":\#(p),"included":[\#(bundle())]}"#), (200, refs("certificates", certs)), (200, listing(usableCerts))]
    if let devices { steps += [(200, refs("devices", devices)), (200, listing(usableDevices))] }
    return FakeTransport(steps + more)
}

@Test func renewKeepsNameCertificatesAndDevices() async throws {
    let t = renewing(profile("P1", name: "My Ad Hoc"), certs: ["C1", "C2"], usableCerts: [cert("C1"), cert("C2", "IOS_DISTRIBUTION")],
                     devices: ["D1", "D2", "D3"], usableDevices: [device("D1", iphone), device("D2", iphone), device("D3", iphone)],
                     then: [(204, ""), (201, #"{"data":\#(profile("P2", name: "My Ad Hoc"))}"#)])
    let out = try await cli(t, terminal: FakeTerminal(answer: true)).renew("P1", yes: false)
    #expect(out.hasPrefix("deleted profile P1; created profile My Ad Hoc (P2, ios-app-adhoc) for com.example.app: 2 certificates, 3 devices"))
    #expect(t.requests[5].httpMethod == "DELETE" && t.requests[5].url!.path == "/v1/profiles/P1")
    let sent = try body(t.requests[6])
    #expect(sent["data"]?["attributes"]?["name"] == .string("My Ad Hoc"))
    #expect(sent["data"]?["attributes"]?["profileType"] == .string("IOS_APP_ADHOC"))
    #expect(sent["data"]?["relationships"]?["bundleId"]?["data"]?["id"] == .string("B1"))
    #expect(ids(sent["data"]?["relationships"]?["certificates"]?["data"]) == ["C1", "C2"])
    #expect(ids(sent["data"]?["relationships"]?["devices"]?["data"]) == ["D1", "D2", "D3"])
}

@Test func renewLeavesOutWhatCanNoLongerBeInAProfile() async throws {
    let said = Said()
    let t = renewing(profile("P1"), certs: ["C1", "OLD"], usableCerts: [cert("C1"), cert("OLD", expires: "2026-01-01T00:00:00.000+0000")],
                     devices: ["D1", "D2", "GONE"], usableDevices: [device("D1", iphone), device("D2", iphone, status: "DISABLED")],
                     then: [(204, ""), (201, #"{"data":\#(profile("P2"))}"#)])
    _ = try await cli(t, said: said).renew("P1", yes: true)
    let sent = try body(t.requests[6])
    #expect(ids(sent["data"]?["relationships"]?["certificates"]?["data"]) == ["C1"])
    #expect(ids(sent["data"]?["relationships"]?["devices"]?["data"]) == ["D1"])
    #expect(said.lines == ["left out: certificate OLD (expired or revoked)", "left out: device D2 (disabled, or no longer registered)",
                           "left out: device GONE (disabled, or no longer registered)"])
}

@Test func renewOfAStoreProfileReadsNoDevicesAndPrintsJSON() async throws {
    let t = renewing(profile("P1", type: "MAC_APP_STORE"), certs: ["C1"], usableCerts: [cert("C1", "MAC_APP_DISTRIBUTION")],
                     then: [(204, ""), (201, #"{"data":\#(profile("P2", type: "MAC_APP_STORE"))}"#)])
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli(t, json: true).renew("P1", yes: true).utf8))
    #expect(doc["replaced"] == .string("P1") && doc["profile"]?["id"] == .string("P2"))
    #expect(doc["certificates"] == .array([.string("C1")]) && doc["devices"] == .array([]))
    #expect(!t.requests.contains { $0.url!.path.hasSuffix("/devices") })
    #expect(t.requests[1].url!.path == "/v1/profiles/P1/relationships/certificates" && t.requests[2].url!.query?.contains("MAC_APP_DISTRIBUTION") == true)
}

@Test func renewDeclinedOrWithNothingUsableLeftSendsNothing() async throws {
    let said = Said()
    let declined = renewing(profile("P1"), certs: ["C1"], usableCerts: [cert("C1")], devices: ["D1"], usableDevices: [device("D1", iphone)])
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).renew("P1", yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"])
    #expect(declined.requests.allSatisfy { $0.httpMethod == "GET" })

    let noCertificates = renewing(profile("P1"), certs: ["OLD"], usableCerts: [cert("OLD", expires: "2026-01-01T00:00:00.000+0000")],
                                  devices: ["D1"], usableDevices: [device("D1", iphone)])
    let noDevices = renewing(profile("P1"), certs: ["C1"], usableCerts: [cert("C1")], devices: ["D1"], usableDevices: [device("D1", iphone, status: "DISABLED")])
    let empty = renewing(profile("P1"), certs: [], usableCerts: [], devices: ["D1"], usableDevices: [device("D1", iphone)])
    for (t, cause) in [(noCertificates, "no unexpired certificate left"), (noDevices, "no enabled device left"), (empty, "no unexpired certificate left")] {
        do { _ = try await cli(t).renew("P1", yes: true); Issue.record("expected throw") } catch let e as XlessError {
            #expect(e.cause.contains(cause) && e.cause.hasSuffix("nothing was sent"), "\(e.cause)")
        }
        #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}

@Test func renewThatFailsAfterTheDeleteSaysHowToRecreate() async throws {
    let conflict = #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"conflict","detail":"There is a problem with the request entity"}]}"#
    let t = renewing(profile("P1", name: "Fred's Ad Hoc"), certs: ["C1"], usableCerts: [cert("C1")], devices: ["D1", "D2"],
                     usableDevices: [device("D1", iphone), device("D2", iphone)], then: [(204, ""), (409, conflict)])
    do { _ = try await cli(t).renew("P1", yes: true, team: "ABCDE12345"); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.hasPrefix("profile Fred's Ad Hoc (P1) was deleted, but creating it again failed: "))
        #expect(e.fix == #"create it again with: xless profiles create --type ios-app-adhoc --bundle-id com.example.app --cert C1 --devices D1,D2 --name='Fred'\''s Ad Hoc' --team ABCDE12345"#)
    }
}

// MARK: - delete

@Test func deleteAsksFirst() async throws {
    let said = Said()
    let declined = FakeTransport([(200, #"{"data":\#(profile("P1")),"included":[\#(bundle())]}"#)])
    #expect(try await cli(declined, terminal: FakeTerminal(answer: false), said: said).delete("P1", yes: false) == "")
    #expect(declined.requests.count == 1 && said.lines == ["cancelled; nothing was sent"])

    let t = FakeTransport([(200, #"{"data":\#(profile("P1")),"included":[\#(bundle())]}"#), (204, "")])
    #expect(try await cli(t, terminal: FakeTerminal(answer: true)).delete("P1", yes: false) == "deleted profile xless com.example.app IOS_APP_ADHOC (P1)\n")
    #expect(t.requests[1].httpMethod == "DELETE")
    await #expect(throws: XlessError.self) { _ = try await cli(FakeTransport([(200, #"{"data":\#(profile("P1"))}"#)])).delete("P1", yes: false) }
}
