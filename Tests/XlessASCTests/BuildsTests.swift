import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func builds(_ t: MockTransport) -> ASCBuilds {
    ASCBuilds(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })))
}
private func queryItems(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func body(_ r: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data()) }

let buildA = "2f1c7a9e-0b1d-4f7a-9c33-5b2d8e0f1a11"
let buildB = "7b0e3c1d-4a5f-4e6b-8d22-9c1f0a2b3c44"

/// A build as App Store Connect returns it (recorded shape of GET /v1/builds?include=preReleaseVersion,app).
func buildJSON(_ id: String, number: String, state: String = "VALID", expired: Bool = false, encryption: Bool? = false,
               version: String = "PRV1", app: String = "1234567890", declaration: String? = nil, betaDetail: String? = nil) -> String {
    let enc = encryption.map { #","usesNonExemptEncryption":\#($0)"# } ?? ""
    let decl = declaration.map { #","appEncryptionDeclaration":{"data":{"type":"appEncryptionDeclarations","id":"\#($0)"}}"# } ?? ""
    let beta = betaDetail.map { #","buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"\#($0)"}}"# } ?? ""
    return #"{"type":"builds","id":"\#(id)","attributes":{"version":"\#(number)","uploadedDate":"2026-11-20T10:15:00.000-08:00","expirationDate":"2027-02-18T10:15:00.000-08:00","expired":\#(expired),"minOsVersion":"17.0","processingState":"\#(state)","buildAudienceType":"APP_STORE_ELIGIBLE"\#(enc)},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"\#(version)"}},"app":{"data":{"type":"apps","id":"\#(app)"}}\#(decl)\#(beta)},"links":{"self":"https://api.appstoreconnect.apple.com/v1/builds/\#(id)"}}"#
}
func preReleaseJSON(_ id: String, version: String, platform: String = "IOS") -> String {
    #"{"type":"preReleaseVersions","id":"\#(id)","attributes":{"version":"\#(version)","platform":"\#(platform)"}}"#
}
func buildAppJSON(_ id: String = "1234567890", bundleID: String = "com.example.app", name: String = "Example") -> String {
    #"{"type":"apps","id":"\#(id)","attributes":{"bundleId":"\#(bundleID)","name":"\#(name)"}}"#
}
func buildsJSON(_ items: [String], included: [String]) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}"#
}
func singleBuildJSON(_ item: String, included: [String]) -> String {
    #"{"data":\#(item),"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}

// MARK: - References

@Test func buildReferencesParse() throws {
    #expect(try BuildReference.parse(buildA) == .id(buildA))
    #expect(try BuildReference.parse("1.2.0+42") == .version("1.2.0", number: "42"))
    #expect(try BuildReference.parse("1.2.0+1.2.0.2026112301") == .version("1.2.0", number: "1.2.0.2026112301"))
    for bad in ["", "+42", "1.2+", "1.2+x", "v1+2", "42", "1.2.3", "../v1/apps", "-abc", "a b", String(repeating: "a", count: 65)] {
        #expect(throws: IdentifierInputError.self, "\(bad)") { try BuildReference.parse(bad) }
    }
    #expect(BuildState(argument: "Valid") == .valid && BuildState(argument: "done") == nil)
    #expect(BuildPlatform(argument: "visionOS") == .visionOS && BuildPlatform.display("MAC_OS") == "macos" && BuildPlatform.display("WATCH_OS") == "WATCH_OS")
}

// MARK: - Listing

@Test func listSendsFiltersAndKeepsVersionsAndApps() async throws {
    let t = MockTransport([(200, buildsJSON([buildJSON(buildA, number: "42"), buildJSON(buildB, number: "7", state: "PROCESSING", encryption: nil, version: "PRV2")],
                                            included: [preReleaseJSON("PRV1", version: "1.2.0"), preReleaseJSON("PRV2", version: "1.3", platform: "MAC_OS"), buildAppJSON()]))])
    let listing = try await builds(t).list(BuildFilter(appID: "1234567890", appVersion: "1.2.0", number: "42", platform: .ios, states: [.valid, .processing]), limit: 50)
    let q = queryItems(t.requests[0])
    #expect(t.requests[0].url!.path == "/v1/builds")
    #expect(q == ["filter[app]=1234567890", "filter[preReleaseVersion.version]=1.2.0", "filter[version]=42", "filter[preReleaseVersion.platform]=IOS",
                  "filter[processingState]=VALID,PROCESSING", "filter[expired]=false", "fields[apps]=bundleId,name",
                  "include=preReleaseVersion,app", "sort=-uploadedDate", "limit=50"])
    #expect(listing.builds.map(\.name) == ["1.2.0+42", "1.3+7"])
    #expect(listing.builds[1].platform == "MAC_OS" && listing.builds[0].bundleID == "com.example.app" && listing.builds[0].appName == "Example")
    #expect(listing.builds[1].build.attributes.usesNonExemptEncryption == nil)
    #expect(listing.included.count == 3)
}

