import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// One answer of Apple's web interfaces, headers by name (look them up with `header(_:)`, case-insensitively).
public struct AppleWebResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data

    public init(status: Int, headers: [String: String], data: Data) {
        self.status = status; self.headers = headers; self.data = data
    }

    init(_ data: Data, _ response: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        self.init(status: response.statusCode, headers: headers, data: data)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The two undocumented web interfaces the Apple ID session reaches, for error messages.
public enum AppleWebFamily: Sendable, Equatable {
    /// `https://appstoreconnect.apple.com/iris/v1/…` and `/olympus/v1/…`.
    case appStoreConnect
    /// `https://developer.apple.com/services-account/…` (the v1 JSON:API and the older `QH65B2/….action` posts).
    case developerPortal

    public var name: String {
        switch self {
        case .appStoreConnect: "App Store Connect's web interface"
        case .developerPortal: "the developer portal's web interface"
        }
    }

    /// Where a person does the same thing in a browser meanwhile.
    public var page: String {
        switch self {
        case .appStoreConnect: "https://appstoreconnect.apple.com"
        case .developerPortal: "https://developer.apple.com/account/resources"
        }
    }
}

/// The `[account]` errors of the web session. They name the endpoint family and say the interface is undocumented. They
/// never carry a cookie, `scnt`, CSRF token or request body: only the method, the path and Apple's own message.
public enum AppleWebFailure {
    static let undocumented = "this is an undocumented Apple web interface (the one Apple's own pages use) and it may have changed"
    static let agreementsPage = "https://appstoreconnect.apple.com/agreements"

    public static func http(_ family: AppleWebFamily, method: String, path: String, status: Int, message: String?,
                            page: String? = nil) -> XlessError {
        XlessError(.account, "\(family.name) answered HTTP \(status) to \(method) \(path)\(message.map { ": \($0)" } ?? "")",
                   fix: "\(undocumented); re-run with --verbose to see the exchange (redacted), and meanwhile do it at \(page ?? family.page)")
    }

    public static func sessionExpired(_ family: AppleWebFamily, method: String, path: String) -> XlessError {
        XlessError(.account, "\(family.name) refused the Apple ID session for \(method) \(path) (it expired or was signed out)",
                   fix: "run `xless auth logout` to drop a kept session, then re-run to sign in again")
    }

    public static func agreement(_ family: AppleWebFamily, message: String?) -> XlessError {
        XlessError(.account, "Apple has agreements or terms pending for this account (\(family.name) refused\(message.map { ": \($0)" } ?? ""))",
                   fix: "the Account Holder accepts them at \(agreementsPage) and https://developer.apple.com/account (xless never accepts legal terms), then re-run")
    }

    public static func malformed(_ family: AppleWebFamily, method: String, path: String, what: String, page: String? = nil) -> XlessError {
        XlessError(.account, "\(family.name) answered \(method) \(path) with \(what)",
                   fix: "\(undocumented); re-run with --verbose to see the exchange (redacted), and meanwhile do it at \(page ?? family.page)")
    }

    /// The error for a refused answer: 401 → the session; a message about agreements → the agreements; else the status.
    static func refused(_ family: AppleWebFamily, method: String, path: String, response: AppleWebResponse, page: String?) -> XlessError {
        let message = Self.message(response.data)
        if response.status == 401 { return sessionExpired(family, method: method, path: path) }
        if let message, mentionsAgreement(message) { return agreement(family, message: message) }
        return http(family, method: method, path: path, status: response.status, message: message, page: page)
    }

    static func mentionsAgreement(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("agreement") || t.contains("program license") || t.contains("terms and conditions")
    }

    /// Apple's own words from an error body: JSON:API `errors`, the portal's `userString`/`resultString`, or the sign-in's
    /// `serviceErrors`; at most 300 characters, tags removed.
    public static func message(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts: [String] = []
        if let errors = object["errors"] as? [[String: Any]] {
            for e in errors {
                let text = [e["code"], e["title"], e["detail"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                if !text.isEmpty { parts.append(text.joined(separator: " — ")) }
            }
        }
        for key in ["userString", "resultString"] {
            if let s = object[key] as? String, !s.isEmpty { parts.append(s); break }
        }
        if let service = object["serviceErrors"] as? [[String: Any]] {
            parts += service.compactMap { $0["message"] as? String }
        }
        let text = plain(parts.joined(separator: "; "))
        guard !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// Text without HTML tags, whitespace collapsed.
    static func plain(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return noTags.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Remembers the `csrf` / `csrf_ts` tokens of the newest answer that had them, and adds them to every request (as
/// fastlane's spaceship does). They are session secrets: never printed, and `HTTPTrace` redacts them.
struct CSRFTokens: Sendable {
    private(set) var tokens: [String: String] = [:]

    var isEmpty: Bool { tokens.isEmpty }

    mutating func remember(_ response: AppleWebResponse) {
        var next: [String: String] = [:]
        for name in ["csrf", "csrf_ts"] { if let v = response.header(name), !v.isEmpty { next[name] = v } }
        if !next.isEmpty { tokens = next }
    }

    func apply(to request: inout URLRequest) {
        for (k, v) in tokens { request.setValue(v, forHTTPHeaderField: k) }
    }
}
