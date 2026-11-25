import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

// Sales and finance reports (`/v1/salesReports`, `/v1/financeReports`): Apple answers with a gzipped tab-separated
// file, which xless decompresses into the output directory as it arrives (never the whole report in memory), under a
// temporary name until it is complete, and never over an existing file unless asked.

/// One of a report filter's values, as an argument: any case, `-` or `_` (`summary-install-type`).
public protocol ReportValue: RawRepresentable<String>, CaseIterable, Sendable {
    static var what: String { get }
}

extension ReportValue {
    public init(argument: String) throws {
        let wanted = argument.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "_")
        guard let value = Self.allCases.first(where: { $0.rawValue == wanted }) else {
            throw IdentifierInputError("\(argument) is not a \(Self.what): \(Self.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self = value
    }

    /// The values, as help shows them.
    public static var list: String { allCases.map { $0.rawValue }.joined(separator: ", ") }
}

public enum SalesReportType: String, ReportValue {
    case sales = "SALES", preOrder = "PRE_ORDER", newsstand = "NEWSSTAND", subscription = "SUBSCRIPTION"
    case subscriptionEvent = "SUBSCRIPTION_EVENT", subscriber = "SUBSCRIBER"
    case subscriptionOfferCodeRedemption = "SUBSCRIPTION_OFFER_CODE_REDEMPTION", installs = "INSTALLS"
    case firstAnnual = "FIRST_ANNUAL", winBackEligibility = "WIN_BACK_ELIGIBILITY"
    public static let what = "sales report type"
}

public enum SalesReportSubType: String, ReportValue {
    case summary = "SUMMARY", detailed = "DETAILED", summaryInstallType = "SUMMARY_INSTALL_TYPE"
    case summaryTerritory = "SUMMARY_TERRITORY", summaryChannel = "SUMMARY_CHANNEL"
    public static let what = "sales report subtype"
}

public enum ReportFrequency: String, ReportValue {
    case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    public static let what = "report frequency"

    /// What `--date` looks like for this frequency.
    public var dateShape: String {
        switch self {
        case .daily, .weekly: "YYYY-MM-DD"
        case .monthly: "YYYY-MM"
        case .yearly: "YYYY"
        }
    }
}

public enum FinanceReportType: String, ReportValue {
    case financial = "FINANCIAL", financeDetail = "FINANCE_DETAIL"
    public static let what = "finance report type"

    /// The region asked when none is given: every region (`ZZ`) for a financial report, `Z1` (the only one Apple
    /// offers) for a finance detail report.
    public var defaultRegion: String { self == .financial ? "ZZ" : "Z1" }
}

/// What a report download asks App Store Connect for, and the file it is written to.
public protocol ReportRequest: Sendable {
    var path: String { get }
    var query: [(String, String)] { get }
    /// The file name in the output directory: `SALES_SUMMARY_DAILY_85012345_2026-11-20.tsv`.
    var fileName: String { get }
    /// For messages: "daily SALES SUMMARY report of 2026-11-20".
    var display: String { get }
}

public enum ReportInput {
    /// A vendor number (App Store Connect → Payments and Financial Reports): digits only.
    public static func vendor(_ text: String) throws -> String {
        let vendor = text.trimmingCharacters(in: .whitespaces)
        guard (1...20).contains(vendor.count), vendor.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw IdentifierInputError("\(text) is not a vendor number: digits only (App Store Connect → Payments and Financial Reports, top left)")
        }
        return vendor
    }

    /// A date of the given shape (`YYYY-MM-DD`, `YYYY-MM` or `YYYY`) that exists on the calendar.
    public static func date(_ text: String, shape: String) throws -> String {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let widths = shape.split(separator: "-").map(\.count)
        guard parts.count == widths.count, zip(parts, widths).allSatisfy({ $0.count == $1 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            throw IdentifierInputError("\(text) is not a date of the form \(shape)")
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers[0] >= 2000 else { throw IdentifierInputError("\(text): App Store Connect has no reports that old") }
        if numbers.count > 1, !(1...12).contains(numbers[1]) { throw IdentifierInputError("\(text): there is no month \(numbers[1])") }
        if numbers.count > 2 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let comps = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
            guard let day = calendar.date(from: comps), calendar.component(.day, from: day) == numbers[2] else {
                throw IdentifierInputError("\(text): there is no such day")
            }
        }
        return text
    }

    /// A finance region code (`ZZ`, `Z1`, `US`, `EU`…): two capital letters or digits.
    public static func region(_ text: String) throws -> String {
        let region = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard region.count == 2, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw IdentifierInputError("\(text) is not a region code: two letters or digits, e.g. ZZ (every region) or US")
        }
        return region
    }

    /// A report format version (`1_0`, `1_3`).
    public static func version(_ text: String) throws -> String {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            throw IdentifierInputError("\(text) is not a report version: digits_digits, e.g. 1_0")
        }
        return text
    }
}

