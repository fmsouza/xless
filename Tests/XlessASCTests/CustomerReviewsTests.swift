import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func reviews(_ t: MockTransport) -> ASCCustomerReviews {
    ASCCustomerReviews(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func queryItems(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}

/// A review as App Store Connect returns it (GET /v1/apps/{id}/customerReviews?include=response).
func customerReviewJSON(_ id: String, rating: Int = 2, title: String = "Crashes", body: String = "It crashes on launch.", response: String? = nil) -> String {
    let rel = response.map { #","relationships":{"response":{"data":{"type":"customerReviewResponses","id":"\#($0)"}}}"# } ?? #","relationships":{"response":{"links":{"self":"x"}}}"#
    return #"{"type":"customerReviews","id":"\#(id)","attributes":{"rating":\#(rating),"title":"\#(title)","body":"\#(body)","reviewerNickname":"ada","createdDate":"2026-11-20T08:00:00-08:00","territory":"USA"}\#(rel)}"#
}
func reviewResponseJSON(_ id: String, text: String = "Thanks, fixed in 1.2.", state: String = "PUBLISHED") -> String {
    #"{"type":"customerReviewResponses","id":"\#(id)","attributes":{"responseBody":"\#(text)","lastModifiedDate":"2026-11-21T08:00:00-08:00","state":"\#(state)"}}"#
}

@Test func reviewInputIsChecked() throws {
    #expect(try ReviewInput.ratings(["1,2", "2", "5"]) == [1, 2, 5])
    #expect(throws: IdentifierInputError.self) { try ReviewInput.ratings(["0"]) }
    #expect(throws: IdentifierInputError.self) { try ReviewInput.ratings(["six"]) }
    #expect(try ReviewInput.territories(["usa,FRA", "USA"]) == ["USA", "FRA"])
    #expect(throws: IdentifierInputError.self) { try ReviewInput.territories(["US"]) }
    #expect(try ReviewInput.response("  Thanks!\n") == "Thanks!")
    #expect(throws: IdentifierInputError.self) { try ReviewInput.response(" \n ") }
    #expect(throws: IdentifierInputError.self) { try ReviewInput.response(String(repeating: "a", count: ReviewInput.maxResponseLength + 1)) }
    #expect(try ReviewInput.response(String(repeating: "a", count: ReviewInput.maxResponseLength)).count == ReviewInput.maxResponseLength)
    #expect(ReviewInput.isReviewID("00000057-9d5b-1a03"))
    #expect(!ReviewInput.isReviewID("../v1/apps"))
}

@Test func theListingFiltersSortsAndIncludesResponses() async throws {
    let t = MockTransport([(200, #"{"data":[\#(customerReviewJSON("R1", response: "P1")),\#(customerReviewJSON("R2"))],"included":[\#(reviewResponseJSON("P1"))]}"#)])
    let listing = try await reviews(t).list(app: "123", filter: ReviewFilter(ratings: [1, 2], territories: ["USA", "FRA"], answered: false, sort: .lowest), maxItems: 50)
    #expect(t.requests[0].url?.path == "/v1/apps/123/customerReviews")
    #expect(queryItems(t.requests[0]) == ["filter[rating]=1,2", "filter[territory]=USA,FRA", "include=response", "sort=rating",
                                          "exists[publishedResponse]=false", "limit=50"])
    #expect(listing.items.map(\.id) == ["R1", "R2"])
    #expect(ASCCustomerReviews.response(of: listing.items[0], in: listing.included)?.text == "Thanks, fixed in 1.2.")
    #expect(ASCCustomerReviews.response(of: listing.items[1], in: listing.included) == nil)
    #expect(listing.items[0].stars == "2/5")
}

@Test func aResponseIsPostedOnceWithItsReview() async throws {
    let t = MockTransport([(500, "")])
    await #expect(throws: ASCError.self) { try await reviews(t).respond(to: "R1", text: "Thanks") }
    #expect(t.requests.count == 1) // never retried
    let ok = MockTransport([(201, #"{"data":\#(reviewResponseJSON("P9", text: "Thanks", state: "PENDING_PUBLISH"))}"#)])
    let response = try await reviews(ok).respond(to: "R1", text: "Thanks")
    #expect(response.state == "PENDING_PUBLISH")
    let body = try JSONDecoder().decode(JSONValue.self, from: ok.requests[0].httpBody ?? Data())
    #expect(body["data"]?["type"]?.string == "customerReviewResponses")
    #expect(body["data"]?["attributes"]?["responseBody"]?.string == "Thanks")
    #expect(body["data"]?["relationships"]?["review"]?["data"]?["id"]?.string == "R1")
    #expect(ok.requests[0].url?.path == "/v1/customerReviewResponses")
}

@Test func reviewRolesAreCustomerSupport() {
    #expect(ASCRoles.needed(path: "/v1/customerReviewResponses") == "Customer Support")
    #expect(ASCRoles.needed(path: "/v1/apps/123/customerReviews") == "Customer Support")
    #expect(ASCRoles.needed(path: "/v1/apps/123/appStoreVersions") == "App Manager")
    #expect(ASCRoles.needed(path: "/v1/salesReports") == "Sales")
}
