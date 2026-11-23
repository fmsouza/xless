import Crypto
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

/// Recorded shapes of the portal's auth-key answers (fastlane spaceship/portal/key.rb, App Store Connect CLI
/// internal/web/developer_sign_in_keys.go).
enum AuthKeyFixtures {
    static func key(_ id: String, _ name: String, services: [String]? = ["U27F4V844T"], canDownload: Bool = false,
                    bundles: [String] = []) -> [String: Any] {
        var k: [String: Any] = ["keyId": id, "keyName": name, "canDownload": canDownload, "canRevoke": true]
        if let services {
            k["services"] = services.map { s -> [String: Any] in
                ["id": s, "name": "Service", "configurations": s == "APPLE_ID_AUTH_KEY_CONFIGURATION"
                    ? bundles.map { ["id": $0, "type": "bundle", "identifier": "com.example.app"] } : []]
            }
        }
        return k
    }

    static func keys(_ keys: [[String: Any]], total: Int? = nil) -> [String: Any] {
        var o: [String: Any] = ["resultCode": 0, "keys": keys]
        if let total { o["totalRecords"] = total }
        return o
    }
}

private let p8 = P256.Signing.PrivateKey().pemRepresentation

final class PortalAuthKeysTests: XCTestCase {
    func testServicesAreNamedTheWayPeopleTypeThem() {
        XCTAssertEqual(AuthKeyService(argument: "APNs"), .apns)
        XCTAssertEqual(AuthKeyService(argument: "device-check"), .deviceCheck)
        XCTAssertEqual(AuthKeyService(argument: "musickit"), .musicKit)
        XCTAssertEqual(AuthKeyService(argument: "sign-in-with-apple"), .signInWithApple)
        XCTAssertEqual(AuthKeyService(argument: "siwa"), .signInWithApple)
        XCTAssertNil(AuthKeyService(argument: "mapkit"))
        XCTAssertEqual(AuthKeyService(id: "U27F4V844T"), .apns)
        XCTAssertEqual(AuthKeyService.apns.limit, 2)
        XCTAssertNil(AuthKeyService.deviceCheck.limit)
    }

