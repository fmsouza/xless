import Foundation

/// `~/.config/xless/testflight.env`, read as data: `NAME=value` lines as a shell writes them, never run by one. Comments,
/// `export`, quotes, backslashes, a leading `~/` and `$NAME` or `${NAME}` mean what they do in a shell; anything that would
/// run or redirect something, or that a shell reads in another way, is refused: with its line and the variable's name, and
/// no part of its value, which may be a password.
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
                if let c = next, c != "\n" { throw Problem(line: line, what: "has something after \(EnvFile.valueOf(name))") }
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
            if next == "~" {
                guard at + 1 >= text.count || ["/", "\n", " ", "\t"].contains(text[at + 1]) else { throw tilde(of: name) }
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
                            out.append(contentsOf: try variable(of: name, quoted: true).unicodeScalars)
                        } else {
                            if c == "`" { throw runs(in: name) }
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
                case "$": out.append(contentsOf: try variable(of: name, quoted: false).unicodeScalars)
                case "`": throw runs(in: name)
                case ";", "&", "|", "<", ">", "(", ")":
                    throw Problem(line: line, what: "has a character that means something to a shell in \(EnvFile.valueOf(name)) (put it in ' if it is meant as it is)")
                case ":":
                    out.append(take())
                    if next == "~" { throw tilde(of: name) }
                default: out.append(take())
                }
            }
            return String(out)
        }

        func runs(in name: String) -> Problem { Problem(line: line, what: "would run a command in \(EnvFile.valueOf(name))") }
        func tilde(of name: String) -> Problem {
            Problem(line: line, what: "has a ~ that is not ~/ at the start in \(EnvFile.valueOf(name)) (put it in ' if it is meant as it is)")
        }

        /// `$NAME` or `${NAME}`; a `$` that means nothing to a shell stands for itself.
        mutating func variable(of name: String, quoted: Bool) throws -> String {
            _ = take()
            if next == "(" { throw runs(in: name) }
            let braced = next == "{"
            if braced { _ = take() }
            let used = word()
            if !braced, used.isEmpty {
                // its special parameters, its other quotes and its old arithmetic
                let means: [Unicode.Scalar] = ["@", "*", "#", "?", "-", "$", "!", "["] + (quoted ? [] : ["'", "\""])
                guard let c = next, means.contains(c) else { return "$" }
            } else if EnvFile.isName(used), !braced || next == "}", let value = environment[used] {
                if braced { _ = take() }
                return value
            }
            throw Problem(line: line, what: "has a $ of something that is not set, or not a variable, in \(EnvFile.valueOf(name)) (put it in ' if it is meant as it is)")
        }
    }

    /// `name`, when it is a variable's as they are usually written: what a line of a wrapped key looks like is never said.
    public static func shown(_ name: String) -> String? { name.wholeMatch(of: /[A-Z_][A-Z0-9_]{0,47}/) == nil ? nil : name }

    fileprivate static func valueOf(_ name: String) -> String { shown(name).map { "the value of \($0)" } ?? "its value" }

    static func isName(_ text: String) -> Bool { text.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil }
}
