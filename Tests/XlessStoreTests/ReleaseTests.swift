import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

// `release submit`'s pre-flight and submission sequence against the path-routed fake App Store Connect of StorePullTests.

/// The fake app with nothing pending (as StorePushTests' `synced`), a valid build B1 of 1.1 not attached yet, and no
/// review submission.
func releaseApp() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/accessibilityDeclarations"] = (200, list([
        #"{"type":"accessibilityDeclarations","id":"AC1","attributes":{"deviceFamily":"IPHONE","state":"PUBLISHED","supportsVoiceover":true,"supportsDarkInterface":true}}"#,
    ]))
    routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":null}"#)
    routes["/v1/builds/B1"] = (200, buildJSON())
    routes["/v1/builds"] = (200, list([buildItem()], included: buildIncluded))
    routes["/v1/reviewSubmissions"] = (200, list([]))
    return routes
}

func buildItem(state: String = "VALID", encryption: String = "false") -> String {
    #"{"type":"builds","id":"B1","attributes":{"version":"42","processingState":"\#(state)","expired":false,"usesNonExemptEncryption":\#(encryption)},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"PRV1"}},"app":{"data":{"type":"apps","id":"123"}}}}"#
}
let buildIncluded = [#"{"type":"preReleaseVersions","id":"PRV1","attributes":{"version":"1.1","platform":"IOS"}}"#,
                     #"{"type":"apps","id":"123","attributes":{"bundleId":"com.example.app","name":"Example"}}"#]
func buildJSON(state: String = "VALID", encryption: String = "false") -> String {
    #"{"data":\#(buildItem(state: state, encryption: encryption)),"included":[\#(buildIncluded.joined(separator: ","))]}"#
}

let releaseVersion = ASCAppStoreVersion(resource: ASCAnyResource(type: "appStoreVersions", id: "V2", attributes: [
    "platform": .string("IOS"), "versionString": .string("1.1"), "appVersionState": .string("PREPARE_FOR_SUBMISSION"),
    "releaseType": .string("SCHEDULED"), "earliestReleaseDate": .string("2026-12-01T08:00:00Z"),
]))

private func resources(_ t: HTTPTransport) -> ASCResources { ASCResources(client: ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })) }

private func writes(_ t: RoutedTransport) -> [String] {
    t.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
}

/// The fake app pulled into a fresh `appstore/` (the caller removes `root`).
private func pulledRelease() async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(releaseApp()), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 }))
        .run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    return (root, dir)
}

private func build(_ t: RoutedTransport) async throws -> ASCBuildDetail { try await ASCBuilds(resources: resources(t)).get(id: "B1") }

private func names(_ checks: [PreflightCheck]) -> [String] { checks.map(\.name) }

// MARK: Pre-flight

@Test func aPushedCompleteListingPassesThePreflight() async throws {
    let (root, dir) = try await pulledRelease()
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(releaseApp())
    let report = try await ReleasePreflight(resources: resources(t)).run(.init(app: fakeASCApp, platform: "IOS", version: releaseVersion,
                                                                                build: try await build(t), manifestDir: dir, today: today))
    #expect(report.passed, "\(report.text)")
    #expect(report.checks.filter { $0.status == .ok }.map(\.name) == ["manifest", "metadata", "listing", "screenshots", "pricing", "availability", "build", "encryption", "review contact"])
    #expect(report.checks.first { $0.name == "privacy" }?.status == .warning, "no web session: not checked")
    #expect(report.checks.contains { $0.name == "screenshots" && $0.status == .warning && $0.message.contains("iPad") })
    #expect(writes(t).isEmpty, "the pre-flight only reads")
}

