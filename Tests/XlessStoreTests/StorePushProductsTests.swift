import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

// `store push --only iap,subscriptions` against the path-routed fake App Store Connect of StorePullTests.

private let productParts = StorePush.Options(parts: [.iap, .subscriptions], today: today)

/// The fake app pulled into a fresh `appstore/` (the caller removes `root`), with `files` written into it.
private func pulledWith(_ files: [String: String]) async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(fakeApp()), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    for (path, text) in files { try write(text, path, in: dir) }
    return (root, dir)
}

private func push(_ t: RoutedTransport, _ notes: Notes = Notes()) -> StorePush {
    StorePush(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })), say: { notes.say($0) })
}

private func json(_ r: URLRequest) -> [String: Any] { (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
private func data(_ r: URLRequest) -> [String: Any] { (json(r)["data"] as? [String: Any]) ?? [:] }

/// App Store Connect with the app's in-app purchase com.example.coins100 (reference name "Coins", en-US text, USA 0.99,
/// sold in USA and CAN) and no subscription group.
private func withCoins() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/inAppPurchasesV2"] = (200, list([
        #"{"type":"inAppPurchases","id":"IAP1","attributes":{"productId":"com.example.coins100","name":"Coins","inAppPurchaseType":"CONSUMABLE","state":"APPROVED","familySharable":false,"reviewNote":"Buy it from the Store tab."}}"#,
        #"{"type":"inAppPurchases","id":"IAP2","attributes":{"productId":"com.example.legacy","name":"Old","inAppPurchaseType":"NON_CONSUMABLE"}}"#,
    ]))
    routes["/v2/inAppPurchases/IAP1/inAppPurchaseLocalizations"] = (200, list([
        #"{"type":"inAppPurchaseLocalizations","id":"IL1","attributes":{"locale":"en-US","name":"100 Coins","description":"Coins."}}"#,
        #"{"type":"inAppPurchaseLocalizations","id":"IL2","attributes":{"locale":"fr-FR","name":"100 pièces"}}"#,
    ]))
    routes["/v2/inAppPurchases/IAP1/iapPriceSchedule"] = (200, single(#"{"type":"inAppPurchasePriceSchedules","id":"IPS1","relationships":{"baseTerritory":{"data":{"type":"territories","id":"USA"}}}}"#))
    routes["/v1/inAppPurchasePriceSchedules/IPS1/manualPrices"] = (200, list([
        #"{"type":"inAppPurchasePrices","id":"IPR1","attributes":{"startDate":null,"endDate":null},"relationships":{"inAppPurchasePricePoint":{"data":{"type":"inAppPurchasePricePoints","id":"IPP1"}},"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
    ], included: [#"{"type":"inAppPurchasePricePoints","id":"IPP1","attributes":{"customerPrice":"0.99"}}"#]))
    routes["/v2/inAppPurchases/IAP1/inAppPurchaseAvailability"] = (200, single(#"{"type":"inAppPurchaseAvailabilities","id":"IA1","attributes":{"availableInNewTerritories":true}}"#))
    routes["/v1/inAppPurchaseAvailabilities/IA1/availableTerritories"] = (200, list([#"{"type":"territories","id":"USA"}"#, #"{"type":"territories","id":"CAN"}"#]))
    routes["/v1/apps/123/subscriptionGroups"] = (200, list([]))
    return routes
}

@Test func anExistingInAppPurchaseIsUpdatedWhereItDiffers() async throws {
    let (root, dir) = try await pulledWith(["iap/com.example.coins100.yml": coinsYAML])
    defer { try? FileManager.default.removeItem(at: root) }
    try write(pngHeader(1242, 2208), "iap/com.example.coins100.png", in: dir)
    let t = RoutedTransport(withCoins())
    acceptUploads(t)
    let notes = Notes()
    let p = push(t, notes)
    let manifest = ManifestReader.read(dir).manifest
    let (plan, _) = try await p.plan(app: fakeASCApp, manifest: manifest, dir: dir, options: productParts)
    #expect(plan.changes.map(\.text) == [
        #"~ in-app purchase com.example.coins100: referenceName: "Coins" → "100 Coins""#,
        #"~ in-app purchase com.example.coins100 text en-US: description: "Coins." → "A pile of coins.""#,
        #"+ in-app purchase com.example.coins100 review screenshot: com.example.coins100.png: "upload""#,
        #"~ in-app purchase com.example.coins100 availability: now available in: "GBR""#,
    ])
    #expect(plan.notes.contains("in-app purchase com.example.coins100 has text in fr-FR at App Store Connect that appstore/iap/com.example.coins100.yml does not: kept (--prune deletes it)"))
    #expect(plan.notes.contains { $0.contains("in-app purchase com.example.legacy with no file in appstore/iap/: kept") })
    #expect(plan.changes.allSatisfy { $0.part == .iap })

    _ = try await p.apply(plan, app: fakeASCApp, manifest: manifest, dir: dir, options: productParts, sender: mediaSender(t))
    #expect(sent(t).filter { !$0.contains("ReviewScreenshots") && $0 != "PUT storage" }
        == ["PATCH /v2/inAppPurchases/IAP1", "PATCH /v1/inAppPurchaseLocalizations/IL1", "POST /v1/inAppPurchaseAvailabilities"])
    #expect(sent(t).contains("POST /v1/inAppPurchaseAppStoreReviewScreenshots") && sent(t).contains("PUT storage"))
    let reserve = try #require(t.requests.first { $0.url!.path == "/v1/inAppPurchaseAppStoreReviewScreenshots" && $0.httpMethod == "POST" })
    let rel = (data(reserve)["relationships"] as? [String: Any])?["inAppPurchaseV2"] as? [String: Any]
    #expect((rel?["data"] as? [String: Any])?["id"] as? String == "IAP1")
    let availability = try #require(t.requests.first { $0.url!.path == "/v1/inAppPurchaseAvailabilities" })
    let territories = (((data(availability)["relationships"] as? [String: Any])?["availableTerritories"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    #expect(territories == ["CAN", "GBR", "USA"])
    #expect((data(availability)["attributes"] as? [String: Any])?["availableInNewTerritories"] as? Bool == true)
    // Recorded in media.lock: the next push uploads nothing.
    #expect(MediaLock.read(dir).files["iap/com.example.coins100.png"] != nil)
}

@Test func aProductsTypeCannotChange() async throws {
    let (root, dir) = try await pulledWith(["iap/com.example.coins100.yml": coinsYAML.replacingOccurrences(of: "CONSUMABLE", with: "NON_CONSUMABLE")])
    defer { try? FileManager.default.removeItem(at: root) }
    try write(pngHeader(1242, 2208), "iap/com.example.coins100.png", in: dir)
    let t = RoutedTransport(withCoins())
    await #expect { try await push(t).plan(app: fakeASCApp, manifest: ManifestReader.read(dir).manifest, dir: dir, options: productParts) } throws: {
        ($0 as? XlessError)?.cause == "appstore/iap/com.example.coins100.yml says type NON_CONSUMABLE, App Store Connect has com.example.coins100 as CONSUMABLE: a product's type cannot change"
    }
}

@Test func newProductsAreCreatedThenPlannedAgainRoundByRound() async throws {
    let coins = coinsYAML.replacingOccurrences(of: "reviewScreenshot: iap/com.example.coins100.png\n", with: "")
    let (root, dir) = try await pulledWith(["iap/com.example.coins100.yml": coins, "subscriptions/premium/group.yml": premiumGroupYAML,
                                            "subscriptions/premium/com.example.monthly.yml": monthlyYAML])
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = fakeApp()
    routes["/v1/apps/123/inAppPurchasesV2"] = (200, list([]))
    routes["/v1/apps/123/subscriptionGroups"] = (200, list([]))
    let t = RoutedTransport(routes)
    t.onRequest = { r, t in
        guard r.httpMethod == "POST" else { return }
        switch r.url!.path {
        case "/v2/inAppPurchases":
            let iap = #"{"type":"inAppPurchases","id":"IAPN","attributes":{"productId":"com.example.coins100","name":"100 Coins","inAppPurchaseType":"CONSUMABLE","familySharable":false,"reviewNote":"Buy it from the Store tab.","state":"MISSING_METADATA"}}"#
            t.routes["POST /v2/inAppPurchases"] = (201, single(iap))
            t.routes["/v1/apps/123/inAppPurchasesV2"] = (200, list([iap]))
            t.routes["/v2/inAppPurchases/IAPN/inAppPurchaseLocalizations"] = (200, list([]))
            t.routes["/v2/inAppPurchases/IAPN/pricePoints"] = (200, list([
                #"{"type":"inAppPurchasePricePoints","id":"IPP0","attributes":{"customerPrice":"0.0"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
                #"{"type":"inAppPurchasePricePoints","id":"IPP1","attributes":{"customerPrice":"0.99"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
            ]))
        case "/v1/subscriptionGroups":
            let group = #"{"type":"subscriptionGroups","id":"G1","attributes":{"referenceName":"Premium"}}"#
            t.routes["POST /v1/subscriptionGroups"] = (201, single(group))
            t.routes["/v1/apps/123/subscriptionGroups"] = (200, list([group]))
            t.routes["/v1/subscriptionGroups/G1/subscriptionGroupLocalizations"] = (200, list([]))
            t.routes["/v1/subscriptionGroups/G1/subscriptions"] = (200, list([]))
        case "/v1/subscriptions":
            let sub = #"{"type":"subscriptions","id":"SUB1","attributes":{"productId":"com.example.monthly","name":"Premium Monthly","subscriptionPeriod":"ONE_MONTH","groupLevel":1}}"#
            t.routes["POST /v1/subscriptions"] = (201, single(sub))
            t.routes["/v1/subscriptionGroups/G1/subscriptions"] = (200, list([sub]))
            t.routes["/v1/subscriptions/SUB1/subscriptionLocalizations"] = (200, list([]))
            t.routes["/v1/subscriptions/SUB1/prices"] = (200, list([]))
            t.routes["/v1/subscriptions/SUB1/pricePoints"] = (200, list([
                #"{"type":"subscriptionPricePoints","id":"SPP1","attributes":{"customerPrice":"4.99"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
            ]))
        default: break
        }
    }
    let p = push(t)
    let manifest = ManifestReader.read(dir).manifest
    let (plan, _) = try await p.plan(app: fakeASCApp, manifest: manifest, dir: dir, options: productParts)
    // A dry run shows the creates only; the rest needs their IDs.
    #expect(plan.changes.map(\.subject) == ["in-app purchase com.example.coins100", "subscription group Premium"])
    #expect(plan.changes.allSatisfy { $0.replans })
    #expect(plan.notes.contains("in-app purchase com.example.coins100: its text, review screenshot, prices and availability are planned once App Store Connect has it"))
    let create = try #require(plan.changes.first)
    #expect(create.text == """
        + in-app purchase com.example.coins100
            type: "CONSUMABLE"
            referenceName: "100 Coins"
            reviewNote: "Buy it from the Store tab."
            familySharable: "false"
        """)

    var shown: [StorePlan] = []
    let applied = try await p.apply(plan, app: fakeASCApp, manifest: manifest, dir: dir, options: productParts, sender: mediaSender(t), show: { shown.append($0) })
    #expect(sent(t) == ["POST /v2/inAppPurchases", "POST /v1/subscriptionGroups", "POST /v1/subscriptions",
                        "POST /v1/inAppPurchaseLocalizations", "POST /v1/inAppPurchasePriceSchedules", "POST /v1/inAppPurchaseAvailabilities",
                        "POST /v1/subscriptionGroupLocalizations", "POST /v1/subscriptionLocalizations", "POST /v1/subscriptionPrices"])
    #expect(shown.count == 2, "each plan made after creating is shown")
    #expect(applied.sent.count == 9)
    #expect(t.requests.filter { $0.httpMethod == "POST" && $0.url!.path == "/v2/inAppPurchases" }.count == 1, "each create is sent once")
    let created = try #require(t.requests.first { $0.url!.path == "/v2/inAppPurchases" })
    #expect((data(created)["attributes"] as? [String: Any])?["productId"] as? String == "com.example.coins100")
    let schedule = try #require(t.requests.first { $0.url!.path == "/v1/inAppPurchasePriceSchedules" })
    #expect("\(json(schedule))".contains("IPP1") && "\(json(schedule))".contains("IAPN"))
    let price = try #require(t.requests.first { $0.url!.path == "/v1/subscriptionPrices" })
    #expect("\(data(price))".contains("SPP1"))
    #expect((data(price)["attributes"] as? [String: Any])?["preserveCurrentPrice"] == nil, "a first price has no subscribers to preserve")
    let sub = try #require(t.requests.first { $0.url!.path == "/v1/subscriptions" })
    #expect((data(sub)["attributes"] as? [String: Any])?["subscriptionPeriod"] as? String == "ONE_MONTH")
    #expect("\(data(sub)["relationships"] ?? "")".contains("G1"))
}

/// A subscription SUB1 in group Premium (G1), priced USA 4.99 and GBR 3.99, sold in USA, GBR and CAN.
private func withMonthly(gbr: String = "3.99") -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/inAppPurchasesV2"] = (200, list([]))
    routes["/v1/apps/123/subscriptionGroups"] = (200, list([#"{"type":"subscriptionGroups","id":"G1","attributes":{"referenceName":"Premium"}}"#]))
    routes["/v1/subscriptionGroups/G1/subscriptionGroupLocalizations"] = (200, list([
        #"{"type":"subscriptionGroupLocalizations","id":"GL1","attributes":{"locale":"en-US","name":"Premium","customAppName":"Example"}}"#,
    ]))
    routes["/v1/subscriptionGroups/G1/subscriptions"] = (200, list([
        #"{"type":"subscriptions","id":"SUB1","attributes":{"productId":"com.example.monthly","name":"Premium Monthly","subscriptionPeriod":"ONE_MONTH","groupLevel":1}}"#,
    ]))
    routes["/v1/subscriptions/SUB1/subscriptionLocalizations"] = (200, list([
        #"{"type":"subscriptionLocalizations","id":"SL1","attributes":{"locale":"en-US","name":"Premium Monthly","description":"Everything, every month."}}"#,
    ]))
    routes["/v1/subscriptions/SUB1/subscriptionAvailability"] = (200, single(#"{"type":"subscriptionAvailabilities","id":"SA1","attributes":{"availableInNewTerritories":false}}"#))
    routes["/v1/subscriptionAvailabilities/SA1/availableTerritories"] = (200, list(["USA", "GBR", "CAN"].map { #"{"type":"territories","id":"\#($0)"}"# }))
    routes["/v1/subscriptions/SUB1/prices"] = (200, list([
        #"{"type":"subscriptionPrices","id":"SP1","attributes":{"startDate":null},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}},"subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"SPP1"}}}}"#,
        #"{"type":"subscriptionPrices","id":"SP2","attributes":{"startDate":"2026-01-01"},"relationships":{"territory":{"data":{"type":"territories","id":"GBR"}},"subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"GPP"}}}}"#,
        #"{"type":"subscriptionPrices","id":"SP3","attributes":{"startDate":null},"relationships":{"territory":{"data":{"type":"territories","id":"CAN"}},"subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"CPP1"}}}}"#,
    ], included: [
        #"{"type":"subscriptionPricePoints","id":"SPP1","attributes":{"customerPrice":"4.99"}}"#,
        #"{"type":"subscriptionPricePoints","id":"GPP","attributes":{"customerPrice":"\#(gbr)"}}"#,
        #"{"type":"subscriptionPricePoints","id":"CPP1","attributes":{"customerPrice":"6.99"}}"#,
    ]))
    routes["/v1/subscriptions/SUB1/pricePoints"] = (200, list([
        #"{"type":"subscriptionPricePoints","id":"SPP1","attributes":{"customerPrice":"4.99"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
        #"{"type":"subscriptionPricePoints","id":"SPP2","attributes":{"customerPrice":"5.99"},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
    ]))
    for (point, can) in [("SPP1", ("CPP1", "6.99")), ("SPP2", ("CPP2", "7.99"))] {
        routes["/v1/subscriptionPricePoints/\(point)/equalizations"] = (200, list([
            #"{"type":"subscriptionPricePoints","id":"\#(can.0)","attributes":{"customerPrice":"\#(can.1)"},"relationships":{"territory":{"data":{"type":"territories","id":"CAN"}}}}"#,
            #"{"type":"subscriptionPricePoints","id":"GPP-\#(point)","attributes":{"customerPrice":"4.49"},"relationships":{"territory":{"data":{"type":"territories","id":"GBR"}}}}"#,
        ]))
    }
    return routes
}

private let monthlyPriced = monthlyYAML.replacingOccurrences(of: "  price: \"4.99\"\n", with: "  price: \"4.99\"\n  territories:\n    GBR: \"3.99\"\n")

@Test func anUnchangedSubscriptionPushesNothing() async throws {
    let (root, dir) = try await pulledWith(["subscriptions/premium/group.yml": premiumGroupYAML, "subscriptions/premium/com.example.monthly.yml": monthlyPriced])
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(withMonthly())
    let (plan, _) = try await push(t).plan(app: fakeASCApp, manifest: ManifestReader.read(dir).manifest, dir: dir, options: productParts)
    #expect(plan.changes.isEmpty, "\(plan.changes.map(\.text))")
}

@Test func aNewSubscriptionPriceKeepsExistingSubscribersOnTheirsByDefault() async throws {
    let wanted = monthlyPriced.replacingOccurrences(of: "price: \"4.99\"", with: "price: \"5.99\"")
    let (root, dir) = try await pulledWith(["subscriptions/premium/group.yml": premiumGroupYAML, "subscriptions/premium/com.example.monthly.yml": wanted])
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(withMonthly())
    let p = push(t)
    let manifest = ManifestReader.read(dir).manifest
    let (plan, _) = try await p.plan(app: fakeASCApp, manifest: manifest, dir: dir, options: productParts)
    #expect(plan.changes.map(\.text) == ["""
        ~ subscription com.example.monthly prices
            price CAN: "6.99" → "7.99"
            price: "4.99" → "5.99"
            existing subscribers: "keep their price"
        """])
    _ = try await p.apply(plan, app: fakeASCApp, manifest: manifest, dir: dir, options: productParts, sender: mediaSender(t))
    let posts = t.requests.filter { $0.url!.path == "/v1/subscriptionPrices" }
    #expect(posts.count == 2, "GBR keeps its manual price")
    #expect(posts.allSatisfy { (data($0)["attributes"] as? [String: Any])?["preserveCurrentPrice"] as? Bool == true })
    #expect(posts.map { "\(data($0))" }.contains { $0.contains("CPP2") })
}

@Test func withoutProductFilesPushReadsNoProducts() async throws {
    let (root, dir) = try await pulledWith([:])
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(fakeApp())
    let (plan, _) = try await push(t).plan(app: fakeASCApp, manifest: ManifestReader.read(dir).manifest, dir: dir, options: productParts)
    #expect(plan.changes.isEmpty && plan.notes.isEmpty)
    #expect(!t.requests.contains { $0.url!.path.contains("inAppPurchase") || $0.url!.path.contains("subscription") })
}

private let coinsShotTemplate = "https://is1-ssl.mzstatic.com/image/thumb/b/coins.png/{w}x{h}bb.{f}"
private let coinsShotURL = "https://is1-ssl.mzstatic.com/image/thumb/b/coins.png/1242x2208bb.png"

/// The app with both products, the in-app purchase's App Review screenshot included.
private func withProducts() -> [String: (Int, String)] {
    var routes = withMonthly()
    for (key, value) in withCoins() where key.contains("nAppPurchase") { routes[key] = value }
    routes["/v2/inAppPurchases/IAP2/inAppPurchaseLocalizations"] = (200, list([]))
    routes["/v2/inAppPurchases/IAP1/appStoreReviewScreenshot"] = (200, single(#"{"type":"inAppPurchaseAppStoreReviewScreenshots","id":"RS1","attributes":{"fileName":"coins.png","sourceFileChecksum":"apple-coins","imageAsset":{"templateUrl":"\#(coinsShotTemplate)","width":1242,"height":2208},"assetDeliveryState":{"state":"COMPLETE"}}}"#))
    return routes
}

@Test func pullWritesTheProductsAndPushingThemBackSendsNothing() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let cdn = FakeCDN(introStream.merging([homeURL: homePNG, coinsShotURL: pngHeader(1242, 2208)]) { $1 })
    let report = try await puller(RoutedTransport(withProducts()), cdn).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    #expect(report.inAppPurchases == 2 && report.subscriptions == 1)
    #expect(report.text.contains("  2 in-app purchases, 1 subscription\n"))
    #expect(read("iap/com.example.coins100.yml", in: dir) == """
        # Written by `xless store pull` (docs/appstore-manifest.md#in-app-purchases-and-subscriptions); values are App Store Connect's.
        type: CONSUMABLE
        referenceName: Coins
        familySharable: false
        reviewNote: Buy it from the Store tab.
        reviewScreenshot: iap/com.example.coins100.png
        pricing:
          baseTerritory: USA
          price: '0.99'
        availability:
          territories:
          - CAN
          - USA
          newTerritories: true
        localizations:
          en-US:
            name: 100 Coins
            description: Coins.
          fr-FR:
            name: 100 pièces

        """)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("iap/com.example.coins100.png").path))
    #expect(MediaLock.read(dir).files["iap/com.example.coins100.png"]?.appleChecksum == "apple-coins")
    #expect(read("subscriptions/premium/group.yml", in: dir)?.contains("referenceName: Premium\nlocalizations:\n  en-US:\n    name: Premium\n    customAppName: Example\n") == true)
    let monthly = try #require(read("subscriptions/premium/com.example.monthly.yml", in: dir))
    #expect(monthly.contains("pricing:\n  baseTerritory: USA\n  price: '4.99'\n  territories:\n    GBR: '3.99'\n"), "CAN is Apple's equivalent: not listed")
    #expect(monthly.contains("period: ONE_MONTH\ngroupLevel: 1\n"))
    let read = ManifestReader.read(dir)
    #expect(read.issues.filter { $0.severity == .error }.isEmpty, "\(read.issues)")

    let t = RoutedTransport(withProducts())
    let (plan, _) = try await push(t).plan(app: fakeASCApp, manifest: read.manifest, dir: dir, options: productParts)
    #expect(plan.changes.isEmpty, "\(plan.changes.map(\.text))")
}

@Test func productsTheKeyMayNotReadKeepTheirFiles() async throws {
    let (root, dir) = try await pulledWith(["iap/com.example.coins100.yml": coinsYAML])
    defer { try? FileManager.default.removeItem(at: root) }
    try write(pngHeader(1242, 2208), "iap/com.example.coins100.png", in: dir)
    var routes = fakeApp()
    routes["/v1/apps/123/inAppPurchasesV2"] = (403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"no"}]}"#)
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    #expect(ManifestReader.read(dir).manifest.products.iaps["com.example.coins100"]?.referenceName == "100 Coins")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("iap/com.example.coins100.png").path))
}
