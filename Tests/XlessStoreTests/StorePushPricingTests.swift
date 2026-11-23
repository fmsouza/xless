import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

// The `pricing` part of `store push`: the price schedule and availability, against the routed fake App Store Connect.

private func pulled(_ routes: [String: (Int, String)]) async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    return (root, dir)
}

private func client(_ t: HTTPTransport) -> ASCClient { ASCClient(credentials: storeCreds, transport: t, sleep: { _ in }) }
private func pusher(_ t: HTTPTransport) -> StorePush { StorePush(resources: ASCResources(client: client(t))) }
private func sender(_ t: HTTPTransport) -> StoreSender { StoreSender(client: client(t), secret: { _ in "" }) }
private let pricingOnly = StorePush.Options(parts: [.pricing], today: today)

private func writes(_ t: RoutedTransport) -> [String] {
    t.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
}
private func json(_ t: RoutedTransport, _ key: String) throws -> [String: Any] {
    let r = try #require(t.requests.first { "\($0.httpMethod!) \($0.url!.path)" == key })
    return try #require(r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
}

/// The fake app's price points in each territory (by the request's filter[territory]).
private func withPricePoints(_ routes: [String: (Int, String)]) -> RoutedTransport {
    let points: [String: [(String, String)]] = [
        "USA": [("P0", "0.0"), ("P1", "0.99"), ("P2", "1.29"), ("PP2", "1.99"), ("PP3", "2.99")],
        "JPN": [("J0", "0.0"), ("PJ1", "300"), ("J2", "400")],
        "GBR": [("G0", "0.0"), ("G1", "0.99")],
    ]
    let t = RoutedTransport(routes)
    t.onRequest = { request, t in
        guard request.url!.path == "/v1/apps/123/appPricePoints" else { return }
        let territory = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[territory]" }?.value ?? ""
        let items = (points[territory] ?? []).map {
            #"{"type":"appPricePoints","id":"\#($0.0)","attributes":{"customerPrice":"\#($0.1)"},"relationships":{"territory":{"data":{"type":"territories","id":"\#(territory)"}}}}"#
        }
        t.routes["/v1/apps/123/appPricePoints"] = (200, list(items))
    }
    return t
}

/// The included appPrices of a schedule POST: "territory? start → point" per price, in order.
private func prices(_ body: [String: Any]) -> [String] {
    ((body["included"] as? [[String: Any]]) ?? []).map { item in
        let start = (item["attributes"] as? [String: Any])?["startDate"]
        let point = (((item["relationships"] as? [String: Any])?["appPricePoint"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
        return "\((start as? String) ?? "now") \(point ?? "?")"
    }
}

@Test func aPulledScheduleWithChangesAndManualPricesPushesNothing() async throws {
    let (root, dir) = try await pulled(scheduledPricing())
    defer { try? FileManager.default.removeItem(at: root) }
    let t = withPricePoints(scheduledPricing())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: ManifestReader.read(dir).manifest, dir: dir, options: pricingOnly)
    #expect(plan.changes.isEmpty && plan.notes.isEmpty)
    #expect(!t.requests.contains { $0.url!.path.hasSuffix("appPricePoints") }, "nothing to send: no price point is looked up")
}

@Test func aNewAppGetsAFreeScheduleAndIsAvailableEverywhere() async throws {
    var routes = fakeApp()
    routes["/v1/apps/123/appPriceSchedule"] = nil
    routes["/v1/apps/123/appAvailabilityV2"] = nil
    var m = StoreManifest(app: AppYAML())
    m.app.version = "1.1"
    m.app.pricing = AppYAML.Pricing(baseTerritory: "USA", price: "free")
    m.app.availability = AppYAML.Availability(territories: .all)
    let t = withPricePoints(routes)
    let push = pusher(t)
    let dir = URL(fileURLWithPath: "/nonexistent/appstore")
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(report.planText == """
        com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION):
          + price schedule
              baseTerritory: "USA"
              price: "free"
          + availability
              territories: "all"
              newTerritories: "true"
        2 changes: 2 to create

        """)
    try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly, sender: sender(t))
    #expect(writes(t) == ["POST /v1/appPriceSchedules", "POST /v2/appAvailabilities"])

    let schedule = try json(t, "POST /v1/appPriceSchedules")
    let data = try #require(schedule["data"] as? [String: Any])
    let relationships = try #require(data["relationships"] as? [String: Any])
    #expect(data["type"] as? String == "appPriceSchedules")
    #expect((relationships["app"] as? [String: Any])?["data"] as? [String: String] == ["type": "apps", "id": "123"])
    #expect((relationships["baseTerritory"] as? [String: Any])?["data"] as? [String: String] == ["type": "territories", "id": "USA"])
    #expect((relationships["manualPrices"] as? [String: Any])?["data"] as? [[String: String]] == [["type": "appPrices", "id": "${price-1}"]])
    #expect(prices(schedule) == ["now P0"])
    let included = try #require((schedule["included"] as? [[String: Any]])?.first)
    #expect(included["id"] as? String == "${price-1}" && included["type"] as? String == "appPrices")
    #expect((included["attributes"] as? [String: Any])?["startDate"] is NSNull, "the current price starts now")

    let availability = try json(t, "POST /v2/appAvailabilities")
    let av = try #require(availability["data"] as? [String: Any])
    #expect((av["attributes"] as? [String: Bool]) == ["availableInNewTerritories": true])
    let linked = (((av["relationships"] as? [String: Any])?["territoryAvailabilities"] as? [String: Any])?["data"] as? [[String: String]])?.map { $0["id"]! }
    #expect(linked == ["${CAN}", "${GBR}", "${USA}"])
    let entries = try #require(availability["included"] as? [[String: Any]])
    #expect(entries.map { ($0["attributes"] as? [String: Bool])?["available"] } == [true, true, true])
    #expect(entries.map { (((($0["relationships"] as? [String: Any])?["territory"] as? [String: Any])?["data"]) as? [String: String])?["id"] } == ["CAN", "GBR", "USA"])
}

@Test func aNewAvailabilityInSomeTerritoriesIsNotAddedToNewOnes() async throws {
    var routes = fakeApp()
    routes["/v1/apps/123/appAvailabilityV2"] = (200, single(nil))
    var m = StoreManifest(app: AppYAML())
    m.app.version = "1.1"
    m.app.availability = AppYAML.Availability(territories: .only(["USA"]))
    let t = RoutedTransport(routes)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: URL(fileURLWithPath: "/x/appstore"), options: pricingOnly)
    #expect(plan.changes.map(\.text) == ["+ availability\n    territories: \"USA\"\n    newTerritories: \"false\""])
    let body = plan.changes[0].requests[0].body
    #expect(body?["included"]?[0]?["attributes"]?["available"] == .bool(false), "CAN is listed, unavailable")
    #expect(body?["included"]?[2]?["attributes"]?["available"] == .bool(true))
}

