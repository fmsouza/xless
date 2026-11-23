import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func products(_ t: MockTransport) -> ASCProducts {
    ASCProducts(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func page(_ items: [String], included: [String] = [], next: String? = nil) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"\#(next.map { #","next":"\#($0)""# } ?? "")}}"#
}
private func iap(_ id: String, _ product: String) -> String {
    #"{"type":"inAppPurchases","id":"\#(id)","attributes":{"productId":"\#(product)","name":"N","inAppPurchaseType":"CONSUMABLE"}}"#
}

@Test func productIDsAreSafeAsFileNames() {
    #expect(ProductID.isProductID("com.example.coins_100-a"))
    for bad in ["", ".hidden", "..", "a/b", "a b", "coins!", String(repeating: "a", count: 101)] { #expect(!ProductID.isProductID(bad), "\(bad)") }
    #expect(InAppPurchaseType.parse("non-consumable") == "NON_CONSUMABLE" && InAppPurchaseType.parse("subscription") == nil)
}

@Test func inAppPurchasesAreReadOnEveryPageAndResolvedByProductIDOrID() async throws {
    let t = MockTransport([
        (200, page([iap("2", "com.example.b")], next: "https://api.appstoreconnect.apple.com/v1/apps/1/inAppPurchasesV2?cursor=x")),
        (200, page([iap("1", "com.example.a")])),
    ])
    let all = try await products(t).inAppPurchases(app: "1")
    #expect(all.map(\.attributes.productId) == ["com.example.a", "com.example.b"])
    #expect(t.requests.first?.url?.path == "/v1/apps/1/inAppPurchasesV2")

    let r = MockTransport([(200, page([iap("1", "com.example.a"), iap("2", "com.example.b")])), (200, page([iap("1", "com.example.a"), iap("2", "com.example.b")]))])
    #expect(try await products(r).resolveIAP("com.example.b", app: "1").id == "2")
    #expect(try await products(r).resolveIAP("1", app: "1").attributes.productId == "com.example.a")
}

@Test func aSubscriptionsCurrentPriceIsTheLatestStarted() {
    let prices = [
        ASCSubscriptionPrice(id: "a", territory: "USA", start: nil, customerPrice: "4.99", pointID: "P1"),
        ASCSubscriptionPrice(id: "b", territory: "USA", start: "2026-06-01", customerPrice: "5.99", pointID: "P2"),
        ASCSubscriptionPrice(id: "c", territory: "USA", start: "2027-01-01", customerPrice: "6.99", pointID: "P3"),
        ASCSubscriptionPrice(id: "d", territory: "GBR", start: "2027-01-01", customerPrice: "4.49", pointID: "G1"),
    ]
    let current = ASCSubscriptionPrice.current(prices, on: "2026-11-23")
    #expect(current["USA"]?.id == "b")
    #expect(current["GBR"] == nil, "a price that has not started is not current")
}

@Test func subscriptionPricesTakeTheirTerritoryAndPointFromTheIncludedPoint() async throws {
    let t = MockTransport([(200, page([
        #"{"type":"subscriptionPrices","id":"SP1","attributes":{"startDate":"2026-01-01","preserved":true},"relationships":{"subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"PP1"}}}}"#,
    ], included: [#"{"type":"subscriptionPricePoints","id":"PP1","attributes":{"customerPrice":"4.99"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#]))])
    let prices = try await products(t).subscriptionPrices("S1")
    #expect(prices == [ASCSubscriptionPrice(id: "SP1", territory: "USA", start: "2026-01-01", customerPrice: "4.99", pointID: "PP1", preserved: true)])
    let query = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "include" }?.value
    #expect(query == "territory,subscriptionPricePoint")
}

@Test func anAbsentScreenshotOrAvailabilityIsNil() async throws {
    let t = MockTransport([(404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"x"}]}"#), (200, #"{"data":null}"#)])
    #expect(try await products(t).iapScreenshot("1") == nil)
    #expect(try await products(t).subscriptionAvailability("1") == nil)
}

@Test func sandboxTestersArePickedByAccountOrID() throws {
    let testers = [ASCSandboxTester(resource: ASCAnyResource(type: "sandboxTesters", id: "T1", attributes: ["acAccountName": .string("a@example.com")]))]
    #expect(try ASCSandboxTesters.pick(["A@EXAMPLE.COM", "T1"], from: testers).map(\.id) == ["T1"])
    #expect(throws: XlessError.self) { try ASCSandboxTesters.pick(["b@example.com"], from: testers) }
}
