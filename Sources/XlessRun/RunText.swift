import Crypto
import Foundation
import Yams

/// The top-level values of an xless.yml or an overlay that a run needs before any xless step reads it.
struct RunTop {
    private let values: [String: String]
    /// The keys with a list or a mapping.
    private let others: Set<String>

    /// `nil` scalars, and everything that is not one, count as absent. Throws what YAML says is wrong with the file.
    init(yaml: String) throws {
        var values: [String: String] = [:], others: Set<String> = []
        if case .mapping(let mapping)? = try Yams.compose(yaml: yaml) {
            for (key, value) in mapping {
                guard let name = key.scalar?.string else { continue }
                guard case .scalar(let scalar) = value else { others.insert(name); continue }
                guard !scalar.string.isEmpty else { continue }
                if scalar.style == .plain, ["~", "null", "Null", "NULL"].contains(scalar.string) { continue }
                values[name] = scalar.string
            }
        }
        self.values = values
        self.others = others
    }

    func isNotOneValue(_ key: String) -> Bool { others.contains(key) }

    subscript(_ key: String) -> String? { values[key] }
}

enum RunText {
    /// `word` quoted for a shell when it needs it, as the dry run prints commands.
    static func quoted(_ word: String) -> String {
        if word.wholeMatch(of: /[A-Za-z0-9_.\/:=,@%+-]+/) != nil { return word }
        return "'" + replace("'", in: word, with: "'\\''") + "'"
    }

    static func commandLine(_ words: [String]) -> String { words.map { quoted($0) + " " }.joined() }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The Xcode version as image tags spell it (scripts/build-images.sh): major.minor, plus the patch when it is not 0
    /// ("26" and "26.0.0" → 26.0, "26.2.0" → 26.2, "26.0.1" stays). nil: not a version.
    static func xcodeTag(_ version: String) -> String? {
        guard version.wholeMatch(of: /[0-9]+(\.[0-9]+){0,2}/) != nil else { return nil }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        return "\(parts[0]).\(minor)" + (parts.count > 2 && parts[2] != 0 ? ".\(parts[2])" : "")
    }

    /// A `docker run --mount` bind; a path with ',' or '"' is CSV-quoted, so any path works.
    static func bind(_ source: String, _ destination: String, readOnly: Bool = false) -> String {
        let quoted = source.utf8.contains { $0 == UInt8(ascii: ",") || $0 == UInt8(ascii: "\"") }
        return "type=bind,\(quoted ? "\"src=\(replace("\"", in: source, with: "\"\""))\"" : "src=\(source)"),dst=\(destination)\(readOnly ? ",readonly" : "")"
    }

    /// A run directory as `xless secrets materialize` makes it, <…>/xless/<32 hex digits> or <…>/xless/secrets/<32 hex digits>:
    /// nothing else is ever removed as one.
    static func isSecretsDirectory(_ path: String) -> Bool {
        guard isAbsolute(path) else { return false }
        var parts = Array(cut(path, at: "/", keepingEmpty: true).dropFirst())
        guard !parts.contains(where: { ["", ".", ".."].contains($0) }), let id = parts.popLast(), isRunID(id) else { return false }
        if parts.last == "secrets" { parts.removeLast() }
        return parts.last == "xless"
    }

    /// Where a run in containers keeps a project's xless.yml, as it names it: <home>/.cache/xless/run/<32 hex digits>.
    static func isConfigurationDirectory(_ path: String, home: String) -> Bool {
        isAbsolute(path) && value(of: "\(configurations(home: home))/", in: path).map(isRunID) == true
    }

    static func configurations(home: String) -> String { "\(home)/.cache/xless/run" }

    private static func isRunID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { UInt8(ascii: "0")...UInt8(ascii: "9") ~= $0 || UInt8(ascii: "a")...UInt8(ascii: "f") ~= $0 }
    }

    // MARK: - Bytes
    //
    // Paths, and what programs say, are cut and compared by their bytes: to Swift a "/" and a mark that combines with it are one
    // Character, which is not "/", and "\r\n" is one that is not a line break.

    static func isAbsolute(_ path: String) -> Bool { path.utf8.first == UInt8(ascii: "/") }

    static func cut(_ text: String, at separator: Unicode.Scalar, max: Int = .max, keepingEmpty: Bool = false) -> [String] {
        text.utf8.split(separator: UInt8(ascii: separator), maxSplits: max, omittingEmptySubsequences: !keepingEmpty).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Those that are not empty.
    static func lines(_ text: String) -> [String] { cut(text, at: "\n") }

    static func has(_ prefix: String, before text: String) -> Bool { text.utf8.starts(with: prefix.utf8) }

    /// What follows `prefix`; nil: `text` does not start with it.
    static func value(of prefix: String, in text: String) -> String? {
        has(prefix, before: text) ? String(decoding: text.utf8.dropFirst(prefix.utf8.count), as: UTF8.self) : nil
    }

    private static func replace(_ byte: Unicode.Scalar, in text: String, with other: String) -> String {
        cut(text, at: byte, keepingEmpty: true).joined(separator: other)
    }
}
