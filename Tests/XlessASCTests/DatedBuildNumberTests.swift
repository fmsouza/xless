import Foundation
import Testing
import XlessCore
@testable import XlessASC

// 2026-10-15 12:00 UTC
private let today = Date(timeIntervalSince1970: 1_792_065_600)

private func fails(_ existing: [String], containing: String) {
    do {
        _ = try DatedBuildNumber.next(version: "1.0.0", today: today, existing: existing)
        Issue.record("expected a throw for \(existing)")
    } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.cause.contains(containing), "\(e.cause)")
    } catch { Issue.record("wrong error \(error)") }
}

@Test func startsAtOne() throws {
    #expect(try DatedBuildNumber.next(version: "1.0.0", today: today, existing: []) == "1.0.0.2026101501")
}

@Test func incrementsPastTheMaxNN() throws {
    #expect(try DatedBuildNumber.next(version: "1.0.0", today: today, existing: ["1.0.0.2026101501", "1.0.0.2026101507"]) == "1.0.0.2026101508")
}

@Test func yesterdaysBuildsDoNotCount() throws {
    #expect(try DatedBuildNumber.next(version: "1.0.0", today: today, existing: ["1.0.0.2026101499"]) == "1.0.0.2026101501")
}

@Test func capsAtNinetyNine() {
    fails(["1.0.0.2026101599"], containing: "99 builds already uploaded for 1.0.0 today")
}

@Test func legacyBuildThatSortsHigherRefuses() {
    fails(["3"], containing: "would not sort after existing build 3")
}

@Test func futureDatedBuildRefuses() {
    fails(["1.0.0.2026101601"], containing: "would not sort after existing build 1.0.0.2026101601")
}

@Test func dottedComparisonTreatsMissingComponentsAsZero() {
    #expect(DatedBuildNumber.compare("1.0.0.2026101501", "1.0.0.2026101501") == 0)
    #expect(DatedBuildNumber.compare("3", "1.0.0.2026101501") > 0)
    #expect(DatedBuildNumber.compare("1.0", "1.0.0") == 0)
    #expect(DatedBuildNumber.compare("1.0.0.2026101502", "1.0.0.2026101501") > 0)
}

private func page(_ ids: [String], next: String? = nil) -> String {
    let data = ids.map { #"{"type":"builds","id":"b\#($0)","attributes":{"version":"\#($0)"}}"# }.joined(separator: ",")
    let links = next.map { #","links":{"next":"\#($0)"}"# } ?? ""
    return #"{"data":[\#(data)]\#(links)}"#
}

@Test func existingBuildsFollowsPagesWithTheRightQuery() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#),
        (200, page(["1.0.0.2026101501"], next: "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=app1&cursor=XYZ&limit=200")),
        (200, page(["1.0.0.2026101502"])),
    ])
    let client = ASCClient(credentials: testCreds, transport: t)
    let got = try await DatedBuildNumber.existingBuilds(client: client, bundleID: "com.example.app", version: "1.0.0")
    #expect(got == ["1.0.0.2026101501", "1.0.0.2026101502"])
    #expect(t.requests.count == 3)
    let q0 = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!
    #expect(q0.path == "/v1/apps")
    #expect(q0.queryItems?.contains(URLQueryItem(name: "filter[bundleId]", value: "com.example.app")) == true)
    let q1 = URLComponents(url: t.requests[1].url!, resolvingAgainstBaseURL: false)!
    #expect(q1.path == "/v1/builds")
    let items = Dictionary(uniqueKeysWithValues: q1.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(items["filter[app]"] == "app1")
    #expect(items["filter[preReleaseVersion.version]"] == "1.0.0")
    #expect(items["fields[builds]"] == "version")
    #expect(items["limit"] == "200")
    #expect(t.requests[2].url!.absoluteString.contains("cursor=XYZ"))
}

