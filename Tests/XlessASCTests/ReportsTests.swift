import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessCore
@testable import XlessASC

private func reports(_ t: HTTPTransport) -> ASCReports {
    ASCReports(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }))
}
private func queryItems(_ r: URLRequest) -> [String] {
    (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
}
private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-reports-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

/// Answers each request with the next script: chunks of a 2xx body (a `nil` chunk = the connection drops there), or an
/// error status and body.
final class ChunkTransport: HTTPTransport, @unchecked Sendable {
    enum Answer { case body([Data?]), status(Int, String) }
    var answers: [Answer]
    var requests: [URLRequest] = []
    init(_ answers: [Answer]) { self.answers = answers }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { fatalError("reports stream") }
    func stream(_ request: URLRequest, chunk: @escaping @Sendable (Data) throws -> Void) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let answer = answers.removeFirst()
        switch answer {
        case .status(let status, let body):
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        case .body(let chunks):
            for piece in chunks {
                guard let piece else { throw URLError(.networkConnectionLost) }
                try chunk(piece)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
    }
}

private func pieces(_ data: Data, size: Int = 100) -> [Data?] {
    stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
}

// MARK: - Requests

@Test func salesReportQueryAndFileName() throws {
    let r = try SalesReportRequest(vendor: "85012345", type: .subscription, subType: .summary, frequency: .monthly, date: "2026-10", version: "1_3")
    #expect(r.path == "/v1/salesReports")
    #expect(r.query.map { "\($0.0)=\($0.1)" } == ["filter[vendorNumber]=85012345", "filter[reportType]=SUBSCRIPTION", "filter[reportSubType]=SUMMARY",
                                                  "filter[frequency]=MONTHLY", "filter[reportDate]=2026-10", "filter[version]=1_3"])
    #expect(r.fileName == "SUBSCRIPTION_SUMMARY_MONTHLY_85012345_2026-10.tsv")
    let daily = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    #expect(daily.query.map(\.0).contains("filter[version]") == false)
    #expect(daily.fileName == "SALES_SUMMARY_DAILY_85012345_2026-11-20.tsv")
}

@Test func financeReportRegionDefaultsAndFileName() throws {
    let financial = try FinanceReportRequest(vendor: "85012345", date: "2026-10")
    #expect(financial.region == "ZZ")
    #expect(financial.query.map { "\($0.0)=\($0.1)" } == ["filter[vendorNumber]=85012345", "filter[reportType]=FINANCIAL", "filter[regionCode]=ZZ", "filter[reportDate]=2026-10"])
    #expect(financial.fileName == "FINANCIAL_ZZ_85012345_2026-10.tsv")
    #expect(try FinanceReportRequest(vendor: "1", type: .financeDetail, date: "2026-10").region == "Z1")
    #expect(try FinanceReportRequest(vendor: "1", region: "us", date: "2026-10").region == "US")
    #expect(throws: IdentifierInputError.self) { try FinanceReportRequest(vendor: "1", type: .financeDetail, region: "US", date: "2026-10") }
}

@Test func reportInputIsCheckedBeforeAnythingIsSent() throws {
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85-01", date: "2026-11-20") }
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85012345", date: "2026-11") } // daily needs a day
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85012345", frequency: .monthly, date: "2026-13") }
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85012345", date: "2026-02-30") }
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85012345", frequency: .yearly, date: "26") }
    #expect(throws: IdentifierInputError.self) { try SalesReportRequest(vendor: "85012345", date: "2026-11-20", version: "1.0") }
    #expect(throws: IdentifierInputError.self) { try FinanceReportRequest(vendor: "85012345", date: "2026-10-01") }
    #expect(throws: IdentifierInputError.self) { try FinanceReportRequest(vendor: "85012345", region: "USA", date: "2026-10") }
    #expect(try SalesReportRequest(vendor: "85012345", frequency: .yearly, date: "2025").date == "2025")
    #expect(try SalesReportSubType(argument: "summary-install-type") == .summaryInstallType)
    #expect(throws: IdentifierInputError.self) { try ReportFrequency(argument: "hourly") }
}

// MARK: - Downloads

