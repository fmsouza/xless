import Foundation

/// `HTTPTrace`'s redaction for free text: what a command printed, a `--verbose` trace, a process's environment. Used by
/// `xless secrets redact` (scripts/acceptance-m7.sh records every command's output through it). What is hidden becomes
/// `<redacted>`:
///
/// - a PEM private key block, whole (an unterminated one hides the rest of the text); certificates stay;
/// - a JWT (`eyJ….….…`) and whatever follows `Bearer `;
/// - the value of a header line (`> Cookie: …`, `Authorization: …`) whose name `HTTPTrace` hides;
/// - the value of a JSON string field (`"password": "…"`) or a `name=value` pair (a form, an environment line) whose
///   name `HTTPTrace.isSecretField` hides, or that names a secret variable (`SecretEnvironment`, not its `_FILE` form);
/// - the query of a URL on any host but the documented API's (a presigned upload's signature);
/// - every value of `hiding` (an Apple ID, say).
///
/// Redacting redacted text changes nothing more.
public enum TextRedaction {
    public static func redact(_ text: String, hiding: [String] = []) -> String {
        var out = hidePEM(text)
        for value in hiding.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: value, with: HTTPTrace.placeholder)
        }
        out = out.split(separator: "\n", omittingEmptySubsequences: false).map { redactLine(String($0)) }.joined(separator: "\n")
        return out
    }

    // MARK: Rules

    static let pemBegin = try! NSRegularExpression(pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#)
    static let pemEnd = try! NSRegularExpression(pattern: #"-----END [A-Z0-9 ]*PRIVATE KEY-----"#)
    static let jwt = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#)
    static let bearer = try! NSRegularExpression(pattern: #"(?i)(bearer\s+)(?!<redacted>)[^\s'"]+"#)
    static let header = try! NSRegularExpression(pattern: #"^(\s*[<>]\s+)?([A-Za-z0-9_-]+):\s(.*)$"#)
    static let jsonField = try! NSRegularExpression(pattern: #""([A-Za-z0-9_.-]+)"(\s*:\s*)"((?:[^"\\]|\\.)*)""#)
    static let pair = try! NSRegularExpression(pattern: #"(^|[&?\s;,'"(])([A-Za-z_][A-Za-z0-9_.-]*)=([^&\s;,'"]*)"#)
    static let url = try! NSRegularExpression(pattern: #"(https?://)([A-Za-z0-9.-]+)(:[0-9]+)?([^\s?'"]*)\?([^\s'"]*)"#)

    /// PEM private key blocks, BEGIN to END on any lines, become one placeholder.
    static func hidePEM(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var pos = 0
        while let begin = pemBegin.firstMatch(in: text, range: NSRange(location: pos, length: ns.length - pos)) {
            out += ns.substring(with: NSRange(location: pos, length: begin.range.location - pos)) + HTTPTrace.placeholder
            let from = begin.range.location + begin.range.length
            guard let end = pemEnd.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) else { return out }
            pos = end.range.location + end.range.length
        }
        return out + ns.substring(from: pos)
    }

    static func redactLine(_ line: String) -> String {
        var line = line
        let p = HTTPTrace.placeholder
        // A header line: the whole value, when HTTPTrace would hide it.
        if let m = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let name = Range(m.range(at: 2), in: line).map({ String(line[$0]) }),
           let value = Range(m.range(at: 3), in: line), line[value] != p,
           HTTPTrace.redact(headers: [name: "x"]).first == "\(name): \(p)" {
            line.replaceSubrange(value, with: p)
            return line
        }
        line = replace(jwt, in: line) { _ in p }
        line = replace(bearer, in: line) { groups in groups[1] + p }
        line = replace(jsonField, in: line) { g in isSecret(g[1]) ? "\"\(g[1])\"\(g[2])\"\(p)\"" : g[0] }
        line = replace(pair, in: line) { g in isSecret(g[2]) && g[3] != p && !g[3].isEmpty ? "\(g[1])\(g[2])=\(p)" : g[0] }
        line = replace(url, in: line) { g in
            HTTPTrace.hostsWithVisibleQueries.contains(g[2].lowercased()) || g[5] == p ? g[0] : "\(g[1])\(g[2])\(g[3])\(g[4])?\(p)"
        }
        return line
    }

    /// A field or variable whose value is a secret.
    static func isSecret(_ name: String) -> Bool {
        if name.uppercased().hasSuffix("_FILE") { return false }
        return HTTPTrace.isSecretField(name) || SecretEnvironment.isSecret(name) || SecretEnvironment.isKeyOrToken(name)
    }

    /// `text` with each match of `regex` replaced by `with(groups)` (group 0 = the whole match; a missing group is "").
    static func replace(_ regex: NSRegularExpression, in text: String, with: ([String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
            out += with(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
