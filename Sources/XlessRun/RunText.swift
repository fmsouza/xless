import Crypto
import Foundation
import Yams

/// The top-level values of an xless.yml or an overlay that a run needs before any xless step reads it.
struct RunTop {
    private let values: [String: String]

    /// `nil` scalars, and everything that is not one, count as absent. Throws what YAML says is wrong with the file.
    init(yaml: String) throws {
        var values: [String: String] = [:]
        if case .mapping(let mapping)? = try Yams.compose(yaml: yaml) {
            for (key, value) in mapping {
                guard let name = key.scalar?.string, case .scalar(let scalar) = value, !scalar.string.isEmpty else { continue }
                if scalar.style == .plain, ["~", "null", "Null", "NULL"].contains(scalar.string) { continue }
                values[name] = scalar.string
            }
        }
        self.values = values
    }

    subscript(_ key: String) -> String? { values[key] }
}

enum RunText {
    /// `word` quoted for a shell when it needs it, as the dry run prints commands.
    static func quoted(_ word: String) -> String {
        if word.wholeMatch(of: /[A-Za-z0-9_.\/:=,@%+-]+/) != nil { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        let src = source.contains(",") || source.contains("\"") ? "\"src=\(source.replacingOccurrences(of: "\"", with: "\"\""))\"" : "src=\(source)"
        return "type=bind,\(src),dst=\(destination)\(readOnly ? ",readonly" : "")"
    }

    /// A run directory as `xless secrets materialize` makes it: nothing else is ever removed as one.
    static func isSecretsDirectory(_ path: String) -> Bool {
        path.wholeMatch(of: /\/([^\/]+\/)*xless(\/secrets)?\/[0-9a-f]{32}/) != nil && !path.contains("/../") && !path.contains("/./")
    }
}
