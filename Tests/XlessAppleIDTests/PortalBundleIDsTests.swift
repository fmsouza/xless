import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

/// A bundle ID as `v1/bundleIds/{id}?include=bundleIdCapabilities…` answers (the shape App Store Connect CLI recorded:
/// the capability relationship's `meta.paging` is `{total: 0, limit: 50}` next to the items).
func bundleDocument(groups: [String]? = ["GRP1"], groupsEnabled: Bool = true, containers: [String]? = nil) -> [String: Any] {
    var refs: [[String: Any]] = [["type": "bundleIdCapabilities", "id": "B1_PUSH"]]
    var included: [[String: Any]] = [[
        "type": "bundleIdCapabilities", "id": "B1_PUSH",
        "attributes": ["enabled": true, "settings": [], "editable": true],
        "relationships": ["capability": ["data": ["type": "capabilities", "id": "PUSH_NOTIFICATIONS"]]],
    ], [
        "type": "bundleIdCapabilities", "id": "B1_PAY",
        "attributes": ["enabled": true, "settings": [["key": "X", "options": [["key": "Y", "enabled": true]]]]],
        "relationships": ["capability": ["data": ["type": "capabilities", "id": "APPLE_PAY"]],
                          "merchantIds": ["data": [["type": "merchantIds", "id": "M1"]], "meta": ["paging": ["total": 0, "limit": 2147483647]]]],
    ]]
    refs.append(["type": "bundleIdCapabilities", "id": "B1_PAY"])
    if let groups {
        refs.append(["type": "bundleIdCapabilities", "id": "B1_APP_GROUPS"])
        included.append(["type": "bundleIdCapabilities", "id": "B1_APP_GROUPS",
                         "attributes": ["enabled": groupsEnabled, "settings": []],
                         "relationships": ["capability": ["data": ["type": "capabilities", "id": "APP_GROUPS"]],
                                           "appGroups": ["data": groups.map { ["type": "appGroups", "id": $0] },
                                                         "meta": ["paging": ["total": 0, "limit": 2147483647]]]]])
    }
    if let containers {
        refs.append(["type": "bundleIdCapabilities", "id": "B1_ICLOUD"])
        included.append(["type": "bundleIdCapabilities", "id": "B1_ICLOUD",
                         "attributes": ["enabled": true, "settings": [["key": "ICLOUD_VERSION", "options": [["key": "XCODE_6", "enabled": true]]]]],
                         "relationships": ["capability": ["data": ["type": "capabilities", "id": "ICLOUD"]],
                                           "cloudContainers": ["data": containers.map { ["type": "cloudContainers", "id": $0] }]]])
    }
    return ["data": ["type": "bundleIds", "id": "B1",
                     "attributes": ["identifier": "com.example.app", "name": "Example", "platform": "IOS", "seedId": "ABCDE12345",
                                    "~permissions.edit": true],
                     "relationships": ["bundleIdCapabilities": ["data": refs, "meta": ["paging": ["total": 0, "limit": 50]]]]],
            "included": included]
}

final class PortalBundleIDsTests: XCTestCase {
    let bundle = PortalBundleID(id: "B1", identifier: "com.example.app", name: "Example", platform: "IOS")