    func testKeyIDsAreCheckedBeforeAnythingIsSent() async throws {
        XCTAssertTrue(PortalAuthKeys.isKeyID("ABC123DEF4"))
        for bad in ["", "ABC/123", "ABC 123", "abc&x=1", String(repeating: "A", count: 33), "ÄBC"] { XCTAssertFalse(PortalAuthKeys.isKeyID(bad), bad) }
        let (portal, mock) = makePortal { _ in .json(200, AuthKeyFixtures.keys([])) }
        let keys = PortalAuthKeys(portal: portal)
        do { _ = try await keys.get(id: "../x"); XCTFail() } catch {}
        do { try await keys.revoke(id: "a b"); XCTFail() } catch {}
        do { _ = try await keys.downloadPrivateKey(id: "a&b"); XCTFail() } catch let e as APIKeyDownloadError {
            guard case .unreadable = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(mock.requests.count, 0)
    }

    func testListsEveryPageAndFillsServicesTheListingLeftOut() async throws {
        let (portal, mock) = makePortal { r in
            switch r.url!.lastPathComponent {
            case "list":
                let page = Int(formValue(r, "pageNumber") ?? "0")!
                return .json(200, AuthKeyFixtures.keys(page == 1 ? [AuthKeyFixtures.key("K1", "Push")]
                                                                 : [AuthKeyFixtures.key("K2", "Check", services: nil), AuthKeyFixtures.key("K3", "Music", services: [])], total: 3))
            case "get":
                return formValue(r, "keyId") == "K2"
                    ? .json(200, AuthKeyFixtures.keys([AuthKeyFixtures.key("K2", "Check", services: ["DQ8HTZ7739"])]))
                    : .json(200, AuthKeyFixtures.keys([AuthKeyFixtures.key("K3", "Music", services: ["6A7HVUVQ3M"])]))
            default: return .init(status: 500)
            }
        }
        let keys = try await PortalAuthKeys(portal: portal).list()
        XCTAssertEqual(keys.map(\.id), ["K1", "K2", "K3"])
        XCTAssertEqual(keys.map(\.name), ["Push", "Check", "Music"])
        XCTAssertEqual(keys.map(\.serviceKinds), [[.apns], [.deviceCheck], [.musicKit]])
        XCTAssertEqual(mock.requests.first?.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/auth/key/list")
        XCTAssertEqual(formValue(mock.requests[0], "teamId"), "ABCDE12345")
        XCTAssertEqual(formValue(mock.requests[0], "pageSize"), "500")
        XCTAssertEqual(formValue(mock.requests[0], "sort"), "name=asc")
        XCTAssertEqual(mock.requests.map { $0.url!.lastPathComponent }, ["list", "list", "get", "get"])
    }

    func testGetsOneKeyWithItsSignInWithAppleBundles() async throws {
        let (portal, _) = makePortal { _ in
            .json(200, AuthKeyFixtures.keys([AuthKeyFixtures.key("K1", "Login", services: ["APPLE_ID_AUTH_KEY_CONFIGURATION"], bundles: ["B1"])]))
        }
        let key = try await PortalAuthKeys(portal: portal).get(id: "K1")
        XCTAssertEqual(key.services?.first?.bundleIDs, ["B1"])
        XCTAssertEqual(key.serviceKinds, [.signInWithApple])
        XCTAssertTrue(key.canRevoke)
    }

    func testAGetForAnotherKeyIsRefused() async throws {
        let (portal, _) = makePortal { _ in .json(200, AuthKeyFixtures.keys([])) }
        do { _ = try await PortalAuthKeys(portal: portal).get(id: "K9"); XCTFail() } catch let e as XlessError {
            XCTAssertEqual(e.cause, "the team has no auth key K9")
            XCTAssertTrue(e.fix.contains("xless keys list"))
        }
    }

    func testCreatesOnceWithTheServiceRequestsAfterPrimingTheKeysCSRF() async throws {
        let (portal, mock) = makePortal { r in
            switch r.url!.lastPathComponent {
            case "list": return .json(200, AuthKeyFixtures.keys([]), headers: ["csrf": "k", "csrf_ts": "9"])
            case "create": return .json(200, AuthKeyFixtures.keys([AuthKeyFixtures.key("NEW1", "Push", services: ["U27F4V844T", "APPLE_ID_AUTH_KEY_CONFIGURATION"],
                                                                                         canDownload: true, bundles: ["B1"])]))
            default: return .init(status: 500)
            }
        }
        let key = try await PortalAuthKeys(portal: portal).create(name: "Push", services: [.apns, .signInWithApple], bundleIDs: ["B1"])
        XCTAssertEqual(key.id, "NEW1")
        XCTAssertTrue(key.canDownload)
        let create = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(create.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/auth/key/v2/create")
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.header("Content-Type"), "application/json")
        XCTAssertEqual(create.header("csrf"), "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.httpBody!) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Push")
        XCTAssertEqual(body["teamId"] as? String, "ABCDE12345")
        let requests = try XCTUnwrap(body["serviceConfigurationsRequests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["serviceId"] as? String, "U27F4V844T")
        XCTAssertEqual(requests[0]["isNew"] as? Bool, true)
        XCTAssertEqual(requests[0]["environment"] as? String, "all")
        XCTAssertEqual(requests[0]["scope"] as? String, "team")
        XCTAssertEqual((requests[0]["identifiers"] as? [String: Any])?.count, 0)
        XCTAssertEqual(requests[1]["serviceId"] as? String, "APPLE_ID_AUTH_KEY_CONFIGURATION")
        XCTAssertEqual((requests[1]["identifiers"] as? [String: Any])?["bundle"] as? [String], ["B1"])
        XCTAssertEqual(mock.requests.filter { $0.url!.lastPathComponent == "create" }.count, 1)
    }

    func testAMusicKitRequestNamesItsMusicIDs() {
        let r = AuthKeyService.musicKit.request(bundleIDs: [], musicIDs: ["M1"])
        XCTAssertEqual(r["serviceId"] as? String, "6A7HVUVQ3M")
        XCTAssertEqual((r["identifiers"] as? [String: Any])?["music"] as? [String], ["M1"])
        XCTAssertEqual((AuthKeyService.deviceCheck.request(bundleIDs: [])["identifiers"] as? [String: Any])?.count, 0)
    }

    func testACreateWithoutAnAnswerSaysAKeyMayExistAndIsNotRetried() async throws {
        struct Cut: Error {}
        let (portal, mock) = makePortal { r in
            if r.url!.lastPathComponent == "create" { throw Cut() }
            return .json(200, AuthKeyFixtures.keys([]))
        }
        do { _ = try await PortalAuthKeys(portal: portal).create(name: "Push", services: [.apns], bundleIDs: []); XCTFail() } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("got no answer"), e.cause)
            XCTAssertTrue(e.fix.contains("xless keys list"), e.fix)
        }
        XCTAssertEqual(mock.requests.filter { $0.url!.lastPathComponent == "create" }.count, 1)
    }

    func testACreateAnswerThatNamesNoKeySaysToCheckTheList() async throws {
        let (portal, _) = makePortal { r in
            r.url!.lastPathComponent == "create" ? .json(200, ["resultCode": 0, "keys": [] as [Any]]) : .json(200, AuthKeyFixtures.keys([]))
        }
        do { _ = try await PortalAuthKeys(portal: portal).create(name: "Push", services: [.apns], bundleIDs: []); XCTFail() } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("names no key"), e.cause)
            XCTAssertTrue(e.fix.contains("xless keys list"), e.fix)
        }
    }