@Test func listDefaultsToBuildsThatHaveNotExpired() async throws {
    let t = MockTransport([(200, buildsJSON([], included: [])), (200, buildsJSON([], included: [])), (200, buildsJSON([], included: []))])
    _ = try await builds(t).list(BuildFilter())
    _ = try await builds(t).list(BuildFilter(expired: true))
    _ = try await builds(t).list(BuildFilter(expired: nil))
    #expect(queryItems(t.requests[0]).contains("filter[expired]=false"))
    #expect(queryItems(t.requests[1]).contains("filter[expired]=true"))
    #expect(!queryItems(t.requests[2]).contains { $0.hasPrefix("filter[expired]") })
}

// MARK: - Finding a build by version and number

@Test func findMatchesVersionAndNumberExactly() async throws {
    let t = MockTransport([(200, buildsJSON([buildJSON(buildB, number: "420"), buildJSON(buildA, number: "42")], included: [preReleaseJSON("PRV1", version: "1.2.0"), buildAppJSON()]))])
    let found = try await builds(t).find(version: "1.2.0", number: "42", appID: "1234567890")
    #expect(found?.id == buildA)
    let q = queryItems(t.requests[0])
    #expect(q.contains("filter[version]=42") && q.contains("filter[preReleaseVersion.version]=1.2.0") && q.contains("filter[app]=1234567890"))
    #expect(!q.contains { $0.hasPrefix("filter[expired]") }, "an expired build is still found")

    let none = MockTransport([(200, buildsJSON([], included: []))])
    #expect(try await builds(none).find(version: "1.2.0", number: "42") == nil)
}

@Test func findRefusesAmbiguousMatches() async throws {
    let t = MockTransport([(200, buildsJSON([buildJSON(buildA, number: "42"), buildJSON(buildB, number: "42", version: "PRV2", app: "999")],
                                            included: [preReleaseJSON("PRV1", version: "1.2.0"), preReleaseJSON("PRV2", version: "1.2.0", platform: "MAC_OS"),
                                                       buildAppJSON(), buildAppJSON("999", bundleID: "com.example.other")]))])
    do { _ = try await builds(t).find(version: "1.2.0", number: "42"); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.contains("2 builds are 1.2.0+42") && e.cause.contains("com.example.app, ios") && e.cause.contains("com.example.other, macos"))
        #expect(e.fix.contains("--app") && e.fix.contains("--platform"))
    }
}

@Test func resolveReadsTheBuildWithItsDetails() async throws {
    let one = singleBuildJSON(buildJSON(buildA, number: "42", declaration: "DECL1", betaDetail: "BD1"), included: [
        preReleaseJSON("PRV1", version: "1.2.0"), buildAppJSON(),
        #"{"type":"buildBetaDetails","id":"BD1","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"READY_FOR_BETA_SUBMISSION"}}"#,
        #"{"type":"appEncryptionDeclarations","id":"DECL1","attributes":{"appEncryptionDeclarationState":"APPROVED","exempt":true}}"#,
    ])
    let t = MockTransport([(200, buildsJSON([buildJSON(buildA, number: "42")], included: [preReleaseJSON("PRV1", version: "1.2.0")])), (200, one)])
    let detail = try await builds(t).resolve(.version("1.2.0", number: "42"))
    #expect(t.requests[1].url!.path == "/v1/builds/\(buildA)")
    #expect(queryItems(t.requests[1]).contains("include=preReleaseVersion,app,buildBetaDetail,appEncryptionDeclaration"))
    #expect(detail.internalBetaState == "IN_BETA_TESTING" && detail.externalBetaState == "READY_FOR_BETA_SUBMISSION")
    #expect(detail.encryptionDeclarationID == "DECL1" && detail.encryptionDeclaration?.attributes?["appEncryptionDeclarationState"]?.string == "APPROVED")

    let missing = MockTransport([(200, buildsJSON([], included: []))])
    do { _ = try await builds(missing).resolve(.version("2.0", number: "1"), appID: "1234567890"); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause == "no build 2.0+1 is visible to this API key in app 1234567890")
        #expect(e.fix.contains("xless builds wait 2.0+1"))
    }
}

// MARK: - Changes