@Test func aReportIsDecompressedIntoTheDirectory() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let text = reportText(lines: 2000)
    let gz = try gzipped(text) ?? storedGzip(text)
    let t = ChunkTransport([.body(pieces(gz, size: 333))])
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    let file = try await reports(t).download(report, into: dir.appendingPathComponent("out"), force: false)
    #expect(file == ReportFile(path: dir.appendingPathComponent("out/SALES_SUMMARY_DAILY_85012345_2026-11-20.tsv").path, bytes: text.count, replaced: false))
    #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == text)
    #expect(listing(dir.appendingPathComponent("out")) == ["SALES_SUMMARY_DAILY_85012345_2026-11-20.tsv"])
    #expect(t.requests.first?.url?.path == "/v1/salesReports")
    #expect(t.requests.first?.value(forHTTPHeaderField: "Accept") == "application/a-gzip")
    #expect(queryItems(t.requests[0]).contains("filter[reportDate]=2026-11-20"))
}

@Test func anExistingReportIsRefusedBeforeAnyRequestUnlessForced() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let report = try FinanceReportRequest(vendor: "85012345", date: "2026-10")
    let target = dir.appendingPathComponent(report.fileName)
    try Data("old\n".utf8).write(to: target)
    let t = ChunkTransport([.body([storedGzip(Data("new\n".utf8))])])
    await #expect(throws: XlessError.self) { try await reports(t).download(report, into: dir, force: false) }
    #expect(t.requests.isEmpty)
    #expect(try Data(contentsOf: target) == Data("old\n".utf8))
    let file = try await reports(t).download(report, into: dir, force: true)
    #expect(file.replaced)
    #expect(try Data(contentsOf: target) == Data("new\n".utf8))
    #expect(listing(dir) == [report.fileName])
}

@Test func aRetryStartsTheFileAgain() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let text = reportText(lines: 300)
    let gz = storedGzip(text)
    let t = ChunkTransport([.body([gz.prefix(500), nil]), .status(503, ""), .body(pieces(gz))])
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    let file = try await reports(t).download(report, into: dir, force: false)
    #expect(t.requests.count == 3)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == text)
    #expect(listing(dir) == [report.fileName])
}

@Test func noReportForTheDateSaysSoAndWritesNothing() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let t = ChunkTransport([.status(404, #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"The specified resource does not exist","detail":"There were no sales for the date specified."}]}"#)])
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    do {
        _ = try await reports(t).download(report, into: dir, force: false)
        Issue.record("expected an error")
    } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.hasPrefix("App Store Connect has no daily SALES SUMMARY report of 2026-11-20"))
        #expect(e.cause.contains("There were no sales for the date specified."))
    }
    #expect(listing(dir).isEmpty)
}

@Test func aCorruptOrCutReportLeavesNothingBehind() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let gz = storedGzip(reportText(lines: 100))
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    for body in [gz.prefix(gz.count - 3), storedGzip(Data("x".utf8), crc: 1)] {
        let t = ChunkTransport([.body([body])])
        await #expect(throws: XlessError.self) { try await reports(t).download(report, into: dir, force: false) }
        #expect(listing(dir).isEmpty)
    }
    let empty = ChunkTransport([.body([])])
    await #expect(throws: XlessError.self) { try await reports(empty).download(report, into: dir, force: false) }
    #expect(listing(dir).isEmpty)
}

@Test func aBodyThatIsNotGzipIsWrittenAsItIs() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let text = Data("Provider\tUnits\nAPPLE\t3\n".utf8)
    let t = ChunkTransport([.body([text.prefix(1), text.dropFirst(1)])])
    let report = try SalesReportRequest(vendor: "85012345", date: "2026-11-20")
    let file = try await reports(t).download(report, into: dir, force: false)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == text)
}

@Test func theDefaultStreamHandsA2xxBodyToTheSink() async throws {
    let t = MockTransport([(200, "abc"), (400, #"{"errors":[]}"#)])
    let got = ByteCounter()
    let request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/x")!)
    let (ok, okBody) = try await t.stream(request) { got.add($0.count) }
    #expect(ok.statusCode == 200 && okBody.isEmpty && got.total == 3)
    let (bad, badBody) = try await t.stream(request) { got.add($0.count) }
    #expect(bad.statusCode == 400 && badBody == Data(#"{"errors":[]}"#.utf8) && got.total == 3)
}

@Test func aTracedDownloadShowsOnlyTheSizeOfTheBody() async throws {
    let lines = Lines()
    let t = TracingTransport(MockTransport([(200, "secret-looking report body")]), trace: HTTPTrace(sink: lines.sink))
    let request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/salesReports")!)
    _ = try await t.stream(request) { _ in }
    let text = lines.all.joined(separator: "\n")
    #expect(text.contains("(26 bytes streamed)"))
    #expect(!text.contains("report body"))
}
