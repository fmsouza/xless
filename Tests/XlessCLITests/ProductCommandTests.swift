import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private func listing(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
private func single(_ item: String) -> String { #"{"data":\#(item)}"# }
private let appJSON = #"{"type":"apps","id":"1","attributes":{"bundleId":"com.example.app","name":"Example"}}"#
private let coins = #"{"type":"inAppPurchases","id":"IAP1","attributes":{"productId":"com.example.coins100","name":"100 Coins","inAppPurchaseType":"CONSUMABLE","state":"APPROVED","familySharable":false}}"#
private let notFound = (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"not found"}]}"#)

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> ProductCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ProductCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json,
                      terminal: { terminal }, say: { said.lines.append($0) }, today: ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!)
}

@Test func productCommandsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    for name in ["iap", "subscriptions", "sandbox-testers"] {
        #expect(group.map { help[$0.upperBound...].contains(name) } == true, "\(name)")
    }
}

@Test func badProductArgumentsAreRefusedBeforeAnythingIsSent() {
    #expect(throws: (any Error).self) { try IAPListCommand.parse([]) }                                        // --app is required
    #expect(throws: (any Error).self) { try IAPShowCommand.parse(["../v1", "--app", "com.example.app"]) }
    #expect(throws: (any Error).self) { try IAPPricePointsCommand.parse(["com.example.coins", "--app", "com.example.app", "--territory", "US"]) }
    #expect(throws: (any Error).self) { try SubscriptionsPricePointsCommand.parse(["com.example.monthly", "--app", "com.example.app", "--price", "$4"]) }
    #expect(throws: (any Error).self) { try SandboxTestersClearCommand.parse([]) }
    #expect(throws: (any Error).self) { try SandboxTestersClearCommand.parse(["a@example.com", "--all"]) }
}

@Test func iapListShowsEveryProduct() async throws {
    let t = FakeTransport([(200, listing([appJSON])), (200, listing([coins]))])
    let out = try await cli(t).iapList(app: "com.example.app")
    #expect(out.contains("PRODUCT ID") && out.contains("com.example.coins100") && out.contains("CONSUMABLE") && out.contains("APPROVED"))
    #expect(t.requests.map(\.url!.path) == ["/v1/apps", "/v1/apps/1/inAppPurchasesV2"])
}