@Test func thePreflightListsEveryMissingItemAtOnce() async throws {
    var routes = releaseApp()
    routes["/v1/appStoreVersions/V2/appStoreVersionLocalizations"] = (200, list([
        #"{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{"locale":"en-US","description":"","keywords":"tools","supportUrl":null}}"#,
    ]))
    routes["/v1/appStoreVersionLocalizations/VL1/appScreenshotSets"] = (200, list([]))
    routes["/v1/appStoreVersions/V2/appStoreReviewDetail"] = (200, single(nil))
    routes["/v1/apps/123/appPriceSchedule"] = nil
    routes["/v1/apps/123/appAvailabilityV2"] = nil
    let t = RoutedTransport(routes)
    let missing = try tempDir().appendingPathComponent("appstore")
    let report = try await ReleasePreflight(resources: resources(t)).run(.init(app: fakeASCApp, platform: "IOS", version: releaseVersion,
                                                                                build: nil, manifestDir: missing, today: today))
    #expect(!report.passed)
    #expect(names(report.failures) == ["listing", "screenshots", "pricing", "availability", "build", "review contact"])
    #expect(report.failures[0].message == "en-US: no description, support URL")
    #expect(report.checks[0] == PreflightCheck("manifest", .skipped, "no appstore/ directory: the listing is checked on App Store Connect only"))
    #expect(report.text.hasPrefix("  FAIL  listing         en-US: no description, support URL — "))
    #expect(report.failures.allSatisfy { $0.fix != nil })
}

@Test func anUnpushedChangeOrAnotherVersionFailsThePreflight() async throws {
    let (root, dir) = try await pulledRelease()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Does other things.\n", "en-US/description.txt", in: dir)
    let t = RoutedTransport(releaseApp())
    let input = ReleasePreflight.Input(app: fakeASCApp, platform: "IOS", version: releaseVersion, build: try await build(t), manifestDir: dir, today: today)
    let report = try await ReleasePreflight(resources: resources(t)).run(input)
    #expect(names(report.failures) == ["metadata"])
    #expect(report.failures[0].message == "1 change in appstore/ is not on App Store Connect (version text en-US)")
    #expect(report.failures[0].fix?.hasPrefix("`xless store push`") == true)

    let app = try String(contentsOf: dir.appendingPathComponent("app.yml"), encoding: .utf8)
    try write(app.replacingOccurrences(of: "version: '1.1'", with: "version: '1.2'").replacingOccurrences(of: "version: \"1.1\"", with: "version: \"1.2\""), "app.yml", in: dir)
    let other = try await ReleasePreflight(resources: resources(t)).run(input)
    #expect(other.failures.map(\.message) == ["appstore/app.yml describes version 1.2, not 1.1"])
    #expect(other.checks.contains(PreflightCheck("metadata", .skipped, "not compared with App Store Connect until appstore/ is fixed")))
}

@Test func theBuildMustBeValidAndAnswerExportCompliance() async throws {
    var routes = releaseApp()
    routes["/v1/builds/B1"] = (200, buildJSON(state: "PROCESSING", encryption: "null"))
    let t = RoutedTransport(routes)
    let report = try await ReleasePreflight(resources: resources(t)).run(.init(app: fakeASCApp, platform: "IOS", version: releaseVersion,
                                                                                build: try await build(t), manifestDir: nil, today: today))
    #expect(report.failures.map(\.message) == ["build 1.1+42 (B1) is still processing", "export compliance of build 1.1+42 (B1) is not answered"])
    #expect(report.failures.map(\.fix) == ["`xless builds wait B1`, then re-run", "`xless builds update B1 --uses-non-exempt-encryption false` (or true, with --encryption-declaration)"])
}

// MARK: The submission

private func submit(_ t: RoutedTransport, build: BuildReference? = .version("1.1", number: "42"), release: ReleaseChoice? = nil, phased: Bool? = nil,
                    dir: URL? = nil, dryRun: Bool = false, notes: Notes = Notes()) async throws -> ReleaseSubmission.Outcome {
    try await ReleaseSubmission(resources: resources(t), say: { notes.say($0) }).run(.init(
        app: fakeASCApp, platform: "IOS", version: releaseVersion, build: build, release: release, phased: phased, manifestDir: dir, dryRun: dryRun, today: today))
}

let draftSubmission = #"{"type":"reviewSubmissions","id":"S1","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"}}"#

@Test func aFreshSubmissionAttachesTheBuildAndSubmits() async throws {
    let t = RoutedTransport(releaseApp())
    let out = try await submit(t)
    #expect(out.outcome == .submitted)
    #expect(writes(t) == ["PATCH /v1/appStoreVersions/V2/relationships/build", "POST /v1/reviewSubmissions", "POST /v1/reviewSubmissionItems",
                          "PATCH /v1/reviewSubmissions/\(out.submissionID!)"])
    #expect(out.steps == ["attach build 1.1+42 (B1)", "create a review submission", "add version 1.1 to it", "submit it"])
    let item = try JSONDecoder().decode(JSONValue.self, from: t.requests.first { $0.url!.path == "/v1/reviewSubmissionItems" }!.httpBody!)
    #expect(item["data"]?["relationships"]?["reviewSubmission"]?["data"]?["id"]?.string == out.submissionID)
    #expect(item["data"]?["relationships"]?["appStoreVersion"]?["data"]?["id"]?.string == "V2")
}

