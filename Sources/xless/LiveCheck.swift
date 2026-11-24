import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessAppleID
import XlessASC
import XlessCore
import XlessStore

// `xless live-check` (hidden; scripts/acceptance-m7.sh step 0): a read-only contract check against a real account. It
// calls, with xless's own readers and models, the list and get endpoints the Apple account commands use (not the report
// downloads, which need a vendor number and a day with sales, nor each in-app purchase's own reads), and reports
// each one: so a response shape Apple changed (or one xless guessed wrong, docs/research/m7-live-checklist.md) shows up
// before anything is written. Both halves go through guard transports that refuse to send a write.

/// One endpoint's result.
struct LiveCheckLine: Encodable, Sendable, Equatable {
    enum Status: String, Encodable, Sendable { case ok, warn, fail, skip }
    var area: String
    var check: String
    var status: Status
    var detail: String
}

/// A check's answer: `warn` when it decoded but xless reads fields Apple never sent; `skip` when it could not be read
/// (a 403 for this key's role, nothing to read it from).
struct LiveAnswer: Sendable {
    var status: LiveCheckLine.Status = .ok
    var detail: String

    static func count(_ n: Int, _ noun: String) -> LiveAnswer { LiveAnswer(detail: "\(n) \(noun)\(n == 1 ? "" : "s")") }

    /// `items` counted, with the attribute names xless reads that no item carried (a typo in xless, or Apple renamed
    /// it; or the field is simply unset on this account: read it).
    /// - Parameter ignoring: fields the read leaves out on purpose (a sparse fieldset).
    static func listed<A: ASCAttributes>(_ items: [ASCKeptResource<A>], _ noun: String, ignoring: Set<String> = []) -> LiveAnswer {
        var answer = count(items.count, noun)
        let missing = LiveCheck.unsent(items.map(\.resource), as: A.self).filter { !ignoring.contains($0) }
        if !missing.isEmpty {
            answer.status = .warn
            answer.detail += "; xless reads \(missing.joined(separator: ", ")), never sent"
        }
        return answer
    }

    static func part<T>(_ part: StorePart<T>, _ describe: (T) -> LiveAnswer) -> LiveAnswer {
        switch part {
        case .value(let v): describe(v)
        case .absent: LiveAnswer(detail: "none (404)")
        case .forbidden: LiveAnswer(status: .skip, detail: "403: this API key's role cannot read it")
        }
    }
}

struct LiveCheck {
    /// The documented API (nil: `apiSkip` says why).
    var api: ASCResources?
    var apiSkip = "no App Store Connect API key"
    /// The Apple ID web session kept by `xless auth login --keep`, its team selected (nil: `webSkip` says why).
    var web: AppleWebSession?
    var webSkip = "no kept Apple ID session"
    /// The app to read app-scoped endpoints on: an app ID or a bundle ID (default: the first app).
    var app: String?

    func run() async -> [LiveCheckLine] {
        var run = LiveCheckRun()
        var appID: String?
        var bundleID: String? = app.flatMap { $0.contains(".") ? $0 : nil }
        if let api {
            (appID, bundleID) = await checkAPI(api, into: &run, bundleID: bundleID)
        } else {
            run.skip("api", "every documented API endpoint", apiSkip)
        }
        if let web {
            await checkWeb(web, into: &run, appID: appID, bundleID: bundleID)
        } else {
            run.skip("web", "every Apple ID web session endpoint", webSkip)
        }
        return run.lines
    }

    // MARK: The documented API

