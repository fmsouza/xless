import Foundation
import XlessASC
import XlessCore
import XlessStore

/// `xless iap`, `xless subscriptions` and `xless sandbox-testers`: reads of an app's products and the team's sandbox
/// testers (documented API, API key). Returns what goes to stdout; `say` is stderr.
struct ProductCLI {
    let resources: ASCResources
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var today = Date()

    var products: ASCProducts { ASCProducts(resources: resources) }
    var apps: ASCApps { ASCApps(resources: resources) }

    struct Listing<D: Encodable>: Encodable { var data: D }

    // MARK: - In-app purchases

    func iapList(app argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let iaps = try await products.inAppPurchases(app: app.id)
        if json { return try ASCOutput.json(Listing(data: iaps)) }
        guard !iaps.isEmpty else { return "\(app.name) has no in-app purchases (auto-renewable subscriptions: `xless subscriptions list`)\n" }
        return TextTable(["PRODUCT ID", "TYPE", "REFERENCE NAME", "STATE", "ID"], iaps.map {
            [$0.attributes.productId ?? "", $0.attributes.inAppPurchaseType ?? "", $0.attributes.name ?? "", $0.attributes.state ?? "", $0.id]
        }).rendered
    }

    struct IAPDetail: Encodable {
        var inAppPurchase: ASCInAppPurchase
        var localizations: [ASCProductLocalization]
        var prices: [String: String]?
        var baseTerritory: String?
        var availability: ASCProductAvailability?
        var reviewScreenshot: ASCAnyResource?
        var versions: [ASCProductVersion]
    }

