import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

/// Recorded shapes of the developer portal's answers (App Store Connect CLI's fixtures and fastlane's spaceship).
enum PortalFixtures {
    static func appGroup(_ id: String, _ identifier: String, name: String = "Shared") -> [String: Any] {
        ["applicationGroup": id, "identifier": identifier, "name": name, "prefix": "ABCDE12345", "status": "current"]
    }

    static func appGroups(_ groups: [[String: Any]], total: Int? = nil) -> [String: Any] {
        ["resultCode": 0, "pageNumber": 1, "pageSize": 500, "totalRecords": total ?? groups.count, "applicationGroupList": groups]
    }

    static func container(_ id: String, _ identifier: String, hidden: Bool = false) -> [String: Any] {
        ["id": id, "type": "cloudContainers",
         "attributes": ["identifier": identifier, "name": "Container", "prefix": "ABCDE12345", "hidden": hidden, "canEdit": true, "canDelete": false]]
    }

    static func containers(_ items: [[String: Any]]) -> [String: Any] {
        ["data": items, "links": ["self": "x"], "meta": ["paging": ["total": items.count, "limit": 1000]]]
    }
}

/// Form fields of a URL-encoded body, repeated keys in order.
func formFields(_ r: URLRequest) -> [(String, String)] {
    r.bodyString.split(separator: "&").map { pair in
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        return (kv[0], kv.count > 1 ? kv[1] : "")
    }
}

func formValue(_ r: URLRequest, _ key: String) -> String? { formFields(r).first { $0.0 == key }?.1 }

