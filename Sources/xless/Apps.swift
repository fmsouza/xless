import Foundation
import XlessAppleID
import XlessASC
import XlessCore

// What the `xless apps` commands do once their arguments are valid (docs/apple-account.md#xless-apps): reading and
// updating app records with the API key, and creating one through the Apple ID web session.

/// An app record as `apps create` reports it, whichever interface found or made it.
struct AppSummary: Codable, Equatable {
    var id: String
    var name: String?
    var bundleId: String
    var sku: String?
    var primaryLocale: String?

    init(id: String, name: String?, bundleId: String, sku: String?, primaryLocale: String?) {
        self.id = id; self.name = name; self.bundleId = bundleId; self.sku = sku; self.primaryLocale = primaryLocale
    }

    init(_ app: ASCApp) {
        self.init(id: app.id, name: app.attributes.name, bundleId: app.bundleID, sku: app.attributes.sku, primaryLocale: app.attributes.primaryLocale)
    }

    init(_ app: WebApp) {
        self.init(id: app.id, name: app.name, bundleId: app.bundleID, sku: app.sku, primaryLocale: app.primaryLocale)
    }
}

/// The documented API's part of `apps create` (the API key), when a key resolves.
protocol AppCreationAPI {
    /// The key's issuer ID: its App Store Connect team.
    var issuerID: String { get }
    func findApp(bundleID: String) async throws -> AppSummary?
    /// Whether the key can read the app by its ID (false on 404).
    func showsApp(id: String) async throws -> Bool
    func hasBundleID(_ identifier: String) async throws -> Bool
    /// Registers the identifier as a universal bundle ID, as the sign stage does.
    func registerBundleID(_ identifier: String) async throws
}

/// The web session's part of `apps create`: the create itself, and the lookups when no API key resolves.
protocol AppCreationWeb {
    /// The issuer ID of the session's App Store Connect team (its provider's public ID), when App Store Connect says.
    func issuerID() async throws -> String?
    func findApp(bundleID: String) async throws -> AppSummary?
    /// Throws when the team has no such bundle ID (the developer portal's error says how to register it).
    func requireBundleID(_ identifier: String) async throws
    func create(_ request: AppCreateRequest) async -> AppCreateAnswer
}

struct KeyAppCreationAPI: AppCreationAPI {
    let apps: ASCApps
    let bundleIDs: ASCBundleIDs
    let issuerID: String

    init(resources: ASCResources) {
        apps = ASCApps(resources: resources); bundleIDs = ASCBundleIDs(resources: resources); issuerID = resources.client.issuerID
    }

    func findApp(bundleID: String) async throws -> AppSummary? { try await apps.find(bundleID: bundleID).map(AppSummary.init) }
    func showsApp(id: String) async throws -> Bool { try await apps.shows(id: id) }
    func hasBundleID(_ identifier: String) async throws -> Bool { try await bundleIDs.find(identifier: identifier) != nil }
    func registerBundleID(_ identifier: String) async throws {
        _ = try await bundleIDs.create(identifier: identifier, name: PortalName.bundleID(for: identifier), platform: .universal)
    }
}

struct WebAppCreation: AppCreationWeb {
    let apps: ASCWebApps
    let portal: PortalBundleIDs

    func issuerID() async throws -> String? { try await apps.asc.session().provider?.publicProviderId }
    func findApp(bundleID: String) async throws -> AppSummary? { try await apps.find(bundleID: bundleID).map(AppSummary.init) }
    func requireBundleID(_ identifier: String) async throws { _ = try await portal.resolve(identifier) }
    func create(_ request: AppCreateRequest) async -> AppCreateAnswer { await apps.create(request) }
}

/// What `apps create` did: the app it created, or the one that already had the bundle ID.
struct AppCreated: Encodable {
    var created: [AppSummary]
    var existing: [AppSummary]

    var text: String {
        if let app = created.first {
            return "created app \(app.name ?? "") (\(app.id)) for \(app.bundleId)\(app.sku.map { ", SKU \($0)" } ?? "")\n"
        }
        guard let app = existing.first else { return "" }
        return "\(app.bundleId) already has an app record: \(app.name ?? "") (\(app.id))\(app.sku.map { ", SKU \($0)" } ?? ""); nothing was sent\n"
    }
}

