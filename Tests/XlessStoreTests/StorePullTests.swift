import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

/// App Store Connect by path: each request gets the body registered for "METHOD path", else (a GET) for its path (404
/// when none), and is recorded. An unregistered write answers 201 with a created resource `NEW<n>`. `onRequest` sees
/// each request first and may change the routes (App Store Connect's state after a write).
final class RoutedTransport: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var requests: [URLRequest] = []
    var onRequest: ((URLRequest, RoutedTransport) -> Void)?
    private let lock = NSLock()

    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock {
            requests.append(request)
            onRequest?(request, self)
            let method = request.httpMethod ?? "GET", path = request.url!.path
            if let route = routes["\(method) \(path)"] { return route }
            if method != "GET" { return (201, #"{"data":{"type":"x","id":"NEW\#(requests.count)"}}"#) }
            return routes[path] ?? (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"not found"}]}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func queries(_ path: String) -> [[String]] {
        requests.filter { $0.url!.path == path }.map { r in
            (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
        }
    }
}

/// Media served by URL; records what was fetched.
final class FakeCDN: @unchecked Sendable {
    var files: [String: Data]
    var fetched: [String] = []
    init(_ files: [String: Data]) { self.files = files }
    func download(_ url: URL) async throws -> Data {
        fetched.append(url.absoluteString)
        guard let data = files[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

let storeCreds = ASCCredentials(keyID: "KEY123", issuerID: "iss-1", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)

func list(_ items: [String], included: [String] = []) -> String {
    #"{"data":[\#(items.joined(separator: ","))]\#(included.isEmpty ? "" : #","included":[\#(included.joined(separator: ","))]"#),"links":{"self":"x"}}"#
}
func single(_ item: String?) -> String { #"{"data":\#(item ?? "null"),"links":{"self":"x"}}"# }

let homePNG = pngHeader(1320, 2868)
let homeTemplate = "https://is1-ssl.mzstatic.com/image/thumb/a/home.png/{w}x{h}bb.{f}"
let homeURL = "https://is1-ssl.mzstatic.com/image/thumb/a/home.png/1320x2868bb.png"
let introStream = ["https://example.apple.com/intro.m3u8": Data("#EXTM3U\n".utf8)]

/// An app with one editable iOS version, en-US and de-DE, one screenshot, and every optional part.
func fakeApp() -> [String: (Int, String)] {
    [
        "/v1/apps/123/appStoreVersions": (200, list([
            #"{"type":"appStoreVersions","id":"V1","attributes":{"platform":"IOS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION","appStoreState":"READY_FOR_SALE","copyright":"2025 Example","releaseType":"MANUAL","createdDate":"2025-01-01T00:00:00Z"}}"#,
            #"{"type":"appStoreVersions","id":"V2","attributes":{"platform":"IOS","versionString":"1.1","appVersionState":"PREPARE_FOR_SUBMISSION","appStoreState":"PREPARE_FOR_SUBMISSION","copyright":"2026 Example Inc.","releaseType":"SCHEDULED","earliestReleaseDate":"2026-12-01T08:00:00Z","createdDate":"2026-11-01T00:00:00Z"}}"#,
        ])),
        "/v1/apps/123/appInfos": (200, list([
            #"{"type":"appInfos","id":"I1","attributes":{"state":"READY_FOR_DISTRIBUTION","appStoreState":"READY_FOR_SALE"},"relationships":{"primaryCategory":{"data":{"type":"appCategories","id":"GAMES"}}}}"#,
            #"{"type":"appInfos","id":"I2","attributes":{"state":"PREPARE_FOR_SUBMISSION"},"relationships":{"primaryCategory":{"data":{"type":"appCategories","id":"UTILITIES"}},"primarySubcategoryOne":{"data":null},"secondaryCategory":{"data":{"type":"appCategories","id":"PRODUCTIVITY"}}}}"#,
        ])),
        "/v1/appInfos/I2/appInfoLocalizations": (200, list([
            #"{"type":"appInfoLocalizations","id":"L1","attributes":{"locale":"en-US","name":"Example","subtitle":"Does things","privacyPolicyUrl":"https://example.com/privacy","privacyChoicesUrl":null}}"#,
            #"{"type":"appInfoLocalizations","id":"L2","attributes":{"locale":"de-DE","name":"Beispiel","subtitle":""}}"#,
        ])),
        "/v1/appInfos/I2/ageRatingDeclaration": (200, single(#"{"type":"ageRatingDeclarations","id":"A1","attributes":{"gambling":false,"violenceCartoonOrFantasy":"NONE","kidsAgeBand":null,"ageRatingOverrideV2":"NONE"}}"#)),
        "/v1/appStoreVersions/V2/appStoreVersionLocalizations": (200, list([
            #"{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{"locale":"en-US","description":"Does things.\nWell.","keywords":"tools,example","supportUrl":"https://example.com/support","marketingUrl":null,"promotionalText":null,"whatsNew":"Fixes."}}"#,
            #"{"type":"appStoreVersionLocalizations","id":"VL2","attributes":{"locale":"de-DE","description":"Macht Dinge.","keywords":"werkzeug","supportUrl":"https://example.com/de"}}"#,
        ])),
        "/v1/appStoreVersions/V2/appStoreReviewDetail": (200, single(#"{"type":"appStoreReviewDetails","id":"R1","attributes":{"contactFirstName":"Ada","contactLastName":"Lovelace","contactPhone":"+1 555 0100","contactEmail":"ada@example.com","demoAccountName":"demo@example.com","demoAccountRequired":true,"notes":"Line one\nLine two"}}"#)),
        "/v1/appStoreVersions/V2/appStoreVersionPhasedRelease": (200, single(#"{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"INACTIVE"}}"#)),
        "/v1/appStoreVersionLocalizations/VL1/appScreenshotSets": (200, list([#"{"type":"appScreenshotSets","id":"S1","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}"#])),
        "/v1/appScreenshotSets/S1/appScreenshots": (200, list([
            #"{"type":"appScreenshots","id":"SS1","attributes":{"fileName":"01-home.png","fileSize":1000,"sourceFileChecksum":"apple-home","imageAsset":{"templateUrl":"\#(homeTemplate)","width":1320,"height":2868},"assetDeliveryState":{"state":"COMPLETE"}}}"#,
            #"{"type":"appScreenshots","id":"SS2","attributes":{"fileName":"Settings Screen.png","sourceFileChecksum":"apple-settings","assetDeliveryState":{"state":"UPLOAD_COMPLETE"}}}"#,
        ])),
        "/v1/appStoreVersionLocalizations/VL1/appPreviewSets": (200, list([])),
        "/v1/appStoreVersionLocalizations/VL2/appScreenshotSets": (200, list([])),
        "/v1/appStoreVersionLocalizations/VL2/appPreviewSets": (200, list([#"{"type":"appPreviewSets","id":"PS1","attributes":{"previewType":"IPHONE_67"}}"#])),
        "/v1/appPreviewSets/PS1/appPreviews": (200, list([#"{"type":"appPreviews","id":"PV1","attributes":{"fileName":"intro.mov","sourceFileChecksum":"apple-intro","videoUrl":"https://example.apple.com/intro.m3u8","assetDeliveryState":{"state":"COMPLETE"}}}"#])),
        "/v1/appEncryptionDeclarations": (200, list([
            #"{"type":"appEncryptionDeclarations","id":"E1","attributes":{"createdDate":"2025-01-01T00:00:00Z","exempt":false,"containsProprietaryCryptography":true}}"#,
            #"{"type":"appEncryptionDeclarations","id":"E2","attributes":{"createdDate":"2026-01-01T00:00:00Z","exempt":true,"containsProprietaryCryptography":false,"appEncryptionDeclarationState":"APPROVED","documentUrl":null}}"#,
        ])),
        "/v1/apps/123/accessibilityDeclarations": (200, list([
            #"{"type":"accessibilityDeclarations","id":"AC1","attributes":{"deviceFamily":"IPHONE","state":"PUBLISHED","supportsVoiceover":false}}"#,
            #"{"type":"accessibilityDeclarations","id":"AC2","attributes":{"deviceFamily":"IPHONE","state":"DRAFT","supportsVoiceover":true,"supportsDarkInterface":true}}"#,
        ])),
        "/v1/apps/123/endUserLicenseAgreement": (200, single(#"{"type":"endUserLicenseAgreements","id":"EU1","attributes":{"agreementText":"Terms."}}"#)),
        "/v1/endUserLicenseAgreements/EU1/territories": (200, list([#"{"type":"territories","id":"USA"}"#, #"{"type":"territories","id":"CAN"}"#])),
        "/v1/territories": (200, list([#"{"type":"territories","id":"USA"}"#, #"{"type":"territories","id":"CAN"}"#, #"{"type":"territories","id":"GBR"}"#])),
        "/v1/apps/123/appPriceSchedule": (200, single(#"{"type":"appPriceSchedules","id":"PR1","relationships":{"baseTerritory":{"data":{"type":"territories","id":"USA"}}}}"#)),
        "/v1/appPriceSchedules/PR1/manualPrices": (200, list([
            #"{"type":"appPrices","id":"AP1","attributes":{"startDate":null,"endDate":"2026-01-01"},"relationships":{"appPricePoint":{"data":{"type":"appPricePoints","id":"PP1"}}}}"#,
            #"{"type":"appPrices","id":"AP2","attributes":{"startDate":"2026-01-01","endDate":null},"relationships":{"appPricePoint":{"data":{"type":"appPricePoints","id":"PP2"}}}}"#,
        ], included: [#"{"type":"appPricePoints","id":"PP1","attributes":{"customerPrice":"0.0"}}"#, #"{"type":"appPricePoints","id":"PP2","attributes":{"customerPrice":"1.99"}}"#])),
        "/v1/apps/123/appAvailabilityV2": (200, single(#"{"type":"appAvailabilities","id":"AV1","attributes":{"availableInNewTerritories":false}}"#)),
        "/v2/appAvailabilities/AV1/territoryAvailabilities": (200, list([
            #"{"type":"territoryAvailabilities","id":"T1","attributes":{"available":true},"relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}"#,
            #"{"type":"territoryAvailabilities","id":"T2","attributes":{"available":false},"relationships":{"territory":{"data":{"type":"territories","id":"GBR"}}}}"#,
            #"{"type":"territoryAvailabilities","id":"T3","attributes":{"available":true},"relationships":{"territory":{"data":{"type":"territories","id":"CAN"}}}}"#,
        ])),
    ]
}

let fakeASCApp = ASCApp(resource: ASCAnyResource(type: "apps", id: "123", attributes: [
    "bundleId": .string("com.example.app"), "sku": .string("EXAMPLE1"), "primaryLocale": .string("en-US"), "name": .string("Example"),
    "contentRightsDeclaration": .string("DOES_NOT_USE_THIRD_PARTY_CONTENT"),
]))

final class Notes: @unchecked Sendable {
    var lines: [String] = []
    func say(_ s: String) { lines.append(s) }
}

func puller(_ t: RoutedTransport, _ cdn: FakeCDN, _ notes: Notes = Notes()) -> StorePull {
    StorePull(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })),
              download: { try await cdn.download($0) }, say: { notes.say($0) })
}

let today = ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!

@Test func pullWritesTheWholeListing() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let t = RoutedTransport(fakeApp())
    let cdn = FakeCDN([homeURL: homePNG, "https://example.apple.com/intro.m3u8": Data("#EXTM3U\n".utf8)])
    let notes = Notes()
    let report = try await puller(t, cdn, notes).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)

    #expect(read("app.yml", in: dir) == """
        # The App Store listing (docs/appstore-manifest.md). `xless store pull` rewrites this file; values are App Store Connect's.
        bundleID: com.example.app
        sku: EXAMPLE1
        platform: IOS
        primaryLocale: en-US
        version: '1.1'
        copyright: 2026 Example Inc.
        contentRights: DOES_NOT_USE_THIRD_PARTY_CONTENT
        categories:
          primary: UTILITIES
          secondary: PRODUCTIVITY
        ageRating:
          ageRatingOverrideV2: NONE
          gambling: false
          violenceCartoonOrFantasy: NONE
        release:
          type: SCHEDULED
          earliestDate: '2026-12-01T08:00:00Z'
          phased: true
        review:
          contact:
            firstName: Ada
            lastName: Lovelace
            phone: +1 555 0100
            email: ada@example.com
          demoAccount:
            required: true
            name: demo@example.com
            passwordSecret: XLESS_DEMO_PASSWORD
          notes: |-
            Line one
            Line two
        encryption:
          containsProprietaryCryptography: false
          exempt: true
        accessibility:
          IPHONE:
            supportsDarkInterface: true
            supportsVoiceover: true
        eula:
          file: eula.txt
          territories:
          - CAN
          - USA
        pricing:
          baseTerritory: USA
          price: '1.99'
        availability:
          territories:
          - CAN
          - USA
          newTerritories: false

        """)
    #expect(read("en-US/name.txt", in: dir) == "Example\n")
    #expect(read("en-US/description.txt", in: dir) == "Does things.\nWell.\n")
    #expect(read("en-US/whats_new.txt", in: dir) == "Fixes.\n")
    #expect(read("en-US/marketing_url.txt", in: dir) == nil)
    #expect(read("de-DE/subtitle.txt", in: dir) == nil, "an empty value is no file")
    #expect(read("eula.txt", in: dir) == "Terms.\n")
    #expect(try Data(contentsOf: dir.appendingPathComponent("en-US/screenshots/APP_IPHONE_67/01-home.png")) == homePNG)
    #expect(cdn.fetched == [homeURL, "https://example.apple.com/intro.m3u8"])
    #expect(MediaLock.read(dir).files.values == [
        "en-US/screenshots/APP_IPHONE_67/01-home.png": .init(md5: MD5Hex.of(homePNG), appleChecksum: "apple-home", id: "SS1"),
        // What pull could not download is recorded as there at Apple, with no local file, for push to leave alone.
        "en-US/screenshots/APP_IPHONE_67/02-Settings-Screen.png": .init(md5: nil, appleChecksum: "apple-settings", id: "SS2"),
        "de-DE/previews/IPHONE_67/01-intro.mov": .init(md5: nil, appleChecksum: "apple-intro", id: "PV1"),
    ])
    #expect(report.text == """
        Pulled com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION) into appstore/: 2 locales (en-US, de-DE), 2 screenshots, 1 preview (1 downloaded, 0 unchanged)
          not downloaded: en-US/screenshots/APP_IPHONE_67/02-Settings-Screen.png (processing: UPLOAD_COMPLETE)
          not downloaded: de-DE/previews/IPHONE_67/01-intro.mov (App Store Connect serves it only as a stream)

        """)
    #expect(notes.lines.contains { $0.contains("xless secrets import XLESS_DEMO_PASSWORD") })
    // The pulled manifest reads back without a problem, and validates as a draft.
    let back = ManifestReader.read(dir)
    #expect(back.issues.isEmpty)
    #expect(ManifestValidator.validate(back.manifest, at: dir, draft: true).filter { $0.severity == .error }.isEmpty)
}

@Test func theDemoPasswordIsNeverAskedFor() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(fakeApp())
    _ = try await puller(t, FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: root.appendingPathComponent("appstore"), today: today)
    let q = t.queries("/v1/appStoreVersions/V2/appStoreReviewDetail")
    #expect(q == [["fields[appStoreReviewDetails]=contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName,demoAccountRequired,notes"]])
    #expect(!q.joined().joined().contains("Password"))
}

@Test func liveAndVersionSelectionsPickTheirVersion() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = fakeApp()
    routes["/v1/appInfos/I1/appInfoLocalizations"] = (200, list([#"{"type":"appInfoLocalizations","id":"L9","attributes":{"locale":"en-US","name":"Old"}}"#]))
    routes["/v1/appStoreVersions/V1/appStoreVersionLocalizations"] = (200, list([]))
    let dir = root.appendingPathComponent("appstore")
    let report = try await puller(RoutedTransport(routes), FakeCDN([:])).run(app: fakeASCApp, platform: nil, selection: .live, into: dir, today: today)
    #expect(report.version == "1.0")
    #expect(read("en-US/name.txt", in: dir) == "Old\n")
    #expect(read("app.yml", in: dir)?.contains("primary: GAMES") == true, "the live app info")
    await #expect(throws: XlessError.self) {
        _ = try await puller(RoutedTransport(routes), FakeCDN([:])).run(app: fakeASCApp, platform: nil, selection: .version("9.9"), into: dir, today: today)
    }
    do {
        _ = try await puller(RoutedTransport(routes), FakeCDN([:])).run(app: fakeASCApp, platform: "MAC_OS", selection: .automatic, into: dir, today: today)
        Issue.record("no macOS version")
    } catch let e as XlessError {
        #expect(e.description == "[account] the app has no App Store version for MAC_OS — pass --platform for another platform, or create the version in App Store Connect (`xless store push` will, #94)")
    }
}

@Test func partsTheKeyMayNotReadKeepTheManifestsValues() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("primaryLocale: en-US\nrelease:\n  phased: true\neula:\n  file: eula.txt\n  territories: all\npricing:\n  price: free\n", "app.yml", in: dir)
    try write("Our terms.\n", "eula.txt", in: dir)
    var routes = fakeApp()
    let forbidden = (403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"no"}]}"#)
    for path in ["/v1/apps/123/endUserLicenseAgreement", "/v1/appStoreVersions/V2/appStoreVersionPhasedRelease", "/v1/apps/123/appPriceSchedule"] { routes[path] = forbidden }
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    let app = try #require(read("app.yml", in: dir))
    #expect(app.contains("phased: true") && app.contains("eula:\n  file: eula.txt\n  territories: all") && app.contains("pricing:\n  price: free"))
    #expect(read("eula.txt", in: dir) == "Our terms.\n")
}

@Test func pullRefusesWhatItMustNotReplace() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pull = puller(RoutedTransport(fakeApp()), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 }))
    try write("# my project\n", "README.md", in: root)
    do {
        _ = try await pull.run(app: fakeASCApp, platform: nil, selection: .automatic, into: root, today: today)
        Issue.record("pulled over a directory that is not a manifest")
    } catch let e as XlessError { #expect(e.cause.contains("is not an App Store manifest (it has no app.yml) and is not empty")) }
    #expect(read("README.md", in: root) == "# my project\n")
    let dir = root.appendingPathComponent("appstore")
    try write("primaryLocale: [en-US\nprivacy:\n  collectsData: false\n", "app.yml", in: dir)
    do {
        _ = try await pull.run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
        Issue.record("pulled over an unreadable app.yml")
    } catch let e as XlessError { #expect(e.cause.hasPrefix("appstore/app.yml cannot be read: is not valid YAML")) }
    #expect(read("app.yml", in: dir) == "primaryLocale: [en-US\nprivacy:\n  collectsData: false\n")
}

@Test func unusableNamesFromAppleAreLeftOut() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = fakeApp()
    routes["/v1/appStoreVersions/V2/appStoreVersionLocalizations"] = (200, list([
        #"{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{"locale":"en-US","description":"Does things."}}"#,
        #"{"type":"appStoreVersionLocalizations","id":"VL3","attributes":{"locale":"../../evil","description":"x"}}"#,
    ]))
    routes["/v1/appStoreVersionLocalizations/VL1/appScreenshotSets"] = (200, list([#"{"type":"appScreenshotSets","id":"S1","attributes":{"screenshotDisplayType":"../X"}}"#]))
    let notes = Notes()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream), notes).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["appstore"])
    #expect(ManifestReader.read(dir).manifest.locales.keys.sorted() == ["de-DE", "en-US"])
    #expect(notes.lines.contains("note: App Store Connect sent a localization with an unusable locale (../../evil); it is left out"))
    #expect(notes.lines.contains("note: App Store Connect sent a media set of an unusable type (../X); it is left out"))
}

@Test func optionalPartsAppleDoesNotHaveAreLeftOut() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = fakeApp()
    for path in ["/v1/apps/123/endUserLicenseAgreement", "/v1/apps/123/appPriceSchedule", "/v1/apps/123/appAvailabilityV2",
                 "/v1/apps/123/accessibilityDeclarations", "/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] { routes[path] = nil }
    routes["/v1/appEncryptionDeclarations"] = (403, #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"no"}]}"#)
    let notes = Notes()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 }), notes).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    let app = try #require(read("app.yml", in: dir))
    #expect(app.contains("eula: standard") && !app.contains("pricing") && !app.contains("availability") && !app.contains("encryption") && app.contains("phased: false"))
    #expect(notes.lines.contains("note: this API key may not read the encryption declarations (HTTP 403); app.yml keeps what it had for it"))
}

@Test func anUnchangedOriginalIsKeptNotDownloaded() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    // The original upload (bigger than Apple's re-encoded copy), recorded in the lock by an earlier push.
    let original = homePNG + Data(repeating: 7, count: 100)
    try write(original, "en-US/screenshots/APP_IPHONE_67/01-my-home.png", in: dir)
    try write("primaryLocale: en-US\nreview:\n  demoAccount:\n    passwordSecret: MY_DEMO\nprivacy:\n  collectsData: false\n", "app.yml", in: dir)
    try write("# keep me\n", "README.md", in: dir)
    try write(try MediaLock(files: ["en-US/screenshots/APP_IPHONE_67/01-my-home.png": .init(md5: MD5Hex.of(original), appleChecksum: "apple-home")]).render(),
              MediaLock.fileName, in: dir)
    let cdn = FakeCDN(introStream)
    let report = try await puller(RoutedTransport(fakeApp()), cdn).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    #expect(cdn.fetched == ["https://example.apple.com/intro.m3u8"], "the screenshot is not downloaded")
    #expect(report.kept == 1 && report.downloaded == 0)
    #expect(try Data(contentsOf: dir.appendingPathComponent("en-US/screenshots/APP_IPHONE_67/01-home.png")) == original)
    #expect(read("en-US/screenshots/APP_IPHONE_67/01-my-home.png", in: dir) == nil, "renamed after Apple's file name")
    #expect(MediaLock.read(dir).files["en-US/screenshots/APP_IPHONE_67/01-home.png"]?.md5 == MD5Hex.of(original))
    let app = try #require(read("app.yml", in: dir))
    #expect(app.contains("passwordSecret: MY_DEMO") && app.hasSuffix("privacy:\n  collectsData: false\n"))
    #expect(read("README.md", in: dir) == "# keep me\n")
}

@Test func aFailedDownloadLeavesTheOldManifest() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("primaryLocale: en-US\n", "app.yml", in: dir)
    await #expect(throws: (any Error).self) {
        _ = try await puller(RoutedTransport(fakeApp()), FakeCDN([:])).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    }
    #expect(read("app.yml", in: dir) == "primaryLocale: en-US\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["appstore"], "no partial or staging directory left")
}

@Test func mediaFileNamesArePositionAndASafeName() {
    #expect(MediaFetch.fileName(index: 1, original: "01-home.png", kind: "screenshots") == "01-home.png")
    #expect(MediaFetch.fileName(index: 3, original: "Écran d'accueil.PNG", kind: "screenshots") == "03--cran-d-accueil.PNG")
    let hostile = MediaFetch.fileName(index: 2, original: "../../etc/passwd", kind: "screenshots")
    #expect(hostile.hasPrefix("02-") && hostile.hasSuffix(".png") && !hostile.contains("/"))
    #expect(MediaFetch.fileName(index: 12, original: nil, kind: "previews") == "12-preview.mov")
    #expect(MediaFetch.fileName(index: 1, original: "clip.mp4", kind: "previews") == "01-clip.mp4")
}
