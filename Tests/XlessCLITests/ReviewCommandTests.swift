import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private func review(_ id: String, response: String? = nil) -> String {
    let rel = response.map { #","relationships":{"response":{"data":{"type":"customerReviewResponses","id":"\#($0)"}}}"# } ?? ""
    return #"{"type":"customerReviews","id":"\#(id)","attributes":{"rating":1,"title":"Crashes","body":"Line one\nLine two","reviewerNickname":"ada","createdDate":"2026-11-20T08:00:00-08:00","territory":"USA"}\#(rel)}"#
}
private func response(_ id: String, _ text: String = "Fixed in 1.2.") -> String {
    #"{"type":"customerReviewResponses","id":"\#(id)","attributes":{"responseBody":"\#(text)","lastModifiedDate":"2026-11-21T08:00:00-08:00","state":"PUBLISHED"}}"#
}
private let appJSON = #"{"data":{"type":"apps","id":"123","attributes":{"bundleId":"com.example.app","name":"Example"}}}"#

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> ReviewCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return ReviewCLI(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: json,
                     terminal: { terminal }, say: { said.lines.append($0) })
}

@Test func reviewsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    for name in ["reviews", "reports", "webhooks"] {
        #expect(group.map { help[$0.upperBound...].contains(name) } == true, "\(name)")
    }
}

@Test func badReviewArgumentsAreRefusedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try ReviewsListCommand.parse([]) }                                        // no --app
    #expect(throws: (any Error).self) { try ReviewsListCommand.parse(["--app", "123", "--rating", "6"]) }
    #expect(throws: (any Error).self) { try ReviewsListCommand.parse(["--app", "123", "--answered", "--unanswered"]) }
    #expect(throws: (any Error).self) { try ReviewsListCommand.parse(["--app", "123", "--sort", "best"]) }
    #expect(throws: (any Error).self) { try ReviewsListCommand.parse(["--app", "123", "--territory", "U"]) }
    #expect(throws: (any Error).self) { try ReviewsRespondCommand.parse(["R1"]) }                                  // no text
    #expect(throws: (any Error).self) { try ReviewsRespondCommand.parse(["R1", "--text", "a", "--file", "f"]) }
    #expect(throws: (any Error).self) { try ReviewsRespondCommand.parse(["R1", "--text", "  "]) }
    #expect(throws: (any Error).self) { try ReviewsDeleteResponseCommand.parse(["../x"]) }
    let list = try ReviewsListCommand.parse(["--app", "com.example.app", "--rating", "1,2", "--sort", "Oldest"])
    #expect(list.limit == 100 && !list.all)
}

