import Foundation
import XlessASC
import XlessCore

// The `pricing` part: the price schedule (POST /v1/appPriceSchedules, which replaces the whole schedule) and the
// territories the app is available in (POST /v2/appAvailabilities once, then PATCH /v1/territoryAvailabilities/{id}).
// Both belong to the app, not to a version. Absent app.yml keys are not managed: what App Store Connect has for them is
// kept (and carried into a new schedule).

/// A manual price as the schedule should hold it: `start` nil is the current price.
struct PlannedPrice: Sendable {
    var territory: String
    var start: String?
    /// As the manifest or App Store Connect writes it.
    var price: String
    /// The price point, when known (App Store Connect's own entries); else resolved before sending.
    var point: String?

    var key: String { "\(territory)|\(start ?? "")" }
    var value: Decimal { CustomerPrice.parse(price) ?? -1 }
}

extension PushContext {
    mutating func planPricing() async throws {
        try await planPriceSchedule()
        try await planAvailability()
    }

    // MARK: - Price schedule

    mutating func planPriceSchedule() async throws {
        guard let wanted = app.pricing else { return }
        let appID = target.app.id
        let points = ASCPricePoints(resources: asc.resources)
        try await planSchedule(wanted, read: try await asc.priceSchedule(of: appID), ScheduleTarget(
            part: .pricing, subject: "price schedule", owner: "the app", prefix: "",
            lister: "xless apps price-points \(target.app.bundleID)", inspect: "xless api GET /v1/apps/\(appID)/appPriceSchedule --include manualPrices",
            path: "/v1/appPriceSchedules", scheduleType: "appPriceSchedules", priceType: "appPrices", pointRelationship: "appPricePoint",
            pointType: "appPricePoints", holder: ("app", "apps", appID), points: { try await points.list(app: appID, territory: $0) }))
    }

    /// A price schedule (the app's, an in-app purchase's): POST `path` replaces it whole.
    struct ScheduleTarget {
        var part: StorePushPart
        var subject: String
        /// `the app`, `in-app purchase com.example.coins`: what has no schedule yet.
        var owner: String
        /// Before `pricing…` in notes: "" for app.yml, `iap/com.example.coins.yml: ` for a product.
        var prefix: String
        /// The command listing the price points (`--territory` appended).
        var lister: String
        /// The command showing the schedule.
        var inspect: String
        var path: String
        var scheduleType: String
        var priceType: String
        var pointRelationship: String
        var pointType: String
        /// The schedule's relationship to what it prices: name, type, ID.
        var holder: (name: String, type: String, id: String)
        /// The price points of a territory.
        var points: (String) async throws -> [ASCPricePoint]
        /// Each price's own relationship to what it prices, when the API has one (`inAppPurchaseV2`).
        var priceHolder: (name: String, type: String, id: String)? = nil
    }