/// `apps create`, in order: an app that already has the bundle ID is reported (nothing is sent); the bundle ID must be
/// registered (with the API key, xless offers to register it, once the key and the Apple ID session are known to be on
/// the same team); then one create request through the web session. When its outcome is unclear, the app is looked up
/// by bundle ID before anything is said.
struct AppCreation {
    /// nil when no API key resolves: the lookups go through the web session.
    var api: (any AppCreationAPI)?
    /// Signs in (once, when first needed).
    var web: () async throws -> any AppCreationWeb
    var confirm: (_ question: String, _ action: String) throws -> Bool
    var say: (String) -> Void
    /// Waits between lookups of a new app (tests do not).
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// nil when the user declined to register the bundle ID (nothing was sent).
    func run(_ request: AppCreateRequest) async throws -> AppCreated? {
        let bundle = request.bundleID
        // A bundle identifier belongs to one team only, so an app the key finds is the app, whichever team that is.
        if let api, let existing = try await api.findApp(bundleID: bundle) { return reportExisting(existing, request) }
        let web = try await web()
        if let api {
            try await sameTeam(api, web)
            if !(try await api.hasBundleID(bundle)) {
                let question = "Bundle ID \(bundle) is not registered on this team, and an app needs one. Register it now (universal, named \"\(PortalName.bundleID(for: bundle))\")?"
                guard try confirm(question, "registering bundle ID \(bundle)") else {
                    say("cancelled; nothing was sent")
                    return nil
                }
                try await api.registerBundleID(bundle)
                say("registered bundle ID \(bundle)")
            }
        } else {
            if let existing = try await web.findApp(bundleID: bundle) { return reportExisting(existing, request) }
            try await web.requireBundleID(bundle)
        }
        switch await web.create(request) {
        case .created(let app):
            if let api { try await awaitVisible(app.id, api) }
            return AppCreated(created: [AppSummary(app)], existing: [])
        case .refused(_, let error):
            throw error
        case .ambiguous(let why):
            let found: AppSummary?
            do { found = try await lookUp(bundle, web) } catch {
                throw XlessError(.account, "\(why), and xless could not check whether the app for \(bundle) was created",
                                 fix: "check with `xless apps show \(bundle)` (or App Store Connect > Apps) before re-running; re-running when the app exists only reports it")
            }
            guard var found else {
                throw XlessError(.account, "\(why), and App Store Connect shows no app for \(bundle) yet",
                                 fix: "re-run the same `xless apps create`: if the app was created meanwhile, it is reported, not created twice")
            }
            if found.name == nil { found.name = request.name }
            say("note: \(why), but the app for \(bundle) exists")
            return AppCreated(created: [found], existing: [])
        }
    }

    /// How often, and how many times, a new app is read with the API key.
    static let visibleEvery: Duration = .seconds(10)
    static let visibleTries = 18

    /// Waits until the API key can read the app the web session created: `GET /v1/apps/{id}` has answered 404 right after
    /// the create (#165), and what comes next (`xless store push`, provision's listing) goes through it. The app exists,
    /// so one that still does not show, or a lookup that fails, is never an error here.
    private func awaitVisible(_ id: String, _ api: any AppCreationAPI) async throws {
        for attempt in 1...Self.visibleTries {
            do { if try await api.showsApp(id: id) { return } } catch let e where !(e is CancellationError) {}
            if attempt == 1 { say("waiting for the App Store Connect API to show app \(id)") }
            if attempt < Self.visibleTries { try await pause(Self.visibleEvery) }
        }
        say("note: the App Store Connect API does not show app \(id) yet; wait a few minutes before `xless store push` or `xless provision apply`")
    }

    /// The app after an unclear answer: through the web session, else through the API key.
    private func lookUp(_ bundle: String, _ web: any AppCreationWeb) async throws -> AppSummary? {
        do { return try await web.findApp(bundleID: bundle) } catch {
            guard let api else { throw error }
            return try await api.findApp(bundleID: bundle)
        }
    }

    /// Refuses to go on when the API key's team is not the Apple ID session's: the key would register the bundle ID on
    /// one team and the app would be created on the other.
    private func sameTeam(_ api: any AppCreationAPI, _ web: any AppCreationWeb) async throws {
        guard let issuer = try await web.issuerID(), !issuer.isEmpty else { return }
        guard issuer.caseInsensitiveCompare(api.issuerID) == .orderedSame else {
            throw XlessError(.account, "the App Store Connect API key (issuer \(api.issuerID)) belongs to another team than the Apple ID session's (issuer \(issuer)); nothing was sent",
                             fix: "use the key of the team the app is for (`--team <TEAM_ID>` picks the store's key; ASC_KEY_* in the environment take precedence, so unset them), or pass --team for the key's team")
        }
    }

    private func reportExisting(_ app: AppSummary, _ request: AppCreateRequest) -> AppCreated {
        var differences: [String] = []
        if let name = app.name, name != request.name { differences.append("its name is \"\(name)\"") }
        if let sku = app.sku, sku != request.sku { differences.append("its SKU is \(sku)") }
        if let locale = app.primaryLocale, locale != request.primaryLocale { differences.append("its primary locale is \(locale)") }
        if !differences.isEmpty {
            say("note: the existing app is kept as it is: \(differences.joined(separator: ", ")) (`xless apps update` changes the primary locale)")
        }
        return AppCreated(created: [], existing: [app])
    }
}

/// `apps list | show | update`, on the API key; returns what goes to standard output and says notes on standard error.
struct AppCLI {
    let apps: ASCApps
    var json = false
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func with(json: Bool) -> AppCLI { var copy = self; copy.json = json; return copy }