/// The order check needs every number: an answer it cannot read is an error, never a shorter list.
@Test(arguments: [#"{"version":42}"#, #"{"version":{"a":1}}"#, "{}", #"{"version":null}"#])
func aBuildWhoseNumberCannotBeReadIsNotLeftOut(attributes: String) async throws {
    let app = (200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#)
    let t = MockTransport([app, (200, #"{"data":[{"type":"builds","id":"b1","attributes":{"version":"1.0.0.2026101501"}},{"type":"builds","id":"b2","attributes":\#(attributes)}]}"#)])
    let client = ASCClient(credentials: testCreds, transport: t)
    await #expect(throws: DecodingError.self) { try await DatedBuildNumber.existingBuilds(client: client, bundleID: "com.example.app", version: "1.0.0") }

    let unreadable = MockTransport([(200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":7}}]}"#)])
    let other = ASCClient(credentials: testCreds, transport: unreadable)
    await #expect(throws: DecodingError.self) { try await DatedBuildNumber.existingBuilds(client: other, bundleID: "com.example.app", version: "1.0.0") }
}

@Test func noAppRecordMeansNoBuildsYet() async throws {
    // First run: the bundle ID is registered at `sign` and `upload` reports the missing record, so this must not fail.
    let t = MockTransport([(200, #"{"data":[]}"#)])
    let client = ASCClient(credentials: testCreds, transport: t)
    #expect(try await DatedBuildNumber.existingBuilds(client: client, bundleID: "com.example.app", version: "1.0.0") == [])
    #expect(t.requests.count == 1)
    let v = try await DatedBuildNumber.compute(version: "1.0.0", bundleID: "com.example.app", secrets: Secrets(env: ascEnv), today: today,
                                               makeClient: { _ in ASCClient(credentials: testCreds, transport: MockTransport([(200, #"{"data":[]}"#)])) })
    #expect(v == "1.0.0.2026101501")
}

// MARK: resolve (the Context-level behaviour)

private let ascEnv = ["ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_KEY_P8": "pem"]

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("xless-dated-\(UUID().uuidString)/.xless/build/ios/build-number")
}

@Test func notFreshReadsTheRecordedNumber() async throws {
    let f = tempFile()
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "1.0.0.2026101503\n".write(to: f, atomically: true, encoding: .utf8)
    let v = try await DatedBuildNumber.resolve(version: "1.0.0", bundleID: "com.example.app", fresh: false, file: f,
                                               secrets: Secrets(env: [:]), today: today, makeClient: { _ in fatalError("no network") })
    #expect(v == "1.0.0.2026101503")
}

@Test func notFreshWithoutRecordIsAConfigError() async {
    do {
        _ = try await DatedBuildNumber.resolve(version: "1.0.0", bundleID: "com.example.app", fresh: false, file: tempFile(),
                                               secrets: Secrets(env: [:]), today: today, makeClient: { _ in fatalError("no network") })
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.cause == "no build number recorded for this work copy")
        #expect(e.fix.contains("xless ship"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func freshWithoutCredentialsPointsAtTheKeys() async {
    do {
        _ = try await DatedBuildNumber.resolve(version: "1.0.0", bundleID: "com.example.app", fresh: true, file: tempFile(),
                                               secrets: Secrets(env: [:]), today: today, makeClient: { _ in fatalError("no network") })
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.fix.contains("ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func freshQueriesComputesAndPersists() async throws {
    let f = tempFile()
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#),
        (200, page(["1.0.0.2026101501"])),
    ])
    let v = try await DatedBuildNumber.resolve(version: "1.0.0", bundleID: "com.example.app", fresh: true, file: f,
                                               secrets: Secrets(env: ascEnv), today: today,
                                               makeClient: { _ in ASCClient(credentials: testCreds, transport: t) })
    #expect(v == "1.0.0.2026101502")
    #expect(try String(contentsOf: f, encoding: .utf8) == "1.0.0.2026101502\n")
}

@Test func signedOrNonAsciiDigitNNIsIgnored() throws {
    // "+5" and "-1" are not two ASCII digits, so they are not NN values.
    #expect(try DatedBuildNumber.next(version: "1.0.0", today: today, existing: ["1.0.0.2026101+5", "1.0.0.2026101-1", "1.0.0.2026101٣٣"]) == "1.0.0.2026101501")
}

@Test func nextLinkWithBracketedKeysArrivesIntact() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#),
        (200, page(["1.0.0.2026101501"], next: "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=app1&filter[preReleaseVersion.version]=1.0.0&fields[builds]=version&limit=200&cursor=AB%2BC")),
        (200, page([])),
    ])
    _ = try await DatedBuildNumber.existingBuilds(client: ASCClient(credentials: testCreds, transport: t), bundleID: "com.example.app", version: "1.0.0")
    let c = URLComponents(url: t.requests[2].url!, resolvingAgainstBaseURL: false)!
    #expect(c.path == "/v1/builds")
    let items = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(items["filter[app]"] == "app1")
    #expect(items["filter[preReleaseVersion.version]"] == "1.0.0")
    #expect(items["cursor"] == "AB+C", "\(t.requests[2].url!.absoluteString)")
    #expect(!t.requests[2].url!.absoluteString.contains("%255B"), "double-encoded")
}

@Test func resolutionGate() {
    #expect(DatedBuildNumber.shouldResolve(scheme: .dated, override: nil))
    #expect(!DatedBuildNumber.shouldResolve(scheme: .dated, override: "7"))
    #expect(!DatedBuildNumber.shouldResolve(scheme: .fixed, override: nil))
    #expect(!DatedBuildNumber.shouldResolve(scheme: .fixed, override: "7"))
}

@Test func freshRuns() {
    #expect(DatedBuildNumber.isFreshRun(command: "ship", from: .prepare))
    #expect(DatedBuildNumber.isFreshRun(command: "ship", from: .build))
    #expect(!DatedBuildNumber.isFreshRun(command: "ship", from: .assets))
    #expect(!DatedBuildNumber.isFreshRun(command: "ship", from: .upload))
    #expect(DatedBuildNumber.isFreshRun(command: "prepare"))
    #expect(DatedBuildNumber.isFreshRun(command: "build"))
    for c in ["assets", "finalize", "sign", "package", "upload"] { #expect(!DatedBuildNumber.isFreshRun(command: c)) }
}

@Test func nextLinkWithEncodedBracketsArrivesIntact() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#),
        (200, page(["1.0.0.2026101501"], next: "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=app1&filter%5BpreReleaseVersion.version%5D=1.0.0&cursor=AB%2BC")),
        (200, page([])),
    ])
    _ = try await DatedBuildNumber.existingBuilds(client: ASCClient(credentials: testCreds, transport: t), bundleID: "com.example.app", version: "1.0.0")
    let c = URLComponents(url: t.requests[2].url!, resolvingAgainstBaseURL: false)!
    let items = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(items["filter[preReleaseVersion.version]"] == "1.0.0")
    #expect(items["cursor"] == "AB+C")
    #expect(t.requests[2].url!.absoluteString.hasSuffix("cursor=AB%2BC"))
}

// MARK: settle (Context.load)

private func datedConfig() -> ProjectConfig {
    ProjectConfig(bundleID: "com.example.app", teamID: "ABCDE12345", version: "1.0.0", build: "1.0.0.2000010101",
                  platforms: [.ios: PlatformConfig(minimumOS: "16.0", product: "App")], buildScheme: .dated)
}

private func settleError(_ config: ProjectConfig, override: String? = nil, fresh: Bool = true, transport: MockTransport) async -> XlessError? {
    var c = config
    do {
        try await DatedBuildNumber.settle(&c, override: override, file: tempFile(), secrets: Secrets(env: ascEnv), fresh: fresh, today: today,
                                          makeClient: { _ in ASCClient(credentials: testCreds, transport: transport, sleep: { _ in }) })
        return nil
    } catch let e as XlessError { return e } catch {
        Issue.record("escaped the stage contract: \(error)")
        return nil
    }
}

@Test func settleReportsDecodingFailuresAsConfigErrors() async {
    let e = await settleError(datedConfig(), transport: MockTransport([(200, "not json")]))
    #expect(e?.stage == .config)
}

@Test func settleReportsNetworkFailuresAsConfigErrors() async {
    let e = await settleError(datedConfig(), transport: MockTransport(steps: Array(repeating: .failure(.notConnectedToInternet), count: 5)))
    #expect(e?.stage == .config)
    #expect(e?.cause.contains("network error") == true, "\(String(describing: e))")
}

@Test func settleReportsASCErrorsAsConfigErrors() async {
    let e = await settleError(datedConfig(), transport: MockTransport([(401, #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED"}]}"#)]))
    #expect(e?.stage == .config)
    #expect(e?.cause.contains("HTTP 401") == true)
    #expect(e?.fix.contains("ASC_KEY_ID") == true)
}

@Test func settleResolvesADatedBuild() async throws {
    var c = datedConfig()
    let t = MockTransport([(200, #"{"data":[{"type":"apps","id":"app1","attributes":{"bundleId":"com.example.app"}}]}"#), (200, page(["1.0.0.2026101501"]))])
    try await DatedBuildNumber.settle(&c, override: nil, file: tempFile(), secrets: Secrets(env: ascEnv), fresh: true, today: today,
                                      makeClient: { _ in ASCClient(credentials: testCreds, transport: t) })
    #expect(c.build == "1.0.0.2026101502" && c.buildScheme == .dated)
}

@Test func datedOverrideKeepsTheDatedSchemeAndIsRecorded() async throws {
    var c = datedConfig()
    let f = tempFile()
    try await DatedBuildNumber.settle(&c, override: "1.0.0.2026010101", file: f, secrets: Secrets(env: [:]), fresh: true, today: today,
                                      makeClient: { _ in fatalError("an override makes no App Store Connect call") })
    #expect(c.build == "1.0.0.2026010101" && c.buildScheme == .dated)
    // Later stages of the run, started without the override, read the same number.
    #expect(try String(contentsOf: f, encoding: .utf8) == "1.0.0.2026010101\n")
    var later = datedConfig()
    try await DatedBuildNumber.settle(&later, override: nil, file: f, secrets: Secrets(env: [:]), fresh: false, today: today,
                                      makeClient: { _ in fatalError("no network") })
    #expect(later.build == "1.0.0.2026010101")
}

@Test(arguments: ["2026101501", "7", "1.0.1.2026101501", "1.0.0.2026101500"])
func datedOverrideMustBeADatedBuildOfTheVersion(override: String) async {
    let e = await settleError(datedConfig(), override: override, transport: MockTransport([]))
    #expect(e?.stage == .config)
    #expect(e?.cause.contains("invalid for a dated build of version 1.0.0") == true, "\(String(describing: e))")
}

@Test func fixedOverrideStaysFixed() async throws {
    var c = datedConfig()
    c.buildScheme = .fixed; c.build = "3"
    try await DatedBuildNumber.settle(&c, override: "42", file: tempFile(), secrets: Secrets(env: [:]), fresh: true, today: today,
                                      makeClient: { _ in fatalError("no network") })
    #expect(c.build == "42" && c.buildScheme == .fixed)
    let e = await settleError(c, override: "1.0.0.2026101501", transport: MockTransport([]))
    #expect(e?.stage == .config)
}

// MARK: macOS (Developer ID: no App Store Connect)

private func macConfig(build: String = "1.0.0.200001010000") -> ProjectConfig {
    ProjectConfig(bundleID: "com.example.app", teamID: "ABCDE12345", version: "1.0.0", build: build,
                  platforms: [.macos: PlatformConfig(minimumOS: "11.0", product: "App", distribution: .developerID)], buildScheme: .dated)
}

@Test func macOSBuildNumberIsMinuteResolutionUTC() {
    // 2026-10-16 15:30:45 UTC
    #expect(DatedBuildNumber.macOS(version: "1.0.0", now: Date(timeIntervalSince1970: 1_792_164_645)) == "1.0.0.202610161530")
}

@Test func macOSDatedValidationAcceptsOnlyTheTwelveDigitForm() throws {
    try macConfig().validate()
    try macConfig(build: "1.0.0.202610162359").validate()
    for bad in ["1.0.0.2026101501", "1.0.0.202610162400", "1.0.0.202610151560", "1.0.1.202610151530", "7"] {
        #expect(throws: XlessError.self, "\(bad)") { try macConfig(build: bad).validate() }
    }
    // iOS keeps the ten-digit form only.
    var ios = datedConfig(); ios.build = "1.0.0.202610151530"
    #expect(throws: XlessError.self) { try ios.validate() }
}

@Test func macOSDatedSettleUsesTheClockAndNeverQueriesAppStoreConnect() async throws {
    var c = macConfig()
    let f = tempFile()
    try await DatedBuildNumber.settle(&c, override: nil, file: f, secrets: Secrets(env: [:]), fresh: true, today: today,
                                      makeClient: { _ in fatalError("macOS dated builds make no App Store Connect call") })
    #expect(c.build == "1.0.0.202610151200" && c.buildScheme == .dated)
    var later = macConfig()
    try await DatedBuildNumber.settle(&later, override: nil, file: f, secrets: Secrets(env: [:]), fresh: false, today: Date(),
                                      makeClient: { _ in fatalError("no network") })
    #expect(later.build == "1.0.0.202610151200")   // later stages read the recorded number
    var over = macConfig()
    try await DatedBuildNumber.settle(&over, override: "1.0.0.202601010101", file: tempFile(), secrets: Secrets(env: [:]), fresh: true, today: today,
                                      makeClient: { _ in fatalError("no network") })
    #expect(over.build == "1.0.0.202601010101")
}

/// A build that is never uploaded (a React Native simulator build) chooses `<version>.<YYYYMMDD>01` without App Store
/// Connect when it starts, and later stages read the record.
@Test func localDatedBuildNumbersNeedNoAppStoreConnect() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("xless-local-\(UUID().uuidString)/build-number")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(throws: XlessError.self) { try DatedBuildNumber.resolveLocal(version: "1.0.0", fresh: false, file: file) }
    #expect(try DatedBuildNumber.resolveLocal(version: "1.0.0", fresh: true, file: file, today: today) == "1.0.0.2026101501")
    #expect(try DatedBuildNumber.resolveLocal(version: "1.0.0", fresh: false, file: file) == "1.0.0.2026101501")
}
