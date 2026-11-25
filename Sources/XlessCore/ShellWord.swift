import Foundation

/// One word of a command line that xless prints to be pasted into a shell.
public enum ShellWord {
    /// `word` as is when it is made of safe characters, else single-quoted.
    public static func quoted(_ word: String) -> String {
        let safe = !word.isEmpty && word.first != "=" && word.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_./@:=+,-".unicodeScalars.contains($0))
        }
        return safe ? word : inQuotes(word)
    }

    /// `word` single-quoted.
    public static func inQuotes(_ word: String) -> String { "'" + word.replacing(scalar: "'", with: "'\\''") + "'" }
}

extension String {
    /// With `text` for each `scalar`. To Swift a scalar and a mark that combines with it are one Character, which `replacingOccurrences`
    /// and `contains` do not find: whoever reads the bytes does.
    public func replacing(scalar: Unicode.Scalar, with text: String) -> String {
        var out = UnicodeScalarView()
        for next in unicodeScalars { if next == scalar { out.append(contentsOf: text.unicodeScalars) } else { out.append(next) } }
        return String(out)
    }

    public func contains(scalar: Unicode.Scalar) -> Bool { unicodeScalars.contains(scalar) }
}
