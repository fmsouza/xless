import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ASCErrorItem: Codable, Sendable {
    /// Where in the request the problem is: a JSON pointer into the body (`/data/attributes/name`) or a query parameter.
    public struct Source: Codable, Sendable, Equatable {
        public var pointer: String?
        public var parameter: String?
        public init(pointer: String? = nil, parameter: String? = nil) { self.pointer = pointer; self.parameter = parameter }
    }
    public var status: String?
    public var code: String?
    public var title: String?
    public var detail: String?
    public var source: Source? = nil
}

public struct ASCError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var items: [ASCErrorItem]
    /// The request that failed (method and path, never the query or a header).
    public var method: String? = nil
    public var path: String? = nil
    /// A 429's `Retry-After`, in seconds, when App Store Connect sent one.
    public var retryAfter: Int? = nil

    public init(status: Int, items: [ASCErrorItem], method: String? = nil, path: String? = nil, retryAfter: Int? = nil) {
        self.status = status; self.items = items; self.method = method; self.path = path; self.retryAfter = retryAfter
    }

    public var description: String {
        let msgs = items.map { item in
            let text = [item.code, item.title, item.detail].compactMap { $0 }.joined(separator: ": ")
            guard let at = item.source?.pointer ?? item.source?.parameter else { return text }
            return text + " (\(at))"
        }
        return "App Store Connect HTTP \(status)" + (msgs.isEmpty ? "" : " — " + msgs.joined(separator: "; "))
    }
}

/// A response as received: what `xless api` prints.
public struct ASCResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    /// A header's value, by case-insensitive name.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ASCClient: Sendable {
    let credentials: ASCCredentials
    let transport: HTTPTransport
    let baseURL: URL
    let sleep: @Sendable (Duration) async throws -> Void
    /// What the responses' `X-Rate-Limit` headers said; warns when the hourly budget is nearly spent.
    public let rateLimits: ASCRateLimitMonitor
    public static let maxAttempts = 5
    /// The longest `Retry-After` waited for. A longer one (the hourly budget is spent) fails at once, saying how long.
    static let maxRetryAfter = 60

    public init(credentials: ASCCredentials, transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com")!,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                rateLimits: ASCRateLimitMonitor = ASCRateLimitMonitor()) {
        self.credentials = credentials; self.transport = transport; self.baseURL = baseURL; self.sleep = sleep; self.rateLimits = rateLimits
    }

    public func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        try decode(await send("GET", path, query: query, body: nil))
    }

    public func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("POST", path, query: [], body: JSONEncoder().encode(body)))
    }

    /// Single attempt, never retried: for non-idempotent creates where a retry could duplicate a scarce resource.
    public func postOnce<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("POST", path, query: [], body: JSONEncoder().encode(body), maxAttempts: 1))
    }

    public func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try decode(await send("PATCH", path, query: [], body: JSONEncoder().encode(body)))
    }

    public func delete(_ path: String) async throws {
        _ = try await send("DELETE", path, query: [], body: nil)
    }

    /// DELETE with a body: removing linkage from a to-many relationship.
    public func delete<B: Encodable>(_ path: String, body: B) async throws {
        _ = try await send("DELETE", path, query: [], body: JSONEncoder().encode(body))
    }

    /// Any method on any documented path, the response as received (`xless api`). Non-2xx responses throw `ASCError`.
    /// `maxAttempts: 1` for a request that must not be repeated (a POST).
    public func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
                        maxAttempts: Int = ASCClient.maxAttempts) async throws -> ASCResponse {
        let (data, response) = try await exchange(method, path, query: query, body: body, maxAttempts: maxAttempts)
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields { headers["\(k)"] = "\(v)" }
        return ASCResponse(status: response.statusCode, headers: headers, data: data)
    }

    /// Sends a pre-built request (e.g. upload PUTs to Apple's storage URLs) with the same retry policy and no auth header.
    public func raw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetry { try await transport.send(request) }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == ASCEmpty.self, data.isEmpty { return ASCEmpty() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, query: [(String, String)], body: Data?, maxAttempts: Int = ASCClient.maxAttempts) async throws -> Data {
        try await exchange(method, path, query: query, body: body, maxAttempts: maxAttempts).0
    }

    func exchange(_ method: String, _ path: String, query: [(String, String)], body: Data?, maxAttempts: Int) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves a literal "+" alone, which servers read as a space; paging cursors can contain one.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return try await withRetry(maxAttempts: maxAttempts, method: method, path: path) {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try JWT.appStoreConnect(credentials))", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return try await transport.send(req)
        }
    }

    func withRetry(maxAttempts: Int = ASCClient.maxAttempts, method: String? = nil, path: String? = nil,
                   _ op: () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let result: (Data, HTTPURLResponse)
            do { result = try await op() } catch let e as URLError {
                if attempt >= maxAttempts { throw e }
                try await sleep(.seconds(1 << (attempt - 1)))
                continue
            }
            let (data, response) = result
            if let header = response.value(forHTTPHeaderField: "X-Rate-Limit"), let limit = ASCRateLimit.parse(header) {
                rateLimits.record(limit)
            }
            if (200..<300).contains(response.statusCode) { return result }
            let retryAfter = response.statusCode == 429 ? response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } : nil
            let retryable = response.statusCode == 429 || response.statusCode >= 500
            if !retryable || attempt >= maxAttempts || (retryAfter ?? 0) > Self.maxRetryAfter {
                struct Envelope: Decodable { var errors: [ASCErrorItem]? }
                let items = (try? JSONDecoder().decode(Envelope.self, from: data))?.errors ?? []
                throw ASCError(status: response.statusCode, items: items, method: method, path: path, retryAfter: retryAfter)
            }
            try await sleep(.seconds(retryAfter ?? (1 << (attempt - 1))))
        }
    }
}