    func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    func capabilities(_ body: [String: Any]) -> [[String: Any]] {
        (((body["data"] as? [String: Any])?["relationships"] as? [String: Any])?["bundleIdCapabilities"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
    }

    func capability(_ caps: [[String: Any]], _ type: String) -> [String: Any]? { caps.first { PortalBundleIDs.capabilityType($0) == type } }

    func testReadsWhatTheCapabilityLinks() throws {
        XCTAssertEqual(try PortalBundleIDs.state(document: bundleDocument(groups: ["GRP1", "GRP2"]), kind: .appGroup, bundle: "com.example.app"),
                       LinkedState(present: true, enabled: true, ids: ["GRP1", "GRP2"]))
        XCTAssertEqual(try PortalBundleIDs.state(document: bundleDocument(groups: nil), kind: .appGroup, bundle: "x"),
                       LinkedState(present: false, enabled: false, ids: []))
        XCTAssertEqual(try PortalBundleIDs.state(document: bundleDocument(containers: ["C1"]), kind: .cloudContainer, bundle: "x").ids, ["C1"])
    }

    func testThePatchChangesOnlyTheGroupsAndKeepsEveryOtherCapability() throws {
        let body = try json(PortalBundleIDs.patchBody(document: bundleDocument(groups: ["GRP1"], containers: ["C1"]), kind: .appGroup,
                                                      ids: ["GRP1", "GRP2"], enabled: true, teamID: "ABCDE12345", bundle: "com.example.app"))
        let data = try XCTUnwrap(body["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, "B1")
        XCTAssertEqual(data["type"] as? String, "bundleIds")
        let attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["teamId"] as? String, "ABCDE12345")
        XCTAssertEqual(attributes["identifier"] as? String, "com.example.app")
        XCTAssertNil(attributes["~permissions.edit"])
        let caps = capabilities(body)
        XCTAssertEqual(caps.map { $0["id"] as? String }, ["B1_PUSH", "B1_PAY", "B1_APP_GROUPS", "B1_ICLOUD"])
        // Only enabled and settings go back; the other relationships as Apple sent them.
        XCTAssertEqual((capability(caps, "PUSH_NOTIFICATIONS")?["attributes"] as? [String: Any])?.keys.sorted(), ["enabled", "settings"])
        let pay = try XCTUnwrap(capability(caps, "APPLE_PAY"))
        XCTAssertEqual((((pay["relationships"] as? [String: Any])?["merchantIds"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"] as? String, "M1")
        XCTAssertEqual(((pay["attributes"] as? [String: Any])?["settings"] as? [[String: Any]])?.first?["key"] as? String, "X")
        let icloud = try XCTUnwrap(capability(caps, "ICLOUD"))
        XCTAssertEqual((((icloud["relationships"] as? [String: Any])?["cloudContainers"] as? [String: Any])?["data"] as? [[String: Any]])?.count, 1)
        let groups = try XCTUnwrap(capability(caps, "APP_GROUPS"))
        XCTAssertEqual(((groups["attributes"] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((((groups["relationships"] as? [String: Any])?["appGroups"] as? [String: Any])?["data"] as? [[String: String]]),
                       [["type": "appGroups", "id": "GRP1"], ["type": "appGroups", "id": "GRP2"]])
    }

    func testAMissingAppGroupsCapabilityIsAddedButAMissingICloudOneIsRefused() throws {
        let body = try json(PortalBundleIDs.patchBody(document: bundleDocument(groups: nil), kind: .appGroup, ids: ["GRP9"], enabled: true,
                                                      teamID: "ABCDE12345", bundle: "com.example.app"))
        let added = try XCTUnwrap(capability(capabilities(body), "APP_GROUPS"))
        XCTAssertNil(added["id"])
        XCTAssertEqual(((added["attributes"] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue, true)
        XCTAssertThrowsError(try PortalBundleIDs.patchBody(document: bundleDocument(), kind: .cloudContainer, ids: ["C1"], enabled: true,
                                                           teamID: "ABCDE12345", bundle: "com.example.app")) {
            XCTAssertTrue(($0 as? XlessError)?.fix.contains("xless bundle-ids capabilities com.example.app enable ICLOUD") ?? false, "\($0)")
        }
    }

    func testAnIncompleteCapabilityListIsNeverWrittenBack() throws {
        var doc = bundleDocument()
        var data = doc["data"] as! [String: Any]
        data["relationships"] = ["bundleIdCapabilities": ["links": ["related": "https://x"]]]
        doc["data"] = data
        XCTAssertThrowsError(try PortalBundleIDs.patchBody(document: doc, kind: .appGroup, ids: [], enabled: true, teamID: "T", bundle: "com.example.app")) {
            XCTAssertTrue(($0 as? XlessError)?.cause.contains("nothing was sent") ?? false, "\($0)")
        }
        data["relationships"] = ["bundleIdCapabilities": ["data": [["type": "bundleIdCapabilities", "id": "B1_PUSH"]], "links": ["next": "https://x?cursor=2"]]]
        doc["data"] = data
        XCTAssertThrowsError(try PortalBundleIDs.state(document: doc, kind: .appGroup, bundle: "b"))
        data["relationships"] = ["bundleIdCapabilities": ["data": [["type": "bundleIdCapabilities", "id": "B1_PUSH"]], "meta": ["paging": ["total": 7, "limit": 50]]]]
        doc["data"] = data
        XCTAssertThrowsError(try PortalBundleIDs.state(document: doc, kind: .appGroup, bundle: "b"))
        data["relationships"] = ["bundleIdCapabilities": ["data": [["type": "bundleIdCapabilities", "id": "UNKNOWN"]]]]
        doc["data"] = data
        XCTAssertThrowsError(try PortalBundleIDs.state(document: doc, kind: .appGroup, bundle: "b"))
    }

    func testResolvesABundleIdentifierExactly() async throws {
        let (portal, mock) = makePortal { _ in
            .json(200, ["data": [["type": "bundleIds", "id": "B2", "attributes": ["identifier": "com.example.app.widget", "name": "W"]],
                                 ["type": "bundleIds", "id": "B1", "attributes": ["identifier": "com.example.app", "name": "Example", "platform": "IOS"]]]])
        }
        let resolved = try await PortalBundleIDs(portal: portal).resolve("com.example.app")
        XCTAssertEqual(resolved, bundle)
        let body = try json(XCTUnwrap(mock.requests.first?.httpBody))
        XCTAssertEqual(body["urlEncodedQueryParams"] as? String, "fields%5BbundleIds%5D=name%2Cidentifier%2Cplatform&filter%5Bidentifier%5D=com.example.app&limit=200")
        do { _ = try await PortalBundleIDs(portal: portal).resolve("com.example.other"); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.cause, "the team has no bundle ID com.example.other")
        }
    }

    /// A portal that serves `document` for the bundle ID and applies a PATCH's App Groups to it.
    func portalApplyingPatches(_ initial: [String: Any], patchStatus: Int = 200) -> (PortalWebClient, MockTransport) {
        let doc = Box(initial)
        return makePortal { r in
            if r.url!.lastPathComponent == "listProvisioningProfiles.action" { return .json(200, ["resultCode": 0], headers: ["csrf": "t", "csrf_ts": "1"]) }
            if r.url!.lastPathComponent == "assignApplicationGroupToAppId.action" {
                doc.value = bundleDocument(groups: formFields(r).filter { $0.0 == "applicationGroups" }.map(\.1))
                return .json(200, ["resultCode": 0])
            }
            if r.httpMethod == "PATCH" {
                guard patchStatus == 200 else { return .json(patchStatus, ["errors": [["title": "Not Found"]]]) }
                let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
                let caps = (((body["data"] as! [String: Any])["relationships"] as! [String: Any])["bundleIdCapabilities"] as! [String: Any])["data"] as! [[String: Any]]
                let groups = caps.first { PortalBundleIDs.capabilityType($0) == "APP_GROUPS" }
                let ids = (((groups?["relationships"] as? [String: Any])?["appGroups"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                doc.value = bundleDocument(groups: ids)
                return .json(200, ["data": ["type": "bundleIds", "id": "B1"]])
            }
            return .json(200, doc.value)
        }
    }

    func testAssignsThroughAPatchAndChecksTheResult() async throws {
        let (portal, mock) = portalApplyingPatches(bundleDocument(groups: ["GRP1"]))
        let after = try await PortalBundleIDs(portal: portal).setLinked(.appGroup, ids: ["GRP1", "GRP2"], enabled: true, on: bundle)
        XCTAssertEqual(after.ids, ["GRP1", "GRP2"])
        let patch = try XCTUnwrap(mock.requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(patch.url!.absoluteString, "https://developer.apple.com/services-account/v1/bundleIds/B1")
        XCTAssertEqual(patch.header("csrf"), "t")
        XCTAssertEqual(mock.requests.filter { $0.httpMethod == "PATCH" }.count, 1)
        let read = try json(XCTUnwrap(mock.requests.first?.httpBody))
        XCTAssertTrue((read["urlEncodedQueryParams"] as? String)?.contains("bundleIdCapabilities.appGroups") ?? false)
    }

    func testFallsBackToTheAssignActionWhenThePatchIsRefusedAsAbsent() async throws {
        let (portal, mock) = portalApplyingPatches(bundleDocument(groups: ["GRP1"]), patchStatus: 404)
        let after = try await PortalBundleIDs(portal: portal).setLinked(.appGroup, ids: ["GRP1", "GRP2"], enabled: true, on: bundle)
        XCTAssertEqual(after.ids, ["GRP1", "GRP2"])
        let post = try XCTUnwrap(mock.requests.first { $0.url!.lastPathComponent == "assignApplicationGroupToAppId.action" })
        XCTAssertEqual(formFields(post).map(\.0), ["appIdId", "displayId", "applicationGroups", "applicationGroups", "teamId"])
        XCTAssertEqual(formValue(post, "appIdId"), "B1")
    }

    func testAPatchThatDidNotTakeIsAnError() async {
        let (portal, _) = makePortal { r in
            if r.url!.lastPathComponent == "listProvisioningProfiles.action" { return .json(200, ["resultCode": 0], headers: ["csrf": "t", "csrf_ts": "1"]) }
            if r.httpMethod == "PATCH" { return .json(200, [:]) }
            return .json(200, bundleDocument(groups: ["GRP1"]))
        }
        do { _ = try await PortalBundleIDs(portal: portal).setLinked(.appGroup, ids: ["GRP1", "GRP2"], enabled: true, on: bundle); XCTFail("expected an error") }
        catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("now lists GRP1 instead of GRP1, GRP2"), e.cause)
        } catch { XCTFail("\(error)") }
    }

    func testAForbiddenPatchIsNotRetriedAnotherWay() async {
        let (portal, mock) = portalApplyingPatches(bundleDocument(groups: ["GRP1"]), patchStatus: 403)
        do { _ = try await PortalBundleIDs(portal: portal).setLinked(.appGroup, ids: ["GRP2"], enabled: true, on: bundle); XCTFail("expected an error") }
        catch let e as XlessError { XCTAssertTrue(e.cause.contains("HTTP 403 to PATCH /services-account/v1/bundleIds/B1"), e.cause) } catch { XCTFail("\(error)") }
        XCTAssertFalse(mock.requests.contains { $0.url!.lastPathComponent == "assignApplicationGroupToAppId.action" })
    }
}
