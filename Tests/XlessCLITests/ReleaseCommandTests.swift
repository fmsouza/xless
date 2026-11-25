import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
import XlessStore
@testable import xless

/// App Store Connect by "METHOD path" (else, for a GET, by path; 404 when unknown); unrouted writes answer 201 `NEW`.
private final class Routes: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var requests: [URLRequest] = []
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let method = request.httpMethod ?? "GET", path = request.url!.path
        let (status, body) = routes["\(method) \(path)"] ?? (method != "GET" ? (201, #"{"data":{"type":"x","id":"NEW"}}"#)
                                                             : routes[path] ?? (404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"not found"}]}"#))
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var writes: [String] { requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" } }
}

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: Routes, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> ReleaseCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ReleaseCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json,
                      terminal: { terminal }, say: { said.lines.append($0) })
}

private func data(_ items: [String]) -> String { #"{"data":[\#(items.joined(separator: ","))],"links":{"self":"x"}}"# }
private func one(_ item: String?) -> String { #"{"data":\#(item ?? "null")}"# }
private func version(_ id: String, _ string: String, _ state: String, platform: String = "IOS", created: String = "2026-01-01T00:00:00Z") -> String {
    #"{"type":"appStoreVersions","id":"\#(id)","attributes":{"platform":"\#(platform)","versionString":"\#(string)","appVersionState":"\#(state)","releaseType":"MANUAL","createdDate":"\#(created)"}}"#
}
private func phased(_ state: String) -> String {
    #"{"type":"appStoreVersionPhasedReleases","id":"P1","attributes":{"phasedReleaseState":"\#(state)","currentDayNumber":3}}"#
}
private let app = #"{"type":"apps","id":"123","attributes":{"bundleId":"com.example.app","name":"Example","primaryLocale":"en-US"}}"#
private let wanted = ReleaseWanted(app: "123", platform: nil, version: nil)

private func routes(_ versions: [String], _ extra: [String: (Int, String)] = [:]) -> Routes {
    var r: [String: (Int, String)] = ["/v1/apps/123": (200, one(app)), "/v1/apps/123/appStoreVersions": (200, data(versions)),
                                      "/v1/reviewSubmissions": (200, data([]))]
    r.merge(extra) { $1 }
    return Routes(r)
}

@Test func releaseIsInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("release") } == true, "\(help)")
}

@Test func badReleaseArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try ReleaseCreateCommand.parse([]) }
    #expect(throws: (any Error).self) { try ReleaseCreateCommand.parse(["1.2b"]) }
    #expect(throws: (any Error).self) { try ReleaseCreateCommand.parse(["1.2", "--app-version", "1.2"]) }
    #expect(throws: (any Error).self) { try ReleaseAttachCommand.parse(["42"]) }                          // a bare build number
    #expect(throws: (any Error).self) { try ReleaseSubmitCommand.parse(["--release", "tomorrow"]) }
    #expect(throws: (any Error).self) { try ReleaseSubmitCommand.parse(["--release", "2001-01-01"]) }
    #expect(throws: (any Error).self) { try ReleaseSubmitCommand.parse(["--platform", "watchos"]) }
    #expect(throws: (any Error).self) { try ReleaseStatusCommand.parse(["--app-version", "latest"]) }
    let submit = try ReleaseSubmitCommand.parse(["--app", "com.example.app", "--build", "1.2+42", "--release", "auto", "--no-phased", "--dry-run", "--app-version", "1.2"])
    #expect(submit.phased == false && submit.dryRun && submit.target.appVersion == "1.2")
    #expect(try ReleaseSubmitCommand.parse(["--phased"]).phased == true)
    #expect(try ReleaseSubmitCommand.parse([]).phased == nil)
    _ = try ReleasePhasedPauseCommand.parse(["--app", "123", "--json"])
    _ = try ReleaseCancelCommand.parse(["--yes"])
}