    func checkAPI(_ r: ASCResources, into run: inout LiveCheckRun, bundleID wanted: String?) async -> (String?, String?) {
        let apps = ASCApps(resources: r)
        var appList: [ASCApp] = []
        await run.check("api", "GET /v1/apps") { appList = try await apps.list(); return .listed(appList, "app") }
        var devices: [ASCDevice] = []
        await run.check("api", "GET /v1/devices") { devices = try await ASCDevices(resources: r).list(); return .count(devices.count, "device") }
        if let device = devices.first {
            await run.check("api", "GET /v1/devices/{id}") { LiveAnswer(detail: try await ASCDevices(resources: r).get(id: device.resource.id).attributes.status ?? "no status") }
        }
        var bundles: [ASCBundleID] = []
        await run.check("api", "GET /v1/bundleIds") { bundles = try await ASCBundleIDs(resources: r).list(); return .listed(bundles, "bundle ID") }
        await run.check("api", "GET /v1/merchantIds") { .listed(try await ASCMerchantIDs(resources: r).list(), "merchant ID") }
        var certificates: [ASCCertificate] = []
        await run.check("api", "GET /v1/certificates") { certificates = try await ASCCertificates(resources: r).list(); return .listed(certificates, "certificate", ignoring: ["certificateContent"]) }
        if let certificate = certificates.first {
            await run.check("api", "GET /v1/certificates/{id}") {
                let full = try await ASCCertificates(resources: r).get(id: certificate.id)
                var answer = LiveAnswer.listed([full], "certificate")
                if full.der == nil { answer.status = .warn; answer.detail += "; no certificateContent xless can read" }
                return answer
            }
            await run.check("api", "GET /v1/profiles?include=certificates") {
                .count(try await ASCCertificates(resources: r).profiles(using: certificate.id).count, "profile")
            }
        }
        var profiles: [ASCProfile] = []
        await run.check("api", "GET /v1/profiles?include=bundleId") { profiles = try await ASCProfiles(resources: r).list().profiles; return .listed(profiles, "profile") }
        if let profile = profiles.first {
            await run.check("api", "GET /v1/profiles/{id}?include=bundleId") {
                let (full, bundle) = try await ASCProfiles(resources: r).get(id: profile.id, withContent: true)
                var answer = LiveAnswer.listed([full], "profile")
                if full.content == nil { answer.status = .warn; answer.detail += "; no profileContent xless can read" }
                if bundle == nil { answer.status = .warn; answer.detail += "; no bundle ID included" }
                return answer
            }
        }
        var users: [ASCUser] = []
        await run.check("api", "GET /v1/users") { users = try await ASCUsers(resources: r).list().items; return .listed(users, "user") }
        if let user = users.first {
            await run.check("api", "GET /v1/users/{id}") { .listed([try await ASCUsers(resources: r).get(id: user.id)], "user") }
        }
        await run.check("api", "GET /v1/userInvitations") { .listed(try await ASCUsers(resources: r).invitations().items, "invitation") }
        await run.check("api", "GET /v1/sandboxTesters") { .listed(try await ASCSandboxTesters(resources: r).list(), "sandbox tester") }
        let store = StoreASC(resources: r)
        await run.check("api", "GET /v1/territories") { .part(try await store.territories()) { .count($0.count, "territory") } }
        await run.check("api", "GET /v1/appCategories") { .count(try await store.categories(platform: "IOS").count, "category") }

        // The app's own endpoints.
        let app: ASCApp?
        if let wantedApp = self.app {
            var found: ASCApp?
            await run.check("api", "the app \(wantedApp)") { found = try await apps.resolve(wantedApp); return LiveAnswer(detail: found.map { "\($0.name) (\($0.id))" } ?? "") }
            app = found
        } else {
            app = appList.first
        }
        guard let app else {
            run.skip("api", "the endpoints of an app", self.app == nil ? "the account has no app yet (re-run with --app after creating one)" : "the app was not found")
            return (nil, wanted)
        }
        if let bundle = bundles.first(where: { $0.identifier == app.bundleID }) {
            await run.check("api", "GET /v1/bundleIds/{id}/bundleIdCapabilities") {
                .listed(try await ASCBundleIDs(resources: r).capabilities(of: bundle.id), "capability")
            }
        }
        await run.check("api", "GET /v1/apps/{id}") { .listed([try await apps.get(id: app.id)], "app") }
        var infos: [ASCKeptResource<StoreAppInfoAttributes>] = []
        await run.check("api", "GET /v1/apps/{id}/appInfos") { infos = try await store.appInfos(of: app.id); return .listed(infos, "app info") }
        if let info = infos.first {
            await run.check("api", "GET /v1/appInfos/{id}/appInfoLocalizations") { .listed(try await store.appInfoLocalizations(of: info.id), "localization") }
            await run.check("api", "GET /v1/appInfos/{id}/ageRatingDeclaration") { .part(try await store.ageRating(of: info.id)) { .count($0.count, "answer") } }
        }
        var versions: [ASCKeptResource<StoreVersionAttributes>] = []
        await run.check("api", "GET /v1/apps/{id}/appStoreVersions") { versions = try await store.versions(of: app.id); return .listed(versions, "version") }
        if let version = versions.first {
            var localizations: [ASCKeptResource<StoreVersionLocalizationAttributes>] = []
            await run.check("api", "GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations") {
                localizations = try await store.versionLocalizations(of: version.id); return .listed(localizations, "localization")
            }
            await run.check("api", "GET /v1/appStoreVersions/{id}/appStoreReviewDetail") { .part(try await store.reviewDetailResource(of: version.id)) { .listed([$0], "review detail") } }
            await run.check("api", "GET /v1/appStoreVersions/{id}/appStoreVersionPhasedRelease") { .part(try await store.phasedRelease(of: version.id)) { LiveAnswer(detail: $0 ? "phased" : "not phased") } }
            await run.check("api", "GET /v1/appStoreVersions/{id}/build") { LiveAnswer(detail: try await ASCRelease(resources: r).buildID(of: version.id) ?? "no build attached") }
            if let localization = localizations.first {
                await run.check("api", "GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets") {
                    let sets = try await store.screenshotSets(of: localization.id)
                    var answer = LiveAnswer.listed(sets.flatMap(\.items), "screenshot")
                    answer.detail = "\(sets.count) set\(sets.count == 1 ? "" : "s"), " + answer.detail
                    return answer
                }
                await run.check("api", "GET /v1/appStoreVersionLocalizations/{id}/appPreviewSets") { .count(try await store.previewSets(of: localization.id).count, "preview set") }
            }
        }
        await run.check("api", "GET /v1/apps/{id}/endUserLicenseAgreement") { .part(try await store.eula(of: app.id)) { _ in LiveAnswer(detail: "custom") } }
        await run.check("api", "GET /v1/apps/{id}/appEncryptionDeclarations") { .listed(try await ASCBuilds(resources: r).declarations(appID: app.id), "declaration") }
        await run.check("api", "GET /v1/apps/{id}/accessibilityDeclarations") { .part(try await store.accessibility(of: app.id)) { .count($0.count, "declaration") } }
        await run.check("api", "GET /v1/apps/{id}/appPriceSchedule") { .part(try await store.priceSchedule(of: app.id)) { .count($0.prices.count, "price") } }
        await run.check("api", "GET /v1/apps/{id}/appAvailabilityV2") { .part(try await store.availability(of: app.id)) { .count($0.entries.count, "territory") } }
        await run.check("api", "GET /v1/apps/{id}/appPricePoints?filter[territory]=USA") { .count(try await ASCPricePoints(resources: r).list(app: app.id, territory: "USA").count, "price point") }
        var builds: ASCBuildListing?
        await run.check("api", "GET /v1/builds?filter[app]") {
            builds = try await ASCBuilds(resources: r).list(BuildFilter(appID: app.id, expired: nil), limit: 20)
            return .listed(builds?.builds.map(\.build) ?? [], "build")
        }
        if let build = builds?.builds.first {
            await run.check("api", "GET /v1/builds/{id}?include=…") {
                let detail = try await ASCBuilds(resources: r).get(id: build.build.id)
                return LiveAnswer(detail: "\(detail.name), beta \(detail.internalBetaState ?? "?")")
            }
        }
        let testflight = ASCTestFlight(resources: r)
        await run.check("api", "GET /v1/apps/{id}/betaGroups") { .listed(try await testflight.groups(app: app.id), "group") }
        await run.check("api", "GET /v1/betaTesters?filter[apps]") { .listed(try await testflight.testers(app: app.id).items, "tester") }
        await run.check("api", "GET /v1/apps/{id}/betaAppLocalizations") { .listed(try await testflight.localizations(app: app.id), "localization") }
        await run.check("api", "GET /v1/apps/{id}/betaAppReviewDetail") { .listed([try await testflight.reviewDetail(app: app.id)], "review detail") }
        await run.check("api", "GET /v1/apps/{id}/betaLicenseAgreement") {
            try await testflight.license(app: app.id).map { .listed([$0], "licence") } ?? LiveAnswer(detail: "none")
        }
        let release = ASCRelease(resources: r)
        await run.check("api", "GET /v1/apps/{id}/appStoreVersions (release)") { .listed(try await release.versions(app: app.id, platform: "IOS"), "version") }
        var submissions: [ASCReviewSubmission] = []
        await run.check("api", "GET /v1/reviewSubmissions?filter[app]") { submissions = try await release.submissions(app: app.id, platform: "IOS"); return .listed(submissions, "submission") }
        if let submission = submissions.first {
            await run.check("api", "GET /v1/reviewSubmissions/{id}/items") { .listed(try await release.items(of: submission.id), "item") }
        }
        let products = ASCProducts(resources: r)
        await run.check("api", "GET /v1/apps/{id}/inAppPurchasesV2") { .listed(try await products.inAppPurchases(app: app.id), "in-app purchase") }
        await run.check("api", "GET /v1/apps/{id}/subscriptionGroups") { .listed(try await products.groups(app: app.id), "subscription group") }
        await run.check("api", "GET /v1/apps/{id}/customerReviews") { .listed(try await ASCCustomerReviews(resources: r).list(app: app.id, maxItems: 20).items, "review") }
        await run.check("api", "GET /v1/apps/{id}/webhooks") { .listed(try await ASCWebhooks(resources: r).list(app: app.id), "webhook") }
        return (app.id, app.bundleID)
    }

