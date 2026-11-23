import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A redirect xless will not follow: from https to anything else. Names the host only (an address Apple hands out may
/// carry a signature in its query).
public struct RedirectRefused: Error, Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public var description: String { "refused a redirect from https to a non-https address (\(host))" }
}

/// How `URLSessionTransport` follows redirects. URLSession never follows one by itself (swift-corelibs-foundation would
/// resend every header, `Authorization` included, to wherever the `Location` points): xless does, at most `maxHops`
/// times, and the API key's token, and any cookie, stay with the origin (scheme, host and port) they were sent to.
public enum HTTPRedirect {
    public static let maxHops = 10
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    /// Headers that never follow a redirect to another origin.
    static let credentials: Set<String> = ["authorization", "cookie", "proxy-authorization"]

    /// The request to send after `response` answered `request`; nil when the response is no redirect to follow (another
    /// status, or no usable `Location`). 303, and 301/302 after a POST, become a GET without a body; 307 and 308 keep the
    /// method and the body. Throws `RedirectRefused` for an https request redirected to anything but https.
    public static func next(after request: URLRequest, response: HTTPURLResponse) throws -> URLRequest? {
        guard statuses.contains(response.statusCode), let from = request.url,
              let location = response.value(forHTTPHeaderField: "Location"),
              let to = URL(string: location, relativeTo: from)?.absoluteURL, let scheme = to.scheme?.lowercased()
        else { return nil }
        let fromScheme = from.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && fromScheme == "http") else {
            throw RedirectRefused(host: to.host ?? "?")
        }
        let method = request.httpMethod ?? "GET"
        let toGet = response.statusCode == 303 ? method != "HEAD" : ([301, 302].contains(response.statusCode) && method == "POST")
        var next = URLRequest(url: to, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        next.httpMethod = toGet ? "GET" : method
        if !toGet { next.httpBody = request.httpBody }
        let sameOrigin = origin(of: from) == origin(of: to)
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if !sameOrigin && credentials.contains(lower) { continue }
            if toGet && (lower == "content-type" || lower == "content-length") { continue }
            next.setValue(value, forHTTPHeaderField: name)
        }
        return next
    }

    /// Scheme, host (lower case) and port (the scheme's default when absent).
    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
    }
}