    mutating func planSchedule(_ wanted: AppYAML.Pricing, read: StorePart<StorePriceSchedule>, _ t: ScheduleTarget) async throws {
        if case .forbidden = read { return }
        let schedule = read.value
        let day = StoreASC.day(options.today)
        let appleBase = schedule?.baseTerritory
        let base = wanted.baseTerritory ?? appleBase ?? "USA"

        // What App Store Connect has now and to come; a current price is keyed with no start.
        let have: [PlannedPrice] = (schedule?.live(on: day) ?? []).map {
            PlannedPrice(territory: $0.territory, start: $0.current(on: day) ? nil : $0.start, price: $0.customerPrice, point: $0.pointID)
        }

        // Scheduled changes from today or earlier are in effect: each is its territory's current price (latest wins).
        var inEffect: [String: AppYAML.Pricing.Change] = [:]
        var future: [PlannedPrice]?
        if let changes = wanted.changes {
            future = []
            for change in changes.sorted(by: { $0.date < $1.date }) {
                let territory = change.territory ?? base
                if change.date <= day {
                    inEffect[territory] = change
                    note("\(t.prefix)pricing.changes: the change of \(change.date) (\(territory) \(CustomerPrice.display(change.price))) is in effect; `xless store pull` rewrites pricing")
                } else {
                    future?.append(PlannedPrice(territory: territory, start: change.date, price: change.price))
                }
            }
        }

        var want: [PlannedPrice] = []
        // The base territory's current price.
        if let change = inEffect[base] {
            want.append(PlannedPrice(territory: base, price: change.price))
        } else if let price = wanted.price {
            want.append(PlannedPrice(territory: base, price: price))
        } else if base == appleBase {
            want += have.filter { $0.territory == base && $0.start == nil }
        } else if schedule == nil {
            note("\(t.prefix)pricing has no price: App Store Connect has no price schedule for \(t.owner) yet, and none is created")
            return
        } else {
            throw XlessError(.account, "\(t.prefix)pricing.baseTerritory changes to \(base), but pricing has no price there",
                             fix: "add `price:` in \(base)'s currency (`\(t.lister) --territory \(base)`)")
        }
        // App Store Connect's prices that are carried over must not pin the old base territory's prices: once the base
        // changes, the old base follows the new one unless app.yml gives it a manual price.
        let oldBase = appleBase.flatMap { $0 == base ? nil : $0 }
        let carried = have.filter { $0.territory != base && $0.territory != oldBase }
        // Manual prices in other territories.
        var others: [String: PlannedPrice] = [:]
        if let territories = wanted.territories {
            for (territory, price) in territories.values where territory != base { others[territory] = PlannedPrice(territory: territory, price: price) }
        } else {
            for price in carried where price.start == nil { others[price.territory] = price }
        }
        for (territory, change) in inEffect where territory != base { others[territory] = PlannedPrice(territory: territory, price: change.price) }
        want += others.keys.sorted().map { others[$0]! }
        // Changes to come.
        want += (future ?? have.filter { $0.start != nil && $0.territory != oldBase }).sorted { ($0.start ?? "", $0.territory) < ($1.start ?? "", $1.territory) }
        var keys: Set<String> = []
        for p in want where !keys.insert(p.key).inserted {
            throw XlessError(.account, "\(t.prefix)pricing has two prices for \(p.territory) \(p.start.map { "from \($0)" } ?? "now")",
                             fix: "keep one (a change without territory is for the base territory, \(base))")
        }

        // Compare: same base territory and the same prices (as numbers) on the same days.
        var fields: [StoreFieldChange] = []
        if schedule == nil || appleBase != base { fields.append(StoreFieldChange("baseTerritory", from: appleBase, to: base)) }
        let haveByKey = Dictionary(have.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let wantByKey = Dictionary(want.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        func label(_ p: PlannedPrice) -> String {
            (p.territory == base ? "price" : "price \(p.territory)") + (p.start.map { " from \($0)" } ?? "")
        }
        for p in want where haveByKey[p.key].map({ $0.value != p.value }) ?? true {
            fields.append(StoreFieldChange(label(p), from: haveByKey[p.key].map { CustomerPrice.display($0.price) }, to: CustomerPrice.display(p.price)))
        }
        for p in have.sorted(by: { ($0.start ?? "", $0.territory) < ($1.start ?? "", $1.territory) }) where wantByKey[p.key] == nil {
            fields.append(StoreFieldChange(label(p), from: CustomerPrice.display(p.price), to: nil))
        }
        guard !fields.isEmpty else { return }
        if schedule?.incomplete == true {
            throw XlessError(.account, "App Store Connect's \(t.subject) has prices xless could not read, and sending a schedule replaces all of them",
                             fix: "re-run `xless store push`; if it persists, check the schedule with `\(t.inspect)`")
        }

        // Price points: App Store Connect's own for a price it already has, else resolved (one listing per territory).
        for i in want.indices where want[i].point == nil {
            if let same = haveByKey[want[i].key], same.value == want[i].value { want[i].point = same.point }
        }
        var listings: [String: [ASCPricePoint]] = [:]
        for i in want.indices where want[i].point == nil {
            let territory = want[i].territory
            if listings[territory] == nil { listings[territory] = try await t.points(territory) }
            want[i].point = try ASCPricePoints.resolve(want[i].price, in: listings[territory]!, territory: territory, app: target.app.bundleID, command: t.lister).id
        }

        let ids = want.indices.map { "${price-\($0 + 1)}" }
        let included: [JSONValue] = want.indices.map { i in
            var relationships: [String: JSONValue] = [t.pointRelationship: StoreRequest.link(t.pointType, want[i].point)]
            if let price = t.priceHolder { relationships[price.name] = StoreRequest.link(price.type, price.id) }
            return .object(["type": .string(t.priceType), "id": .string(ids[i]),
                            "attributes": .object(["startDate": want[i].start.map { .string($0) } ?? .null]),
                            "relationships": .object(relationships)])
        }
        let data: JSONValue = .object([
            "type": .string(t.scheduleType),
            "relationships": .object([
                t.holder.name: StoreRequest.link(t.holder.type, t.holder.id),
                "baseTerritory": StoreRequest.link("territories", base),
                "manualPrices": .object(["data": .array(ids.map { .object(["type": .string(t.priceType), "id": .string($0)]) })]),
            ]),
        ])
        add(StoreChange(schedule == nil ? .create : .update, t.part, t.subject, fields: fields,
                        requests: [StoreRequest(method: "POST", path: t.path, body: .object(["data": data, "included": .array(included)]))]))
    }

    // MARK: - Availability

    mutating func planAvailability() async throws {
        guard let wanted = app.availability else { return }
        let read = try await asc.availability(of: target.app.id)
        switch read {
        case .forbidden: return
        case .absent:
            guard let territories = wanted.territories else {
                if wanted.newTerritories != nil {
                    note("availability has no territories: App Store Connect has no availability for the app yet, and none is created")
                }
                return
            }
            guard let all = try await asc.territories().value, !all.isEmpty else {
                throw XlessError(.account, "App Store Connect did not list its territories, so the app's availability cannot be created",
                                 fix: "re-run `xless store push`")
            }
            let known = Set(all)
            let chosen = try chosenTerritories(territories, known: known)
            let newTerritories = wanted.newTerritories ?? (territories == .all)
            let codes = all.sorted()
            let included: [JSONValue] = codes.map { code in
                .object(["type": .string("territoryAvailabilities"), "id": .string("${\(code)}"),
                         "attributes": .object(["available": .bool(chosen.contains(code))]),
                         "relationships": .object(["territory": StoreRequest.link("territories", code)])])
            }
            let data: JSONValue = .object([
                "type": .string("appAvailabilities"),
                "attributes": .object(["availableInNewTerritories": .bool(newTerritories)]),
                "relationships": .object([
                    "app": StoreRequest.link("apps", target.app.id),
                    "territoryAvailabilities": StoreRequest.links("territoryAvailabilities", codes.map { "${\($0)}" }),
                ]),
            ])
            add(StoreChange(.create, .pricing, "availability",
                            fields: [StoreFieldChange("territories", from: nil, to: Self.describe(chosen, of: known)),
                                     StoreFieldChange("newTerritories", from: nil, to: "\(newTerritories)")],
                            requests: [StoreRequest(method: "POST", path: "/v2/appAvailabilities", body: .object(["data": data, "included": .array(included)]))]))
        case .value(let availability):
            if let want = wanted.newTerritories, let have = availability.newTerritories, want != have {
                note("availability.newTerritories is \(want), App Store Connect has \(have): its API sets it only when the availability is created, so it is not sent")
            }
            guard let territories = wanted.territories else { return }
            let known = Set(availability.entries.map(\.territory))
            let chosen = try chosenTerritories(territories, known: known)
            // Making the app available is an update; taking it off sale somewhere is a deletion, which push asks about.
            let added = availability.entries.filter { chosen.contains($0.territory) && !$0.available }
            let removed = availability.entries.filter { !chosen.contains($0.territory) && $0.available }
            for (entries, available) in [(added, true), (removed, false)] where !entries.isEmpty {
                let codes = Self.describe(Set(entries.map(\.territory)), of: known)
                add(StoreChange(available ? .update : .delete, .pricing, available ? "availability" : "availability in \(codes)",
                                fields: available ? [StoreFieldChange("now available in", from: nil, to: codes)] : [],
                                requests: entries.map { StoreRequest.update("territoryAvailabilities", id: $0.id, attributes: ["available": .bool(available)]) }))
            }
        }
    }

    /// The territory codes `territories` names, every one known to App Store Connect.
    func chosenTerritories(_ territories: StoreTerritories, known: Set<String>) throws -> Set<String> {
        guard case .only(let list) = territories else { return known }
        let unknown = Set(list).subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw XlessError(.account, "availability.territories: App Store Connect has no territory \(unknown.joined(separator: ", ")) for the app",
                             fix: "use App Store Connect's three-letter codes (`xless api GET /v1/territories` lists them)")
        }
        return Set(list)
    }

    /// `all`, a few codes, or how many.
    static func describe(_ territories: Set<String>, of known: Set<String>) -> String {
        if territories == known, !known.isEmpty { return "all" }
        if territories.isEmpty { return "none" }
        return territories.count <= 6 ? territories.sorted().joined(separator: ", ") : "\(territories.count) territories"
    }
}