    func testAServerErrorOnCreateIsAnUnknownOutcome() async throws {
        let (portal, _) = makePortal { r in
            r.url!.lastPathComponent == "create" ? .init(status: 502) : .json(200, AuthKeyFixtures.keys([]))
        }
        do { _ = try await PortalAuthKeys(portal: portal).create(name: "Push", services: [.apns], bundleIDs: []); XCTFail() } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("HTTP 502"), e.cause)
            XCTAssertTrue(e.fix.contains("may have been created"), e.fix)
        }
    }

    func testARefusedCreateSaysWhatApplesSaid() async throws {
        let (portal, _) = makePortal { r in
            r.url!.lastPathComponent == "create"
                ? .json(200, ["resultCode": 9401, "userString": "You have already reached the maximum allowed number of Keys for this service."])
                : .json(200, AuthKeyFixtures.keys([]))
        }
        do { _ = try await PortalAuthKeys(portal: portal).create(name: "Push", services: [.apns], bundleIDs: []); XCTFail() } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("maximum allowed number of Keys"), e.cause)
        }
    }

    func testDownloadsThePrivateKeyOnceAsAP256PEM() async throws {
        let (portal, mock) = makePortal { _ in MockTransport.Reply(status: 200, headers: ["Content-Type": "text/plain"], body: Data(p8.utf8)) }
        let secret = try await PortalAuthKeys(portal: portal).downloadPrivateKey(id: "NEW1")
        XCTAssertEqual(secret.utf8String(), p8)
        XCTAssertEqual(mock.requests.count, 1)
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/auth/key/download?teamId=ABCDE12345&keyId=NEW1")
        XCTAssertNil(r.httpBody)
    }

    func testADownloadThatIsNotAKeyIsUnreadableAndNotRetried() async throws {
        for body in ["<html>Sign in</html>", "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"] {
            let (portal, mock) = makePortal { _ in MockTransport.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data(body.utf8)) }
            do { _ = try await PortalAuthKeys(portal: portal).downloadPrivateKey(id: "NEW1"); XCTFail() } catch let e as APIKeyDownloadError {
                guard case .unreadable = e else { return XCTFail("\(e)") }
            }
            XCTAssertEqual(mock.requests.count, 1)
        }
    }

    func testARefusedDownloadSaysApplesWords() async throws {
        let (portal, _) = makePortal { _ in .json(200, ["resultCode": 1100, "userString": "This key has already been downloaded."]) }
        do { _ = try await PortalAuthKeys(portal: portal).downloadPrivateKey(id: "NEW1"); XCTFail() } catch let e as APIKeyDownloadError {
            XCTAssertEqual(e, .refused(status: 200, message: "This key has already been downloaded."))
        }
        let (portal404, _) = makePortal { _ in .init(status: 404) }
        do { _ = try await PortalAuthKeys(portal: portal404).downloadPrivateKey(id: "NEW1"); XCTFail() } catch let e as APIKeyDownloadError {
            XCTAssertEqual(e, .refused(status: 404, message: nil))
        }
    }

    func testADownloadWithoutAnAnswerIsNoAnswer() async throws {
        struct Cut: Error {}
        let (portal, mock) = makePortal { _ in throw Cut() }
        do { _ = try await PortalAuthKeys(portal: portal).downloadPrivateKey(id: "NEW1"); XCTFail() } catch let e as APIKeyDownloadError {
            guard case .noAnswer = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testRevokesWithTheKeysCSRF() async throws {
        let (portal, mock) = makePortal { r in
            r.url!.lastPathComponent == "list" ? .json(200, AuthKeyFixtures.keys([]), headers: ["csrf": "k", "csrf_ts": "9"]) : .json(200, ["resultCode": 0])
        }
        try await PortalAuthKeys(portal: portal).revoke(id: "K1")
        let revoke = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(revoke.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/auth/key/revoke")
        XCTAssertEqual(formValue(revoke, "keyId"), "K1")
        XCTAssertEqual(formValue(revoke, "teamId"), "ABCDE12345")
        XCTAssertEqual(revoke.header("csrf"), "k")
    }
}
