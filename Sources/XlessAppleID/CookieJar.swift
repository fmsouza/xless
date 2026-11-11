import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Apple session's cookies, in this process's memory only: never written to disk, never handed to another process,
/// gone when the process exits (or on `clear()`). A subset of RFC 6265: host-only and Domain cookies, Path, Secure,
/// Expires and Max-Age. A Domain must contain the response's host and have a dot in it, so a cookie never reaches a host
/// outside the domain that set it.
final class CookieJar: @unchecked Sendable {
    private struct Cookie {
        let name: String
        var value: String
        let domain: String
        let hostOnly: Bool
        let path: String
        var secure: Bool
        var expires: Date?
    }

    private let lock = NSLock()
    private var cookies: [Cookie] = []
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    var isEmpty: Bool { lock.withLock { cookies.isEmpty } }

    func clear() { lock.withLock { cookies.removeAll() } }

    func store(from response: HTTPURLResponse, for url: URL) {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie"), let host = url.host?.lowercased() else { return }
        for line in Self.splitCookies(raw) {
            guard let cookie = parse(line, host: host, requestPath: url.path) else { continue }
            lock.withLock {
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                if let e = cookie.expires, e <= now() { return }
                cookies.append(cookie)
            }
        }
    }

    /// The `Cookie` header for a request to `url`, or nil when no cookie matches.
    func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let https = url.scheme?.lowercased() == "https"
        let t = now()
        let matching = lock.withLock { () -> [Cookie] in
            cookies.removeAll { $0.expires.map { $0 <= t } ?? false }
            return cookies.filter { c in
                (c.hostOnly ? host == c.domain : Self.domainMatches(host: host, domain: c.domain))
                    && Self.pathMatches(path, c.path) && (!c.secure || https)
            }
        }
        guard !matching.isEmpty else { return nil }
        return matching.enumerated()
            .sorted { ($0.element.path.count, -$0.offset) > ($1.element.path.count, -$1.offset) }
            .map { "\($0.element.name)=\($0.element.value)" }
            .joined(separator: "; ")
    }

    // MARK: parsing

    /// Splits a `Set-Cookie` value that may hold several cookies joined by commas (as Foundation merges repeated
    /// headers). A comma starts a new cookie only when `name=` follows it; a comma inside an Expires date does not.
    static func splitCookies(_ raw: String) -> [String] {
        var out: [String] = []
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let last = out.last, !startsCookie(trimmed) || last.isEmpty {
                out[out.count - 1] = last + "," + part
            } else {
                out.append(String(part))
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func startsCookie(_ s: String) -> Bool {
        guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { return false }
        return !s[..<eq].contains { $0 == ";" || $0 == " " || $0 == "\t" }
    }

    private func parse(_ line: String, host: String, requestPath: String) -> Cookie? {
        var parts = line.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, let eq = parts[0].firstIndex(of: "="), eq != parts[0].startIndex else { return nil }
        let name = String(parts[0][..<eq]), value = String(parts[0][parts[0].index(after: eq)...])
        parts.removeFirst()
        var domain: String?, path: String?, secure = false, expires: Date?, maxAge: Int?
        for attr in parts {
            let kv = attr.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = kv.first else { continue }
            let key = first.lowercased(), val = kv.count > 1 ? kv[1] : ""
            switch key {
            case "domain":
                var d = val.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                if !d.isEmpty { domain = d }
            case "path": if val.hasPrefix("/") { path = val }
            case "secure": secure = true
            case "expires": expires = Self.parseDate(val)
            case "max-age": maxAge = Int(val)
            default: break
            }
        }
        if let maxAge { expires = now().addingTimeInterval(TimeInterval(max(maxAge, -1))) }
        if let d = domain {
            guard d.contains("."), Self.domainMatches(host: host, domain: d) else { return nil }
        }
        return Cookie(name: name, value: value, domain: domain ?? host, hostOnly: domain == nil,
                      path: path ?? Self.defaultPath(requestPath), secure: secure, expires: expires)
    }

    private static func domainMatches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func pathMatches(_ path: String, _ cookiePath: String) -> Bool {
        if path == cookiePath { return true }
        guard path.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")
    }

    private static func defaultPath(_ path: String) -> String {
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func parseDate(_ s: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
