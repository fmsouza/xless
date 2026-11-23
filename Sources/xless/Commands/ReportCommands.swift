import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless reports`: sales and finance reports, written to disk decompressed (docs/apple-account.md#xless-reports).

struct ReportsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reports",
        abstract: "Download sales and finance reports as tab-separated files.",
        discussion: """
        Uses the App Store Connect API key (/v1/salesReports, /v1/financeReports): sales reports need the Sales role, \
        finance reports the Finance role (or Admin). The vendor number is in App Store Connect → Payments and Financial \
        Reports. Apple sends each report gzipped; xless writes it decompressed into --out as it arrives, named after \
        what it holds, and never replaces a file there without --force.

          xless reports sales download --vendor 85012345 --date 2026-11-20 --out reports/
          xless reports sales download --vendor 85012345 --frequency monthly --date 2026-10 --type subscription --out reports/
          xless reports finance download --vendor 85012345 --date 2026-10 --out reports/
        """,
        subcommands: [ReportsSalesCommand.self, ReportsFinanceCommand.self])
}

struct ReportsSalesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sales", abstract: "Sales, subscription and install reports.",
                                                    subcommands: [ReportsSalesDownloadCommand.self])
}

struct ReportsFinanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "finance", abstract: "Financial (proceeds and payments) reports.",
                                                    subcommands: [ReportsFinanceDownloadCommand.self])
}

/// Where a report goes, and the shared account options of a download.
struct ReportOutputOptions: ParsableArguments {
    @Option(help: ArgumentHelp("The directory the report is written to (made when missing).", valueName: "dir")) var out: String
    @Flag(help: "Replace a report of the same name already in --out.") var force = false
    @OptionGroup var team: TeamOption
    @OptionGroup var output: JSONOption
    @OptionGroup var trace: VerboseOption
}

/// Opens the account session, downloads `report` and prints where it went.
private func download(_ report: some ReportRequest, _ options: ReportOutputOptions) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: options.team.team, verbose: options.trace.verbose)
        let out = try await ReportCLI(reports: ASCReports(client: session.client), json: options.output.json)
            .download(report, into: options.out, force: options.force)
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

private func checked<T>(_ make: () throws -> T) throws -> T {
    do { return try make() } catch let e as IdentifierInputError { throw ValidationError(e.description) }
}

struct ReportsSalesDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download one sales report: <TYPE>_<SUBTYPE>_<FREQUENCY>_<vendor>_<date>.tsv in --out.",
        discussion: """
        --date is the day (YYYY-MM-DD) of a daily report, the last day of the week (YYYY-MM-DD, a Sunday) of a weekly \
        one, the month (YYYY-MM) of a monthly one and the year (YYYY) of a yearly one. Each type has its own subtypes, \
        frequencies and versions (developer.apple.com/documentation/appstoreconnectapi/get-v1-salesreports); without \
        --report-version, Apple's default for the type is used.
        """)

    @Option(help: ArgumentHelp("The vendor number (App Store Connect → Payments and Financial Reports).", valueName: "number")) var vendor: String
    @Option(help: ArgumentHelp("The report's day, week, month or year (see below).", valueName: "date")) var date: String
    @Option(help: ArgumentHelp("daily, weekly, monthly or yearly.", valueName: "frequency")) var frequency = "daily"
    @Option(help: ArgumentHelp("The report type: \(SalesReportType.list) (any case, - or _).", valueName: "type")) var type = "sales"
    @Option(help: ArgumentHelp("The subtype: \(SalesReportSubType.list) (any case, - or _).", valueName: "subtype")) var subtype = "summary"
    @Option(name: .customLong("report-version"), help: ArgumentHelp("The report format version, e.g. 1_0 or 1_3.", valueName: "version"))
    var reportVersion: String?
    @OptionGroup var output: ReportOutputOptions

    func request() throws -> SalesReportRequest {
        try checked {
            try SalesReportRequest(vendor: vendor, type: SalesReportType(argument: type), subType: SalesReportSubType(argument: subtype),
                                   frequency: ReportFrequency(argument: frequency), date: date, version: reportVersion)
        }
    }

    func validate() throws { _ = try request() }

    func run() async throws { try await download(try request(), output) }
}

struct ReportsFinanceDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download one finance report: <TYPE>_<REGION>_<vendor>_<YYYY-MM>.tsv in --out.",
        discussion: """
        --date is Apple's fiscal month (YYYY-MM). FINANCIAL reports are per region (--region, default ZZ: every region \
        consolidated); FINANCE_DETAIL reports exist for region Z1 only.
        """)

    @Option(help: ArgumentHelp("The vendor number (App Store Connect → Payments and Financial Reports).", valueName: "number")) var vendor: String
    @Option(help: ArgumentHelp("The fiscal month, YYYY-MM.", valueName: "month")) var date: String
    @Option(help: ArgumentHelp("FINANCIAL or FINANCE_DETAIL (any case, - or _).", valueName: "type")) var type = "financial"
    @Option(help: ArgumentHelp("The region code (ZZ, Z1, US, EU…). Default: ZZ, or Z1 for FINANCE_DETAIL.", valueName: "code")) var region: String?
    @OptionGroup var output: ReportOutputOptions

    func request() throws -> FinanceReportRequest {
        try checked { try FinanceReportRequest(vendor: vendor, type: FinanceReportType(argument: type), region: region, date: date) }
    }

    func validate() throws { _ = try request() }

    func run() async throws { try await download(try request(), output) }
}

/// What a report download prints.
struct ReportCLI {
    let reports: ASCReports
    var json = false

    func download(_ report: some ReportRequest, into directory: String, force: Bool) async throws -> String {
        let file = try await reports.download(report, into: URL(fileURLWithPath: directory), force: force)
        if json { return try ASCOutput.json(file) }
        return "wrote \(file.path) (\(file.bytes) bytes\(file.replaced ? ", replacing the previous file" : ""))\n"
    }
}
