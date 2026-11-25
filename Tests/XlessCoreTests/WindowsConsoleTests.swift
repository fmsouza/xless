#if os(Windows)
import CXlessWindowsTestSupport
import Foundation
import Testing
@testable import XlessCore

// The questions that XlessWindowsProbe asks on a pseudo console, answered as at a keyboard.

/// `XlessWindowsProbe ask <kind>` on a console of its own.
private final class Terminal: @unchecked Sendable {
    private let console: OpaquePointer
    private(set) var shown = ""

    /// `standard`: what the probe takes for its standard handles instead of the console's (`input=NUL`); `bare`: started with none.
    init(_ kind: String, standard: [String] = [], bare: Bool = false) throws {
        let probe = try #require(Self.probe, "XlessWindowsProbe.exe is not beside the tests")
        var code: UInt32 = 0
        let started = (["\"\(probe)\" ask \(kind)"] + standard).joined(separator: " ").withCString(encodedAs: UTF16.self) { xless_test_console_start($0, nil, bare ? 1 : 0, &code) }
        console = try #require(started, "Windows error \(code)")
    }

    deinit { xless_test_console_end(console) }

    static let probe: String? = {
        var places = [Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
        places += places.map { $0.deletingLastPathComponent() }
        return places.map { $0.appendingPathComponent("XlessWindowsProbe.exe") }.first { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.path.replacingOccurrences(of: "/", with: "\\") }
    }()

    func type(_ text: String) { _ = Array(text.utf8).withUnsafeBytes { xless_test_console_type(console, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) } }
    func hangUp() { xless_test_console_hang_up(console) }
    func exit() -> Int64 { xless_test_console_wait(console, 60000) }

    /// Reads until the console shows `text`.
    @discardableResult
    func wait(for text: String, seconds: Double = 60) -> Bool {
        let until = Date(timeIntervalSinceNow: seconds)
        while !plain.contains(text), Date() < until {
            guard read(200) >= 0 else { break }
        }
        return plain.contains(text)
    }

    private func read(_ milliseconds: UInt32) -> Int64 {
        var piece = [CChar](repeating: 0, count: 4096)
        let got = xless_test_console_read(console, &piece, piece.count, milliseconds)
        if got > 0 { shown += String(decoding: piece.prefix(Int(got)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return got
    }

    /// What is shown to the end.
    func rest() -> String {
        let code = exit()
        while read(500) > 0 {}
        return plain + "\n[\(code)]"
    }

    /// Without the sequences that place and colour it.
    var plain: String { shown.replacing(/\u{1B}\[[0-?]*[ -\/]*[@-~]|\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)|\u{1B}[=>78]/, with: "") }
}

private func hex(_ text: String) -> String { "answer " + text.utf8.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined(separator: " ") }

@Test(arguments: [("Passw0rd ok", "Passw0rd ok"), ("wrong\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}right", "right"), ("no\u{15}yes", "yes"), ("p\u{e4}ss w\u{f6}rd \u{20ac}", "p\u{e4}ss w\u{f6}rd \u{20ac}"),
                  ("a\u{1F511}", "a\u{1F511}"), ("\u{1F511}\u{7F}b", "b"), ("", "")])
func aSecretIsReadAndNothingOfItIsShown(typed: String, read: String) throws {
    let terminal = try Terminal("secret")
    #expect(terminal.wait(for: "Passphrase:"), "\(terminal.shown.debugDescription)")
    terminal.type(typed + "\r")
    #expect(terminal.wait(for: hex(read)), "\(terminal.shown.debugDescription)")
    let all = terminal.rest()
    #expect(all.hasSuffix("[0]"), "\(all.debugDescription)")
    for word in ["Passw0rd", "wrong", "right", "yes", "w\u{f6}rd"] where typed.contains(word) { #expect(!all.contains(word), "\(all.debugDescription)") }
}

@Test func whatIsTypedBeforeTheQuestionIsNoAnswer() throws {
    let terminal = try Terminal("secret")
    terminal.type("early\r")
    #expect(terminal.wait(for: "Passphrase:"))
    Thread.sleep(forTimeInterval: 0.5)
    terminal.type("real\r")
    // The line typed ahead is thrown away when it was there already; when it came with the question it is its answer.
    #expect(terminal.wait(for: "answer"))
    #expect(!terminal.rest().contains("early"))
}

@Test func aLineIsReadAndShown() throws {
    let terminal = try Terminal("line")
    #expect(terminal.wait(for: "Name:"))
    terminal.type("me@example.com\r")
    #expect(terminal.wait(for: hex("me@example.com")), "\(terminal.shown.debugDescription)")
    #expect(terminal.rest().contains("me@example.com"))
}

@Test func ctrlCAtAQuestionEndsItWith130() throws {
    for kind in ["secret", "line"] {
        let terminal = try Terminal(kind)
        #expect(terminal.wait(for: kind == "secret" ? "Passphrase:" : "Name:"))
        terminal.type("abc")
        Thread.sleep(forTimeInterval: 0.5)
        terminal.type("\u{3}")
        let all = terminal.rest()
        #expect(all.hasSuffix("[130]") && !all.contains("answer"), "\(kind): \(all.debugDescription)")
    }
}

@Test func aConsoleThatIsClosedEndsTheQuestion() throws {
    let terminal = try Terminal("secret")
    #expect(terminal.wait(for: "Passphrase:"))
    terminal.type("abc")
    terminal.hangUp()
    #expect(terminal.exit() > 0)
}

@Test func theEndOfInputIsNoAnswer() throws {
    let secret = try Terminal("secret")
    #expect(secret.wait(for: "Passphrase:"))
    secret.type("\u{1A}")
    #expect(secret.rest().contains("the console closed before an answer"))
    let line = try Terminal("line")
    #expect(line.wait(for: "Name:"))
    line.type("\u{1A}\r")
    #expect(line.rest().contains("the console closed before an answer"))
}

@Test func controlCharactersAndLongAnswersAreRefused() throws {
    let control = try Terminal("secret")
    #expect(control.wait(for: "Passphrase:"))
    control.type("ab\u{16}\r")
    #expect(control.rest().contains("a control character was typed"))
    let long = try Terminal("secret")
    #expect(long.wait(for: "Passphrase:"))
    long.type(String(repeating: "x", count: 1025) + "\r")
    let all = long.rest()
    #expect(all.contains("longer than 1024 bytes") && !all.contains("xxx"), "\(all.debugDescription)")
    let most = try Terminal("secret")
    #expect(most.wait(for: "Passphrase:"))
    most.type(String(repeating: "x", count: 1024) + "\r")
    #expect(most.rest().hasSuffix("[0]"))
}

@Test func aTerminalThatIsNoConsoleIsRefused() throws {
    let id = UUID().uuidString.lowercased()
    let mintty = try Terminal("secret", standard: [#"output=\\.\pipe\msys-\#(id)-pty0-to-master"#])
    let refused = mintty.rest()
    #expect(refused.contains("not a Windows console") && refused.hasSuffix("[10]"), "\(refused.debugDescription)")
    let none = try Terminal("secret", standard: ["input=NUL", "output=NUL", "error=NUL"])
    #expect(none.exit() == 10)
    #expect(!none.wait(for: "Passphrase:", seconds: 1))
    // one of the three is enough
    let redirected = try Terminal("secret", standard: ["input=NUL"])
    #expect(redirected.wait(for: "Passphrase:"), "\(redirected.shown.debugDescription)")
    redirected.type("x\r")
    #expect(redirected.exit() == 0)
}

/// A program may be started without standard handles, as by one that has none itself: it is told so, and does not fall.
@Test func aProcessWithoutStandardHandlesIsRefused() throws {
    let bare = try Terminal("secret", bare: true)
    #expect(bare.exit() == 10)
    #expect(!bare.wait(for: "Passphrase:", seconds: 1))
}

@Test func thePipesOfAMinttyAreKnownByTheirNames() {
    for name in [#"\msys-dd50a72ab4668b33-pty0-from-master"#, #"\cygwin-c5e39b7a9d22bafb-pty12-to-master"#, #"\MSYS-1888ae32e00d56aa-PTY1-to-master"#] {
        #expect(WindowsConsole.isPseudoTerminal(name), "\(name)")
    }
    for name in [#"\msys-dd50a72ab4668b33-1234-pipe-0x1"#, #"\xless-pty0"#, "", #"\msys-"#, #"\Device\NamedPipe"#] { #expect(!WindowsConsole.isPseudoTerminal(name), "\(name)") }
}
#endif
