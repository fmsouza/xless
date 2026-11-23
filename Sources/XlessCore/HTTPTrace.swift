import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `--verbose` view of HTTP exchanges with Apple, redacted so a trace can be pasted into an issue: it never shows a
/// credential, a session token, a cookie, a presigned URL's signature or a secret JSON / form field. What is hidden is
/// replaced by `<redacted>`; a body that is neither JSON nor a form shows only its size. Transports wrap themselves in
/// it (`TracingTransport`, `TracingAppleTransport`); each half of an exchange reaches `sink` as one multi-line string.
public struct HTTPTrace: Sendable {
    public static let placeholder = "<redacted>"
    /// Bodies longer than this (after redaction) are cut.
    public static let maxBodyCharacters = 4096

    let sink: @Sendable (String) -> Void

    public init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    /// Lines on standard error.
    public static let standardError = HTTPTrace { text in FileHandle.standardError.write(Data((text + "\n").utf8)) }

    public func request(method: String, url: URL?, headers: [String: String], body: Data?) {
        var lines = ["> \(method) \(Self.redact(url: url))"]
        lines += Self.redact(headers: headers).map { "> \($0)" }
        if let text = Self.redact(body: body, contentType: Self.value(of: "Content-Type", in: headers)) { lines.append("> \(text)") }
        emit(lines.joined(separator: "\n"))
    }

    public func response(status: Int, url: URL?, headers: [String: String], body: Data?) {
        var lines = ["< \(status) \(Self.redact(url: url))"]
        lines += Self.redact(headers: headers).map { "< \($0)" }
        if let text = Self.redact(body: body, contentType: Self.value(of: "Content-Type", in: headers)) { lines.append("< \(text)") }
        emit(lines.joined(separator: "\n"))
    }

    /// Hides `value` wherever a trace would show it from now on, in any field: for a secret xless sends in a body,
    /// which an answer may repeat (Apple's error text quoting a demo account's password).
    public static func hide(_ value: String) {
        guard !value.isEmpty else { return }
        hidden.insert(value)
        // As a JSON body shows it, when it has characters JSON escapes.
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]) {
            let escaped = String(decoding: data, as: UTF8.self).dropFirst(2).dropLast(2)
            if !escaped.isEmpty, escaped != value { hidden.insert(String(escaped)) }
        }
    }

    private static let hidden = HiddenValues()

    func emit(_ text: String) { sink(Self.hidden.scrub(text)) }

    /// A request that got no response. Only the error's kind is shown: error descriptions carry the full URL.
    public func failure(url: URL?, error: any Error) {
        let kind = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error))
        emit("! \(Self.redact(url: url)) failed: \(kind)")
    }

    public func request(_ request: URLRequest) {
        self.request(method: request.httpMethod ?? "GET", url: request.url, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
    }

    public func response(_ response: HTTPURLResponse, body: Data?) {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields { headers["\(k)"] = "\(v)" }
        self.response(status: response.statusCode, url: response.url, headers: headers, body: body)
    }

    // MARK: Redaction

    /// The only host whose query strings are shown: the documented API's filters and cursors carry no secret. Any other
    /// host's query (a presigned upload URL's signature, a redirect's token) is hidden.
    static let hostsWithVisibleQueries: Set<String> = ["api.appstoreconnect.apple.com"]

    /// scheme://host[:port]/path, plus the query for `hostsWithVisibleQueries`; user info and fragment never.
    public static func redact(url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "-" }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        if parts.percentEncodedQuery != nil, !hostsWithVisibleQueries.contains(parts.host?.lowercased() ?? "") {
            parts.percentEncodedQuery = nil
            return (parts.string ?? "-") + "?" + placeholder
        }
        return parts.string ?? "-"
    }

    static let secretHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "scnt", "x-apple-id-session-id", "x-apple-hc",
        "x-apple-session-token", "x-apple-twosv-trust-token", "csrf", "csrf_ts",
    ]
    static let secretHeaderWords = ["auth", "cookie", "token", "secret", "session", "password", "csrf", "signature", "scnt"]

    /// `Name: value` lines sorted by name; secret headers keep their name only, `Location` is shown as a redacted URL.
    public static func redact(headers: [String: String]) -> [String] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { name, value in
            let lower = name.lowercased()
            if secretHeaders.contains(lower) || secretHeaderWords.contains(where: lower.contains) { return "\(name): \(placeholder)" }
            if lower == "location" || lower == "content-location" { return "\(name): \(redact(url: URL(string: value)))" }
            return "\(name): \(value)"
        }
    }

    static let secretFieldNames: Set<String> = ["key", "a", "b", "c", "m1", "m2"]
    static let secretFieldWords = ["password", "passphrase", "secret", "token", "privatekey", "apikey", "cookie", "securitycode", "session"]

    /// Whether a JSON or form field named `name` holds a secret: the SRP exchange's `a`, `b`, `c`, `m1`, `m2`, a `key`,
    /// and anything named like a password, secret, token, private key, cookie, session or the two-factor code.
    public static func isSecretField(_ name: String) -> Bool {
        let lower = name.lowercased().filter { $0 != "_" && $0 != "-" }
        return secretFieldNames.contains(lower) || secretFieldWords.contains(where: lower.contains)
    }

    /// The body as text with secret fields replaced: a JSON object or array (sorted keys) or a form; anything else (a
    /// PEM, a certificate, a bare value, a binary upload) only as its size and type.
    public static func redact(body: Data?, contentType: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let type = contentType?.lowercased() ?? ""
        let text: String
        if type.contains("json") || type.isEmpty || type.hasPrefix("text/javascript"),
           let json = try? JSONSerialization.jsonObject(with: body), // an object or an array: a bare "123456" is no JSON here
           let data = try? JSONSerialization.data(withJSONObject: redact(json: json), options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else if type.hasPrefix("application/x-www-form-urlencoded") {
            text = String(decoding: body, as: UTF8.self).split(separator: "&", omittingEmptySubsequences: false).map { pair in
                let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let decoded = String(name).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(name)
                return isSecretField(decoded) ? "\(name)=\(placeholder)" : String(pair)
            }.joined(separator: "&")
        } else {
            return "<\(body.count) bytes\(contentType.map { ", \($0)" } ?? "")>"
        }
        guard text.count > maxBodyCharacters else { return text }
        return String(text.prefix(maxBodyCharacters)) + "… (\(text.count - maxBodyCharacters) more characters)"
    }

    static func redact(json: Any) -> Any {
        if let object = json as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in object { out[k] = isSecretField(k) ? placeholder : redact(json: v) }
            return out
        }
        if let array = json as? [Any] { return array.map(redact(json:)) }
        return json
    }

    static func value(of header: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(header) == .orderedSame }?.value
    }
}

/// The values `HTTPTrace.hide` was given (longest first, so a value containing another is hidden whole).
private final class HiddenValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func insert(_ value: String) {
        lock.withLock {
            guard !values.contains(value) else { return }
            values.append(value)
            values.sort { $0.count > $1.count }
        }
    }

    func scrub(_ text: String) -> String {
        lock.withLock { values.reduce(text) { $0.replacingOccurrences(of: $1, with: HTTPTrace.placeholder) } }
    }
}
