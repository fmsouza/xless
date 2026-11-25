import Foundation
#if os(Windows)
import XlessCore
#endif

/// App Store Connect's hourly request budget for the API key's user, from a response's `X-Rate-Limit` header
/// (`user-hour-lim:3600;user-hour-rem:3599;`).
public struct ASCRateLimit: Sendable, Equatable {
    public var limit: Int
    public var remaining: Int

    public init(limit: Int, remaining: Int) { self.limit = limit; self.remaining = remaining }

    public static func parse(_ header: String) -> ASCRateLimit? {
        var limit: Int?, remaining: Int?
        for part in header.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Int(kv[1]) else { continue }
            switch kv[0] {
            case "user-hour-lim": limit = value
            case "user-hour-rem": remaining = value
            default: break
            }
        }
        guard let limit, let remaining else { return nil }
        return ASCRateLimit(limit: limit, remaining: remaining)
    }

    /// At most a tenth of the hour's budget left.
    public var nearlySpent: Bool { limit > 0 && remaining * 10 <= limit }
}

/// The latest budget the responses reported, shared by the copies of an `ASCClient`; warns once (per monitor) when it is
/// nearly spent, so a long command (a `--paginate`, a `provision apply`) says why it may soon be refused.
public final class ASCRateLimitMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ASCRateLimit?
    private var warned = false
    private let warn: @Sendable (String) -> Void

    public static let standardError: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// `warn` receives the one warning line (default: standard error).
    public init(warn: @escaping @Sendable (String) -> Void = ASCRateLimitMonitor.standardError) {
        self.warn = warn
    }

    public var latest: ASCRateLimit? { lock.withLock { last } }

    func record(_ limit: ASCRateLimit) {
        let shouldWarn: Bool = lock.withLock {
            last = limit
            guard limit.nearlySpent, !warned else { return false }
            warned = true
            return true
        }
        if shouldWarn {
            warn("warning: App Store Connect's hourly request budget is nearly spent (\(limit.remaining) of \(limit.limit) requests left); further requests may be refused with HTTP 429 until the hour is over")
        }
    }
}

#if os(Windows)
extension FileHandle {
    func write(_ data: Data) { WindowsOutput.write(data, to: self) }
}
#endif
