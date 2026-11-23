import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func release(_ t: MockTransport) -> ASCRelease {
    ASCRelease(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func call(_ r: URLRequest) -> String { r.httpMethod! + " " + r.url!.path }
private func q(_ r: URLRequest, _ name: String) -> String? {
    URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

let releaseNow = ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!

@Test func releaseChoicesParse() throws {
    #expect(try ReleaseChoice.parse("manual") == .manual)
    #expect(try ReleaseChoice.parse("AUTO") == .afterApproval)
    #expect(try ReleaseChoice.parse("after-approval") == .afterApproval)
    #expect(try ReleaseChoice.parse("2026-12-01", now: releaseNow) == .scheduled("2026-12-01T00:00:00Z"))
    #expect(try ReleaseChoice.parse("2026-12-01T10:00+01:00", now: releaseNow) == .scheduled("2026-12-01T09:00:00Z"))
    #expect(try ReleaseChoice.parse("2026-12-01T09:00:00Z", now: releaseNow).releaseType == "SCHEDULED")
    #expect(throws: IdentifierInputError.self) { try ReleaseChoice.parse("2026-11-01", now: releaseNow) }          // past
    #expect(throws: IdentifierInputError.self) { try ReleaseChoice.parse("2026-12-01T09:30:00Z", now: releaseNow) } // not on the hour
    #expect(throws: IdentifierInputError.self) { try ReleaseChoice.parse("2026-02-30", now: releaseNow) }
    #expect(throws: IdentifierInputError.self) { try ReleaseChoice.parse("soon", now: releaseNow) }
}

@Test func aReleaseChoiceMatchesTheSameInstantWrittenOtherwise() {
    var v = ASCAppStoreVersionAttributes()
    v.releaseType = "SCHEDULED"
    v.earliestReleaseDate = "2026-12-01T09:00:00.000+00:00"
    #expect(ReleaseChoice.scheduled("2026-12-01T09:00:00Z").matches(v))
    #expect(!ReleaseChoice.scheduled("2026-12-01T10:00:00Z").matches(v))
    #expect(!ReleaseChoice.manual.matches(v))
    v.releaseType = "MANUAL"
    #expect(ReleaseChoice.manual.matches(v))
    #expect(ReleaseChoice.display(type: "AFTER_APPROVAL", date: nil) == "after approval")
}

private let versionJSON = #"{"type":"appStoreVersions","id":"V9","attributes":{"platform":"IOS","versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION"}}"#

@Test func createsAVersionAndAttachesABuild() async throws {
    let t = MockTransport([(201, #"{"data":\#(versionJSON)}"#), (204, "")])
    let r = release(t)
    let v = try await r.createVersion(app: "123", platform: "IOS", versionString: "1.2")
    #expect(v.id == "V9" && v.state == "PREPARE_FOR_SUBMISSION" && v.display == "1.2 (ios)")
    try await r.attach(build: "B1", to: "V9")
    #expect(t.requests.map(call) == ["POST /v1/appStoreVersions", "PATCH /v1/appStoreVersions/V9/relationships/build"])
    let created = try body(t.requests[0])
    #expect(created["data"]?["attributes"]?["versionString"]?.string == "1.2")
    #expect(created["data"]?["relationships"]?["app"]?["data"]?["id"]?.string == "123")
    #expect(try body(t.requests[1])["data"]?["id"]?.string == "B1")
}

@Test func submissionsAreReadWithTheirVersionAndSubmitted() async throws {
    let submissions = #"{"data":[{"type":"reviewSubmissions","id":"S1","attributes":{"platform":"IOS","state":"COMPLETE","submittedDate":"2026-01-01T00:00:00Z"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V1"}}}},{"type":"reviewSubmissions","id":"S2","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"}}],"links":{"self":"x"}}"#
    let items = #"{"data":[{"type":"reviewSubmissionItems","id":"I1","attributes":{"state":"READY_FOR_REVIEW"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V2"}}}}],"links":{"self":"x"}}"#
    let t = MockTransport([(200, submissions), (200, items), (201, #"{"data":{"type":"reviewSubmissionItems","id":"I2"}}"#),
                           (200, #"{"data":{"type":"reviewSubmissions","id":"S2","attributes":{"state":"WAITING_FOR_REVIEW"}}}"#),
                           (200, #"{"data":{"type":"reviewSubmissions","id":"S2","attributes":{"state":"CANCELING"}}}"#),
                           (201, #"{"data":{"type":"appStoreVersionReleaseRequests","id":"RR1"}}"#)])
    let r = release(t)
    let found = try await r.submissions(app: "123", platform: "IOS")
    #expect(found.map(\.id) == ["S2", "S1"], "a draft (never submitted) comes first")
    #expect(found[1].versionID == "V1" && found[0].versionID == nil)
    #expect(q(t.requests[0], "filter[app]") == "123" && q(t.requests[0], "filter[platform]") == "IOS" && q(t.requests[0], "include") == "appStoreVersionForReview")
    #expect(try await r.items(of: "S2").first?.versionID == "V2")
    #expect(q(t.requests[1], "include") == "appStoreVersion")
    _ = try await r.addItem(version: "V2", to: "S2")
    #expect(try await r.submit("S2").state == "WAITING_FOR_REVIEW")
    #expect(try await r.cancel("S2").state == "CANCELING")
    try await r.requestRelease(version: "V2")
    #expect(t.requests.dropFirst(2).map(call) == ["POST /v1/reviewSubmissionItems", "PATCH /v1/reviewSubmissions/S2", "PATCH /v1/reviewSubmissions/S2",
                                                  "POST /v1/appStoreVersionReleaseRequests"])
    let item = try body(t.requests[2])["data"]?["relationships"]
    #expect(item?["reviewSubmission"]?["data"]?["id"]?.string == "S2" && item?["appStoreVersion"]?["data"]?["id"]?.string == "V2")
    #expect(try body(t.requests[3])["data"]?["attributes"]?["submitted"] == .bool(true))
    #expect(try body(t.requests[4])["data"]?["attributes"]?["canceled"] == .bool(true))
    #expect(try body(t.requests[5])["data"]?["relationships"]?["appStoreVersion"]?["data"]?["id"]?.string == "V2")
    #expect(t.requests.filter { $0.httpMethod == "POST" }.count == 2, "creates are sent once")
}

@Test func phasedReleasesAreReadCreatedAndMoved() async throws {
    let t = MockTransport([(200, #"{"data":null}"#), (201, #"{"data":{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"INACTIVE"}}}"#),
                           (200, #"{"data":{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"PAUSED"}}}"#),
                           (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"gone"}]}"#)])
    let r = release(t)
    #expect(try await r.phasedRelease(of: "V2") == nil)
    #expect(try await r.createPhasedRelease(on: "V2").state == "INACTIVE")
    #expect(try await r.setPhased("P1", state: "PAUSED").state == "PAUSED")
    try await r.deletePhasedRelease("P1")
    #expect(try body(t.requests[1])["data"]?["attributes"]?["phasedReleaseState"]?.string == "INACTIVE")
    #expect(try body(t.requests[2])["data"]?["attributes"]?["phasedReleaseState"]?.string == "PAUSED")
}

@Test func releaseTypeIsSetWithItsDate() async throws {
    let t = MockTransport([(200, #"{"data":\#(versionJSON)}"#)])
    _ = try await release(t).setRelease(.scheduled("2026-12-01T00:00:00Z"), on: "V9")
    let a = try body(t.requests[0])["data"]?["attributes"]
    #expect(a?["releaseType"]?.string == "SCHEDULED" && a?["earliestReleaseDate"]?.string == "2026-12-01T00:00:00Z")
}