@Test func theManifestGivesTheDefaultAppPlatformAndVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("appstore"), withIntermediateDirectories: true)
    try Data("bundleID: com.example.app\nplatform: MAC_OS\nversion: \"1.4\"\n".utf8).write(to: root.appendingPathComponent("appstore/app.yml"))
    let dir = ["--dir", root.appendingPathComponent("appstore").path]
    #expect(try ReleaseStatusCommand.parse(dir).target.wanted() == ReleaseWanted(app: "com.example.app", platform: "MAC_OS", version: "1.4"))
    #expect(try ReleaseStatusCommand.parse(dir + ["--app-version", "1.5"]).target.wanted().version == "1.5")
    #expect(try ReleaseStatusCommand.parse(dir).target.wanted(manifestVersion: false).version == nil)
    #expect(try ReleaseStatusCommand.parse(dir + ["--platform", "ios"]).target.wanted() == ReleaseWanted(app: "com.example.app", platform: "IOS", version: nil))
    #expect(try ReleaseStatusCommand.parse(dir + ["--app", "com.other.app"]).target.wanted() == ReleaseWanted(app: "com.other.app", platform: nil, version: nil))
    #expect(throws: XlessError.self) { try ReleaseStatusCommand.parse(["--dir", root.appendingPathComponent("none").path]).target.wanted() }
}

// MARK: create, attach

@Test func createSendsOnlyWhatIsMissing() async throws {
    var t = routes([version("V1", "1.0", "READY_FOR_DISTRIBUTION")])
    #expect(try await cli(t).create(app: "123", platform: "IOS", versionString: "1.1").hasPrefix("created ios version 1.1 of com.example.app (NEW)"))
    #expect(t.writes == ["POST /v1/appStoreVersions"])

    t = routes([version("V2", "1.1", "PREPARE_FOR_SUBMISSION"), version("V1", "1.0", "READY_FOR_DISTRIBUTION")],
               ["PATCH /v1/appStoreVersions/V2": (200, one(version("V2", "1.2", "PREPARE_FOR_SUBMISSION")))])
    #expect(try await cli(t).create(app: "123", platform: "IOS", versionString: "1.1") == "com.example.app already has ios version 1.1 (V2, prepare for submission); nothing was sent\n")
    #expect(t.writes.isEmpty)
    #expect(try await cli(t).create(app: "123", platform: "IOS", versionString: "1.2") == "renamed ios version 1.1 (V2), the one being prepared, to 1.2\n")
    #expect(t.writes == ["PATCH /v1/appStoreVersions/V2"])

    // No --platform: the app's only platform, never iOS added to a Mac app.
    t = routes([version("V1", "1.0", "READY_FOR_DISTRIBUTION", platform: "MAC_OS")])
    #expect(try await cli(t).create(app: "123", platform: nil, versionString: "1.1").hasPrefix("created macos version 1.1"))
    #expect(String(data: t.requests.last!.httpBody!, encoding: .utf8)!.contains("\"MAC_OS\""))
    t = routes([version("V1", "1.0", "READY_FOR_DISTRIBUTION", platform: "MAC_OS"), version("V0", "1.0", "READY_FOR_DISTRIBUTION")])
    await #expect(throws: XlessError.self) { _ = try await cli(t).create(app: "123", platform: nil, versionString: "1.1") }

    t = routes([version("V1", "1.0", "READY_FOR_DISTRIBUTION")])
    await #expect(throws: XlessError.self) { _ = try await cli(t).create(app: "123", platform: "IOS", versionString: "1.0") }
    t = routes([version("V2", "1.1", "WAITING_FOR_REVIEW")])
    await #expect(throws: XlessError.self) { _ = try await cli(t).create(app: "123", platform: "IOS", versionString: "1.2") }
    #expect(t.writes.isEmpty)
}

private let build42 = #"{"data":{"type":"builds","id":"B1","attributes":{"version":"42","processingState":"VALID","expired":false},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"PRV1"}},"app":{"data":{"type":"apps","id":"123"}}}},"included":[{"type":"preReleaseVersions","id":"PRV1","attributes":{"version":"1.1","platform":"IOS"}}]}"#