    // MARK: The Apple ID web session

    func checkWeb(_ s: AppleWebSession, into run: inout LiveCheckRun, appID knownAppID: String?, bundleID: String?) async {
        await run.check("web", "GET /olympus/v1/session") {
            let session = try await s.asc.session()
            guard let provider = session.provider else { return LiveAnswer(status: .warn, detail: "no current provider") }
            return LiveAnswer(status: provider.publicProviderId == nil ? .warn : .ok,
                              detail: "provider \(provider.providerId), publicProviderId \(provider.publicProviderId == nil ? "absent" : "present"), \(session.providers.count) provider(s)")
        }
        await run.check("web", "GET /olympus/v1/contractMessages") {
            guard let pending = await s.asc.pendingAgreements() else { return LiveAnswer(status: .warn, detail: "no answer xless can read") }
            return .count(pending.count, "pending agreement")
        }
        await run.check("web", "POST QH65B2/account/listTeams.action") { .count(try await s.portal.teams().count, "team") }
        await run.check("web", "app groups (listApplicationGroups.action)") { .count(try await PortalAppGroups(portal: s.portal).list().count, "app group") }
        await run.check("web", "iCloud containers (v1/cloudContainers)") { .count(try await PortalCloudContainers(portal: s.portal).list().count, "container") }
        var authKeys: [PortalAuthKey] = []
        await run.check("web", "auth keys (account/auth/key/list)") {
            authKeys = try await PortalAuthKeys(portal: s.portal).list()
            let unknown = authKeys.filter { $0.services == nil }.count
            return LiveAnswer(status: unknown == 0 ? .ok : .warn, detail: "\(authKeys.count) key(s)\(unknown == 0 ? "" : ", \(unknown) without services")")
        }
        if let key = authKeys.first {
            await run.check("web", "auth key (account/auth/key/get)") {
                let full = try await PortalAuthKeys(portal: s.portal).get(id: key.id)
                return LiveAnswer(status: full.services == nil ? .warn : .ok, detail: full.services == nil ? "no services" : full.serviceNames)
            }
        }
        var apiKeys: [ASCAPIKeyInfo] = []
        await run.check("web", "GET /iris/v1/apiKeys") {
            apiKeys = try await ASCAPIKeys(asc: s.asc).list()
            let noCreator = apiKeys.filter { $0.createdBy == nil }.count
            return LiveAnswer(status: noCreator == 0 ? .ok : .warn, detail: "\(apiKeys.count) key(s)\(noCreator == 0 ? "" : ", \(noCreator) without createdBy")")
        }
        if let key = apiKeys.first {
            await run.check("web", "GET /iris/v1/apiKeys/{id}") {
                let full = try await ASCAPIKeys(asc: s.asc).get(id: key.id)
                return LiveAnswer(detail: "roles \(full.roles.joined(separator: ",")), \(full.isActive ? "active" : "revoked")")
            }
        }
        guard let bundleID else {
            run.skip("web", "the web endpoints of an app", "no app to read (re-run with --app <bundle ID> after creating one)")
            return
        }
        var appID = knownAppID
        await run.check("web", "GET /iris/v1/apps?filter[bundleId]") {
            let found = try await ASCWebApps(asc: s.asc).find(bundleID: bundleID)
            appID = appID ?? found?.id
            return LiveAnswer(status: found == nil ? .warn : .ok, detail: found.map { "app \($0.id)" } ?? "no app with bundle ID \(bundleID)")
        }
        var portalBundle: PortalBundleID?
        await run.check("web", "v1/bundleIds?filter[identifier]") { portalBundle = try await PortalBundleIDs(portal: s.portal).resolve(bundleID); return LiveAnswer(detail: "bundle ID \(portalBundle?.id ?? "?")") }
        if let portalBundle {
            for kind in PortalLinkedKind.allCases {
                await run.check("web", "v1/bundleIds/{id} (\(kind.capability) relationship)") {
                    let state = try await PortalBundleIDs(portal: s.portal).linked(kind, of: portalBundle)
                    return LiveAnswer(detail: state.present ? "\(state.enabled ? "enabled" : "disabled"), \(state.ids.count) linked" : "capability absent")
                }
            }
        }
        let privacy = ASCWebPrivacy(asc: s.asc)
        await run.check("web", "GET /iris/v1/appDataUsageCategories…") {
            let catalog = try await privacy.catalog()
            return LiveAnswer(detail: "\(catalog.categories.count) categories, \(catalog.purposes.count) purposes, \(catalog.protections.count) protections")
        }
        guard let appID else {
            run.skip("web", "App Privacy of the app", "no app record for \(bundleID)")
            return
        }
        await run.check("web", "GET /iris/v1/apps/{id}/dataUsages") { .count(try await privacy.usages(app: appID).count, "data usage") }
        await run.check("web", "GET /iris/v1/apps/{id}/dataUsagePublishState") {
            let state = try await privacy.publishState(app: appID)
            return LiveAnswer(detail: state.map { "published: \($0.published.map(String.init) ?? "unknown")" } ?? "none (404)")
        }
    }