    func list() async throws -> String {
        let list = try await apps.list()
        if json { return try ASCOutput.json(["data": list]) }
        if list.isEmpty { return "the API key sees no app (create one with `xless apps create`)\n" }
        return TextTable(["ID", "NAME", "BUNDLE ID", "SKU", "PRIMARY LOCALE"], list.map {
            [$0.id, $0.name, $0.bundleID, $0.attributes.sku ?? "", $0.attributes.primaryLocale ?? ""]
        }).rendered
    }

    struct Shown: Encodable { var data: ASCApp; var appInfos: [ASCAppInfo]; var appStoreVersions: [ASCAppStoreVersion] }

    func show(_ argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let infos = try await apps.infos(of: app.id)
        let versions = try await apps.versions(of: app.id)
        if json { return try ASCOutput.json(Shown(data: app, appInfos: infos, appStoreVersions: versions)) }
        let rights = app.attributes.contentRightsDeclaration.map { AppContentRights(rawValue: $0)?.argument ?? $0 } ?? "not declared"
        var out = TextTable(["ID", app.id], [["NAME", app.name], ["BUNDLE ID", app.bundleID], ["SKU", app.attributes.sku ?? ""],
                                              ["PRIMARY LOCALE", app.attributes.primaryLocale ?? ""], ["CONTENT RIGHTS", rights]]).rendered
        out += "\n" + (infos.isEmpty ? "no app info\n" : TextTable(["APP INFO", "STATE", "AGE RATING"], infos.map {
            [$0.id, $0.attributes.state ?? $0.attributes.appStoreState ?? "", $0.attributes.appStoreAgeRating ?? ""]
        }).rendered)
        out += "\n" + (versions.isEmpty ? "no App Store version\n" : TextTable(["VERSION ID", "PLATFORM", "VERSION", "STATE", "CREATED"], versions.map {
            [$0.id, AppPlatform.display($0.attributes.platform), $0.attributes.versionString ?? "",
             $0.attributes.appVersionState ?? $0.attributes.appStoreState ?? "", $0.attributes.createdDate ?? ""]
        }).rendered)
        return out
    }

    struct PricePoint: Encodable { var pricePoint: ASCPricePoint; var equalizations: [ASCPricePoint] }

    /// The app's price points in `territory`, cheapest first; with `price`, that point and what it is in every other
    /// territory (or the nearest points when no point has that price).
    func pricePoints(_ argument: String, territory: String, price: String?) async throws -> String {
        let app = try await apps.resolve(argument)
        let points = ASCPricePoints(resources: apps.resources)
        let list = try await points.list(.app, app.id, territory: territory)
        guard let price else {
            if json { return try ASCOutput.json(["data": list]) }
            if list.isEmpty { return "App Store Connect lists no price point in \(territory) for \(app.name)\n" }
            return TextTable(["PRICE", "PROCEEDS", "CURRENCY", "ID"], list.map {
                [CustomerPrice.display($0.customerPrice), $0.proceeds ?? "", $0.currency ?? "", $0.id]
            }).rendered
        }
        let point = try ASCPricePoints.resolve(price, in: list, territory: territory, app: argument)
        let equal = try await points.equalizations(.app, of: point.id)
        if json { return try ASCOutput.json(PricePoint(pricePoint: point, equalizations: equal)) }
        var out = "\(CustomerPrice.display(point.customerPrice)) in \(territory)\(point.currency.map { " (\($0))" } ?? ""): price point \(point.id)"
        out += point.proceeds.map { ", proceeds \($0)\n" } ?? "\n"
        if equal.isEmpty { return out }
        return out + "\n" + TextTable(["TERRITORY", "CURRENCY", "PRICE", "PROCEEDS"], equal.map {
            [$0.territory, $0.currency ?? "", CustomerPrice.display($0.customerPrice), $0.proceeds ?? ""]
        }).rendered
    }

    func update(_ argument: String, primaryLocale: String?, contentRights: AppContentRights?, bundleID: String?) async throws -> String {
        let app = try await apps.resolve(argument)
        guard let updated = try await apps.update(app, primaryLocale: primaryLocale, contentRights: contentRights, bundleID: bundleID) else {
            if json { return try ASCOutput.json(app) }
            return "\(app.name) (\(app.id)) already has these values; nothing was sent\n"
        }
        if json { return try ASCOutput.json(updated) }
        var changes: [String] = []
        func change(_ label: String, _ old: String?, _ new: String?) {
            if let new, new != old { changes.append("\(label) \(old ?? "none") → \(new)") }
        }
        change("primary locale", app.attributes.primaryLocale, primaryLocale)
        change("content rights", app.attributes.contentRightsDeclaration.map { AppContentRights(rawValue: $0)?.argument ?? $0 }, contentRights?.argument)
        change("bundle ID", app.bundleID, bundleID)
        return "updated \(app.name) (\(app.id)): \(changes.joined(separator: ", "))\n"
    }
}