@Test func aDraftSubmissionIsResumedWhereItStopped() async throws {
    // The draft exists, without the version: add it, then submit; never a second submission.
    var routes = releaseApp()
    routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":{"type":"builds","id":"B1"}}"#)
    routes["/v1/reviewSubmissions"] = (200, list([draftSubmission]))
    routes["/v1/reviewSubmissions/S1/items"] = (200, list([]))
    var t = RoutedTransport(routes)
    var out = try await submit(t, build: nil)
    #expect(writes(t) == ["POST /v1/reviewSubmissionItems", "PATCH /v1/reviewSubmissions/S1"])
    #expect(out.submissionID == "S1" && out.outcome == .submitted)

    // The draft holds the version already: only the submit is left.
    routes["/v1/reviewSubmissions/S1/items"] = (200, list([#"{"type":"reviewSubmissionItems","id":"IT1","attributes":{"state":"READY_FOR_REVIEW"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#]))
    t = RoutedTransport(routes)
    out = try await submit(t)
    #expect(writes(t) == ["PATCH /v1/reviewSubmissions/S1"], "the build is attached already, the item is there")
    #expect(out.steps == ["submit review submission S1"])
}

@Test func aVersionInReviewIsNotSubmittedAgain() async throws {
    var routes = releaseApp()
    routes["/v1/reviewSubmissions"] = (200, list([#"{"type":"reviewSubmissions","id":"S1","attributes":{"platform":"IOS","state":"WAITING_FOR_REVIEW","submittedDate":"2026-11-22T10:00:00Z"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#]))
    let t = RoutedTransport(routes)
    let out = try await submit(t)
    #expect(out.outcome == .alreadyInReview && out.submissionID == "S1" && out.submissionState == "WAITING_FOR_REVIEW")
    #expect(writes(t).isEmpty && out.preflight == nil)
}

@Test func aFailedPreflightSendsNothing() async throws {
    var routes = releaseApp()
    routes["/v1/builds"] = (200, list([buildItem(state: "PROCESSING")], included: buildIncluded))
    routes["/v1/builds/B1"] = (200, buildJSON(state: "PROCESSING"))
    let t = RoutedTransport(routes)
    let out = try await submit(t)
    #expect(out.outcome == .preflightFailed && out.steps.isEmpty)
    #expect(out.preflight?.failures.map(\.name) == ["build"])
    #expect(writes(t).isEmpty)
}

@Test func aDraftOfAnotherVersionIsRefused() async throws {
    var routes = releaseApp()
    routes["/v1/reviewSubmissions"] = (200, list([draftSubmission]))
    routes["/v1/reviewSubmissions/S1/items"] = (200, list([#"{"type":"reviewSubmissionItems","id":"IT9","attributes":{"state":"READY_FOR_REVIEW"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V1"}}}}"#]))
    let t = RoutedTransport(routes)
    await #expect(throws: XlessError.self) { _ = try await submit(t) }
    #expect(writes(t).isEmpty)
}

@Test func aDryRunListsTheReleaseStepsAndSendsNothing() async throws {
    let (root, dir) = try await pulledRelease()
    defer { try? FileManager.default.removeItem(at: root) }
    // app.yml says SCHEDULED and phased; the flags override both, so the manifest still counts as pushed.
    let t = RoutedTransport(releaseApp())
    let out = try await submit(t, release: .afterApproval, phased: false, dir: dir, dryRun: true)
    #expect(out.outcome == .dryRun, "\(out.preflight?.text ?? "")")
    #expect(out.steps == ["attach build 1.1+42 (B1)", "release scheduled 2026-12-01T08:00:00Z → after approval", "remove the phased release",
                          "create a review submission", "add version 1.1 to it", "submit it"])
    #expect(writes(t).isEmpty)
    let sent = RoutedTransport(releaseApp())
    _ = try await submit(sent, release: .afterApproval, phased: false, dir: dir)
    #expect(writes(sent).prefix(3) == ["PATCH /v1/appStoreVersions/V2/relationships/build", "PATCH /v1/appStoreVersions/V2", "DELETE /v1/appStoreVersionPhasedReleases/P1"])
}

@Test func anApprovedOrReleasedVersionIsNotSubmittable() {
    func version(_ state: String) -> ASCAppStoreVersion {
        ASCAppStoreVersion(resource: ASCAnyResource(type: "appStoreVersions", id: "V2", attributes: ["platform": .string("IOS"), "versionString": .string("1.1"), "appVersionState": .string(state)]))
    }
    #expect(ReleaseSubmission.notSubmittable(version("PENDING_DEVELOPER_RELEASE")).fix == "`xless release publish` releases it")
    #expect(ReleaseSubmission.notSubmittable(version("READY_FOR_DISTRIBUTION")).cause == "version 1.1 (ios) is ready for distribution; nothing was sent")
}

@Test func aRejectedSubmissionIsSubmittedAgain() async throws {
    var routes = releaseApp()
    routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":{"type":"builds","id":"B1"}}"#)
    routes["/v1/reviewSubmissions"] = (200, list([#"{"type":"reviewSubmissions","id":"S1","attributes":{"platform":"IOS","state":"UNRESOLVED_ISSUES"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#]))
    routes["PATCH /v1/reviewSubmissions/S1"] = (200, single(#"{"type":"reviewSubmissions","id":"S1","attributes":{"state":"WAITING_FOR_REVIEW"}}"#))
    let t = RoutedTransport(routes)
    let rejected = ASCAppStoreVersion(resource: ASCAnyResource(type: "appStoreVersions", id: "V2", attributes: [
        "platform": .string("IOS"), "versionString": .string("1.1"), "appVersionState": .string("REJECTED")]))
    let out = try await ReleaseSubmission(resources: resources(t)).run(.init(app: fakeASCApp, platform: "IOS", version: rejected, today: today))
    #expect(out.outcome == .submitted && out.steps == ["submit review submission S1 again"])
    #expect(out.submissionState == "WAITING_FOR_REVIEW")
    #expect(writes(t) == ["PATCH /v1/reviewSubmissions/S1"])
}

@Test func aStepThatFailsSaysHowToResume() async throws {
    var routes = releaseApp()
    routes["POST /v1/reviewSubmissionItems"] = (409, #"{"errors":[{"status":"409","code":"STATE_ERROR","title":"no","detail":"not now"}]}"#)
    let t = RoutedTransport(routes)
    let notes = Notes()
    await #expect(throws: (any Error).self) { _ = try await submit(t, notes: notes) }
    #expect(writes(t) == ["PATCH /v1/appStoreVersions/V2/relationships/build", "POST /v1/reviewSubmissions", "POST /v1/reviewSubmissionItems"])
    #expect(notes.lines.last == "note: 2 of 4 steps were sent before add version 1.1 to it failed; re-run `xless release submit` to resume (it sends only what is missing)")
}

@Test func phasedAddsAPhasedReleaseOnlyWhenThereIsNone() async throws {
    var routes = releaseApp()
    routes["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, single(nil))
    var t = RoutedTransport(routes)
    var out = try await submit(t, phased: true, dryRun: true)
    #expect(out.steps.contains("add a phased release (7 days, from the release)"))
    _ = try await submit(t, phased: true)
    #expect(writes(t).contains("POST /v1/appStoreVersionPhasedReleases"))
    routes["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, single(#"{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"ACTIVE"}}"#))
    t = RoutedTransport(routes)
    out = try await submit(t, phased: false, dryRun: true)
    #expect(!out.steps.contains { $0.contains("phased") } && out.notes == ["the phased release has started (active); --no-phased leaves it"])
}

@Test func anIPadOnlyAppPassesWithAWarningAboutIPhone() async throws {
    var routes = releaseApp()
    routes["/v1/appStoreVersionLocalizations/VL1/appScreenshotSets"] = (200, list([#"{"type":"appScreenshotSets","id":"S1","attributes":{"screenshotDisplayType":"APP_IPAD_PRO_3GEN_129"}}"#]))
    let t = RoutedTransport(routes)
    let report = try await ReleasePreflight(resources: resources(t)).run(.init(app: fakeASCApp, platform: "IOS", version: releaseVersion,
                                                                                build: try await build(t), manifestDir: nil, today: today))
    #expect(report.passed, "\(report.text)")
    #expect(report.checks.contains { $0.name == "screenshots" && $0.status == .warning && $0.message.hasPrefix("en-US: no iPhone screenshot") })
    #expect(report.checks[0].message == "no manifest for this app and platform: the listing is checked on App Store Connect only")
}

// MARK: Products

/// The release app with an in-app purchase whose version is being prepared, and a subscription group (its version
/// ready for review) whose subscription is ready to submit but has no version.
private func releaseWithProducts(iapState: String = "READY_TO_SUBMIT") -> [String: (Int, String)] {
    var routes = releaseApp()
    routes["/v1/apps/123/inAppPurchasesV2"] = (200, list([#"{"type":"inAppPurchases","id":"IAP1","attributes":{"productId":"com.example.coins","name":"Coins","inAppPurchaseType":"CONSUMABLE","state":"\#(iapState)"}}"#]))
    routes["/v2/inAppPurchases/IAP1/inAppPurchaseLocalizations"] = (200, list([#"{"type":"inAppPurchaseLocalizations","id":"IL1","attributes":{"locale":"en-US","name":"Coins"}}"#]))
    routes["/v2/inAppPurchases/IAP1/versions"] = (200, list([
        #"{"type":"inAppPurchaseVersions","id":"IV0","attributes":{"version":1,"state":"APPROVED"}}"#,
        #"{"type":"inAppPurchaseVersions","id":"IV1","attributes":{"version":2,"state":"PREPARE_FOR_SUBMISSION"}}"#,
    ]))
    routes["/v1/apps/123/subscriptionGroups"] = (200, list([#"{"type":"subscriptionGroups","id":"G1","attributes":{"referenceName":"Premium"}}"#]))
    routes["/v1/subscriptionGroups/G1/subscriptionGroupLocalizations"] = (200, list([]))
    routes["/v1/subscriptionGroups/G1/versions"] = (200, list([#"{"type":"subscriptionGroupVersions","id":"GV1","attributes":{"version":1,"state":"READY_FOR_REVIEW"}}"#]))
    routes["/v1/subscriptionGroups/G1/subscriptions"] = (200, list([#"{"type":"subscriptions","id":"SUB1","attributes":{"productId":"com.example.monthly","name":"Monthly","subscriptionPeriod":"ONE_MONTH","state":"READY_TO_SUBMIT"}}"#]))
    routes["/v1/subscriptions/SUB1/subscriptionLocalizations"] = (200, list([#"{"type":"subscriptionLocalizations","id":"SL1","attributes":{"locale":"en-US","name":"Monthly"}}"#]))
    routes["/v1/subscriptions/SUB1/versions"] = (200, list([]))
    routes["/v1/subscriptions/SUB1/prices"] = (200, list([]))
    return routes
}

private func pulledWithProducts(_ routes: [String: (Int, String)]) async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 }))
        .run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    return (root, dir)
}

@Test func theManifestsProductsGoToAppReviewWithTheVersion() async throws {
    let (root, dir) = try await pulledWithProducts(releaseWithProducts())
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(releaseWithProducts())
    let out = try await submit(t, dir: dir)
    #expect(out.outcome == .submitted, "\(out.preflight?.text ?? "")")
    #expect(out.preflight?.checks.first { $0.name == "products" }?.status == .ok)
    #expect(out.steps == ["attach build 1.1+42 (B1)", "create a review submission", "add version 1.1 to it",
                          "add in-app purchase com.example.coins to it", "add subscription group Premium to it",
                          "submit subscription com.example.monthly with the version", "submit it"])
    #expect(writes(t) == ["PATCH /v1/appStoreVersions/V2/relationships/build", "POST /v1/reviewSubmissions", "POST /v1/reviewSubmissionItems",
                          "POST /v1/reviewSubmissionItems", "POST /v1/reviewSubmissionItems", "POST /v1/subscriptionSubmissions",
                          "PATCH /v1/reviewSubmissions/\(out.submissionID!)"])
    let items = try t.requests.filter { $0.url!.path == "/v1/reviewSubmissionItems" }.map { try JSONDecoder().decode(JSONValue.self, from: $0.httpBody!) }
    #expect(items[1]["data"]?["relationships"]?["inAppPurchaseVersion"]?["data"]?["id"]?.string == "IV1")
    #expect(items[2]["data"]?["relationships"]?["subscriptionGroupVersion"]?["data"]?["id"]?.string == "GV1")
    #expect(items.allSatisfy { $0["data"]?["relationships"]?["reviewSubmission"]?["data"]?["id"]?.string == out.submissionID })
    let classic = try JSONDecoder().decode(JSONValue.self, from: t.requests.first { $0.url!.path == "/v1/subscriptionSubmissions" }!.httpBody!)
    #expect(classic["data"]?["relationships"]?["subscription"]?["data"]?["id"]?.string == "SUB1")
}

@Test func productsTheDraftHoldsAreNotAddedTwiceAndNoProductsLeavesThemOut() async throws {
    var routes = releaseWithProducts()
    routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":{"type":"builds","id":"B1"}}"#)
    routes["/v1/reviewSubmissions"] = (200, list([draftSubmission]))
    routes["/v1/reviewSubmissions/S1/items"] = (200, list([
        #"{"type":"reviewSubmissionItems","id":"IT1","attributes":{"state":"READY_FOR_REVIEW"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#,
        #"{"type":"reviewSubmissionItems","id":"IT2","attributes":{"state":"READY_FOR_REVIEW"},"relationships":{"inAppPurchaseVersion":{"data":{"type":"inAppPurchaseVersions","id":"IV1"}}}}"#,
    ]))
    let (root, dir) = try await pulledWithProducts(routes)
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(routes)
    let out = try await submit(t, build: nil, dir: dir, dryRun: true)
    #expect(out.steps == ["add subscription group Premium to it", "submit subscription com.example.monthly with the version", "submit review submission S1"])
    // App Store Connect gives an item's product version only when it is included.
    #expect(t.queries("/v1/reviewSubmissions/S1/items").allSatisfy { $0.contains("include=appStoreVersion,inAppPurchaseVersion,subscriptionVersion,subscriptionGroupVersion") })

    let none = try await ReleaseSubmission(resources: resources(RoutedTransport(routes))).run(.init(
        app: fakeASCApp, platform: "IOS", version: releaseVersion, manifestDir: dir, dryRun: true, today: today, products: false))
    #expect(none.steps == ["submit review submission S1"])
}

@Test func aProductMissingMetadataFailsThePreflight() async throws {
    let (root, dir) = try await pulledWithProducts(releaseWithProducts(iapState: "MISSING_METADATA"))
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(releaseWithProducts(iapState: "MISSING_METADATA"))
    let out = try await submit(t, dir: dir)
    #expect(out.outcome == .preflightFailed)
    let check = try #require(out.preflight?.checks.first { $0.name == "products" })
    #expect(check.status == .failed && check.message == "in-app purchase com.example.coins is missing metadata")
    #expect(writes(t).isEmpty)
}

@Test func noProductsSkipsTheProductsCheck() async throws {
    let (root, dir) = try await pulledWithProducts(releaseWithProducts(iapState: "MISSING_METADATA"))
    defer { try? FileManager.default.removeItem(at: root) }
    let t = RoutedTransport(releaseWithProducts(iapState: "MISSING_METADATA"))
    let out = try await ReleaseSubmission(resources: resources(t)).run(.init(
        app: fakeASCApp, platform: "IOS", version: releaseVersion, build: .version("1.1", number: "42"), manifestDir: dir, dryRun: true, today: today, products: false))
    #expect(out.outcome == .dryRun, "\(out.preflight?.text ?? "")")
    #expect(out.preflight?.checks.contains { $0.name == "products" } == false)
    #expect(!out.steps.contains { $0.contains("in-app purchase") || $0.contains("subscription") })
}

@Test func aSubmissionAppReviewSentBackTakesTheProductsToo() async throws {
    var routes = releaseWithProducts()
    routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":{"type":"builds","id":"B1"}}"#)
    routes["/v1/reviewSubmissions"] = (200, list([#"{"type":"reviewSubmissions","id":"S2","attributes":{"platform":"IOS","state":"UNRESOLVED_ISSUES"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#]))
    routes["/v1/reviewSubmissions/S2/items"] = (200, list([#"{"type":"reviewSubmissionItems","id":"IT1","attributes":{"state":"REJECTED"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#]))
    let (root, dir) = try await pulledWithProducts(routes)
    defer { try? FileManager.default.removeItem(at: root) }
    let out = try await submit(RoutedTransport(routes), build: nil, dir: dir, dryRun: true)
    #expect(out.steps == ["add in-app purchase com.example.coins to it", "add subscription group Premium to it",
                          "submit subscription com.example.monthly with the version", "submit review submission S2 again"])
}