    // MARK: Helpers

    /// The attribute names `A` reads that none of `resources` carried (none for an empty list).
    static func unsent<A: ASCAttributes>(_ resources: [ASCAnyResource], as _: A.Type) -> [String] {
        guard !resources.isEmpty else { return [] }
        let known = Mirror(reflecting: A()).children.compactMap(\.label).map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        let sent = Set(resources.flatMap { ($0.attributes ?? [:]).keys })
        return known.filter { !sent.contains($0) }.sorted()
    }

    /// The report: one line per check, then the counts.
    static func text(_ lines: [LiveCheckLine]) -> String {
        let width = lines.map(\.check.count).max() ?? 0
        var out = lines.map { line in
            let mark = line.status == .fail ? "FAIL" : line.status.rawValue
            return "\(mark.padding(toLength: 4, withPad: " ", startingAt: 0))  \(line.area.padding(toLength: 3, withPad: " ", startingAt: 0))  \(line.check.padding(toLength: width, withPad: " ", startingAt: 0))  \(line.detail)"
        }
        let count = { (s: LiveCheckLine.Status) in lines.filter { $0.status == s }.count }
        out.append("")
        out.append("\(count(.ok)) ok, \(count(.warn)) to read, \(count(.fail)) failed, \(count(.skip)) skipped")
        return out.joined(separator: "\n") + "\n"
    }
}