@Test func theListShowsEachReviewWithItsResponse() async throws {
    let t = FakeTransport([(200, appJSON), (200, #"{"data":[\#(review("R1", response: "P1")),\#(review("R2"))],"included":[\#(response("P1"))]}"#)])
    let out = try await cli(t).list(app: "123", filter: ReviewFilter(), limit: 2)
    #expect(out.contains("R1  1/5  USA  2026-11-20  by ada\n  Crashes\n  Line one\n  Line two\n  ↳ response P1 (PUBLISHED, 2026-11-21):\n    Fixed in 1.2.\n"))
    #expect(out.contains("R2  1/5"))
    #expect(out.contains("(the first 2; --limit or --all for more)"))
}

@Test func respondingWithTheSameTextSendsNothing() async throws {
    let t = FakeTransport([(200, #"{"data":\#(review("R1", response: "P1")),"included":[\#(response("P1"))]}"#)])
    let out = try await cli(t).respond("R1", text: "Fixed in 1.2.", yes: false)
    #expect(out == "review R1 already has this response (PUBLISHED); nothing was sent\n")
    #expect(t.requests.count == 1)
}

@Test func replacingAResponseAsksFirst() async throws {
    let read = #"{"data":\#(review("R1", response: "P1")),"included":[\#(response("P1"))]}"#
    // No terminal and no --yes: refused, nothing sent.
    let refused = FakeTransport([(200, read)])
    await #expect(throws: XlessError.self) { try await cli(refused).respond("R1", text: "New text", yes: false) }
    #expect(refused.requests.count == 1)
    // Answered no.
    let said = Said()
    let no = FakeTransport([(200, read)])
    #expect(try await cli(no, terminal: FakeTerminal(answer: false), said: said).respond("R1", text: "New text", yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"])
    // --yes: replaced.
    let yes = FakeTransport([(200, read), (201, #"{"data":\#(response("P2", "New text"))}"#)])
    let out = try await cli(yes, json: true).respond("R1", text: "New text", yes: true)
    #expect(out.contains(#""result" : "replaced""#))
    #expect(yes.requests[1].httpMethod == "POST")
}

@Test func aFirstResponseIsSentWithoutAsking() async throws {
    let t = FakeTransport([(200, #"{"data":\#(review("R1"))}"#), (201, #"{"data":\#(response("P2", "Thanks"))}"#)])
    let out = try await cli(t).respond("R1", text: "Thanks", yes: false)
    #expect(out.hasPrefix("responded to review R1 (1/5): response P2, PUBLISHED"))
}

@Test func deletingAResponse() async throws {
    let none = FakeTransport([(200, #"{"data":\#(review("R1"))}"#)])
    #expect(try await cli(none).deleteResponse("R1", yes: false) == "review R1 has no response; nothing was sent\n")
    let t = FakeTransport([(200, #"{"data":\#(review("R1", response: "P1")),"included":[\#(response("P1"))]}"#), (204, "")])
    #expect(try await cli(t).deleteResponse("R1", yes: true) == "deleted response P1 to review R1\n")
    #expect(t.requests[1].httpMethod == "DELETE")
    #expect(t.requests[1].url?.path == "/v1/customerReviewResponses/P1")
}

@Test func reviewTextCannotDriveTheTerminal() {
    #expect(ReviewCLI.printable("a\u{1B}]52;c;ZXZpbA==\u{07}b\u{9B}2J") == "a\u{FFFD}]52;c;ZXZpbA==\u{FFFD}b\u{FFFD}2J")
    #expect(ReviewCLI.printable("line\r\nnext\tx", keepingLines: true) == "line\nnext\tx")
    #expect(ReviewCLI.printable("line\nnext") == "line\u{FFFD}next")
    let review = ASCCustomerReview(resource: ASCAnyResource(type: "customerReviews", id: "R1", attributes: [
        "rating": .int(1), "title": .string("\u{1B}[2JGone"), "body": .string("ok\u{1B}[31m"), "reviewerNickname": .string("x\u{07}")]))
    let text = ReviewCLI.block(review, response: nil)
    #expect(!text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
}

@Test func reportArgumentsAreCheckedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try ReportsSalesDownloadCommand.parse(["--vendor", "1", "--date", "2026-11-20"]) }           // no --out
    #expect(throws: (any Error).self) { try ReportsSalesDownloadCommand.parse(["--vendor", "x", "--date", "2026-11-20", "--out", "d"]) }
    #expect(throws: (any Error).self) { try ReportsSalesDownloadCommand.parse(["--vendor", "1", "--date", "2026-11", "--out", "d"]) }
    #expect(throws: (any Error).self) { try ReportsSalesDownloadCommand.parse(["--vendor", "1", "--date", "2026-11-20", "--type", "nope", "--out", "d"]) }
    #expect(throws: (any Error).self) { try ReportsFinanceDownloadCommand.parse(["--vendor", "1", "--date", "2026-10", "--type", "finance-detail", "--region", "US", "--out", "d"]) }
    let sales = try ReportsSalesDownloadCommand.parse(["--vendor", "85012345", "--frequency", "monthly", "--date", "2026-10", "--type", "subscription-event",
                                                       "--report-version", "1_3", "--out", "d", "--force"])
    #expect(try sales.request().fileName == "SUBSCRIPTION_EVENT_SUMMARY_MONTHLY_85012345_2026-10.tsv")
    #expect(sales.output.force)
    let finance = try ReportsFinanceDownloadCommand.parse(["--vendor", "85012345", "--date", "2026-10", "--out", "d"])
    #expect(try finance.request().region == "ZZ")
}

@Test func aReportDownloadSaysWhereItWent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-report-cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let creds = try ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    let t = FakeTransport([(200, "Provider\tUnits\n"), (200, "Provider\tUnits\n")])
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    let out = try await ReportCLI(reports: ASCReports(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))).download(report, into: dir.path, force: false)
    #expect(out == "wrote \(dir.path)/SALES_SUMMARY_DAILY_85012345_2026-11-20.tsv (15 bytes)\n")
    let json = try await ReportCLI(reports: ASCReports(client: ASCClient(credentials: creds, transport: t, sleep: { _ in })), json: true)
        .download(report, into: dir.path, force: true)
    #expect(json.contains(#""replaced" : true"#))
}
