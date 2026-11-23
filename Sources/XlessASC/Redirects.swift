import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A redirect xless will not follow: from https to anything else, or one that would carry a request's body to another
/// origin (a 307 or 308 after a PATCH holding a demo account's password). Names the host only (an address Apple hands
/// out may carry a signature in its query).
public struct RedirectRefused: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable { case notHTTPS, bodyToAnotherOrigin }
    public let host: String
    public let reason: Reason
    public init(host: String, reason: Reason = .notHTTPS) { self.host = host; self.reason = reason }
    public var description: String {
        switch reason {
        case .notHTTPS: "refused a redirect from https to a non-https address (\(host))"
        case .bodyToAnotherOrigin: "refused a redirect that would send the request's body on to another host (\(host))"
        }
    }
}

/// More than `HTTPRedirect.maxHops` redirects in a row. Not a `URLError`, so it is not retried.
public struct TooManyRedirects: Error, Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public var description: String { "more than \(HTTPRedirect.maxHops) redirects in a row (last at \(host))" }
}

/// How `URLSessionTransport` follows redirects. URLSession never follows one by itself (swift-corelibs-foundation would
/// resend every header, `Authorization` included, to wherever the `Location` points): xless does, at most `maxHops`
/// times. Within one origin (scheme, host and port) the request keeps its headers; to another origin only `Accept`,
/// `User-Agent` and `Range` follow (as in `AppleWebClient`), so the API key's token stays where it was sent, and a body
/// never does.
public enum HTTPRedirect {
    public static let maxHops = 10
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]
    /// The only headers that follow a redirect to another origin.
    static let crossOrigin: Set<String> = ["accept", "user-agent", "range"]

    /// The request to send after `response` answered `request`; nil when the response is no redirect to follow (another
    /// status, or no usable `Location`). 303, and 301/302 after a POST, become a GET without a body; 307 and 308 keep the
    /// method and the body, so to another origin they are refused when there is a body. Throws `RedirectRefused` for an
    /// https request redirected to anything but https.
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
        let sameOrigin = origin(of: from) == origin(of: to)
        if !toGet, !sameOrigin, let body = request.httpBody, !body.isEmpty {
            throw RedirectRefused(host: to.host ?? "?", reason: .bodyToAnotherOrigin)
        }
        var next = URLRequest(url: to, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        next.httpMethod = toGet ? "GET" : method
        if !toGet { next.httpBody = request.httpBody }
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if !sameOrigin && !crossOrigin.contains(lower) { continue }
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
