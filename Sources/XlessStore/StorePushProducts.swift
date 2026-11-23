import Foundation
import XlessASC
import XlessCore

// The `iap` and `subscriptions` parts: the manifest's product files against App Store Connect's products. A product
// (or subscription group) App Store Connect does not have is created, alone, and the push plans again once it exists
// (its text, screenshot, prices and availability need its ID). One it has is updated where it differs. Nothing is
// ever deleted: products App Store Connect has and the manifest does not are noted. Like app.yml, an absent key is not
// managed.

extension PushContext {
    // MARK: - In-app purchases

    mutating func planInAppPurchases() async throws {
        let wanted = manifest.products.iaps
        guard !wanted.isEmpty else { return }
        let products = ASCProducts(resources: asc.resources)
        let remote: [ASCInAppPurchase]
        do { remote = try await products.inAppPurchases(app: target.app.id) } catch let e as ASCError where e.status == 403 {
            note("iap is not pushed: this API key may not read the app's in-app purchases (HTTP 403)")
            return
        }
        let byProduct = Dictionary(remote.compactMap { r in r.attributes.productId.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        for id in wanted.keys.sorted() {
            let file = wanted[id]!
            if let have = byProduct[id] {
                try await planIAP(id, file, have: have, products: products)
            } else {
                try planNewIAP(id, file)
            }
        }
        let extra = remote.compactMap(\.attributes.productId).filter { wanted[$0] == nil }.sorted()
        if !extra.isEmpty {
            note("App Store Connect has in-app purchase\(extra.count == 1 ? "" : "s") \(extra.joined(separator: ", ")) with no file in \(name)/\(StoreProducts.iapDirectory)/: kept (push never deletes a product; `xless store pull` writes \(extra.count == 1 ? "its file" : "their files"))")
        }
    }

    mutating func planNewIAP(_ id: String, _ file: IAPYAML) throws {
        let path = "\(name)/\(StoreProducts.iapDirectory)/\(id).yml"
        guard let type = file.type, let reference = file.referenceName else {
            throw XlessError(.account, "\(path): App Store Connect has no in-app purchase \(id), and creating one needs `type` and `referenceName`",
                             fix: "add them to \(path)")
        }
        var attributes: [String: JSONValue] = ["productId": .string(id), "inAppPurchaseType": .string(type), "name": .string(reference)]
        var fields = [StoreFieldChange("type", from: nil, to: type), StoreFieldChange("referenceName", from: nil, to: reference)]
        if let note = file.reviewNote.flatMap({ ManifestText.normalize($0, isURL: false) }) {
            attributes["reviewNote"] = .string(note)
            fields.append(StoreFieldChange("reviewNote", from: nil, to: note))
        }
        if let family = file.familySharable {
            attributes["familySharable"] = .bool(family)
            fields.append(StoreFieldChange("familySharable", from: nil, to: "\(family)"))
        }
        let body = StoreRequest.document(type: "inAppPurchases", id: nil, attributes: attributes,
                                         relationships: ["app": StoreRequest.link("apps", target.app.id)])
        add(StoreChange(.create, .iap, "in-app purchase \(id)", fields: fields,
                        requests: [StoreRequest(method: "POST", path: "/v2/inAppPurchases", body: body)], replans: true))
        note("in-app purchase \(id): its text, review screenshot, prices and availability are planned once App Store Connect has it")
    }

    mutating func planIAP(_ id: String, _ file: IAPYAML, have: ASCInAppPurchase, products: ASCProducts) async throws {
        let path = "\(name)/\(StoreProducts.iapDirectory)/\(id).yml"
        let subject = "in-app purchase \(id)"
        if let type = file.type, let current = have.attributes.inAppPurchaseType, type != current {
            throw XlessError(.account, "\(path) says type \(type), App Store Connect has \(id) as \(current): a product's type cannot change",
                             fix: "set `type: \(current)`, or give the new product another product ID")
        }
        var diff = FieldDiff()
        diff.text("name", want: file.referenceName, have: have.attributes.name, clears: false)
        diff.text("reviewNote", want: file.reviewNote, have: have.attributes.reviewNote, clears: false)
        diff.value("familySharable", want: file.familySharable.map { .bool($0) }, have: have.attributes.familySharable.map { .bool($0) })
        if !diff.isEmpty {
            let body = StoreRequest.document(type: "inAppPurchases", id: have.id, attributes: diff.attributes, relationships: [:])
            add(StoreChange(.update, .iap, subject, fields: diff.fields.map(Self.renamingName),
                            requests: [StoreRequest(method: "PATCH", path: "/v2/inAppPurchases/\(have.id)", body: body)]))
        }
        if let wanted = file.localizations {
            try planProductTexts(subject, path: path, wanted: wanted.values.mapValues { [("name", $0.name), ("description", $0.description)] },
                                 remote: try await products.iapLocalizations(have.id), type: "inAppPurchaseLocalizations",
                                 parent: ("inAppPurchaseV2", "inAppPurchases", have.id), part: .iap)
        }
        if let shot = file.reviewScreenshot {
            try planReviewScreenshot(.iapReviewScreenshot, subject: "\(subject) review screenshot", path: shot,
                                     remote: try await products.iapScreenshot(have.id), parent: have.id)
        }
        if let pricing = file.pricing {
            let points = ASCPricePoints(resources: asc.resources)
            let iapID = have.id
            try await planSchedule(pricing, read: try await asc.iapPriceSchedule(of: iapID), ScheduleTarget(
                part: .iap, subject: "\(subject) price schedule", owner: subject, prefix: "\(path): ",
                lister: "xless iap price-points \(id) --app \(target.app.bundleID)",
                inspect: "xless api GET /v2/inAppPurchases/\(iapID)/iapPriceSchedule --include manualPrices",
                path: "/v1/inAppPurchasePriceSchedules", scheduleType: "inAppPurchasePriceSchedules", priceType: "inAppPurchasePrices",
                pointRelationship: "inAppPurchasePricePoint", pointType: "inAppPurchasePricePoints", holder: ("inAppPurchase", "inAppPurchases", iapID),
                points: { try await points.list(path: "/v2/inAppPurchases/\(iapID)/pricePoints", territory: $0) },
                priceHolder: ("inAppPurchaseV2", "inAppPurchases", iapID)))
        }
        if let availability = file.availability {
            try await planProductAvailability(subject, part: .iap, path: path, wanted: availability, have: try await products.iapAvailability(have.id),
                                              create: "inAppPurchaseAvailabilities", holder: ("inAppPurchase", "inAppPurchases", have.id))
        }
    }

    /// The reference name is the API's `name`: plans call it as the file does.
    static func renamingName(_ f: StoreFieldChange) -> StoreFieldChange {
        var f = f
        if f.name == "name" { f.name = "referenceName" }
        if f.name == "subscriptionPeriod" { f.name = "period" }
        return f
    }

    // MARK: - Subscriptions

    mutating func planSubscriptions() async throws {
        let wanted = manifest.products.groups
        guard !wanted.isEmpty else { return }
        let products = ASCProducts(resources: asc.resources)
        let remote: [ASCSubscriptionGroup]
        do { remote = try await products.groups(app: target.app.id) } catch let e as ASCError where e.status == 403 {
            note("subscriptions are not pushed: this API key may not read the app's subscription groups (HTTP 403)")
            return
        }
        // Every subscription App Store Connect has, and its group: a subscription never moves between groups.
        var subsByGroup: [String: [ASCSubscription]] = [:]
        for group in remote { subsByGroup[group.id] = try await products.subscriptions(group: group.id) }
        func groupOf(_ productID: String) -> ASCSubscriptionGroup? {
            remote.first { g in subsByGroup[g.id]?.contains { $0.attributes.productId == productID } ?? false }
        }
        let named = Set(wanted.values.compactMap(\.group.referenceName))
        var matched: Set<String> = []
        for dir in wanted.keys.sorted() {
            let g = wanted[dir]!
            let base = "\(name)/\(StoreProducts.subscriptionsDirectory)/\(dir)"
            guard let reference = g.group.referenceName else {
                throw XlessError(.account, "\(base)/\(StoreProducts.groupFile) has no referenceName, so push cannot tell which group it is",
                                 fix: "add `referenceName:` (`xless store validate` lists what else is missing)")
            }
            var found = remote.first { $0.attributes.referenceName == reference }
            if found == nil {
                // A group whose subscriptions App Store Connect has in one group the manifest does not name: renamed.
                let homes = Set(g.subscriptions.keys.compactMap { groupOf($0)?.id })
                if homes.count == 1, let old = remote.first(where: { $0.id == homes.first! }), !named.contains(old.attributes.referenceName ?? "") {
                    add(StoreChange(.update, .subscriptions, "subscription group \(old.attributes.referenceName ?? old.id)",
                                    fields: [StoreFieldChange("referenceName", from: old.attributes.referenceName, to: reference)],
                                    requests: [.update("subscriptionGroups", id: old.id, attributes: ["referenceName": .string(reference)])]))
                    found = old
                } else if let id = g.subscriptions.keys.sorted().first(where: { groupOf($0) != nil }) {
                    throw XlessError(.account, "\(base)/\(StoreProducts.groupFile) names group \(reference), which App Store Connect does not have, but subscription \(id) is in group \(groupOf(id)?.attributes.referenceName ?? "") there",
                                     fix: "a subscription cannot move between groups: put its file in that group's directory, or give the directory that group's referenceName")
                }
            }
            guard let group = found else {
                add(StoreChange(.create, .subscriptions, "subscription group \(reference)", fields: [StoreFieldChange("referenceName", from: nil, to: reference)],
                                requests: [.create("subscriptionGroups", attributes: ["referenceName": .string(reference)],
                                                   relationships: ["app": StoreRequest.link("apps", target.app.id)])],
                                replans: true))
                note("subscription group \(reference): its text and subscriptions are planned once App Store Connect has it")
                continue
            }
            for id in g.subscriptions.keys.sorted() {
                if let other = groupOf(id), other.id != group.id {
                    throw XlessError(.account, "\(base)/\(id).yml is in group \(reference), but App Store Connect has subscription \(id) in group \(other.attributes.referenceName ?? other.id)",
                                     fix: "a subscription cannot move between groups: put the file back in that group's directory")
                }
            }
            matched.insert(group.id)
            if let texts = g.group.localizations {
                try planProductTexts("subscription group \(reference)", path: "\(base)/\(StoreProducts.groupFile)",
                                     wanted: texts.values.mapValues { [("name", $0.name), ("customAppName", $0.customAppName)] },
                                     remote: try await products.groupLocalizations(group.id), type: "subscriptionGroupLocalizations",
                                     parent: ("subscriptionGroup", "subscriptionGroups", group.id), part: .subscriptions)
            }
            let subs = subsByGroup[group.id] ?? []
            let byProduct = Dictionary(subs.compactMap { s in s.attributes.productId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
            for id in g.subscriptions.keys.sorted() {
                let file = g.subscriptions[id]!
                if let have = byProduct[id] {
                    try await planSubscription(id, file, have: have, path: "\(base)/\(id).yml", products: products)
                } else {
                    try planNewSubscription(id, file, group: group.id, path: "\(base)/\(id).yml")
                }
            }
            let extra = subs.compactMap(\.attributes.productId).filter { g.subscriptions[$0] == nil }.sorted()
            if !extra.isEmpty {
                note("subscription group \(reference) has \(extra.joined(separator: ", ")) at App Store Connect with no file in \(base)/: kept (push never deletes a product)")
            }
        }
        let extra = remote.filter { !matched.contains($0.id) && !named.contains($0.attributes.referenceName ?? "") }
            .compactMap(\.attributes.referenceName).sorted()
        if !extra.isEmpty {
            note("App Store Connect has subscription group\(extra.count == 1 ? "" : "s") \(extra.joined(separator: ", ")) with no directory in \(name)/\(StoreProducts.subscriptionsDirectory)/: kept")
        }
    }

    mutating func planNewSubscription(_ id: String, _ file: SubscriptionYAML, group: String, path: String) throws {
        guard let reference = file.referenceName else {
            throw XlessError(.account, "\(path): App Store Connect has no subscription \(id), and creating one needs `referenceName`", fix: "add it to \(path)")
        }
        var attributes: [String: JSONValue] = ["productId": .string(id), "name": .string(reference)]
        var fields = [StoreFieldChange("referenceName", from: nil, to: reference)]
        if let period = file.period { attributes["subscriptionPeriod"] = .string(period); fields.append(StoreFieldChange("period", from: nil, to: period)) }
        if let level = file.groupLevel { attributes["groupLevel"] = .int(level); fields.append(StoreFieldChange("groupLevel", from: nil, to: "\(level)")) }
        if let family = file.familySharable { attributes["familySharable"] = .bool(family); fields.append(StoreFieldChange("familySharable", from: nil, to: "\(family)")) }
        if let note = file.reviewNote.flatMap({ ManifestText.normalize($0, isURL: false) }) {
            attributes["reviewNote"] = .string(note); fields.append(StoreFieldChange("reviewNote", from: nil, to: note))
        }
        add(StoreChange(.create, .subscriptions, "subscription \(id)", fields: fields,
                        requests: [.create("subscriptions", attributes: attributes, relationships: ["group": StoreRequest.link("subscriptionGroups", group)])],
                        replans: true))
        note("subscription \(id): its text, review screenshot, prices and availability are planned once App Store Connect has it")
    }

    mutating func planSubscription(_ id: String, _ file: SubscriptionYAML, have: ASCSubscription, path: String, products: ASCProducts) async throws {
        let subject = "subscription \(id)"
        var diff = FieldDiff()
        diff.text("name", want: file.referenceName, have: have.attributes.name, clears: false)
        diff.text("subscriptionPeriod", want: file.period, have: have.attributes.subscriptionPeriod, clears: false)
        diff.value("groupLevel", want: file.groupLevel.map { .int($0) }, have: have.attributes.groupLevel.map { .int($0) })
        diff.value("familySharable", want: file.familySharable.map { .bool($0) }, have: have.attributes.familySharable.map { .bool($0) })
        diff.text("reviewNote", want: file.reviewNote, have: have.attributes.reviewNote, clears: false)
        if !diff.isEmpty {
            add(StoreChange(.update, .subscriptions, subject, fields: diff.fields.map(Self.renamingName),
                            requests: [.update("subscriptions", id: have.id, attributes: diff.attributes)]))
        }
        if let wanted = file.localizations {
            try planProductTexts(subject, path: path, wanted: wanted.values.mapValues { [("name", $0.name), ("description", $0.description)] },
                                 remote: try await products.subscriptionLocalizations(have.id), type: "subscriptionLocalizations",
                                 parent: ("subscription", "subscriptions", have.id), part: .subscriptions)
        }
        if let shot = file.reviewScreenshot {
            try planReviewScreenshot(.subscriptionReviewScreenshot, subject: "\(subject) review screenshot", path: shot,
                                     remote: try await products.subscriptionScreenshot(have.id), parent: have.id)
        }
        var haveAvailability: ASCProductAvailability?
        var chosen: Set<String>?
        if file.availability != nil || file.pricing != nil { haveAvailability = try await products.subscriptionAvailability(have.id) }
        if let availability = file.availability {
            chosen = try await planProductAvailability(subject, part: .subscriptions, path: path, wanted: availability, have: haveAvailability,
                                                       create: "subscriptionAvailabilities", holder: ("subscription", "subscriptions", have.id))
        }
        if let pricing = file.pricing {
            try await planSubscriptionPrices(id, subscriptionID: have.id, pricing, territories: chosen ?? haveAvailability.map { Set($0.territories) },
                                             prices: try await products.subscriptionPrices(have.id), path: path)
        }
    }

    /// A subscription's prices: one per territory it is sold in (`territories`; nil: the base territory and those
    /// `pricing.territories` lists), the base price's equivalent unless `pricing.territories` gives one. Each price
    /// that differs is a POST /v1/subscriptionPrices, in effect at once.
    mutating func planSubscriptionPrices(_ id: String, subscriptionID: String, _ pricing: SubscriptionYAML.Pricing, territories: Set<String>?,
                                         prices: [ASCSubscriptionPrice], path: String) async throws {
        let base = pricing.baseTerritory ?? "USA"
        let manual = pricing.territories?.values ?? [:]
        let current = ASCSubscriptionPrice.current(prices, on: StoreASC.day(options.today))
        var scope = territories ?? []
        if territories == nil || pricing.price != nil { scope.insert(base) }
        if pricing.price == nil { scope = scope.filter { manual[$0] != nil } }
        scope.formUnion(manual.keys)
        let points = ASCPricePoints(resources: asc.resources)
        let lister = "xless subscriptions price-points \(id) --app \(target.app.bundleID)"
        func listing(_ territory: String) async throws -> [ASCPricePoint] {
            try await points.list(path: "/v1/subscriptions/\(subscriptionID)/pricePoints", territory: territory)
        }

        // The wanted price point of every territory in scope.
        var wanted: [String: ASCPricePoint] = [:]
        // A price App Store Connect already has is its own point: no listing needed.
        func resolve(_ price: String, in territory: String) async throws -> ASCPricePoint {
            if let have = current[territory], let id = have.pointID, let customer = have.customerPrice,
               let a = CustomerPrice.parse(customer), a == CustomerPrice.parse(price) {
                return ASCPricePoint(id: id, territory: territory, currency: nil, customerPrice: customer, proceeds: nil)
            }
            return try ASCPricePoints.resolve(price, in: try await listing(territory), territory: territory, app: target.app.bundleID, command: lister)
        }
        if let price = pricing.price {
            let point = try await resolve(price, in: base)
            wanted[base] = point
            if scope.contains(where: { $0 != base && manual[$0] == nil }) {
                for p in try await points.equalizations(path: "/v1/subscriptionPricePoints/\(point.id)/equalizations") where scope.contains(p.territory) {
                    wanted[p.territory] = p
                }
            }
        }
        for (territory, price) in manual where territory != base {
            wanted[territory] = try await resolve(price, in: territory)
        }
        let unknown = scope.filter { wanted[$0] == nil }.sorted()
        if !unknown.isEmpty {
            note("\(path): App Store Connect gave no equivalent of the base price in \(Self.describe(Set(unknown), of: [])); those prices are left as they are")
        }

        let preserve = pricing.preserveCurrentPrice ?? true
        var fields: [StoreFieldChange] = []
        var requests: [StoreRequest] = []
        var replacesPrices = false
        for territory in wanted.keys.sorted() {
            let want = wanted[territory]!
            let have = current[territory]
            if let have, have.pointID == want.id || (have.customerPrice.flatMap(CustomerPrice.parse) == want.price && want.price != nil) { continue }
            fields.append(StoreFieldChange(territory == base ? "price" : "price \(territory)", from: have?.customerPrice.map(CustomerPrice.display),
                                           to: CustomerPrice.display(want.customerPrice)))
            var attributes: [String: JSONValue] = [:]
            if have != nil { attributes["preserveCurrentPrice"] = .bool(preserve); replacesPrices = true }
            requests.append(.create("subscriptionPrices", attributes: attributes, relationships: [
                "subscription": StoreRequest.link("subscriptions", subscriptionID),
                "territory": StoreRequest.link("territories", territory),
                "subscriptionPricePoint": StoreRequest.link("subscriptionPricePoints", want.id),
            ]))
        }
        guard !requests.isEmpty else { return }
        if fields.count > 8 {
            let changed = fields.count
            fields = fields.filter { $0.name == "price" } + [StoreFieldChange("prices", from: nil, to: "\(changed) territories")]
        }
        if replacesPrices {
            fields.append(StoreFieldChange("existing subscribers", from: nil, to: preserve ? "keep their price" : "pay the new price"))
        }
        add(StoreChange(current.isEmpty ? .create : .update, .subscriptions, "subscription \(id) prices", fields: fields, requests: requests))
    }

    // MARK: - Shared

    /// A product's (or group's) localizations: each locale of `wanted` (field → value; nil not managed) against
    /// App Store Connect's. A locale it lacks is created (it needs a name); one the file lacks is noted, or deleted
    /// with --prune.
    mutating func planProductTexts(_ subject: String, path: String, wanted: [String: [(String, String?)]], remote: [ASCProductLocalization],
                                   type: String, parent: (name: String, type: String, id: String), part: StorePushPart) throws {
        let byLocale = Dictionary(remote.compactMap { r in r.attributes.locale.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        func have(_ r: ASCProductLocalization, _ field: String) -> String? {
            switch field {
            case "name": r.attributes.name
            case "description": r.attributes.description
            default: r.attributes.customAppName
            }
        }
        for locale in wanted.keys.sorted() {
            let values = wanted[locale]!
            if let r = byLocale[locale] {
                var diff = FieldDiff()
                for (field, value) in values { diff.text(field, want: value, have: have(r, field), clears: false) }
                guard !diff.isEmpty else { continue }
                add(StoreChange(.update, part, "\(subject) text \(locale)", fields: diff.fields, requests: [.update(type, id: r.id, attributes: diff.attributes)]))
            } else {
                var attributes: [String: JSONValue] = ["locale": .string(locale)]
                var fields: [StoreFieldChange] = []
                for (field, value) in values {
                    guard let v = value.flatMap({ ManifestText.normalize($0, isURL: false) }) else { continue }
                    attributes[field] = .string(v)
                    fields.append(StoreFieldChange(field, from: nil, to: v))
                }
                guard attributes["name"] != nil else {
                    throw XlessError(.account, "\(path): localizations.\(locale) has no name, and App Store Connect needs one to add the locale",
                                     fix: "add `name:` under localizations.\(locale)")
                }
                add(StoreChange(.create, part, "\(subject) text \(locale)", fields: fields,
                                requests: [.create(type, attributes: attributes, relationships: [parent.name: StoreRequest.link(parent.type, parent.id)])]))
            }
        }
        for locale in byLocale.keys.sorted() where wanted[locale] == nil {
            if options.prune {
                add(StoreChange(.delete, part, "\(subject) text \(locale)", requests: [.delete(type, id: byLocale[locale]!.id)]))
            } else {
                note("\(subject) has text in \(locale) at App Store Connect that \(path) does not: kept (--prune deletes it)")
            }
        }
    }

    /// The one App Review screenshot of a product: uploaded when App Store Connect's differs (the old one deleted first).
    mutating func planReviewScreenshot(_ kind: StoreMediaKind, subject: String, path: String, remote: ASCAnyResource?, parent: String) throws {
        let file = try localFile(path)
        let items = remote.map { [Self.remote(ASCKeptResource<StoreMediaAttributes>(resource: $0))] } ?? []
        // A product holds one screenshot: anything else App Store Connect has goes when another is uploaded.
        let match = MediaMatcher.match(files: [file.local], remote: items, lock: MediaLock.read(dir), directory: "", prune: true)
        plan.lock.merge(match.lock) { _, new in new }
        guard !match.uploads.isEmpty else { return }
        let deletes = match.deletes + match.pruned.map(\.id)
        let shown = items.first?.fileName ?? "old upload"
        add(StoreChange(items.isEmpty ? .create : .update, kind.part, subject,
                        fields: [StoreFieldChange((path as NSString).lastPathComponent, from: items.isEmpty ? nil : shown, to: "upload")],
                        requests: [], media: StoreMediaWork(kind: kind, container: .parent(parent), slots: [.upload(file.upload)], deletes: deletes, deleteFirst: true)))
    }

    /// A product's availability: sent whole (POST, the API has no update) whenever the territories or
    /// `newTerritories` differ. Returns the territories it is to be sold in (nil: not known).
    @discardableResult
    mutating func planProductAvailability(_ subject: String, part: StorePushPart, path: String, wanted: AppYAML.Availability, have: ASCProductAvailability?,
                                          create type: String, holder: (name: String, type: String, id: String)) async throws -> Set<String>? {
        var chosen: Set<String>
        if let territories = wanted.territories {
            guard let all = try await asc.territories().value, !all.isEmpty else {
                throw XlessError(.account, "App Store Connect did not list its territories, so the availability of \(subject) cannot be compared",
                                 fix: "re-run `xless store push`")
            }
            chosen = try chosenTerritories(territories, known: Set(all))
            let fields = availabilityFields(chosen, all: Set(all), wanted: wanted, have: have)
            guard !fields.isEmpty else { return chosen }
            addAvailability(subject, part: part, chosen: chosen, newTerritories: wanted.newTerritories ?? have?.newTerritories ?? (territories == .all),
                            fields: fields, have: have, type: type, holder: holder)
            return chosen
        }
        guard let have else {
            if wanted.newTerritories != nil { note("\(path): availability has no territories: App Store Connect has no availability for \(subject) yet, and none is created") }
            return nil
        }
        chosen = Set(have.territories)
        if let want = wanted.newTerritories, want != have.newTerritories {
            addAvailability(subject, part: part, chosen: chosen, newTerritories: want, fields: [StoreFieldChange("newTerritories", from: have.newTerritories.map { "\($0)" }, to: "\(want)")],
                            have: have, type: type, holder: holder)
        }
        return chosen
    }

    func availabilityFields(_ chosen: Set<String>, all: Set<String>, wanted: AppYAML.Availability, have: ASCProductAvailability?) -> [StoreFieldChange] {
        var fields: [StoreFieldChange] = []
        let current = Set(have?.territories ?? [])
        if have == nil || current != chosen {
            let added = chosen.subtracting(current), removed = current.subtracting(chosen)
            if have == nil {
                fields.append(StoreFieldChange("territories", from: nil, to: Self.describe(chosen, of: all)))
            } else {
                if !added.isEmpty { fields.append(StoreFieldChange("now available in", from: nil, to: Self.describe(added, of: all))) }
                if !removed.isEmpty { fields.append(StoreFieldChange("no longer available in", from: nil, to: Self.describe(removed, of: all))) }
            }
        }
        let newTerritories = wanted.newTerritories ?? have?.newTerritories ?? (wanted.territories == .all)
        if have == nil || (wanted.newTerritories != nil && have?.newTerritories != newTerritories) {
            fields.append(StoreFieldChange("newTerritories", from: have?.newTerritories.map { "\($0)" }, to: "\(newTerritories)"))
        }
        return fields
    }

    mutating func addAvailability(_ subject: String, part: StorePushPart, chosen: Set<String>, newTerritories: Bool, fields: [StoreFieldChange],
                                  have: ASCProductAvailability?, type: String, holder: (name: String, type: String, id: String)) {
        add(StoreChange(have == nil ? .create : .update, part, "\(subject) availability", fields: fields, requests: [
            .create(type, attributes: ["availableInNewTerritories": .bool(newTerritories)], relationships: [
                holder.name: StoreRequest.link(holder.type, holder.id),
                "availableTerritories": StoreRequest.links("territories", chosen.sorted()),
            ]),
        ]))
    }
}
