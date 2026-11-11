import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// Apple's web session for one run: the transport plus the in-memory cookie jar. Cookies are attached per hop by domain
/// match and stored from every response, redirects included. Redirects are followed here, https only, at most 10 hops;
/// a hop to another host keeps only `Accept`, `User-Agent` and `Range` of the original headers.
public actor AppleWebClient {
    static let maxRedirects = 10
    private let transport: AppleTransport
    private let jar: CookieJar
    private let userAgent: String

    public init(transport: AppleTransport, userAgent: String = "xless") {
        self.transport = transport
        self.jar = CookieJar()
        self.userAgent = userAgent
    }

    public func send(_ request: URLRequest, followRedirects: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response, _) = try await perform(request, followRedirects: followRedirects) { r in
            try await self.transport.send(r)
        }
        return (data, response)
    }

    /// Downloads into `file` (see `AppleTransport.download`), following redirects; returns the unwritten body (if any),
    /// the final response and the final URL.
    func download(_ request: URLRequest, to file: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse, URL) {
        try await perform(request, followRedirects: true) { r in
            try await self.transport.download(r, to: file, progress: progress)
        }
    }

    /// Forgets every cookie of the session.
    public func signOut() { jar.clear() }

    private func perform(_ first: URLRequest, followRedirects: Bool,
                         _ exchange: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse, URL) {
        var request = first
        var hops = 0
        while true {
            guard let url = request.url, url.scheme?.lowercased() == "https" else {
                throw XlessError(.sdk, "refused a non-https request to Apple", fix: "re-run; if it repeats, Apple's sign-in may have changed")
            }
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(jar.header(for: url), forHTTPHeaderField: "Cookie")
            let (data, response) = try await exchange(request)
            jar.store(from: response, for: url)
            guard followRedirects, [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                return (data, response, url)
            }
            hops += 1
            guard hops <= Self.maxRedirects else {
                throw XlessError(.sdk, "Apple redirected more than \(Self.maxRedirects) times", fix: "re-run; if it repeats, Apple's sign-in may have changed")
            }
            guard next.scheme?.lowercased() == "https" else {
                throw XlessError(.sdk, "Apple redirected to a non-https address; xless refuses it", fix: "re-run; if it repeats, report it")
            }
            request = Self.redirect(request, to: next, status: response.statusCode)
        }
    }

    static func redirect(_ request: URLRequest, to url: URL, status: Int) -> URLRequest {
        var r = URLRequest(url: url)
        let method = request.httpMethod ?? "GET"
        let toGet = status == 303 ? method != "HEAD" : ([301, 302].contains(status) && method == "POST")
        r.httpMethod = toGet ? "GET" : method
        if !toGet { r.httpBody = request.httpBody }
        let sameHost = url.host?.lowercased() == request.url?.host?.lowercased()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower == "cookie" { continue }
            if toGet && (lower == "content-type" || lower == "content-length") { continue }
            if sameHost || ["accept", "user-agent", "range"].contains(lower) { r.setValue(value, forHTTPHeaderField: name) }
        }
        return r
    }
}