public struct SalesReportRequest: ReportRequest, Equatable {
    public var vendor: String
    public var type: SalesReportType
    public var subType: SalesReportSubType
    public var frequency: ReportFrequency
    public var date: String
    public var version: String?

    /// Checks every value; throws `IdentifierInputError` before anything is sent.
    public init(vendor: String, type: SalesReportType = .sales, subType: SalesReportSubType = .summary,
                frequency: ReportFrequency = .daily, date: String, version: String? = nil) throws {
        self.vendor = try ReportInput.vendor(vendor)
        self.type = type; self.subType = subType; self.frequency = frequency
        self.date = try ReportInput.date(date, shape: frequency.dateShape)
        self.version = try version.map(ReportInput.version)
    }

    public var path: String { "/v1/salesReports" }

    public var query: [(String, String)] {
        var items = [("filter[vendorNumber]", vendor), ("filter[reportType]", type.rawValue), ("filter[reportSubType]", subType.rawValue),
                     ("filter[frequency]", frequency.rawValue), ("filter[reportDate]", date)]
        if let version { items.append(("filter[version]", version)) }
        return items
    }

    public var fileName: String { "\(type.rawValue)_\(subType.rawValue)_\(frequency.rawValue)_\(vendor)_\(date).tsv" }
    public var display: String { "\(frequency.rawValue.lowercased()) \(type.rawValue) \(subType.rawValue) report of \(date)" }
}

public struct FinanceReportRequest: ReportRequest, Equatable {
    public var vendor: String
    public var type: FinanceReportType
    public var region: String
    /// The fiscal month, `YYYY-MM`.
    public var date: String

    /// Checks every value; throws `IdentifierInputError` before anything is sent.
    public init(vendor: String, type: FinanceReportType = .financial, region: String? = nil, date: String) throws {
        self.vendor = try ReportInput.vendor(vendor)
        self.type = type
        self.region = try region.map(ReportInput.region) ?? type.defaultRegion
        if type == .financeDetail, self.region != "Z1" {
            throw IdentifierInputError("Apple offers FINANCE_DETAIL reports for region Z1 only (all regions); drop --region or give Z1")
        }
        self.date = try ReportInput.date(date, shape: "YYYY-MM")
    }

    public var path: String { "/v1/financeReports" }

    public var query: [(String, String)] {
        [("filter[vendorNumber]", vendor), ("filter[reportType]", type.rawValue), ("filter[regionCode]", region), ("filter[reportDate]", date)]
    }

    public var fileName: String { "\(type.rawValue)_\(region)_\(vendor)_\(date).tsv" }
    public var display: String { "\(type.rawValue) report of \(date) for region \(region)" }
}

/// A report written to disk.
public struct ReportFile: Encodable, Sendable, Equatable {
    public var path: String
    /// Its size, decompressed.
    public var bytes: Int
    /// Whether it replaced a file that was there (`--force`).
    public var replaced: Bool
}

/// Downloads reports into a directory (API key with the Sales or Finance role, or Admin).
public struct ASCReports: Sendable {
    let client: ASCClient

    public init(client: ASCClient) { self.client = client }

