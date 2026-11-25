/// Text from somewhere else (a project, a built app, Apple, a customer) made safe to print: none of it can drive the
/// terminal, start a line of its own, or reorder or hide what is around it.
public enum TerminalText {
    /// `text` with every control, format and invisible character (C0, DEL, C1, line and paragraph separators, bidi
    /// controls, zero-width and other ignorable ones) written out as `\u{1B}`. `keepingLines` leaves line breaks and
    /// tabs, for text that has lines.
    public static func escaped(_ text: String, keepingLines: Bool = false) -> String {
        replacing(text, keepingLines: keepingLines, where: isHidden) { "\\u{\(String($0.value, radix: 16, uppercase: true))}" }
    }

    /// Prose: only C0, DEL and C1 are replaced (by U+FFFD); the joiners and marks that some languages are written with stay.
    public static func prose(_ text: String, keepingLines: Bool = false) -> String {
        replacing(text, keepingLines: keepingLines, where: isControl) { _ in "\u{FFFD}" }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return isControl(scalar) }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    private static func replacing(_ text: String, keepingLines: Bool, where unsafe: (Unicode.Scalar) -> Bool,
                                  with replacement: (Unicode.Scalar) -> String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            if keepingLines, scalar == "\n" || scalar == "\t" { out.append(scalar); continue }
            if keepingLines, scalar == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { continue }
            if unsafe(scalar) { out.append(contentsOf: replacement(scalar).unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
    }
}

extension XlessError {
    /// The same error with nothing in it that drives the terminal (`TerminalText.escaped`); its line breaks stay.
    public var printable: XlessError {
        XlessError(stage, TerminalText.escaped(cause, keepingLines: true), fix: TerminalText.escaped(fix, keepingLines: true), code: code)
    }
}