/// The lines so far; a check that throws is a failure with the error's cause (never a secret: `XlessError`s carry none).
struct LiveCheckRun {
    var lines: [LiveCheckLine] = []

    mutating func check(_ area: String, _ name: String, _ body: () async throws -> LiveAnswer) async {
        do {
            let answer = try await body()
            lines.append(LiveCheckLine(area: area, check: name, status: answer.status, detail: answer.detail))
        } catch {
            let e = XlessError.wrapping(error, stage: .account)
            lines.append(LiveCheckLine(area: area, check: name, status: .fail, detail: e.cause))
        }
    }

    mutating func skip(_ area: String, _ name: String, _ why: String) {
        lines.append(LiveCheckLine(area: area, check: name, status: .skip, detail: why))
    }
}

// MARK: Read-only guards

/// The documented API, GET only: anything else is refused before it reaches the wire.
struct ReadOnlyTransport: HTTPTransport {
    let inner: HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try ReadOnlyGuard.checkAPI(request)
        return try await inner.send(request)
    }

    func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        try ReadOnlyGuard.checkAPI(request)
        return try await inner.stream(request, chunk: chunk)
    }
}

/// The Apple ID web session: GETs, the portal's GET-as-POST (`X-HTTP-Method-Override: GET`), the legacy list and get
/// actions, and App Store Connect's provider switch (session state, nothing of the account). Downloads are refused.
struct ReadOnlyAppleTransport: AppleTransport {
    let inner: AppleTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try ReadOnlyGuard.checkWeb(request)
        return try await inner.send(request)
    }

    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        throw ReadOnlyGuard.refusal(request)
    }
}

