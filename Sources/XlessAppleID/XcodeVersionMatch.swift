import Foundation
import XlessCore

/// Maps the versions a user types (`26.2`, `27`, `26 beta 3`, `26.2,27.0`) onto Apple's download names (`Xcode 26.2`).
public enum XcodeVersionMatch {
    public struct Resolved: Sendable {
        public let token: String
        public let download: AppleDownload
        public let file: AppleDownload.File
    }

    /// Arguments split on commas, trimmed, inner whitespace collapsed, duplicates (case-insensitive) dropped.
    public static func tokens(_ arguments: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for arg in arguments {
            for piece in arg.split(separator: ",") {
                let t = collapse(String(piece))
                guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
                out.append(t)
            }
        }
        return out
    }

    /// Every token resolved, or one error naming every token that matched nothing (so nothing downloads on a typo).
    /// A token matches `Xcode <token>` (case-insensitive); a numeric token also matches `Xcode <v>` when the versions
    /// are equal ignoring trailing zeros (`27` = `27.0`). The file is the `.xip` named `…Universal…`, else the first `.xip`.
    public static func resolve(_ tokens: [String], in downloads: [AppleDownload]) throws -> [Resolved] {
        var resolved: [Resolved] = [], unknown: [String] = [], noXip: [String] = []
        for token in tokens {
            guard let d = match(token, downloads) else { unknown.append(token); continue }
            let xips = d.files.filter { $0.remotePath.lowercased().hasSuffix(".xip") }
            guard let f = xips.first(where: { $0.name.lowercased().contains("universal") }) ?? xips.first else {
                noXip.append(d.name); continue
            }
            resolved.append(Resolved(token: token, download: d, file: f))
        }
        if !unknown.isEmpty {
            let near = unknown.flatMap { closeNames($0, downloads) }
            var seen = Set<String>()
            let hint = near.filter { seen.insert($0).inserted }.prefix(5)
            throw XlessError(.sdk, "Apple offers no Xcode \(unknown.joined(separator: ", "))"
                             + (hint.isEmpty ? "" : " (close: \(hint.joined(separator: ", ")))"),
                             fix: "run `xless xcode download --list` for the names Apple uses, then re-run with those")
        }
        if !noXip.isEmpty {
            throw XlessError(.sdk, "\(noXip.joined(separator: ", ")) has no .xip download (xless needs a .xip)",
                             fix: "pick a newer Xcode (`xless xcode download --list`)")
        }
        return resolved
    }

    static func match(_ token: String, _ downloads: [AppleDownload]) -> AppleDownload? {
        var t = collapse(token).lowercased()
        if t.hasPrefix("xcode ") { t.removeFirst(6) }
        if let d = downloads.first(where: { collapse($0.name).lowercased() == "xcode " + t }) { return d }
        guard let wanted = numericVersion(t) else { return nil }
        return downloads.first { d in
            let name = collapse(d.name).lowercased()
            guard name.hasPrefix("xcode ") else { return false }
            return numericVersion(String(name.dropFirst(6))) == wanted
        }
    }

    /// `27.0.0` → [27]; nil unless the text is dot-separated numbers.
    static func numericVersion(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers = [Int]()
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        return numbers
    }

    private static func closeNames(_ token: String, _ downloads: [AppleDownload]) -> [String] {
        let major = collapse(token).lowercased().replacingOccurrences(of: "xcode ", with: "").split(whereSeparator: { !$0.isNumber }).first
        guard let major else { return [] }
        return downloads.map(\.name).filter { name in
            let rest = collapse(name).lowercased().dropFirst(6)
            return rest.split(whereSeparator: { !$0.isNumber }).first == major
        }
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