@Test func expireAndEncryptionArePatches() async throws {
    let t = MockTransport([(200, singleBuildJSON(buildJSON(buildA, number: "42", expired: true), included: [])),
                           (200, singleBuildJSON(buildJSON(buildA, number: "42", encryption: false), included: [])),
                           (204, "")])
    let b = builds(t)
    #expect(try await b.expire(buildA).isExpired)
    _ = try await b.setUsesNonExemptEncryption(buildA, false)
    try await b.attach(declaration: "DECL1", to: buildA)
    #expect(t.requests.map(\.httpMethod) == ["PATCH", "PATCH", "PATCH"])
    #expect(try body(t.requests[0]) == .object(["data": .object(["type": .string("builds"), "id": .string(buildA), "attributes": .object(["expired": .bool(true)])])]))
    #expect(try body(t.requests[1])["data"]?["attributes"] == .object(["usesNonExemptEncryption": .bool(false)]))
    #expect(t.requests[2].url!.path == "/v1/builds/\(buildA)/relationships/appEncryptionDeclaration")
    #expect(try body(t.requests[2]) == .object(["data": .object(["type": .string("appEncryptionDeclarations"), "id": .string("DECL1")])]))
}

@Test func declarationsAreTheAppsNewestFirst() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"appEncryptionDeclarations","id":"OLD","attributes":{"createdDate":"2025-01-01T00:00:00Z","exempt":true}},{"type":"appEncryptionDeclarations","id":"NEW","attributes":{"createdDate":"2026-01-01T00:00:00Z","appEncryptionDeclarationState":"APPROVED"}}],"links":{"self":"x"}}"#)])
    let list = try await builds(t).declarations(appID: "1234567890")
    #expect(list.map(\.id) == ["NEW", "OLD"])
    #expect(queryItems(t.requests[0]).contains("filter[app]=1234567890"))
}

// MARK: - Waiting

@Test func waitPollsUntilProcessingEnds() async throws {
    let sleeps = SleepRecorder()
    let t = MockTransport([(200, singleBuildJSON(buildJSON(buildA, number: "42", state: "PROCESSING"), included: [])),
                           (200, singleBuildJSON(buildJSON(buildA, number: "42", state: "PROCESSING"), included: [])),
                           (200, singleBuildJSON(buildJSON(buildA, number: "42", state: "VALID"), included: []))])
    var seen: [String?] = []
    let waited = try await builds(t).wait(.id(buildA), interval: .seconds(30), timeout: .seconds(3600), sleep: sleeps.fn) { seen.append($0?.build.processingState) }
    #expect(waited.end == .finished("VALID") && waited.build?.id == buildA)
    #expect(seen == ["PROCESSING", "PROCESSING", "VALID"] && sleeps.durations == [.seconds(30), .seconds(30)])
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func waitLooksUpABuildThatIsNotVisibleYet() async throws {
    let t = MockTransport([(200, buildsJSON([], included: [])),
                           (200, buildsJSON([buildJSON(buildA, number: "42", state: "PROCESSING")], included: [preReleaseJSON("PRV1", version: "1.2.0")])),
                           (200, singleBuildJSON(buildJSON(buildA, number: "42", state: "PROCESSING"), included: [])),
                           (200, singleBuildJSON(buildJSON(buildA, number: "42", state: "INVALID"), included: []))])
    let waited = try await builds(t).wait(.version("1.2.0", number: "42"), timeout: .seconds(3600), sleep: { _ in })
    #expect(waited.end == .finished("INVALID"))
    #expect(t.requests.map(\.url!.path) == ["/v1/builds", "/v1/builds", "/v1/builds/\(buildA)", "/v1/builds/\(buildA)"])
}

@Test func waitTimesOutWithTheLastState() async throws {
    let t = MockTransport([(200, buildsJSON([], included: []))])
    let waited = try await builds(t).wait(.version("1.2.0", number: "42"), timeout: .zero, sleep: { _ in })
    #expect(waited.end == .timedOut(nil) && waited.build == nil)

    let processing = MockTransport([(200, singleBuildJSON(buildJSON(buildA, number: "42", state: "PROCESSING"), included: []))])
    let still = try await builds(processing).wait(.id(buildA), timeout: .zero, sleep: { _ in })
    #expect(still.end == .timedOut("PROCESSING"))
}

@Test func waitStopsOnCancellationWithoutWriting() async throws {
    let t = MockTransport((0..<5).map { _ in (200, singleBuildJSON(buildJSON(buildA, number: "42", state: "PROCESSING"), included: [])) })
    let b = builds(t)
    let task = Task {
        try await b.wait(.id(buildA), timeout: .seconds(3600), sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        })
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "GET")

    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await BuildProcessing.poll(deadline: .now + .seconds(60), interval: .seconds(1), sleep: { _ in }) { "PROCESSING" }
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
}

@Test func pollKeepsGoingOnUnknownStates() async throws {
    var states = ["PROCESSING", "SOMETHING_NEW", "VALID"]
    let end = try await BuildProcessing.poll(deadline: .now + .seconds(60), interval: .seconds(1), sleep: { _ in }) { states.removeFirst() }
    #expect(end == .finished("VALID") && states.isEmpty)
}
