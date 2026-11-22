import Crypto
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class ASCAPIKeysTests: XCTestCase {
    let pem = P256.Signing.PrivateKey().pemRepresentation

    func keys(_ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (ASCAPIKeys, MockTransport) {
        let mock = MockTransport(handler)
        return (ASCAPIKeys(asc: ASCWebClient(web: AppleWebClient(transport: mock, stage: .account))), mock)
    }

    func json(_ r: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
    }

    func testCreatesAnAllAppsTeamKey() async throws {
        let (keys, mock) = keys { _ in
            .json(201, ["data": ["type": "apiKeys", "id": "2X9R4HXF34", "attributes": ["nickname": "ci", "roles": ["APP_MANAGER"], "canDownload": true, "isActive": true]]])
        }
        let key = try await keys.create(nickname: "ci", roles: ["APP_MANAGER"])
        XCTAssertEqual(key.id, "2X9R4HXF34")
        XCTAssertTrue(key.canDownload)
        XCTAssertEqual(key.roles, ["APP_MANAGER"])
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(mock.requests.count, 1)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://appstoreconnect.apple.com/iris/v1/apiKeys")
        XCTAssertEqual(r.bodyString, #"{"data":{"attributes":{"allAppsVisible":true,"keyType":"PUBLIC_API","nickname":"ci","roles":["APP_MANAGER"]},"type":"apiKeys"}}"#)
    }

    func testCreatesAKeyLimitedToSomeApps() async throws {
        let (keys, mock) = keys { _ in .json(201, ["data": ["type": "apiKeys", "id": "K1"]]) }
        _ = try await keys.create(nickname: "n", roles: ["DEVELOPER"], appIDs: ["123", "456"])
        let data = try XCTUnwrap(json(XCTUnwrap(mock.requests.first))["data"] as? [String: Any])
        XCTAssertEqual((data["attributes"] as? [String: Any])?["allAppsVisible"] as? Bool, false)
        let apps = try XCTUnwrap(((data["relationships"] as? [String: Any])?["visibleApps"] as? [String: Any])?["data"] as? [[String: String]])
        XCTAssertEqual(apps, [["type": "apps", "id": "123"], ["type": "apps", "id": "456"]])
    }

    func testAForbiddenCreateNamesTheAccountHolder() async throws {
        let (keys, mock) = keys { _ in .json(403, ["errors": [["status": "403", "code": "FORBIDDEN_ERROR", "title": "not allowed"]]]) }
        do { _ = try await keys.create(nickname: "n", roles: ["ADMIN"]); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("HTTP 403"), e.cause)
            XCTAssertTrue(e.fix.contains("Account Holder"), e.fix)
        }
        XCTAssertEqual(mock.requests.count, 1, "a create is never retried")
    }

    func testDownloadsTheBase64PEMOnce() async throws {
        let b64 = Data(pem.utf8).base64EncodedString()
        let (keys, mock) = keys { _ in .json(200, ["data": ["type": "apiKeys", "id": "2X9R4HXF34", "attributes": ["privateKey": b64]]]) }
        let secret = try await keys.downloadPrivateKey(id: "2X9R4HXF34")
        XCTAssertEqual(secret.utf8String(), pem)
        XCTAssertEqual(mock.requests.count, 1)
        let url = try XCTUnwrap(mock.requests.first?.url)
        XCTAssertEqual(url.path, "/iris/v1/apiKeys/2X9R4HXF34")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "fields[apiKeys]", value: "privateKey")])
    }

    func testAcceptsAPlainOrQuotedPEM() throws {
        for value in [pem, Data(try JSONEncoder().encode(pem)).base64EncodedString()] {
            let body = try JSONSerialization.data(withJSONObject: ["data": ["id": "K1", "attributes": ["privateKey": value]]])
            XCTAssertEqual(try ASCAPIKeys.privateKey(from: body, id: "K1").utf8String().trimmingCharacters(in: .whitespacesAndNewlines),
                           pem.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testADownloadThatFailsSaysHowAndIsNeverRetried() async throws {
        let cases: [(MockTransport.Reply, APIKeyDownloadError)] = [
            (.json(404, ["errors": [["title": "gone"]]]), .refused(status: 404, message: "gone")),
            (.json(200, ["data": ["id": "K1", "attributes": [:]]]), .unreadable("no private key")),
            (.json(200, ["data": ["id": "OTHER", "attributes": ["privateKey": pem]]]), .unreadable("a different key than the one created")),
            (.json(200, ["data": ["id": "K1", "attributes": ["privateKey": Data("not a key".utf8).base64EncodedString()]]]),
             .unreadable("something that is not a P-256 private key (.p8)")),
            (.json(500, [:]), .refused(status: 500, message: nil)),
        ]
        for (reply, expected) in cases {
            let (keys, mock) = keys { _ in reply }
            do { _ = try await keys.downloadPrivateKey(id: "K1"); XCTFail("expected \(expected)") } catch let e as APIKeyDownloadError {
                XCTAssertEqual(e, expected)
            }
            XCTAssertEqual(mock.requests.count, 1)
        }
        struct Cut: Error {}
        let (keys, mock) = keys { _ in throw Cut() }
        do { _ = try await keys.downloadPrivateKey(id: "K1"); XCTFail("expected an error") } catch let e as APIKeyDownloadError {
            guard case .noAnswer = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testAnRSAKeyIsNotAnAPIKey() throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["id": "K1", "attributes": ["privateKey": "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----"]]])
        XCTAssertThrowsError(try ASCAPIKeys.privateKey(from: body, id: "K1"))
    }

    func testListsKeysWithWhoCreatedThemAcrossPages() async throws {
        let (keys, mock) = keys { r in
            if r.url?.query?.contains("cursor=2") == true {
                return .json(200, ["data": [["type": "apiKeys", "id": "K2", "attributes": ["nickname": "old", "roles": ["ADMIN"], "isActive": false],
                                             "relationships": ["revokedBy": ["data": ["type": "actors", "id": "a2"]]]]],
                                   "included": [["type": "actors", "id": "a2", "attributes": ["userName": "admin@example.com"]]]])
            }
            return .json(200, ["data": [["type": "apiKeys", "id": "K1", "attributes": ["nickname": "ci", "roles": ["APP_MANAGER"], "isActive": true, "lastUsed": "2026-11-01"],
                                         "relationships": ["createdBy": ["data": ["type": "actors", "id": "a1"]], "provider": ["data": ["type": "contentProviders", "id": "iss-uuid"]]]]],
                               "included": [["type": "actors", "id": "a1", "attributes": ["firstName": "Jane", "lastName": "Doe"]]],
                               "links": ["next": "https://appstoreconnect.apple.com/iris/v1/apiKeys?cursor=2&include=createdBy"]])
        }
        let list = try await keys.list()
        XCTAssertEqual(list.map(\.id), ["K1", "K2"])
        XCTAssertEqual(list[0].createdBy, "Jane Doe")
        XCTAssertEqual(list[0].issuerID, "iss-uuid")
        XCTAssertEqual(list[0].lastUsed, "2026-11-01")
        XCTAssertEqual(list[1].revokedBy, "admin@example.com")
        XCTAssertFalse(list[1].isActive)
        XCTAssertEqual(mock.requests.count, 2)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(mock.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "include", value: "createdBy,revokedBy,provider")])
    }

    func testANextPageElsewhereIsRefused() async {
        let (keys, mock) = keys { _ in .json(200, ["data": [], "links": ["next": "https://evil.example/iris/v1/apiKeys?cursor=2"]]) }
        do { _ = try await keys.list(); XCTFail("expected an error") } catch {}
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testRevokesWithAPatch() async throws {
        let (keys, mock) = keys { _ in .json(200, ["data": ["type": "apiKeys", "id": "K1", "attributes": ["isActive": false]]]) }
        try await keys.revoke(id: "K1")
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.httpMethod, "PATCH")
        XCTAssertEqual(r.url?.path, "/iris/v1/apiKeys/K1")
        XCTAssertEqual(r.bodyString, #"{"data":{"attributes":{"isActive":false},"id":"K1","type":"apiKeys"}}"#)
    }

    func testKeyIDsAreCheckedBeforeAnyRequest() async {
        let (keys, mock) = keys { _ in .json(200, [:]) }
        for bad in ["", "k1", "K1/../x", "K 1"] {
            do { try await keys.revoke(id: bad); XCTFail(bad) } catch {}
            do { _ = try await keys.get(id: bad); XCTFail(bad) } catch {}
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testAMissingKeyIsNamed() async {
        let (keys, _) = keys { _ in .json(404, [:]) }
        do { _ = try await keys.get(id: "K9"); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("no API key K9"), e.cause)
        } catch { XCTFail("\(error)") }
    }

    func testTheSessionCarriesTheIssuerID() throws {
        let body = #"{"provider":{"providerId":7,"name":"Example","publicProviderId":"69a6de7e-0000-47e3-e053-5b8c7c11a4d1"},"availableProviders":[{"providerId":7,"name":"Example"}]}"#
        let s = try JSONDecoder().decode(OlympusSession.self, from: Data(body.utf8))
        XCTAssertEqual(s.provider?.publicProviderId, "69a6de7e-0000-47e3-e053-5b8c7c11a4d1")
        XCTAssertNil(s.providers.first?.publicProviderId)
    }
}