@Test func aNewPriceKeepsManualPricesAndChangesTheManifestDoesNotManage() async throws {
    let (root, dir) = try await pulled(scheduledPricing())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing?.price = "0.99"
    m.app.pricing?.territories = nil
    m.app.pricing?.changes = nil
    let t = withPricePoints(scheduledPricing())
    let push = pusher(t)
    let (plan, _) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.map(\.text) == [#"~ price schedule: price: "1.99" → "0.99""#])
    #expect(t.queries("/v1/apps/123/appPricePoints") == [["filter[territory]=USA", "fields[territories]=currency", "include=territory", "limit=200"]],
            "only the new price is looked up")
    try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly, sender: sender(t))
    let gbr = Data(#"{"s":"123","t":"GBR","p":"10001"}"#.utf8).base64EncodedString()
    #expect(prices(try json(t, "POST /v1/appPriceSchedules")) == ["now P1", "now PJ1", "2026-12-24 \(gbr)", "2027-01-01 PP3"])
}

@Test func managedTerritoriesAndChangesReplaceAppStoreConnects() async throws {
    let (root, dir) = try await pulled(scheduledPricing())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing?.territories = ["JPN": "400"]
    m.app.pricing?.changes = []
    let t = withPricePoints(scheduledPricing())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.map(\.text) == ["""
        ~ price schedule
            price JPN: "300" → "400"
            price GBR from 2026-12-24: "free" → (none)
            price from 2027-01-01: "2.99" → (none)
        """])
    #expect(prices(plan.changes[0].requests[0].body.map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as! [String: Any] } ?? [:])
            == ["now PP2", "now J2"], "the base price keeps its point; JPN's is looked up")
}

@Test func aChangeWhoseDayHasComeIsTheCurrentPrice() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing?.price = "0.99"
    m.app.pricing?.changes = [.init(date: "2026-11-01", price: "1.99")]
    let t = withPricePoints(fakeApp())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.isEmpty, "1.99 since 2026-11-01 is what App Store Connect has")
    #expect(plan.notes == ["pricing.changes: the change of 2026-11-01 (USA 1.99) is in effect; `xless store pull` rewrites pricing"])
}

@Test func aPriceThatIsNoPricePointFailsBeforeAnythingIsSent() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing?.price = "1.00"
    let t = withPricePoints(fakeApp())
    await #expect(throws: XlessError(.account, "1.00 is not a price point in USA; the nearest are 0.99 and 1.29",
                                     fix: "use one of them (`xless apps price-points com.example.app --territory USA` lists every price point)")) {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    }
    m.app.pricing = AppYAML.Pricing(baseTerritory: "GBR")
    await #expect(throws: XlessError(.account, "pricing.baseTerritory changes to GBR, but pricing has no price there",
                                     fix: "add `price:` in GBR's currency (`xless apps price-points com.example.app --territory GBR`)")) {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    }
    #expect(writes(t).isEmpty)
}