func makePortal(_ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (PortalWebClient, MockTransport) {
    let mock = MockTransport(handler)
    return (PortalWebClient(web: AppleWebClient(transport: mock, stage: .account), teamID: "ABCDE12345"), mock)
}

final class PortalIdentifiersTests: XCTestCase {
    func testIdentifiersAreCheckedBeforeAnythingIsSent() throws {
        XCTAssertEqual(try PortalLinkedKind.appGroup.validate(" group.com.example.shared "), "group.com.example.shared")
        XCTAssertEqual(try PortalLinkedKind.cloudContainer.validate("iCloud.com.example-app.Data"), "iCloud.com.example-app.Data")
        for bad in ["com.example", "group.", "group.com..example", "group.com.example.", "group.com.ex ample", "group.com.exämple", "Group.com.example"] {
            XCTAssertThrowsError(try PortalLinkedKind.appGroup.validate(bad), bad)
        }
        XCTAssertThrowsError(try PortalLinkedKind.cloudContainer.validate("icloud.com.example")) {
            XCTAssertTrue(($0 as? PortalInputError)?.description.contains("iCloud.com.example") ?? false, "\($0)")
        }
    }

    func testResolvesByIdentifierOrIDAndSaysHowToCreateAMissingOne() throws {
        let items = [PortalIdentifier(id: "GRP1234567", identifier: "group.com.example.shared", name: "Shared")]
        XCTAssertEqual(try PortalIdentifiers.resolve("group.com.example.shared", in: items, kind: .appGroup).id, "GRP1234567")
        XCTAssertEqual(try PortalIdentifiers.resolve("GRP1234567", in: items, kind: .appGroup).identifier, "group.com.example.shared")
        XCTAssertThrowsError(try PortalIdentifiers.resolve("group.com.example.other", in: items, kind: .appGroup)) {
            let e = $0 as? XlessError
            XCTAssertEqual(e?.stage, .account)
            XCTAssertEqual(e?.cause, "the team has no app group group.com.example.other")
            XCTAssertTrue(e?.fix.contains("xless app-groups create group.com.example.other") ?? false)
        }
    }

    func testListsAppGroupsOverEveryPage() async throws {
        let (portal, mock) = makePortal { r in
            let page = Int(formValue(r, "pageNumber") ?? "0")!
            return .json(200, PortalFixtures.appGroups(page == 1 ? [PortalFixtures.appGroup("A1", "group.a")] : [PortalFixtures.appGroup("B2", "group.b")], total: 2))
        }
        let groups = try await PortalAppGroups(portal: portal).list()
        XCTAssertEqual(groups.map(\.identifier), ["group.a", "group.b"])
        XCTAssertEqual(groups[0], PortalIdentifier(id: "A1", identifier: "group.a", name: "Shared", prefix: "ABCDE12345", status: "current"))
        XCTAssertEqual(mock.requests.map { $0.url!.absoluteString },
                       Array(repeating: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/listApplicationGroups.action", count: 2))
        XCTAssertEqual(formValue(mock.requests[0], "teamId"), "ABCDE12345")
        XCTAssertEqual(formValue(mock.requests[0], "pageSize"), "500")
        XCTAssertEqual(formValue(mock.requests[0], "sort"), "name=asc")
    }

    func testAListingWithoutATotalStopsAtAShortPage() async throws {
        let (portal, mock) = makePortal { _ in .json(200, ["resultCode": 0, "applicationGroupList": [PortalFixtures.appGroup("A1", "group.a")]]) }
        let groups = try await PortalAppGroups(portal: portal).list()
        XCTAssertEqual(groups.map(\.id), ["A1"])
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testCreatesAnAppGroupOnceAndReportsOneThatExists() async throws {
        let (portal, mock) = makePortal { r in
            switch r.url!.lastPathComponent {
            case "listApplicationGroups.action":
                return .json(200, PortalFixtures.appGroups([PortalFixtures.appGroup("A1", "group.a")]), headers: ["csrf": "t", "csrf_ts": "1"])
            case "addApplicationGroup.action":
                return .json(200, ["resultCode": 0, "applicationGroup": PortalFixtures.appGroup("N3", "group.new", name: "New")])
            default: return .init(status: 500)
            }
        }
        let groups = PortalAppGroups(portal: portal)
        let existing = try await groups.create(identifier: "group.a", name: "A")
        XCTAssertEqual(existing, .existing(PortalIdentifier(id: "A1", identifier: "group.a", name: "Shared", prefix: "ABCDE12345", status: "current")))
        XCTAssertFalse(mock.requests.contains { $0.url!.lastPathComponent == "addApplicationGroup.action" })
        let created = try await groups.create(identifier: "group.new", name: "New")
        XCTAssertEqual(created.item.id, "N3")
        guard case .created = created else { return XCTFail("\(created)") }
        let add = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(add.url!.lastPathComponent, "addApplicationGroup.action")
        XCTAssertEqual(formValue(add, "identifier"), "group.new")
        XCTAssertEqual(formValue(add, "name"), "New")
        XCTAssertEqual(formValue(add, "teamId"), "ABCDE12345")
        XCTAssertEqual(add.header("csrf"), "t")
        XCTAssertEqual(mock.requests.filter { $0.url!.lastPathComponent == "addApplicationGroup.action" }.count, 1)
    }

    func testListsVisibleAndHiddenContainersThroughV1() async throws {
        let (portal, mock) = makePortal { r in
            let hidden = r.url!.query!.contains("true")
            return .json(200, PortalFixtures.containers([PortalFixtures.container(hidden ? "H1" : "V1", hidden ? "iCloud.h" : "iCloud.v", hidden: hidden)]))
        }
        let list = try await PortalCloudContainers(portal: portal).list()
        XCTAssertEqual(list.map(\.identifier), ["iCloud.v", "iCloud.h"])
        XCTAssertEqual(list.map(\.hidden), [false, true])
        let r = mock.requests[0]
        XCTAssertEqual(r.url!.absoluteString, "https://developer.apple.com/services-account/v1/cloudContainers?filter%5BAND%5D%5Bhidden%5D=false")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.header("X-HTTP-Method-Override"), "GET")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as? [String: String]
        XCTAssertEqual(body, ["teamId": "ABCDE12345", "urlEncodedQueryParams": "limit=1000&offset=0&sort=name"])
    }

    func testAContainerListingOfSeveralPagesIsRefused() async {
        let (portal, _) = makePortal { _ in .json(200, ["data": [PortalFixtures.container("V1", "iCloud.v")], "links": ["next": "https://x/next"]]) }
        do { _ = try await PortalCloudContainers(portal: portal).list(); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("more containers than one page holds"), e.cause)
        } catch { XCTFail("\(error)") }
    }

    func testCreatesAContainerThroughV1() async throws {
        let (portal, mock) = makePortal { r in
            if r.url!.lastPathComponent == "listProvisioningProfiles.action" { return .json(200, ["resultCode": 0], headers: ["csrf": "t", "csrf_ts": "1"]) }
            if r.httpMethod == "POST", r.header("X-HTTP-Method-Override") == nil {
                return .json(201, ["data": PortalFixtures.container("C9", "iCloud.com.example.app")])
            }
            return .json(200, PortalFixtures.containers([]))
        }
        let created = try await PortalCloudContainers(portal: portal).create(identifier: "iCloud.com.example.app", name: "Example")
        XCTAssertEqual(created, .created(PortalIdentifier(id: "C9", identifier: "iCloud.com.example.app", name: "Container", prefix: "ABCDE12345", hidden: false)))
        let post = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(post.url!.absoluteString, "https://developer.apple.com/services-account/v1/cloudContainers")
        XCTAssertEqual(post.header("Content-Type"), "application/vnd.api+json")
        XCTAssertEqual(post.bodyString, #"{"data":{"attributes":{"identifier":"iCloud.com.example.app","name":"Example","teamId":"ABCDE12345"},"type":"cloudContainers"}}"#)
        XCTAssertEqual(post.header("csrf"), "t")
    }

    func testFallsBackToTheActionPostsWhenV1IsGone() async throws {
        let (portal, mock) = makePortal { r in
            switch r.url!.lastPathComponent {
            case "cloudContainers": return .json(404, ["errors": [["status": "404", "title": "Not Found"]]])
            case "listCloudContainers.action":
                return .json(200, ["resultCode": 0, "totalRecords": 1, "cloudContainerList": [["cloudContainer": "L1", "identifier": "iCloud.old", "name": "Old"]]])
            case "addCloudContainer.action":
                return .json(200, ["resultCode": 0, "cloudContainer": ["cloudContainer": "L2", "identifier": "iCloud.new", "name": "New"]])
            default: return .json(200, ["resultCode": 0], headers: ["csrf": "t", "csrf_ts": "1"])
            }
        }
        let containers = PortalCloudContainers(portal: portal)
        let listed = try await containers.list()
        XCTAssertEqual(listed.map(\.id), ["L1"])
        let created = try await containers.create(identifier: "iCloud.new", name: "New")
        XCTAssertEqual(created.item.id, "L2")
        let add = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(add.url!.lastPathComponent, "addCloudContainer.action")
        XCTAssertEqual(formValue(add, "identifier"), "iCloud.new")
        XCTAssertEqual(formValue(add, "teamId"), "ABCDE12345")
    }

    func testARealRefusalIsNotRetriedAnotherWay() async {
        let (portal, mock) = makePortal { r in
            if r.header("X-HTTP-Method-Override") == "GET" { return .json(200, PortalFixtures.containers([])) }
            if r.url!.lastPathComponent == "cloudContainers" { return .json(403, ["errors": [["title": "Forbidden", "detail": "Only the Account Holder or an Admin can do this."]]]) }
            return .json(200, ["resultCode": 0], headers: ["csrf": "t", "csrf_ts": "1"])
        }
        do { _ = try await PortalCloudContainers(portal: portal).create(identifier: "iCloud.new", name: "New"); XCTFail("expected an error") }
        catch let e as XlessError {
            XCTAssertEqual(e.cause, "the developer portal's web interface answered HTTP 403 to POST /services-account/v1/cloudContainers: Forbidden — Only the Account Holder or an Admin can do this.")
        } catch { XCTFail("\(error)") }
        XCTAssertFalse(mock.requests.contains { $0.url!.lastPathComponent == "addCloudContainer.action" })
    }
}
