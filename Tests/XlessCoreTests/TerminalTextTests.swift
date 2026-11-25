import Testing
@testable import XlessCore

/// Every scalar that moves the cursor, starts a line, reorders or hides text: C0, DEL, C1, line and paragraph separators,
/// bidi controls, zero-width and other invisible ones.
private let hidden: [Unicode.Scalar] = [
    "\u{0}", "\u{7}", "\u{8}", "\t", "\n", "\r", "\u{1B}", "\u{7F}", "\u{80}", "\u{9B}", "\u{9F}", "\u{AD}", "\u{34F}", "\u{61C}", "\u{180E}",
    "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{2028}", "\u{2029}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
    "\u{2060}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{115F}", "\u{3164}", "\u{FE0F}", "\u{FEFF}", "\u{E0001}", "\u{E0041}",
]

@Test func everyControlAndInvisibleScalarIsWrittenOut() {
    for scalar in hidden {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        #expect(TerminalText.escaped("a\(Character(scalar))b") == "a\\u{\(hex)}b", "U+\(hex)")
    }
    #expect(TerminalText.escaped("W\u{1B}[2J\u{1B}[H.appex\r\n") == "W\\u{1B}[2J\\u{1B}[H.appex\\u{D}\\u{A}")
}

@Test func ordinaryTextIsLeftAsItIs() {
    for text in ["", "PlugIns/Widget.appex", "com.example.app", "Ação é 漢字 العربية ñ", "🙂 \"quoted\" 'x' \\ $()"] {
        #expect(TerminalText.escaped(text) == text)
    }
}

@Test func linesAreKeptOnlyWhenAsked() {
    #expect(TerminalText.escaped("a\r\n\tb\u{1B}c", keepingLines: true) == "a\n\tb\\u{1B}c")
    #expect(TerminalText.escaped("a\rb", keepingLines: true) == "a\\u{D}b")
}

/// Prose (a customer's review): what drives the terminal is replaced, what a script needs to be read (a joiner) is kept.
@Test func proseLosesOnlyWhatDrivesTheTerminal() {
    #expect(TerminalText.prose("a\u{1B}]52;c;ZXZpbA==\u{07}b\u{9B}2J") == "a\u{FFFD}]52;c;ZXZpbA==\u{FFFD}b\u{FFFD}2J")
    #expect(TerminalText.prose("line\r\nnext\tx", keepingLines: true) == "line\nnext\tx")
    #expect(TerminalText.prose("line\nnext") == "line\u{FFFD}next")
    #expect(TerminalText.prose("👩\u{200D}🚀") == "👩\u{200D}🚀")
}