@Test func iapShowReadsTextPriceAvailabilityAndVersions() async throws {
    let t = FakeTransport([
        (200, listing([appJSON])), (200, listing([coins])),
        (200, single(#"{"type":"inAppPurchasePriceSchedules","id":"S1","relationships":{"baseTerritory":{"data":{"type":"territories","id":"USA"}}}}"#)),
        (200, listing([#"{"type":"inAppPurchasePrices","id":"P1","attributes":{"startDate":null},"relationships":{"inAppPurchasePricePoint":{"data":{"type":"inAppPurchasePricePoints","id":"PP1"}},"territory":{"data":{"type":"territories","id":"USA"}}}}"#],
                      included: [#"{"type":"inAppPurchasePricePoints","id":"PP1","attributes":{"customerPrice":"0.99"}}"#])),
        (200, listing([#"{"type":"inAppPurchaseLocalizations","id":"L1","attributes":{"locale":"en-US","name":"100 Coins","description":"A pile of coins."}}"#])),
        (200, single(#"{"type":"inAppPurchaseAvailabilities","id":"A1","attributes":{"availableInNewTerritories":true}}"#)),
        (200, listing([#"{"type":"territories","id":"USA"}"#, #"{"type":"territories","id":"CAN"}"#])),
        notFound,
        (200, listing([#"{"type":"inAppPurchaseVersions","id":"V1","attributes":{"version":1,"state":"APPROVED"}}"#])),
    ])
    let out = try await cli(t).iapShow("com.example.coins100", app: "com.example.app")
    #expect(out.hasPrefix("com.example.coins100 (in-app purchase IAP1)\n"))
    #expect(out.contains("  price:           0.99 (USA)\n"))
    #expect(out.contains("  availability:    CAN, USA, and new territories\n"))
    #expect(out.contains("  review shot:     none\n"))
    #expect(out.contains("  versions:        1 approved\n"))
    #expect(out.contains("  en-US: 100 Coins — A pile of coins.\n"))
}

@Test func anUnknownProductNamesTheListCommand() async {
    let t = FakeTransport([(200, listing([appJSON])), (200, listing([coins]))])
    await #expect { _ = try await cli(t).iapShow("com.example.gems", app: "com.example.app") } throws: {
        ($0 as? XlessError)?.cause == "the app has no in-app purchase com.example.gems" && ($0 as? XlessError)?.fix.contains("xless iap list") == true
    }
}

@Test func subscriptionsListGroupsTheirSubscriptions() async throws {
    let group = #"{"type":"subscriptionGroups","id":"G1","attributes":{"referenceName":"Premium"}}"#
    let empty = #"{"type":"subscriptionGroups","id":"G2","attributes":{"referenceName":"Later"}}"#
    let sub = #"{"type":"subscriptions","id":"S1","attributes":{"productId":"com.example.monthly","name":"Monthly","subscriptionPeriod":"ONE_MONTH","groupLevel":1,"state":"READY_TO_SUBMIT"}}"#
    let t = FakeTransport([(200, listing([appJSON])), (200, listing([group, empty])), (200, listing([sub])), (200, listing([]))])
    let out = try await cli(t).subscriptionsList(app: "com.example.app")
    #expect(out.contains("Premium") && out.contains("com.example.monthly") && out.contains("ONE_MONTH") && out.contains("READY_TO_SUBMIT"))
    #expect(out.contains("Later") && out.contains("(none)"))
}

private let tester = #"{"type":"sandboxTesters","id":"T1","attributes":{"firstName":"Sandy","lastName":"Box","acAccountName":"sandy@example.com","territory":"USA","interruptPurchases":false,"subscriptionRenewalRate":"MONTHLY_RENEWAL_EVERY_FIVE_MINUTES"}}"#

@Test func sandboxTestersAreListed() async throws {
    let out = try await cli(FakeTransport([(200, listing([tester]))])).sandboxList()
    #expect(out.contains("sandy@example.com") && out.contains("Sandy Box") && out.contains("MONTHLY_RENEWAL_EVERY_FIVE_MINUTES") && out.contains("T1"))
}

@Test func clearingAPurchaseHistoryAsksThenSendsOneRequest() async throws {
    var t = FakeTransport([(200, listing([tester]))])
    let said = Said()
    #expect(try await cli(t, terminal: FakeTerminal(answer: false), said: said).sandboxClear(["SANDY@example.com"], all: false, yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"])
    #expect(t.requests.count == 1)

    t = FakeTransport([(200, listing([tester])), (201, #"{"data":{"type":"sandboxTestersClearPurchaseHistoryRequest","id":"R1"}}"#)])
    let out = try await cli(t, terminal: FakeTerminal(answer: true)).sandboxClear(["sandy@example.com"], all: false, yes: false)
    #expect(out == "cleared the purchase history of sandy@example.com\n")
    let post = try #require(t.requests.last)
    #expect(post.httpMethod == "POST" && post.url!.path == "/v2/sandboxTestersClearPurchaseHistoryRequest")
    let body = try JSONDecoder().decode(JSONValue.self, from: post.httpBody!)
    #expect(body["data"]?["type"]?.string == "sandboxTestersClearPurchaseHistoryRequest")
    #expect(body["data"]?["relationships"]?["sandboxTesters"]?["data"]?[0]?["id"]?.string == "T1")

    // An unknown tester is refused before anything is sent.
    t = FakeTransport([(200, listing([tester]))])
    await #expect { _ = try await cli(t).sandboxClear(["nobody@example.com"], all: false, yes: true) } throws: {
        ($0 as? XlessError)?.cause == "no sandbox tester nobody@example.com in this team"
    }
    #expect(t.requests.count == 1)
}
