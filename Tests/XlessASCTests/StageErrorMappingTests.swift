import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XlessASC
@testable import XlessCore

private func mapped(_ stage: Stage, _ op: () async throws -> Void) async -> XlessError? {
    do { try await withStage(stage, op); return nil } catch { return error as? XlessError }
}

@Test func raw401FromClientBecomesStageErrorWithCredentialsHint() async {
    let t = MockTransport([(401, #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","title":"Authentication credentials are missing or invalid."}]}"#)])
    let client = ASCClient(credentials: testCreds, transport: t, sleep: { _ in })
    let e = await mapped(.sign) { let _: ASCDocument<[ASCRef]> = try await client.get("/v1/certificates") }
    #expect(e?.stage == .sign)
    #expect(e?.description.hasPrefix("[sign] App Store Connect HTTP 401") == true)
    #expect(e?.cause.contains("NOT_AUTHORIZED") == true)
    #expect(e?.fix.contains("ASC_KEY_ID") == true && e?.fix.contains("ASC_KEY_P8") == true)
}

@Test func raw403BecomesRoleHint() async {
    let e = await mapped(.upload) { throw ASCError(status: 403, items: [.init(status: "403", code: "FORBIDDEN_ERROR", title: nil, detail: nil)]) }
    #expect(e?.stage == .upload)
    #expect(e?.fix.contains("Admin") == true)
}

@Test func otherASCErrorKeepsTextAndKnownIssue() async {
    let e = await mapped(.upload) {
        throw ASCError(status: 409, items: [.init(status: "409", code: "ENTITY_ERROR", title: nil, detail: "The bundle version must be higher than the previously uploaded version.")])
    }
    #expect(e?.cause.contains("HTTP 409") == true)
    #expect(e?.fix.contains("build number") == true)
}

@Test func urlErrorBecomesNetworkError() async {
    let e = await mapped(.sign) { throw URLError(.notConnectedToInternet) }
    #expect(e?.stage == .sign)
    #expect(e?.cause.contains("network") == true, "\(String(describing: e))")
}

@Test func uploaderWrapsUndecodableResponse() async {
    let t = MockTransport([(200, "not json")])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.cause.contains("looking up the app record")) }
    catch { Issue.record("not an XlessError: \(error)") }
}

@Test func account401SaysRevokedOrWrongIssuer() async {
    let e = await mapped(.account) { throw ASCError(status: 401, items: [.init(status: "401", code: "NOT_AUTHORIZED", title: nil, detail: nil)]) }
    #expect(e?.stage == .account && e?.stage.exitCode == 20)
    #expect(e?.fix.contains("revoked") == true && e?.fix.contains("issuer") == true && e?.fix.contains("clock") == true)
}

@Test(arguments: [("/v1/users", "Admin"), ("/v1/userInvitations/1", "Admin"), ("/v1/certificates", "Admin"),
                  ("/v1/financeReports", "Finance"), ("/v1/salesReports", "Sales"), ("/v1/apps/1", "App Manager"),
                  ("/v1/betaGroups", "App Manager")])
func account403NamesTheRoleNeeded(path: String, role: String) async {
    let e = await mapped(.account) { throw ASCError(status: 403, items: [], method: "GET", path: path) }
    #expect(e?.fix.contains("the \(role) role") == true, "\(String(describing: e))")
    #expect(e?.cause.contains("GET \(path)") == true)
    #expect(e?.fix.contains("`xless auth api-key create --role \(role.uppercased().replacingOccurrences(of: " ", with: "_"))`") == true)
}

@Test func account409NamesTheField() async {
    let item = ASCErrorItem(status: "409", code: "ENTITY_ERROR.ATTRIBUTE.INVALID", title: "invalid", detail: "already used",
                            source: .init(pointer: "/data/attributes/name"))
    let e = await mapped(.account) { throw ASCError(status: 409, items: [item], method: "POST", path: "/v1/bundleIds") }
    #expect(e?.fix.contains("`name`") == true, "\(String(describing: e))")
    #expect(e?.cause.contains("already used") == true)
}

@Test func account429SaysHowLongToWait() async {
    let e = await mapped(.account) { throw ASCError(status: 429, items: [], retryAfter: 1800) }
    #expect(e?.fix.contains("30 minutes") == true, "\(String(describing: e))")
}

@Test func account404AndPagingErrorsMap() async {
    let e = await mapped(.account) { throw ASCError(status: 404, items: [], method: "GET", path: "/v1/apps/nope") }
    #expect(e?.fix.contains("ID") == true)
    let p = await mapped(.account) { throw ASCPagingError.didNotTerminate(path: "/v1/apps") }
    #expect(p?.stage == .account && p?.cause.contains("/v1/apps") == true && p?.fix.contains("bug") == true)
}

@Test func otherStagesKeepTheirFixes() async {
    let e = await mapped(.sign) { throw ASCError(status: 403, items: [], method: "POST", path: "/v1/users") }
    #expect(e?.fix.contains("Admin role") == true)
    #expect(e?.cause.hasPrefix("App Store Connect HTTP 403") == true)
}

@Test func aRequiredAttributeIsSaidToBeMissingNotRefused() async throws {
    // App Store Connect's answer to an age rating without the social media question (#105).
    let item = ASCErrorItem(status: "409", code: "ENTITY_ERROR.ATTRIBUTE.REQUIRED", title: "The provided entity is missing a required attribute",
                            detail: "You must provide a value for the attribute 'socialMedia' with this request", source: .init(pointer: "/data/attributes/socialMedia"))
    let e = await mapped(.account) { throw ASCError(status: 409, items: [item], method: "PATCH", path: "/v1/ageRatingDeclarations/1") }
    #expect(e?.fix == "App Store Connect needs a value for `socialMedia`, which the request did not have: add it")
}

/// App Store Connect's answer to adding a version that is not ready to a review submission (#105): the reasons are in
/// `meta.associatedErrors`, by the path of the resource each is about.
private let refusedVersion = #"""
{"errors":[{"status":"409","code":"STATE_ERROR.ENTITY_STATE_INVALID","title":"appStoreVersions with id 'V1' is not in valid state.","detail":"This resource cannot be reviewed, please check associated errors to see why.","meta":{"associatedErrors":{"/v1/b/":[{"id":"1","status":"409","code":"STATE_ERROR.TWO","title":"Second.","detail":"Second detail."}],"/v1/a/":[{"id":"2","status":"409","code":"ENTITY_ERROR.ONE","title":"First.","detail":"First detail.","source":{"pointer":"/data/attributes/x"}}]}}}]}
"""#

@Test func theReasonsOfARefusalAreSaid() async throws {
    let client = ASCClient(credentials: testCreds, transport: MockTransport([(409, refusedVersion)]), sleep: { _ in })
    let e = await mapped(.account) { let _: ASCDocument<[ASCRef]> = try await client.get("/v1/reviewSubmissionItems") }
    let cause = try #require(e?.cause)
    #expect(cause.contains("please check associated errors to see why."), "\(cause)")
    #expect(cause.contains("/v1/a/: ENTITY_ERROR.ONE: First.: First detail. (/data/attributes/x)"), "\(cause)")
    #expect(cause.contains("/v1/b/: STATE_ERROR.TWO: Second.: Second detail."), "\(cause)")
    #expect(e?.fix.contains("the reasons above") == true, "\(String(describing: e?.fix))")
}

@Test func anUnreadableMetaKeepsTheError() async throws {
    for meta in [#""text""#, #"{"associatedErrors":"text"}"#, #"{"associatedErrors":{"/v1/a/":["text"]}}"#, #"{"other":1}"#, "null"] {
        let client = ASCClient(credentials: testCreds, transport: MockTransport([(409, #"{"errors":[{"status":"409","code":"C","title":"T","detail":"D","meta":\#(meta)}]}"#)]), sleep: { _ in })
        let e = await mapped(.account) { let _: ASCDocument<[ASCRef]> = try await client.get("/v1/x") }
        #expect(e?.cause == "GET /v1/x: App Store Connect HTTP 409 — C: T: D", "\(meta): \(String(describing: e?.cause))")
    }
}

@Test func theChinaMainlandDeclarationsAreExplained() async throws {
    // App Store Connect's answer for a new app sold in China mainland with its App Compliance forms unanswered (#105).
    let form = { (code: String) in
        #"{"status":"409","code":"STATE_ERROR.PPM.compliance.form.\#(code).enforcement.PENDING_COLLECT.NEW_APP_SUBMISSION_BLOCK","title":"App submission blocked","detail":"Cannot submit version due to unfulfilled compliance requirement."}"#
    }
    func fix(_ codes: [String]) async -> String? {
        let body = #"{"errors":[{"status":"409","code":"STATE_ERROR.ENTITY_STATE_INVALID","title":"T","detail":"D","meta":{"associatedErrors":{"/v1/appInfos/1":[\#(codes.map(form).joined(separator: ","))]}}}]}"#
        let client = ASCClient(credentials: testCreds, transport: MockTransport([(409, body)]), sleep: { _ in })
        return await mapped(.account) { let _: ASCDocument<[ASCRef]> = try await client.get("/v1/reviewSubmissionItems") }?.fix
    }
    for codes in [["SECURITYASF395E", "AIGENERATEFD1DE"], ["SECURITYASF395E"], ["AIGENERATEFD1DE"]] {
        let text = try #require(await fix(codes))
        #expect(text.contains("China mainland") && text.contains("App Compliance") && text.contains("CHN") && text.contains("availability.territories"), "\(text)")
    }
    // A form xless does not know: where to answer it, without a country.
    let unknown = try #require(await fix(["OTHERFORM1234"]))
    #expect(unknown.contains("App Compliance") && !unknown.contains("CHN") && !unknown.contains("China"), "\(unknown)")
    let mixed = try #require(await fix(["SECURITYASF395E", "OTHERFORM1234"]))
    #expect(mixed.contains("App Compliance") && !mixed.contains("CHN"), "\(mixed)")
}