@Test func attachChecksTheBuildAndSendsOnce() async throws {
    let t = routes([version("V2", "1.1", "PREPARE_FOR_SUBMISSION")],
                   ["/v1/builds/B1": (200, build42), "/v1/appStoreVersions/V2/relationships/build": (200, #"{"data":null}"#)])
    #expect(try await cli(t).attach(wanted, build: .id("B1")) == "attached build 1.1+42 (B1) to com.example.app 1.1 (ios)\n")
    #expect(t.writes == ["PATCH /v1/appStoreVersions/V2/relationships/build"])
    t.routes["/v1/appStoreVersions/V2/relationships/build"] = (200, #"{"data":{"type":"builds","id":"B1"}}"#)
    #expect(try await cli(t).attach(wanted, build: .id("B1")).hasSuffix("; nothing was sent\n"))
    #expect(t.writes.count == 1)
    let other = routes([version("V3", "1.2", "PREPARE_FOR_SUBMISSION")], ["/v1/builds/B1": (200, build42)])
    await #expect(throws: XlessError.self) { _ = try await cli(other).attach(wanted, build: .id("B1")) }
    #expect(other.writes.isEmpty)
    let mac = routes([version("V4", "1.1", "PREPARE_FOR_SUBMISSION", platform: "MAC_OS")], ["/v1/builds/B1": (200, build42)])
    do { _ = try await cli(mac).attach(wanted, build: .id("B1")); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.cause == "build 1.1+42 (B1) is a ios build, not macos; nothing was sent")
    }
    #expect(mac.writes.isEmpty)
}

// MARK: submit

@Test func submitExitCodesTellTheOutcomeApart() async throws {
    let inReview = routes([version("V2", "1.1", "WAITING_FOR_REVIEW")])
    let (text, exit) = try await cli(inReview).submit(wanted, options: .init())
    #expect(exit == ReleaseExit.alreadyInReview && exit == 22)
    #expect(text == "com.example.app 1.1 (ios) is already in review; nothing was sent\n")
    #expect(inReview.writes.isEmpty)

    // Nothing in place at all: the pre-flight fails (21) and lists what is missing; nothing is sent.
    let empty = routes([version("V2", "1.1", "PREPARE_FOR_SUBMISSION")], ["/v1/appStoreVersions/V2/relationships/build": (200, #"{"data":null}"#),
                                                                           "/v1/apps/123/appInfos": (200, data([])),
                                                                           "/v1/appStoreVersions/V2/appStoreVersionLocalizations": (200, data([]))])
    let said = Said()
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("xless-none-\(UUID().uuidString)")
    let failed = try await cli(empty, said: said).submit(wanted, options: .init(manifestDir: missing))
    #expect(failed.exit == ReleaseExit.preflightFailed && failed.exit == 21)
    #expect(failed.text.hasPrefix("pre-flight of com.example.app 1.1 (ios):\n  FAIL  listing "))
    #expect(failed.text.contains("  FAIL  build           version 1.1 has no build"))
    #expect(said.lines.last?.hasPrefix("error: [account] the pre-flight of com.example.app 1.1 (ios) found ") == true)
    #expect(empty.writes.isEmpty)

    let json = try await cli(empty, json: true).submit(wanted, options: .init(manifestDir: missing))
    #expect(json.exit == 21 && json.text.contains("\"outcome\" : \"preflightFailed\"") && json.text.contains("\"passed\" : false"))
}

// MARK: status, cancel, publish, phased

@Test func statusShowsTheSubmissionAndSaysWhereRejectionReasonsAre() async throws {
    let t = routes([version("V2", "1.1", "REJECTED"), version("V1", "1.0", "READY_FOR_DISTRIBUTION", created: "2025-01-01T00:00:00Z")], [
        "/v1/appStoreVersions/V2/relationships/build": (200, #"{"data":null}"#),
        "/v1/appStoreVersions/V2/appStoreVersionPhasedRelease": (200, one(phased("INACTIVE"))),
        "/v1/reviewSubmissions": (200, data([#"{"type":"reviewSubmissions","id":"S1","attributes":{"state":"UNRESOLVED_ISSUES","submittedDate":"2026-11-20T10:00:00Z"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#])),
        "/v1/reviewSubmissions/S1/items": (200, data([#"{"type":"reviewSubmissionItems","id":"IT1","attributes":{"state":"REJECTED"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#])),
    ])
    let out = try await cli(t).status(wanted)
    #expect(out.contains("rejected"))
    #expect(out.contains("S1: unresolved issues, submitted 2026-11-20T10:00:00Z (item IT1 rejected)"))
    #expect(out.contains("BUILD") && out.contains("none") && out.contains("inactive"))
    #expect(out.contains("does not give App Review's reasons"))
    #expect(t.writes.isEmpty)
}

private let waiting = #"{"type":"reviewSubmissions","id":"S1","attributes":{"state":"WAITING_FOR_REVIEW"},"relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"V2"}}}}"#

@Test func cancelAsksThenWithdrawsTheSubmission() async throws {
    let t = routes([version("V2", "1.1", "WAITING_FOR_REVIEW")], ["/v1/reviewSubmissions": (200, data([waiting])),
                                                                  "PATCH /v1/reviewSubmissions/S1": (200, one(#"{"type":"reviewSubmissions","id":"S1","attributes":{"state":"CANCELING"}}"#))])
    let said = Said()
    #expect(try await cli(t, terminal: FakeTerminal(answer: false), said: said).cancel(wanted, yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"] && t.writes.isEmpty)
    await #expect(throws: XlessError.self) { _ = try await cli(t).cancel(wanted, yes: false) }     // no terminal, no --yes
    #expect(try await cli(t).cancel(wanted, yes: true).hasPrefix("canceled review submission S1 of com.example.app 1.1 (ios) (canceling)"))
    #expect(t.writes == ["PATCH /v1/reviewSubmissions/S1"])
    let none = routes([version("V2", "1.1", "PREPARE_FOR_SUBMISSION")])
    #expect(try await cli(none).cancel(wanted, yes: true) == "com.example.app 1.1 (ios) is in no open review submission; nothing was sent\n")
}

@Test func publishReleasesOnlyAnApprovedVersion() async throws {
    let t = routes([version("V3", "1.2", "PREPARE_FOR_SUBMISSION", created: "2026-11-01T00:00:00Z"), version("V2", "1.1", "PENDING_DEVELOPER_RELEASE")])
    #expect(try await cli(t).publish(wanted).hasPrefix("released com.example.app 1.1 (ios)"), "the version waiting for its release, not the newest")
    #expect(t.writes == ["POST /v1/appStoreVersionReleaseRequests"])
    let released = routes([version("V2", "1.1", "READY_FOR_DISTRIBUTION")])
    #expect(try await cli(released).publish(wanted) == "com.example.app 1.1 (ios) is already released (ready for distribution); nothing was sent\n")
    let editable = routes([version("V3", "1.2", "PREPARE_FOR_SUBMISSION")])
    await #expect(throws: XlessError.self) { _ = try await cli(editable).publish(wanted) }
    let scheduled = routes([version("V2", "1.1", "PENDING_APPLE_RELEASE")])
    #expect(try await cli(scheduled).publish(wanted).hasPrefix("com.example.app 1.1 (ios) is approved and scheduled"))
    #expect(released.writes.isEmpty && editable.writes.isEmpty && scheduled.writes.isEmpty)
}

@Test func phasedReleaseMovesOnlyFromAStateThatAllowsIt() async throws {
    let t = routes([version("V2", "1.1", "READY_FOR_DISTRIBUTION")], ["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease": (200, one(phased("ACTIVE"))),
                                                                     "PATCH /v1/appStoreVersionPhasedReleases/P1": (200, one(phased("PAUSED")))])
    #expect(try await cli(t).phased(.pause, wanted) == "paused the phased release of com.example.app 1.1 (ios) (for up to 30 days in all)\n")
    #expect(t.writes == ["PATCH /v1/appStoreVersionPhasedReleases/P1"])
    #expect(try await cli(t).phased(.resume, wanted) == "the phased release of com.example.app 1.1 (ios) is already active; nothing was sent\n")
    t.routes["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, one(phased("INACTIVE")))
    await #expect(throws: XlessError.self) { _ = try await cli(t).phased(.complete, wanted) }
    t.routes["/v1/appStoreVersions/V2/appStoreVersionPhasedRelease"] = (200, one(nil))
    await #expect(throws: XlessError.self) { _ = try await cli(t).phased(.pause, wanted) }
    #expect(t.writes.count == 1)
}

@Test func everyExitCodeMeansOneThing() {
    // release submit has codes of its own (docs/apple-account.md); --no-input's must not be one of them
    let codes = Stage.allCases.map(\.exitCode) + [ReleaseExit.preflightFailed, ReleaseExit.alreadyInReview, XlessError.provisioningNeeded, 0, 1, 2, 64, 130]
    #expect(Set(codes).count == codes.count)
}