enum ReadOnlyGuard {
    static func refusal(_ request: URLRequest) -> XlessError {
        XlessError(.account, "live-check refused to send \(request.httpMethod ?? "GET") \(HTTPTrace.redact(url: request.url)): it only reads",
                   fix: "this is a bug in xless; please report it")
    }

    static func checkAPI(_ request: URLRequest) throws {
        guard (request.httpMethod ?? "GET").uppercased() == "GET" else { throw refusal(request) }
    }

    /// Legacy portal actions that only read: `…/list…`, `…/get…` (listTeams.action, listApplicationGroups.action,
    /// auth/key/list, auth/key/get, listProvisioningProfiles.action for the CSRF tokens).
    static func isReadingAction(_ path: String) -> Bool {
        guard path.contains("/services-account/QH65B2/") else { return false }
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.hasPrefix("list") || last.hasPrefix("get")
    }

    static func checkWeb(_ request: URLRequest) throws {
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = request.url?.path ?? ""
        switch method {
        case "GET", "HEAD": return
        case "POST":
            if request.value(forHTTPHeaderField: "X-HTTP-Method-Override")?.uppercased() == "GET" { return }
            if isReadingAction(path) { return }
            if request.url?.host == "appstoreconnect.apple.com", path == "/olympus/v1/session" { return }
            throw refusal(request)
        default:
            throw refusal(request)
        }
    }
}
