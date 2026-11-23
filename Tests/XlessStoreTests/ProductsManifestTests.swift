import Foundation
import Testing
@testable import XlessStore

let coinsYAML = """
    type: CONSUMABLE
    referenceName: 100 Coins
    familySharable: false
    reviewNote: Buy it from the Store tab.
    reviewScreenshot: iap/com.example.coins100.png
    pricing:
      baseTerritory: USA
      price: "0.99"
    availability:
      territories: all
      newTerritories: true
    localizations:
      en-US:
        name: 100 Coins
        description: A pile of coins.

    """

let premiumGroupYAML = """
    referenceName: Premium
    localizations:
      en-US:
        name: Premium
        customAppName: Example

    """

let monthlyYAML = """
    referenceName: Premium Monthly
    period: ONE_MONTH
    groupLevel: 1
    pricing:
      baseTerritory: USA
      price: "4.99"
    localizations:
      en-US:
        name: Premium Monthly
        description: Everything, every month.

    """

/// A complete manifest with one in-app purchase and one subscription group of one subscription.
func manifestWithProducts() throws -> URL {
    let dir = try completeManifest()
    try write(coinsYAML, "iap/com.example.coins100.yml", in: dir)
    try write(pngHeader(1242, 2208), "iap/com.example.coins100.png", in: dir)
    try write(premiumGroupYAML, "subscriptions/premium/group.yml", in: dir)
    try write(monthlyYAML, "subscriptions/premium/com.example.monthly.yml", in: dir)
    return dir
}

@Test func productFilesAreRead() throws {
    let dir = try manifestWithProducts()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let read = ManifestReader.read(dir)
    #expect(read.issues.isEmpty, "\(read.issues)")
    let iap = try #require(read.manifest.products.iaps["com.example.coins100"])
    #expect(iap.type == "CONSUMABLE" && iap.referenceName == "100 Coins" && iap.familySharable == false)
    #expect(iap.pricing == AppYAML.Pricing(baseTerritory: "USA", price: "0.99"))
    #expect(iap.availability == AppYAML.Availability(territories: .all, newTerritories: true))
    #expect(iap.localizations?["en-US"] == ProductText(name: "100 Coins", description: "A pile of coins."))
    let group = try #require(read.manifest.products.groups["premium"])
    #expect(group.group.referenceName == "Premium" && group.group.localizations?["en-US"]?.customAppName == "Example")
    let monthly = try #require(group.subscriptions["com.example.monthly"])
    #expect(monthly.period == "ONE_MONTH" && monthly.groupLevel == 1 && monthly.pricing?.price == "4.99")
    #expect(read.manifest.products.productIDs == ["com.example.coins100", "com.example.monthly"])
    // The product directories are not locales.
    #expect(read.manifest.locales.keys.sorted() == ["en-US"])
    #expect(ManifestValidator.validate(read.manifest, at: dir).isEmpty)
}

@Test func productFilesRoundTripThroughTheWriter() throws {
    let dir = try manifestWithProducts()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let first = ManifestReader.read(dir).manifest
    try ManifestWriter.write(first, files: ["iap/com.example.coins100.png": .data(pngHeader(1242, 2208))], lock: MediaLock(), to: dir)
    let again = ManifestReader.read(dir)
    #expect(again.issues.isEmpty, "\(again.issues)")
    #expect(again.manifest.products == first.products)
    #expect(read("iap/com.example.coins100.yml", in: dir)?.hasPrefix("# Written by `xless store pull`") == true)
}

@Test func theWriterOwnsProductFilesButNotOtherFilesThere() {
    #expect(ManifestWriter.owns("iap/com.example.coins100.yml"))
    #expect(ManifestWriter.owns("subscriptions/premium/group.yml"))
    #expect(ManifestWriter.owns("subscriptions/premium/com.example.monthly.yml"))
    #expect(!ManifestWriter.owns("iap/README.md"))
    #expect(!ManifestWriter.owns("iap/com.example.coins100.png"))
    #expect(!ManifestWriter.owns("subscriptions/premium/notes.txt"))
    #expect(!ManifestWriter.owns("subscriptions/premium/deep/x.yml"))
}

@Test func aProductFileNotNamedAfterAProductIDIsRefused() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try write(coinsYAML, "iap/100 coins.yml", in: dir)
    let read = ManifestReader.read(dir)
    #expect(read.issues.map(\.description).contains { $0.contains("appstore/iap/100 coins.yml: 100 coins is not a product ID") })
    #expect(read.manifest.products.iaps.isEmpty)
}

@Test func productValuesAreValidated() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try write("""
        type: AUTO_RENEWABLE
        referenceName: Coins
        reviewScreenshot: ../outside.png
        pricing: { baseTerritory: US, price: "$1" }
        availability: { territories: [usa] }
        localizations:
          en-US: { name: "\(String(repeating: "x", count: 36))" }
          xx_YY!: { name: Bad }
        surprise: 1
        """, "iap/com.example.bad.yml", in: dir)
    try write("referenceName: Premium\n", "subscriptions/premium/group.yml", in: dir)
    try write("""
        referenceName: Monthly
        period: MONTHLY
        groupLevel: 0
        localizations: { en-US: { name: Monthly } }
        """, "subscriptions/premium/com.example.monthly.yml", in: dir)
    try write("referenceName: Yearly\nperiod: ONE_YEAR\ngroupLevel: 0\nlocalizations: { en-US: { name: Yearly } }\n",
              "subscriptions/premium/com.example.yearly.yml", in: dir)
    try write("type: CONSUMABLE\nreferenceName: dup\nlocalizations: { en-US: { name: Dup } }\n", "iap/com.example.monthly.yml", in: dir)
    try write("period: ONE_MONTH\n", "subscriptions/nogroup/com.example.other.yml", in: dir)
    let read = ManifestReader.read(dir)
    let all = (read.issues + ManifestValidator.validate(read.manifest, at: dir)).map(\.description)
    func has(_ text: String) -> Bool { all.contains { $0.contains(text) } }
    #expect(has("appstore/iap/com.example.bad.yml: unknown key `surprise`"))
    #expect(has("type AUTO_RENEWABLE is not an in-app purchase type"))
    #expect(has("reviewScreenshot: ../outside.png is outside appstore/"))
    #expect(has("pricing.baseTerritory US is not a territory code"))
    #expect(has("pricing.price $1 is not a price"))
    #expect(has("availability.territories: usa is not a territory code"))
    #expect(has("localizations.en-US.name is 36 characters, Apple allows 35"))
    #expect(has("localizations: "))
    #expect(has("period MONTHLY is not a subscription period"))
    #expect(has("groupLevel 0 is not a level"))
    #expect(has("groupLevel 0 is also com.example.monthly's"))
    #expect(has("product ID com.example.monthly is also"))
    #expect(has("appstore/subscriptions/nogroup/group.yml: missing"))
}
