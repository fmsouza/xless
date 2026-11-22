import Foundation

/// What the account commands print. `--json` is a stable contract (docs/apple-account.md): the document's keys sorted,
/// two-space indentation, slashes unescaped, one trailing newline; without it, a `TextTable`.
public enum ASCOutput {
    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}

/// Columns separated by two spaces, each as wide as its widest cell (the last one unpadded), a header line first.
public struct TextTable: Sendable {
    public var headers: [String]
    public var rows: [[String]]

    public init(_ headers: [String], _ rows: [[String]]) { self.headers = headers; self.rows = rows }

    public var rendered: String {
        let all = [headers] + rows
        let widths = headers.indices.map { column in all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0 }
        return all.map { row in
            headers.indices.map { column -> String in
                let cell = row.indices.contains(column) ? row[column] : ""
                return column == headers.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
}
