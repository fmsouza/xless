import Foundation
import XlessASC
import XlessCore

// `xless release submit` and the manifest's products: each in-app purchase, subscription group and subscription the
// manifest lists goes to App Review with the version, as an item of the review submission (its version being
// prepared: inAppPurchaseVersion, subscriptionGroupVersion, subscriptionVersion). A product with no such version but
// ready to submit is submitted the older way (POST /v1/inAppPurchaseSubmissions, /v1/subscriptionSubmissions), which
// App Store Connect reviews with the app's version.

/// A product to send to App Review with the version.
public struct ReleaseProduct: Sendable, Equatable {
    public enum How: Sendable, Equatable {
        /// An item of the review submission: `relationship` to the version `type`/`id`.
        case item(relationship: String, type: String, id: String)
        /// The older submission: POST `path` with `relationship` to the product.
        case submission(path: String, relationship: String, type: String, id: String)
    }

    /// `in-app purchase com.example.coins100`.
    public var name: String
    public var how: How

    public init(name: String, how: How) { self.name = name; self.how = how }

    /// What the step says.
    public var step: String {
        switch how {
        case .item: "add \(name) to it"
        case .submission: "submit \(name) with the version"
        }
    }
}

/// The products of a manifest, at App Store Connect.
struct ManifestProducts {
    struct Found {
        var name: String
        var state: String?
        var versions: [ASCProductVersion]
        var item: (relationship: String, type: String)
        var submission: (path: String, relationship: String, type: String)
        var id: String
    }

    var found: [Found] = []
    /// Products the manifest lists that App Store Connect does not have.
    var missing: [String] = []

    /// The products `dir` lists; nil when it lists none.
    static func read(_ dir: URL?, app appID: String, resources: ASCResources) async throws -> ManifestProducts? {
        guard let dir, FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let wanted = ManifestReader.read(dir).manifest.products
        guard !wanted.isEmpty else { return nil }
        let products = ASCProducts(resources: resources)
        var out = ManifestProducts()
        if !wanted.iaps.isEmpty {
            let iaps = try await products.inAppPurchases(app: appID)
            for id in wanted.iaps.keys.sorted() {
                guard let iap = iaps.first(where: { $0.attributes.productId == id }) else { out.missing.append("in-app purchase \(id)"); continue }
                out.found.append(Found(name: "in-app purchase \(id)", state: iap.attributes.state, versions: try await products.iapVersions(iap.id),
                                       item: ("inAppPurchaseVersion", "inAppPurchaseVersions"),
                                       submission: ("/v1/inAppPurchaseSubmissions", "inAppPurchaseV2", "inAppPurchases"), id: iap.id))
            }
        }
        if !wanted.groups.isEmpty {
            let groups = try await products.groups(app: appID)
            for dir in wanted.groups.keys.sorted() {
                let g = wanted.groups[dir]!
                guard let reference = g.group.referenceName, let group = groups.first(where: { $0.attributes.referenceName == reference }) else {
                    out.missing.append("subscription group \(g.group.referenceName ?? dir)")
                    continue
                }
                out.found.append(Found(name: "subscription group \(reference)", state: nil, versions: try await products.groupVersions(group.id),
                                       item: ("subscriptionGroupVersion", "subscriptionGroupVersions"),
                                       submission: ("/v1/subscriptionGroupSubmissions", "subscriptionGroup", "subscriptionGroups"), id: group.id))
                let subs = try await products.subscriptions(group: group.id)
                for id in g.subscriptions.keys.sorted() {
                    guard let s = subs.first(where: { $0.attributes.productId == id }) else { out.missing.append("subscription \(id)"); continue }
                    out.found.append(Found(name: "subscription \(id)", state: s.attributes.state, versions: try await products.subscriptionVersions(s.id),
                                           item: ("subscriptionVersion", "subscriptionVersions"),
                                           submission: ("/v1/subscriptionSubmissions", "subscription", "subscriptions"), id: s.id))
                }
            }
        }
        return out
    }

    /// What goes to App Review: a version being prepared as an item, else (a product ready to submit) the older
    /// submission. Items `existing` already holds are left out.
    func toSubmit(existing: [ASCReviewSubmissionItem]) -> [ReleaseProduct] {
        found.compactMap { f in
            if let v = f.versions.first(where: { ASCProducts.submittableVersionStates.contains($0.attributes.state ?? "") }) {
                if existing.contains(where: { $0.resource.relatedID(f.item.relationship) == v.id && $0.state != "REMOVED" }) { return nil }
                return ReleaseProduct(name: f.name, how: .item(relationship: f.item.relationship, type: f.item.type, id: v.id))
            }
            if f.state == "READY_TO_SUBMIT" {
                return ReleaseProduct(name: f.name, how: .submission(path: f.submission.path, relationship: f.submission.relationship, type: f.submission.type, id: f.id))
            }
            return nil
        }
    }

    /// The pre-flight's `products` check.
    var check: PreflightCheck {
        var problems = missing.map { "\($0) is not on App Store Connect" }
        let incomplete = found.filter { $0.state == "MISSING_METADATA" }.map(\.name)
        problems += incomplete.map { "\($0) is missing metadata" }
        if !problems.isEmpty {
            return PreflightCheck("products", .failed, problems.joined(separator: "; "),
                                  fix: missing.isEmpty ? "give it text, a price and a review screenshot (`xless store push`), then re-run"
                                      : "`xless store push` creates it, then re-run")
        }
        let rejected = found.filter { $0.state == "REJECTED" || $0.state == "DEVELOPER_ACTION_NEEDED" }.map(\.name)
        if !rejected.isEmpty {
            return PreflightCheck("products", .warning, "\(rejected.joined(separator: ", ")) needs changes App Review asked for",
                                  fix: "`xless iap show` / `xless subscriptions show` shows its state")
        }
        return PreflightCheck("products", .ok, "\(found.count) product\(found.count == 1 ? "" : "s") of the manifest on App Store Connect")
    }
}
