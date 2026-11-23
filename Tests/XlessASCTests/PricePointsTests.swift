import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func points(_ t: MockTransport) -> ASCPricePoints {
    ASCPricePoints(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func query(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}

/// A price point as App Store Connect returns it (GET /v1/apps/{id}/appPricePoints).
func pricePointJSON(_ id: String, _ price: String, proceeds: String = "0.0", territory: String = "USA") -> String {
    #"{"type":"appPricePoints","id":"\#(id)","attributes":{"customerPrice":"\#(price)","proceeds":"\#(proceeds)"},"relationships":{"territory":{"data":{"type":"territories","id":"\#(territory)"}}}}"#
}
private func territoryJSON(_ id: String, _ currency: String) -> String { #"{"type":"territories","id":"\#(id)","attributes":{"currency":"\#(currency)"}}"# }
private func page(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}

private let ladder = [("P0", "0.0"), ("P1", "0.99"), ("P2", "1.29"), ("P3", "1.99")].map {
    ASCPricePoint(id: $0.0, territory: "USA", currency: "USD", customerPrice: $0.1, proceeds: nil)
}

@Test func customerPricesAreDecimalsAndFreeIsZero() {
    #expect(CustomerPrice.parse("free") == 0 && CustomerPrice.parse("0.0") == 0)
    #expect(CustomerPrice.parse("0.990") == CustomerPrice.parse("0.99"))
    #expect(CustomerPrice.parse("1,99") == nil && CustomerPrice.parse("$1") == nil && CustomerPrice.parse("") == nil && CustomerPrice.parse("-1") == nil)
    #expect(CustomerPrice.display("0.0") == "free" && CustomerPrice.display("0.99") == "0.99")
}

@Test func aPriceResolvesToTheExactPointOnly() throws {
    #expect(try ASCPricePoints.resolve("0.99", in: ladder, territory: "USA", app: "com.example.app").id == "P1")
    #expect(try ASCPricePoints.resolve("0.990", in: ladder, territory: "USA", app: "com.example.app").id == "P1")
    #expect(try ASCPricePoints.resolve("free", in: ladder, territory: "USA", app: "com.example.app").id == "P0")
    #expect(try ASCPricePoints.resolve("0", in: ladder, territory: "USA", app: "com.example.app").id == "P0")
}

@Test func aMissNamesTheNearestPoints() {
    func failure(_ price: String, _ list: [ASCPricePoint] = ladder) -> XlessError? {
        do { _ = try ASCPricePoints.resolve(price, in: list, territory: "USA", app: "com.example.app"); return nil } catch { return error as? XlessError }
    }
    let between = failure("1.00")
    #expect(between?.stage == .account)
    #expect(between?.cause == "1.00 is not a price point in USA; the nearest are 0.99 and 1.29")
    #expect(between?.fix == "use one of them (`xless apps price-points com.example.app --territory USA` lists every price point)")
    #expect(failure("5")?.cause == "5 is not a price point in USA; the nearest is 1.99")
    #expect(failure("1.5")?.cause == "1.5 is not a price point in USA; the nearest are 1.29 and 1.99")
    #expect(failure("0.99", [])?.cause == "App Store Connect lists no price point in USA for this app")
    #expect(failure("cheap")?.cause == "cheap is not a price: write `free` or the customer price, e.g. 0.99")
}

@Test func listReadsEveryPageSortedWithTheTerritorysCurrency() async throws {
    let t = MockTransport([
        (200, #"{"data":[\#(pricePointJSON("P2", "1.29", proceeds: "0.91")),\#(pricePointJSON("P0", "0.0"))],"included":[\#(territoryJSON("USA", "USD"))],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/apps/123/appPricePoints?cursor=2"}}"#),
        (200, page([pricePointJSON("P1", "0.99", proceeds: "0.7")])),
    ])
    let list = try await points(t).list(app: "123", territory: "USA")
    #expect(list.map(\.id) == ["P0", "P1", "P2"])
    #expect(list.allSatisfy { $0.territory == "USA" && $0.currency == "USD" })
    #expect(list[2].proceeds == "0.91")
    #expect(t.requests[0].url!.path == "/v1/apps/123/appPricePoints")
    #expect(query(t.requests[0]) == ["filter[territory]=USA", "fields[territories]=currency", "include=territory", "limit=200"])
}

@Test func equalizationsAreThePointInEveryOtherTerritory() async throws {
    let t = MockTransport([(200, page([pricePointJSON("Q2", "150", territory: "JPN"), pricePointJSON("Q1", "0.99", territory: "GBR")],
                                      included: [territoryJSON("JPN", "JPY"), territoryJSON("GBR", "GBP")]))])
    let list = try await points(t).equalizations(of: "P1")
    #expect(list.map { "\($0.territory) \($0.currency ?? "") \($0.customerPrice)" } == ["GBR GBP 0.99", "JPN JPY 150"])
    #expect(t.requests[0].url!.path == "/v3/appPricePoints/P1/equalizations")
    #expect(query(t.requests[0]) == ["fields[territories]=currency", "include=territory", "limit=200"])
}
