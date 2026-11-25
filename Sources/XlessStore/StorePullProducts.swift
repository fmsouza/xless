import Foundation
import XlessASC
import XlessCore

// `store pull`'s products: every in-app purchase (`iap/<productId>.yml`) and subscription group
// (`subscriptions/<group>/`) of the app, with their text, App Review screenshot, prices and availability.

extension StorePull {
    /// What pulling the products adds to the manifest directory.
    struct PulledProducts {
        var products = StoreProducts()
        var files: [String: ManifestWriter.Content] = [:]
        var lock: [String: MediaLock.Entry] = [:]
        var skipped: [String] = []
        /// Apple's copies of review screenshots, downloaded with the version's media.
        var downloads: [MediaDownload] = []
    }

    func pullProducts(app: ASCApp, old: StoreProducts?, dir: URL, staging: URL, oldLock: MediaLock, today: Date) async throws -> PulledProducts {
        var out = PulledProducts()
        let products = ASCProducts(resources: asc.resources)
        let day = StoreASC.day(today)
        var everywhere: [String]?
        func all() async throws -> [String] {
            if let everywhere { return everywhere }
            let t = try await asc.territories().value ?? []
            everywhere = t
            return t
        }
        func availability(_ a: ASCProductAvailability?) async throws -> AppYAML.Availability? {
            guard let a else { return nil }
            let known = try await all()
            let isAll = !known.isEmpty && Set(a.territories).isSuperset(of: known)
            return AppYAML.Availability(territories: isAll ? .all : .only(a.territories), newTerritories: a.newTerritories)
        }

        // In-app purchases.
        switch try await asc.optional("in-app purchases", { try await products.inAppPurchases(app: app.id) }) {
        case .forbidden: out.products.iaps = old?.iaps ?? [:]; keepFiles(of: old?.iaps.values.compactMap(\.reviewScreenshot) ?? [], dir: dir, into: &out)
        case .absent: break
        case .value(let iaps):
            for iap in iaps {
                guard let id = usableProductID(iap.attributes.productId) else { continue }
                let previous = old?.iaps[id]
                var file = IAPYAML(type: iap.attributes.inAppPurchaseType, referenceName: Self.text(iap.attributes.name), familySharable: iap.attributes.familySharable,
                                   reviewNote: Self.text(iap.attributes.reviewNote))
                file.localizations = productTexts(try await products.iapLocalizations(iap.id))
                file.reviewScreenshot = try await screenshot(try await products.iapScreenshot(iap.id), base: "\(StoreProducts.iapDirectory)/\(id)",
                                                             previous: previous?.reviewScreenshot, dir: dir, staging: staging, oldLock: oldLock, into: &out)
                switch try await asc.iapPriceSchedule(of: iap.id) {
                case .value(let schedule): file.pricing = schedule.baseTerritory == nil ? nil : schedule.pricing(today: day)
                case .absent: break
                case .forbidden: file.pricing = previous?.pricing
                }
                file.availability = try await availability(try await products.iapAvailability(iap.id))
                out.products.iaps[id] = file
            }
        }

        // Subscription groups and their subscriptions.
        switch try await asc.optional("subscription groups", { try await products.groups(app: app.id) }) {
        case .forbidden:
            out.products.groups = old?.groups ?? [:]
            keepFiles(of: old?.groups.values.flatMap { $0.subscriptions.values.compactMap(\.reviewScreenshot) } ?? [], dir: dir, into: &out)
        case .absent: break
        case .value(let groups):
            var taken: Set<String> = []
            for group in groups {
                guard let reference = group.attributes.referenceName else { continue }
                // The directory the manifest already has for the group keeps its name.
                let dirName = old?.groups.first(where: { $0.value.group.referenceName == reference }).map(\.key).flatMap { taken.contains($0) ? nil : $0 }
                    ?? StoreProducts.directoryName(for: reference, taken: taken.union(old?.groups.keys.map { $0 } ?? []))
                taken.insert(dirName)
                let previous = old?.groups[dirName]
                var g = SubscriptionGroupDir(group: SubscriptionGroupYAML(referenceName: reference))
                let texts = try await products.groupLocalizations(group.id).compactMap { l -> (String, GroupText)? in
                    guard let locale = usableLocale(l.attributes.locale) else { return nil }
                    return (locale, GroupText(name: Self.text(l.attributes.name), customAppName: Self.text(l.attributes.customAppName)))
                }
                g.group.localizations = texts.isEmpty ? nil : SortedMap(Dictionary(texts, uniquingKeysWith: { a, _ in a }))
                for s in try await products.subscriptions(group: group.id) {
                    guard let id = usableProductID(s.attributes.productId) else { continue }
                    let before = previous?.subscriptions[id]
                    var file = SubscriptionYAML(referenceName: Self.text(s.attributes.name), period: s.attributes.subscriptionPeriod, groupLevel: s.attributes.groupLevel,
                                                familySharable: s.attributes.familySharable, reviewNote: Self.text(s.attributes.reviewNote))
                    file.localizations = productTexts(try await products.subscriptionLocalizations(s.id))
                    file.reviewScreenshot = try await screenshot(try await products.subscriptionScreenshot(s.id),
                                                                 base: "\(StoreProducts.subscriptionsDirectory)/\(dirName)/\(id)", previous: before?.reviewScreenshot,
                                                                 dir: dir, staging: staging, oldLock: oldLock, into: &out)
                    file.pricing = try await subscriptionPricing(s.id, prices: try await products.subscriptionPrices(s.id), day: day, previous: before?.pricing)
                    file.availability = try await availability(try await products.subscriptionAvailability(s.id))
                    g.subscriptions[id] = file
                }
                out.products.groups[dirName] = g
            }
        }
        // Product files App Store Connect does not have (never pushed) are not part of what was pulled: say so.
        let name = dir.lastPathComponent
        for id in (old?.iaps.keys.sorted() ?? []) where out.products.iaps[id] == nil {
            say("note: \(name)/\(StoreProducts.iapDirectory)/\(id).yml is not on App Store Connect (never pushed), so the pulled listing does not have it")
        }
        let pulledSubscriptions = Set(out.products.groups.values.flatMap(\.subscriptions.keys))
        for (groupDir, g) in (old?.groups ?? [:]).sorted(by: { $0.key < $1.key }) {
            for id in g.subscriptions.keys.sorted() where !pulledSubscriptions.contains(id) {
                say("note: \(name)/\(StoreProducts.subscriptionsDirectory)/\(groupDir)/\(id).yml is not on App Store Connect (never pushed), so the pulled listing does not have it")
            }
        }
        return out
    }

