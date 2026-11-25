import Foundation

/// `~/.config/xless/testflight.env`, read as data: `NAME=value` lines as a shell writes them, never run by one. Comments,
/// `export`, quotes, backslashes, a leading `~/` and `$NAME` or `${NAME}` mean what they do in a shell; anything that would
/// run or redirect something is refused, with its line.
public enum EnvFile {
    public struct Problem: Error, Equatable {
        public let line: Int
        public let what: String
    }

    /// The assignments of `text`, in order. `environment`: what `$NAME` stands for, before the file's own lines.
    public static func parse(_ text: String, environment: [String: String]) throws -> [(name: String, value: String)] {
        var reader = Reader(text: Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars), environment: environment)
        return try reader.assignments()
    }

    private struct Reader {
        let text: [Unicode.Scalar]
        var environment: [String: String]
        var at = 0
        var line = 1

        var next: Unicode.Scalar? { at < text.count ? text[at] : nil }

        init(text: [Unicode.Scalar], environment: [String: String]) { self.text = text; self.environment = environment }

        mutating func take() -> Unicode.Scalar {
            let c = text[at]
            at += 1
            if c == "\n" { line += 1 }
            return c
        }

        mutating func skipBlanks() { while let c = next, c == " " || c == "\t" { _ = take() } }

        mutating func assignments() throws -> [(name: String, value: String)] {
            var out: [(name: String, value: String)] = []
            while next != nil {
                skipBlanks()
                guard let c = next else { break }
                if c == "\n" { _ = take(); continue }
                if c == "#" { skipComment(); continue }
                var name = word()
                if name == "export", next == " " || next == "\t" {
                    skipBlanks()
                    name = word()
                }
                guard EnvFile.isName(name), next == "=" else { throw Problem(line: line, what: "is not NAME=value") }
                _ = take()
                let value = try self.value(of: name)
                out.append((name, value))
                environment[name] = value
                skipBlanks()
                if next == "#", at > 0, text[at - 1] == " " || text[at - 1] == "\t" { skipComment(); continue }
                if let c = next, c != "\n" { throw Problem(line: line, what: "has more than the value of \(name)") }
            }
            return out
        }

        mutating func skipComment() { while let c = next, c != "\n" { _ = take() } }

        mutating func word() -> String {
            var out = String.UnicodeScalarView()
            while let c = next, c == "_" || (c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c))) { out.append(take()) }
            return String(out)
        }

        mutating func value(of name: String) throws -> String {
            var out = String.UnicodeScalarView()
            if next == "~", at + 1 >= text.count || ["/", "\n", " ", "\t"].contains(text[at + 1]) {
                _ = take()
                out.append(contentsOf: (environment["HOME"] ?? "~").unicodeScalars)
            }
            while let c = next {
                switch c {
                case "\n", " ", "\t": return String(out)
                case "'":
                    let opened = line
                    _ = take()
                    while let c = next, c != "'" { out.append(c); _ = take() }
                    guard next != nil else { throw Problem(line: opened, what: "has a quote that is not closed") }
                    _ = take()
                case "\"":
                    let opened = line
                    _ = take()
                    while let c = next, c != "\"" {
                        if c == "\\", at + 1 < text.count, ["\"", "\\", "$", "`", "\n"].contains(text[at + 1]) {
                            _ = take()
                            let escaped = take()
                            if escaped != "\n" { out.append(escaped) }
                        } else if c == "$" {
                            out.append(contentsOf: try variable(of: name).unicodeScalars)
                        } else {
                            if c == "`" { throw Problem(line: line, what: "would run a command in the value of \(name)") }
                            out.append(take())
                        }
                    }
                    guard next != nil else { throw Problem(line: opened, what: "has a quote that is not closed") }
                    _ = take()
                case "\\":
                    _ = take()
                    guard next != nil else { break }
                    let escaped = take()
                    if escaped != "\n" { out.append(escaped) }
                case "$": out.append(contentsOf: try variable(of: name).unicodeScalars)
                case "`": throw Problem(line: line, what: "would run a command in the value of \(name)")
                case ";", "&", "|", "<", ">", "(", ")": throw Problem(line: line, what: "has an unquoted \(c) in the value of \(name)")
                default: out.append(take())
                }
            }
            return String(out)
        }

        /// `$NAME` or `${NAME}`; a `$` before anything else stands for itself, as in a shell.
        mutating func variable(of name: String) throws -> String {
            _ = take()
            if next == "(" { throw Problem(line: line, what: "would run a command in the value of \(name)") }
            let braced = next == "{"
            if braced { _ = take() }
            let used = word()
            if braced {
                guard EnvFile.isName(used), next == "}" else { throw Problem(line: line, what: "uses more than a variable's name in the value of \(name)") }
                _ = take()
            } else if used.isEmpty { return "$" }
            guard EnvFile.isName(used) else { throw Problem(line: line, what: "uses $\(used) in the value of \(name)") }
            guard let value = environment[used] else { throw Problem(line: line, what: "uses \(used), which is not set") }
            return value
        }
    }

    static func isName(_ text: String) -> Bool { text.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil }
}
