#if os(Windows)
import CXlessWindows
import Foundation

/// This process's console: what /dev/tty is elsewhere. Standard input is never read from; a secret is read without echo, into memory
/// that is not paged out and in no error report.
public final class WindowsConsole: @unchecked Sendable {
    /// Why nothing can be asked, or no answer was read.
    public enum Problem: Error, Equatable, Sendable {
        case absent
        /// A terminal of MSYS2 or Cygwin (Git Bash), which is no console.
        case pseudoTerminal
        case echo, closed, tooLong(Int), control, text
        case failed(String)

        init(_ problem: Int32, _ code: UInt32, room: Int) {
            switch problem {
            case Int32(XLESS_CONSOLE_ABSENT.rawValue): self = .absent
            case Int32(XLESS_CONSOLE_PSEUDO.rawValue): self = .pseudoTerminal
            case Int32(XLESS_CONSOLE_ECHO.rawValue): self = .echo
            case Int32(XLESS_CONSOLE_CLOSED.rawValue): self = .closed
            case Int32(XLESS_CONSOLE_TOO_LONG.rawValue): self = .tooLong(room)
            case Int32(XLESS_CONSOLE_CONTROL.rawValue): self = .control
            case Int32(XLESS_CONSOLE_TEXT.rawValue): self = .text
            default: self = .failed(WindowsError.text(code))
            }
        }

        public var cause: String {
            switch self {
            case .absent: "there is no console"
            case .pseudoTerminal: "this terminal (Git Bash, MSYS2 or Cygwin in mintty) is not a Windows console"
            case .echo: "cannot turn off the console's echo for the secret"
            case .closed: "the console closed before an answer"
            case .tooLong(let room): "the answer is longer than \(room) bytes"
            case .control: "a control character was typed (Ctrl-V does not paste in this console)"
            case .text: "what was typed is not text"
            case .failed(let why): "cannot read from the console: \(why)"
            }
        }

        public var fix: String {
            switch self {
            case .absent, .closed, .failed, .echo: "re-run in a terminal: Windows Terminal, PowerShell or cmd"
            case .pseudoTerminal: "use Windows Terminal, PowerShell or cmd, or run `winpty xless …`"
            case .control: "re-run and paste with the right mouse button, or type it"
            case .tooLong, .text: "re-run and check what is typed at the prompt"
            }
        }
    }

    private let handle: OpaquePointer
    private let lock = NSLock()

    public init() throws {
        var problem: Int32 = 0
        var code: UInt32 = 0
        guard let handle = xless_console_open(&problem, &code) else { throw Problem(problem, code, room: 0) }
        self.handle = handle
    }

    deinit { xless_console_close(handle) }

    /// Line ends are the console's.
    public func say(_ text: String) { lock.withLock { write(text) } }

    /// One line, shown as it is typed.
    public func ask(_ prompt: String) throws -> String {
        try lock.withLock {
            let prompt = wide(prompt)
            let room = 4096
            var bytes = [CChar](repeating: 0, count: room)
            let length = try answered(room) { xless_console_line(handle, prompt, prompt.count, &bytes, room, $0, $1) }
            return String(decoding: bytes.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// One line, at most 1 KiB, of which nothing is shown.
    public func askSecret(_ prompt: String) throws -> SecretBytes {
        try lock.withLock {
            let prompt = wide(prompt)
            let room = 1024
            let line = SecretBytes(count: room)
            let length = try answered(room) { problem, code in
                line.withUnsafeMutableBytes { xless_console_secret(handle, prompt, prompt.count, $0.baseAddress!.assumingMemoryBound(to: CChar.self), room, problem, code) }
            }
            return line.prefix(length)
        }
    }

    private func answered(_ room: Int, _ body: (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt32>) -> Int64) throws -> Int {
        var problem: Int32 = 0
        var code: UInt32 = 0
        let length = body(&problem, &code)
        guard length >= 0 else { throw Problem(problem, code, room: room) }
        return Int(length)
    }

    private func wide(_ text: String) -> [UInt16] { Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf16) }

    private func write(_ text: String) {
        wide(text).withUnsafeBufferPointer { xless_console_write(handle, $0.baseAddress, $0.count) }
    }

    /// Whether a pipe of this name is the terminal of an MSYS2 or Cygwin program.
    static func isPseudoTerminal(_ pipe: String) -> Bool {
        let wide = Array(pipe.utf16)
        return wide.withUnsafeBufferPointer { xless_is_pseudo_terminal($0.baseAddress, $0.count) } != 0
    }
}
#endif