    /// A subscription's current prices as the manifest writes them: the base territory's price, and the territories
    /// whose price is not Apple's equivalent of it.
    func subscriptionPricing(_ id: String, prices: [ASCSubscriptionPrice], day: String, previous: SubscriptionYAML.Pricing?) async throws -> SubscriptionYAML.Pricing? {
        let current = ASCSubscriptionPrice.current(prices, on: day)
        guard !current.isEmpty else { return nil }
        let base = previous?.baseTerritory.flatMap { current[$0] == nil ? nil : $0 } ?? (current["USA"] != nil ? "USA" : current.keys.sorted()[0])
        let basePrice = current[base]!
        var out = SubscriptionYAML.Pricing(baseTerritory: base, price: basePrice.customerPrice.map(CustomerPrice.display),
                                           preserveCurrentPrice: previous?.preserveCurrentPrice)
        var equal: [String: String] = [:]
        if let point = basePrice.pointID, current.count > 1 {
            for p in try await ASCPricePoints(resources: asc.resources).equalizations(.subscription, of: point) {
                equal[p.territory] = p.id
            }
        }
        var manual: [String: String] = [:]
        for (territory, price) in current where territory != base {
            guard let customer = price.customerPrice, price.pointID != equal[territory] || price.pointID == nil else { continue }
            manual[territory] = CustomerPrice.display(customer)
        }
        if !manual.isEmpty { out.territories = SortedMap(manual) }
        return out
    }

    func productTexts(_ localizations: [ASCProductLocalization]) -> SortedMap<ProductText>? {
        let texts = localizations.compactMap { l -> (String, ProductText)? in
            guard let locale = usableLocale(l.attributes.locale) else { return nil }
            return (locale, ProductText(name: Self.text(l.attributes.name), description: Self.text(l.attributes.description)))
        }
        return texts.isEmpty ? nil : SortedMap(Dictionary(texts, uniquingKeysWith: { a, _ in a }))
    }

    /// A product ID App Store Connect sent, when it is safe as a file name.
    func usableProductID(_ id: String?) -> String? {
        guard let id, ProductID.isProductID(id) else {
            say("note: App Store Connect sent a product with an unusable product ID (\(id ?? "none")); it is left out")
            return nil
        }
        return id
    }

    /// The App Review screenshot as a file of the manifest (`<base>.png`): the local original when it is the same
    /// upload, else Apple's copy. Nil (and noted) when there is none, or it cannot be downloaded yet.
    func screenshot(_ remote: ASCAnyResource?, base: String, previous: String?, dir: URL, staging: URL, oldLock: MediaLock,
                    into out: inout PulledProducts) async throws -> String? {
        guard let remote else { return nil }
        let item = ASCKeptResource<StoreMediaAttributes>(resource: remote)
        let a = item.attributes
        let ext = ["jpg", "jpeg"].contains(((a.fileName ?? "") as NSString).pathExtension.lowercased()) ? "jpg" : "png"
        let path = "\(base).\(ext)"
        if let checksum = a.sourceFileChecksum, let local = oldLock.unchangedFile(for: checksum, in: dir) {
            out.files[path] = .file(dir.appendingPathComponent(local))
            out.lock[path] = MediaLock.Entry(md5: oldLock.files[local]?.md5, appleChecksum: checksum, id: item.id)
            return path
        }
        guard a.assetDeliveryState?.state == nil || a.assetDeliveryState?.state == "COMPLETE",
              let url = MediaFetch.deliveryURL(a, kind: "screenshots", name: path) else {
            out.skipped.append("\(path) (\(a.assetDeliveryState?.state.map { "processing: \($0)" } ?? "no delivery URL"))")
            if let previous, let url = StoreManifest.resolve(previous, in: dir), FileManager.default.fileExists(atPath: url.path) {
                out.files[previous] = .file(url)
                return previous
            }
            return nil
        }
        out.downloads.append(MediaDownload(path: path, url: url, staged: staging.appendingPathComponent(path), appleChecksum: a.sourceFileChecksum,
                                           id: item.id, preview: false, counted: false))
        return path
    }

    /// The screenshots of products kept as they were (the key may not read them).
    func keepFiles(of paths: [String], dir: URL, into out: inout PulledProducts) {
        for path in paths {
            guard let url = StoreManifest.resolve(path, in: dir), FileManager.default.fileExists(atPath: url.path) else { continue }
            out.files[path] = .file(url)
        }
    }
}