    /// Writes `report` to `directory/<report.fileName>` (the directory is made when missing): Apple's gzip is
    /// decompressed as it arrives into `.<name>.partial-<pid>` next to it, which becomes the report only once complete
    /// and checked. An existing report is refused before anything is sent unless `force`; nothing is left behind on
    /// failure.
    public func download(_ report: some ReportRequest, into directory: URL, force: Bool) async throws -> ReportFile {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw XlessError(.account, "\(directory.path) is not a directory", fix: "give --out a directory (it is made when missing)")
            }
        } else {
            do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
                throw XlessError(.account, "could not make \(directory.path): \(error.localizedDescription)", fix: "give --out a directory you can write to")
            }
        }
        let target = directory.appendingPathComponent(report.fileName)
        let existed = fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
        if existed {
            if fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw XlessError(.account, "\(target.path) is a directory", fix: "move it away, or give another --out")
            }
            if !force {
                throw XlessError(.account, "\(target.path) already exists; nothing was downloaded", fix: "re-run with --force to replace it, or give another --out")
            }
        }
        let partial = directory.appendingPathComponent(".\(report.fileName).partial-\(ProcessInfo.processInfo.processIdentifier)")
        var sink: ReportSink?
        defer {
            sink?.close()
            try? fm.removeItem(at: partial)
        }
        do {
            try await client.download(report.path, query: report.query, accept: "application/a-gzip") {
                sink?.close()
                try? fm.removeItem(at: partial) // a failed attempt's start
                let fresh = try ReportSink(path: partial.path)
                sink = fresh
                return { try fresh.write($0) }
            }
            guard let sink else { throw XlessError(.account, "App Store Connect sent no report", fix: "re-run the command") }
            try sink.finish()
            let bytes = sink.written
            try place(partial, at: target, force: force)
            return ReportFile(path: target.path, bytes: bytes, replaced: existed)
        } catch let e as ASCError where e.status == 404 {
            let said = e.items.compactMap { $0.detail ?? $0.title }.first.map { " (Apple: \($0))" } ?? ""
            throw XlessError(.account, "App Store Connect has no \(report.display)\(said); nothing was written",
                             fix: "check --date (and --frequency): a day's report appears the next day, a week's (dated its Sunday) on Monday, a month's early in the next month; a period with no sales has no report, and daily reports are kept for a year")
        } catch let e as GzipError {
            throw XlessError(.account, "the report App Store Connect sent is unreadable (\(e.description)); nothing was written", fix: "re-run the command")
        } catch let e as ReportSink.WriteError {
            throw XlessError(.account, "writing \(partial.path) failed: \(e.description); nothing was written", fix: "check the free space and that --out is writable, then re-run")
        }
    }

    /// Moves the complete report into place: without `force`, never over a file that appeared meanwhile.
    func place(_ partial: URL, at target: URL, force: Bool) throws {
        #if os(Windows)
        do { try OutputFile.move(partial.path, to: target.path, replacing: force) } catch let refusal as PrivateFile.Refusal {
            if refusal.kind == .exists {
                throw XlessError(.account, "\(target.path) appeared while the report was downloaded; nothing was written",
                                 fix: "re-run with --force to replace it, or give another --out")
            }
            throw XlessError(.account, "could not move the report to \(target.path): \(refusal.cause)", fix: "check that --out is writable, then re-run")
        }
        #else
        if force {
            guard rename(partial.path, target.path) == 0 else {
                throw XlessError(.account, "could not move the report to \(target.path): \(String(cString: strerror(errno)))", fix: "check that --out is writable, then re-run")
            }
            return
        }
        if link(partial.path, target.path) == 0 { return }
        let linkError = errno
        let appeared = XlessError(.account, "\(target.path) appeared while the report was downloaded; nothing was written",
                                  fix: "re-run with --force to replace it, or give another --out")
        if linkError == EEXIST { throw appeared }
        // A file system without hard links: the existence check and the rename are not one step there.
        if FileManager.default.fileExists(atPath: target.path) { throw appeared }
        guard rename(partial.path, target.path) == 0 else {
            throw XlessError(.account, "could not move the report to \(target.path): \(String(cString: strerror(errno)))", fix: "check that --out is writable, then re-run")
        }
        #endif
    }
}

/// Where one download attempt writes: a new file (O_EXCL), gzip decompressed on the way, or the bytes as they are when
/// they are not gzip (a body some proxy already decompressed).
final class ReportSink: @unchecked Sendable {
    struct WriteError: Error, CustomStringConvertible { let description: String }

    #if os(Windows)
    private let handle: OutputFile
    #else
    private let handle: FileHandle
    #endif
    private var decoder: GzipDecoder?
    private var head = Data()
    private var decided = false
    private var closed = false
    private(set) var written = 0

    init(path: String) throws {
        #if os(Windows)
        do { handle = try OutputFile(creating: path) } catch { throw WriteError(description: "\(error)") }
        #else
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WriteError(description: String(cString: strerror(errno))) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #endif
    }

    func write(_ data: Data) throws {
        if decided { return try feed(data) }
        head.append(data)
        guard head.count >= 2 else { return }
        try decide()
    }

    private func decide() throws {
        decided = true
        let first = head
        head = Data()
        if GzipDecoder.isGzip(first) {
            decoder = GzipDecoder { [unowned self] in try self.save($0) }
        } else if let lead = first.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }), lead == UInt8(ascii: "{") || lead == UInt8(ascii: "<") {
            // A JSON or HTML page is no report (a proxy's or an error page answered with 200).
            throw GzipError("App Store Connect answered with a JSON or HTML document instead of a report")
        }
        try feed(first)
    }

    private func feed(_ data: Data) throws {
        if decoder != nil { try decoder!.write(data) } else { try save(data) }
    }

    private func save(_ data: Data) throws {
        #if os(Windows)
        do { try handle.write(data) } catch { throw WriteError(description: "\(error)") }
        #else
        do { try handle.write(contentsOf: data) } catch { throw WriteError(description: error.localizedDescription) }
        #endif
        written += data.count
    }

    /// The body is complete: checks the gzip ends where it should and flushes the file to disk.
    func finish() throws {
        if !decided {
            guard !head.isEmpty else { throw GzipError("App Store Connect sent an empty report") }
            try decide()
        }
        if decoder != nil { try decoder!.finish() }
        do { try handle.synchronize() } catch { throw WriteError(description: error.localizedDescription) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        #if os(Windows)
        handle.close()
        #else
        try? handle.close()
        #endif
    }
}