    func iapShow(_ argument: String, app appArgument: String) async throws -> String {
        let app = try await apps.resolve(appArgument)
        let iap = try await products.resolveIAP(argument, app: app.id)
        let store = StoreASC(resources: resources, say: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        let schedule = try await store.iapPriceSchedule(of: iap.id).value
        let day = Self.day(today)
        var current: [String: String]?
        if let schedule {
            var prices: [String: String] = [:]
            for p in schedule.prices where p.current(on: day) { prices[p.territory] = CustomerPrice.display(p.customerPrice) }
            current = prices
        }
        let detail = IAPDetail(inAppPurchase: iap, localizations: try await products.iapLocalizations(iap.id), prices: current,
                               baseTerritory: schedule?.baseTerritory, availability: try await products.iapAvailability(iap.id),
                               reviewScreenshot: try await products.iapScreenshot(iap.id), versions: try await products.iapVersions(iap.id))
        if json { return try ASCOutput.json(detail) }
        let a = iap.attributes
        var out = "\(a.productId ?? iap.id) (in-app purchase \(iap.id))\n"
        out += "  type:            \(a.inAppPurchaseType ?? "")\n"
        out += "  reference name:  \(a.name ?? "")\n"
        out += "  state:           \(a.state ?? "")\n"
        out += "  family sharing:  \(a.familySharable.map { $0 ? "yes" : "no" } ?? "")\n"
        if let note = a.reviewNote { out += "  review note:     \(Self.oneLine(note))\n" }
        out += Self.common(prices: current, base: schedule?.baseTerritory, availability: detail.availability, screenshot: detail.reviewScreenshot,
                           versions: detail.versions, texts: detail.localizations, extra: \.description)
        return out
    }

    // MARK: - Subscriptions

    func subscriptionsList(app argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let all = try await products.allSubscriptions(app: app.id)
        let groups = try await products.groups(app: app.id)
        if json {
            struct Group: Encodable { var group: ASCSubscriptionGroup; var subscriptions: [ASCSubscription] }
            return try ASCOutput.json(Listing(data: groups.map { g in Group(group: g, subscriptions: all.filter { $0.group.id == g.id }.map(\.subscription)) }))
        }
        guard !groups.isEmpty else { return "\(app.name) has no subscription groups (other in-app purchases: `xless iap list`)\n" }
        var rows = all.map { g, s in
            [g.attributes.referenceName ?? g.id, s.attributes.productId ?? "", s.attributes.subscriptionPeriod ?? "", s.attributes.groupLevel.map { "\($0)" } ?? "",
             s.attributes.name ?? "", s.attributes.state ?? "", s.id]
        }
        for g in groups where !all.contains(where: { $0.group.id == g.id }) { rows.append([g.attributes.referenceName ?? g.id, "(none)", "", "", "", "", ""]) }
        return TextTable(["GROUP", "PRODUCT ID", "PERIOD", "LEVEL", "REFERENCE NAME", "STATE", "ID"], rows).rendered
    }

    struct SubscriptionDetail: Encodable {
        var group: ASCSubscriptionGroup
        var subscription: ASCSubscription
        var localizations: [ASCProductLocalization]
        var prices: [String: String]
        var availability: ASCProductAvailability?
        var reviewScreenshot: ASCAnyResource?
        var versions: [ASCProductVersion]
    }

    func subscriptionShow(_ argument: String, app appArgument: String) async throws -> String {
        let app = try await apps.resolve(appArgument)
        let (group, s) = try await products.resolveSubscription(argument, app: app.id)
        let current = ASCSubscriptionPrice.current(try await products.subscriptionPrices(s.id), on: Self.day(today))
            .compactMapValues { $0.customerPrice.map(CustomerPrice.display) }
        let detail = SubscriptionDetail(group: group, subscription: s, localizations: try await products.subscriptionLocalizations(s.id), prices: current,
                                        availability: try await products.subscriptionAvailability(s.id),
                                        reviewScreenshot: try await products.subscriptionScreenshot(s.id), versions: try await products.subscriptionVersions(s.id))
        if json { return try ASCOutput.json(detail) }
        let a = s.attributes
        var out = "\(a.productId ?? s.id) (subscription \(s.id))\n"
        out += "  group:           \(group.attributes.referenceName ?? group.id) (\(group.id))\n"
        out += "  reference name:  \(a.name ?? "")\n"
        out += "  period:          \(a.subscriptionPeriod ?? "")\n"
        out += "  level:           \(a.groupLevel.map { "\($0)" } ?? "")\n"
        out += "  state:           \(a.state ?? "")\n"
        out += "  family sharing:  \(a.familySharable.map { $0 ? "yes" : "no" } ?? "")\n"
        if let note = a.reviewNote { out += "  review note:     \(Self.oneLine(note))\n" }
        out += Self.common(prices: current, base: current["USA"] != nil ? "USA" : nil, availability: detail.availability, screenshot: detail.reviewScreenshot,
                           versions: detail.versions, texts: detail.localizations, extra: \.description)
        return out
    }

    // MARK: - Price points

    enum Product { case iap, subscription }

    /// A product's price points in `territory`; with `price`, that point (and, for a subscription, its price in every
    /// other territory).
    func pricePoints(_ kind: Product, _ argument: String, app appArgument: String, territory: String, price: String?) async throws -> String {
        let app = try await apps.resolve(appArgument)
        let points = ASCPricePoints(resources: resources)
        let path: String
        let command: String
        switch kind {
        case .iap:
            let iap = try await products.resolveIAP(argument, app: app.id)
            path = "/v2/inAppPurchases/\(iap.id)/pricePoints"
            command = "xless iap price-points \(argument) --app \(appArgument)"
        case .subscription:
            let s = try await products.resolveSubscription(argument, app: app.id).subscription
            path = "/v1/subscriptions/\(s.id)/pricePoints"
            command = "xless subscriptions price-points \(argument) --app \(appArgument)"
        }
        let list = try await points.list(path: path, territory: territory)
        guard let price else {
            if json { return try ASCOutput.json(Listing(data: list)) }
            if list.isEmpty { return "App Store Connect lists no price point in \(territory) for \(argument)\n" }
            return TextTable(["PRICE", "PROCEEDS", "CURRENCY", "ID"], list.map { [CustomerPrice.display($0.customerPrice), $0.proceeds ?? "", $0.currency ?? "", $0.id] }).rendered
        }
        let point = try ASCPricePoints.resolve(price, in: list, territory: territory, app: appArgument, command: command)
        // In-app purchase points follow the base price automatically; a subscription's are set per territory.
        let equal = kind == .subscription ? try await points.equalizations(path: "/v1/subscriptionPricePoints/\(point.id)/equalizations")
            : try await points.equalizations(path: "/v1/inAppPurchasePricePoints/\(point.id)/equalizations")
        if json { return try ASCOutput.json(AppCLI.PricePoint(pricePoint: point, equalizations: equal)) }
        var out = "\(CustomerPrice.display(point.customerPrice)) in \(territory)\(point.currency.map { " (\($0))" } ?? ""): price point \(point.id)"
        out += point.proceeds.map { ", proceeds \($0)\n" } ?? "\n"
        if equal.isEmpty { return out }
        return out + "\n" + TextTable(["TERRITORY", "CURRENCY", "PRICE", "PROCEEDS"], equal.map {
            [$0.territory, $0.currency ?? "", CustomerPrice.display($0.customerPrice), $0.proceeds ?? ""]
        }).rendered
    }

    // MARK: - Sandbox testers

    var sandbox: ASCSandboxTesters { ASCSandboxTesters(resources: resources) }

    func sandboxList() async throws -> String {
        let testers = try await sandbox.list()
        if json { return try ASCOutput.json(Listing(data: testers)) }
        guard !testers.isEmpty else { return "This team has no sandbox testers (App Store Connect creates them: Users and Access, Sandbox).\n" }
        return TextTable(["ACCOUNT", "NAME", "TERRITORY", "INTERRUPT PURCHASES", "RENEWAL RATE", "ID"], testers.map {
            let a = $0.attributes
            return [a.acAccountName ?? "", [a.firstName, a.lastName].compactMap { $0 }.joined(separator: " "), a.territory ?? "",
                    a.interruptPurchases.map { $0 ? "yes" : "no" } ?? "", a.subscriptionRenewalRate ?? "", $0.id]
        }).rendered
    }

    /// Clears the purchase history of the testers named (or every one with `all`), after asking.
    func sandboxClear(_ names: [String], all: Bool, yes: Bool) async throws -> String {
        let testers = try await sandbox.list()
        let chosen = all ? testers : try ASCSandboxTesters.pick(names, from: testers)
        guard !chosen.isEmpty else { return "This team has no sandbox testers; nothing was sent.\n" }
        let shown = chosen.map { $0.attributes.acAccountName ?? $0.id }
        let who = shown.count <= 3 ? shown.joined(separator: ", ") : "\(shown.count) sandbox testers"
        let question = "Clear the purchase history of \(who)? Their past purchases are forgotten: non-consumables, subscriptions and offers can be bought again."
        guard try AccountConfirm.confirm(question, action: "clearing the purchase history", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await sandbox.clearHistory(chosen.map(\.id))
        if json { return try ASCOutput.json(["cleared": chosen]) }
        return "cleared the purchase history of \(shown.joined(separator: ", "))\n"
    }

    // MARK: - Text

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func oneLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 70 || text.contains("\n") ? String(line.prefix(70)) + "…" : line
    }

    /// Prices, availability, screenshot, versions and text of a product.
    static func common(prices: [String: String]?, base: String?, availability: ASCProductAvailability?, screenshot: ASCAnyResource?,
                       versions: [ASCProductVersion], texts: [ASCProductLocalization], extra: KeyPath<ASCProductLocalizationAttributes, String?>) -> String {
        var out = ""
        if let prices, !prices.isEmpty {
            let b = base.flatMap { prices[$0] != nil ? $0 : nil }
            let others = prices.keys.filter { $0 != b }.sorted()
            out += "  price:           " + (b.map { "\(prices[$0]!) (\($0))" } ?? "") + (others.isEmpty ? "" : "\(b == nil ? "" : "; ")\(others.count) other territor\(others.count == 1 ? "y" : "ies")") + "\n"
        } else {
            out += "  price:           none\n"
        }
        if let availability {
            let t = availability.territories
            out += "  availability:    \(t.count <= 6 ? t.joined(separator: ", ") : "\(t.count) territories")\(availability.newTerritories == true ? ", and new territories" : "")\n"
        } else {
            out += "  availability:    none\n"
        }
        if let screenshot {
            let a = ASCKeptResource<StoreMediaAttributes>(resource: screenshot).attributes
            out += "  review shot:     \(a.fileName ?? screenshot.id)\(a.state.map { " (\($0.lowercased()))" } ?? "")\n"
        } else {
            out += "  review shot:     none\n"
        }
        if !versions.isEmpty {
            out += "  versions:        " + versions.map { "\($0.attributes.version.map { "\($0)" } ?? $0.id) \(($0.attributes.state ?? "").lowercased().replacingOccurrences(of: "_", with: " "))" }.joined(separator: ", ") + "\n"
        }
        for l in texts.sorted(by: { ($0.attributes.locale ?? "") < ($1.attributes.locale ?? "") }) {
            out += "  \(l.attributes.locale ?? l.id): \(l.attributes.name ?? "")\(l.attributes[keyPath: extra].map { " — \(oneLine($0))" } ?? "")\n"
        }
        return out
    }
}