@Test func availabilityChangesOnlyTheTerritoriesThatDiffer() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.availability = AppYAML.Availability(territories: .all, newTerritories: true)
    let t = RoutedTransport(fakeApp())
    let push = pusher(t)
    let (plan, _) = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.map(\.text) == [#"~ availability: now available in: "GBR""#])
    #expect(plan.deletes.isEmpty, "making the app available asks nothing")
    #expect(plan.notes == ["availability.newTerritories is true, App Store Connect has false: its API sets it only when the availability is created, so it is not sent"])
    try await push.apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly, sender: sender(t))
    #expect(writes(t) == ["PATCH /v1/territoryAvailabilities/T2"])
    #expect(try json(t, "PATCH /v1/territoryAvailabilities/T2")["data"] as? NSDictionary
            == ["type": "territoryAvailabilities", "id": "T2", "attributes": ["available": true]] as NSDictionary)

    m.app.availability = AppYAML.Availability(territories: .only(["USA", "XKX"]))
    await #expect(throws: XlessError(.account, "availability.territories: App Store Connect has no territory XKX for the app",
                                     fix: "use App Store Connect's three-letter codes (`xless api GET /v1/territories` lists them)")) {
        _ = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    }
}

@Test func pricingNeedsNoVersionSoItCanBePushedBeforeOneExists() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    var routes = fakeApp()
    routes["/v1/apps/123/appStoreVersions"] = (200, list([
        #"{"type":"appStoreVersions","id":"V1","attributes":{"platform":"IOS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","appStoreState":"READY_FOR_SALE"}}"#,
    ]))
    m.app.version = "1.2"
    m.app.pricing?.price = "0.99"
    let t = withPricePoints(routes)
    let (plan, report) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(report.versionState == "new")
    #expect(plan.changes.map(\.subject) == ["price schedule"])
    await #expect(throws: XlessError.self, "media still needs the version") {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.pricing, .media], today: today))
    }
}

@Test func pricingIsAPartOfPush() throws {
    #expect(try StorePushPart.parse(["pricing,text"]) == [.text, .pricing])
    #expect(StorePushPart.allCases == [.text, .review, .declarations, .pricing, .media])
}

@Test func takingTheAppOffSaleSomewhereIsADeletionThatAsks() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.availability = AppYAML.Availability(territories: .only(["USA", "GBR"]))
    let (plan, _) = try await pusher(RoutedTransport(fakeApp())).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.map(\.text) == [#"~ availability: now available in: "GBR""#, "- availability in CAN"])
    #expect(plan.deletes.map(\.subject) == ["availability in CAN"])
    #expect(plan.deletes[0].requests == [.update("territoryAvailabilities", id: "T3", attributes: ["available": .bool(false)])])
}

@Test func aNewBaseTerritoryLetsTheOldOneFollowIt() async throws {
    let (root, dir) = try await pulled(scheduledPricing())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing = AppYAML.Pricing(baseTerritory: "GBR", price: "0.99")
    let t = withPricePoints(scheduledPricing())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    #expect(plan.changes.map(\.text) == ["""
        ~ price schedule
            baseTerritory: "USA" → "GBR"
            price: "0.99"
            price USA: "1.99" → (none)
            price USA from 2027-01-01: "2.99" → (none)
        """])
    let body = try #require(plan.changes[0].requests[0].body)
    #expect(prices(try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])) == ["now G1", "now PJ1", "2026-12-24 \(Data(#"{"s":"123","t":"GBR","p":"10001"}"#.utf8).base64EncodedString())"],
            "JPN's manual price and GBR's change stay; the old base's prices go, it follows GBR")
}

@Test func twoPricesForOneDayStopThePush() async throws {
    let (root, dir) = try await pulled(fakeApp())
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    m.app.pricing?.changes = [.init(date: "2027-01-01", price: "1.99"), .init(date: "2027-01-01", territory: "USA", price: "2.99")]
    await #expect(throws: XlessError(.account, "pricing has two prices for USA from 2027-01-01", fix: "keep one (a change without territory is for the base territory, USA)")) {
        _ = try await pusher(withPricePoints(fakeApp())).plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly)
    }
}

@Test func aScheduleWithPricesXlessCannotReadIsNeverReplaced() async throws {
    var routes = fakeApp()
    routes["/v1/appPriceSchedules/PR1/manualPrices"] = (200, list([
        #"{"type":"appPrices","id":"AP2","attributes":{"startDate":"2026-01-01","endDate":null},"relationships":{"appPricePoint":{"data":{"type":"appPricePoints","id":"PP2"}}}}"#,
        #"{"type":"appPrices","id":"AP9","attributes":{"startDate":null,"endDate":null},"relationships":{"appPricePoint":{"data":{"type":"appPricePoints","id":"MISSING"}}}}"#,
    ], included: [#"{"type":"appPricePoints","id":"PP2","attributes":{"customerPrice":"1.99"}}"#]))
    let (root, dir) = try await pulled(routes)
    defer { try? FileManager.default.removeItem(at: root) }
    var m = ManifestReader.read(dir).manifest
    #expect(m.app.pricing?.price == "1.99")
    m.app.pricing?.price = "0.99"
    let notes = Notes()
    let push = StorePush(resources: ASCResources(client: client(withPricePoints(routes))), say: { notes.say($0) })
    await #expect(throws: XlessError.self) { _ = try await push.plan(app: fakeASCApp, manifest: m, dir: dir, options: pricingOnly) }
    #expect(notes.lines == ["note: 1 price of the price schedule came without its price point; they are left out"])
}
