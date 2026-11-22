import Foundation

/// Following App Store Connect's paged listings (`links.next`), shared by every paged read.
enum ASCPaging {
    /// A listing with more pages than this did not terminate: callers throw rather than act on a truncated list.
    static let maxPages = 1000

    /// Path and decoded query of a `links.next` URL. Parsed by hand: `URLComponents.queryItems` leaves values undecoded
    /// when the link carries raw brackets, and the client percent-encodes the query again when it sends it.
    static func parseLink(_ link: String) -> (path: String, query: [(String, String)])? {
        // Plain string splitting: URLComponents re-encodes a link with raw brackets as a whole, '%' included.
        guard let schemeEnd = link.range(of: "://") else { return nil }
        let rest = link[schemeEnd.upperBound...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let parts = rest[slash...].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let raw = parts.count > 1 ? parts[1] : ""
        let query = raw.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String { String(s).removingPercentEncoding ?? String(s) }
            return (dec(kv[0]), kv.count > 1 ? dec(kv[1]) : "")
        }
        return (path, query)
    }
}

/// A listing that did not end within `ASCPaging.maxPages` pages. Callers report it in their own stage: acting on a
/// truncated list (a group or build missed) would be worse than failing.
public enum ASCPagingError: Error, Equatable, Sendable, CustomStringConvertible {
    case didNotTerminate(path: String)

    public var description: String {
        switch self {
        case .didNotTerminate(let path): "App Store Connect returned more than \(ASCPaging.maxPages) pages for \(path); pagination did not terminate"
        }
    }
}
