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
