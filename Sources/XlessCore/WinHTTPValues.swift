import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// What WinHTTPSession reads and says: values, which every system can test.

/// A status line and header lines, as WinHTTP gives them.
enum WinHTTPHeaders {
    /// A header that is there more than once has its values in one, separated by a comma (as URLSession's).
    static func parse(_ text: String) -> [String: String] {
        var names: [String: String] = [:] // in small letters → as it is written
        var out: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = names[name.lowercased()] ?? name
            names[name.lowercased()] = key
            out[key] = out[key].map { "\($0), \(value)" } ?? value
        }
        return out
    }
}

/// Which proxy: the one the variables name, as curl has them (and the other systems), else the system's own setting.
enum WinHTTPProxy: Equatable {
    case system, none
    /// WinHTTP's lists: `http=host:port https=host:port`, and the hosts that are reached without it.
    case named(String, bypass: String)

    /// One of another kind, or with a name and a password in it, is refused rather than gone without.
    init(env: [String: String]) throws {
        func value(_ name: String) -> String? { env.variable(name, ignoreCase: true).flatMap { $0.isEmpty ? nil : $0 } }
        let all = value("ALL_PROXY")
        var list: [String] = []
        for scheme in ["http", "https"] {
            let name = "\(scheme.uppercased())_PROXY"
            if let text = value(name) { list.append("\(scheme)=\(try Self.address(text, name))") }
            else if let all { list.append("\(scheme)=\(try Self.address(all, "ALL_PROXY"))") }
        }
        guard !list.isEmpty else { self = .system; return }
        var bypass: [String] = []
        for entry in (value("NO_PROXY") ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
            if entry == "*" { self = .none; return }
            // a name is that of a domain: itself and what is in it
            let host = entry.hasPrefix("*.") ? String(entry.dropFirst(2)) : entry.hasPrefix(".") ? String(entry.dropFirst()) : String(entry)
            guard !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "-._:[]".unicodeScalars.contains($0)) }) else {
                throw XlessError(.config, "NO_PROXY has \(entry), which is not a host name", fix: "give host names and domains, separated by commas")
            }
            let isAddress = host.unicodeScalars.allSatisfy { $0 == "." || ("0"..."9").contains($0) } || host.contains("[")
            bypass.append(host)
            if !isAddress { bypass.append("*.\(host)") }
        }
        self = .named(list.joined(separator: " "), bypass: bypass.joined(separator: ";"))
    }

    private static func address(_ text: String, _ name: String) throws -> String {
        // The value is not repeated: it may hold a password.
        let fix = "set \(name) to http://<host>:<port>"
        let whole = text.contains("://") ? text : "http://\(text)"
        guard let parts = URLComponents(string: whole), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty else {
            throw XlessError(.config, "\(name) is not a proxy's address", fix: fix)
        }
        guard scheme == "http" else { throw XlessError(.config, "\(name) names a proxy of another kind (\(scheme)), which xless cannot use on Windows", fix: fix) }
        guard parts.user == nil, parts.password == nil else {
            throw XlessError(.config, "\(name) has a name and a password for the proxy, which xless does not send on Windows", fix: fix)
        }
        guard parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/", parts.query == nil, parts.fragment == nil,
              host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0 != ";" && $0 != "=" }) else {
            throw XlessError(.config, "\(name) is not a proxy's address", fix: fix)
        }
        let bare = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        return "\(bare.contains(":") ? "[\(bare)]" : bare):\(parts.port ?? 80)"
    }
}

/// What went wrong, in URLError's kinds (which of them are retried, and how, is one rule for every system).
enum WinHTTPFailure {
    static func of(_ code: UInt32, secure: UInt32) -> (URLError.Code, String) {
        switch code {
        case 12002: return (.timedOut, "the server did not answer in time")                                  // ERROR_WINHTTP_TIMEOUT
        case 12007: return (.cannotFindHost, "the server's name is not known")                               // NAME_NOT_RESOLVED
        case 12029: return (.cannotConnectToHost, "cannot connect to the server")                            // CANNOT_CONNECT
        case 12030, 12032: return (.networkConnectionLost, "the connection was lost")                        // CONNECTION_ERROR, RESEND_REQUEST
        case 12017: return (.cancelled, "cancelled")                                                         // OPERATION_CANCELLED
        case 12152: return (.badServerResponse, "the server's answer is not HTTP")                           // INVALID_SERVER_RESPONSE
        case 12005, 12006: return (.badURL, "not an address")                                                // INVALID_URL, UNRECOGNIZED_SCHEME
        case 12044: return (.clientCertificateRequired, "the server wants a certificate of the client's")    // CLIENT_AUTH_CERT_NEEDED
        case 0xFFFF_FFFF: return (.cannotConnectToHost, "a proxy answered instead of the server")            // XLESS_HTTP_NOT_THE_SERVER
        case 12175: return certificate(secure)                                                               // SECURE_FAILURE
        case 12037: return certificate(0x20)                                                                 // SECURE_CERT_DATE_INVALID
        case 12038: return certificate(0x10)                                                                 // SECURE_CERT_CN_INVALID
        case 12045: return certificate(0x08)                                                                 // SECURE_INVALID_CA
        case 12169, 12170, 12179: return certificate(0x04)                                                   // SECURE_INVALID_CERT, _CERT_REVOKED, _CERT_WRONG_USAGE
        case 12157: return certificate(0)                                                                    // SECURE_CHANNEL_ERROR
        default:
            #if os(Windows)
            return (.unknown, "the request failed: \(WindowsError.text(code))")
            #else
            return (.unknown, "the request failed: \(code)")
            #endif
        }
    }

    /// WINHTTP_CALLBACK_STATUS_FLAG_*.
    private static func certificate(_ flags: UInt32) -> (URLError.Code, String) {
        if flags & 0x10 != 0 { return (.serverCertificateUntrusted, "the server's certificate is another name's") }
        if flags & 0x20 != 0 { return (.serverCertificateHasBadDate, "the server's certificate has expired, or is not yet valid") }
        if flags & 0x08 != 0 { return (.serverCertificateHasUnknownRoot, "the server's certificate is not from an authority that Windows trusts") }
        if flags & 0x46 != 0 { return (.serverCertificateUntrusted, "the server's certificate is not valid") }
        return (.secureConnectionFailed, "no secure connection to the server")
    }
}
