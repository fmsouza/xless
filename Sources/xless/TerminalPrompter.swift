#if !os(Windows)
import CXlessProcess
#endif
import Foundation
import XlessAppleID
import XlessCore
import XlessVault

#if !os(Windows)
/// Prompts on the controlling terminal (`/dev/tty`) only: an Apple ID, password, code or the secret store's passphrase is
/// never read from stdin, a pipe, a file, an argument or the environment. Secrets are read with echo off; a signal at
/// that prompt gives the terminal its echo back (see `EchoGuard`).
final class TerminalPrompter: SignInPrompter, PassphrasePrompter, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let stage: Stage

    /// - Parameters:
    ///   - need: what is wrong without a terminal.
    ///   - what: what it is for, for the error of `--no-input`.
    init(stage: Stage = .sdk, what: String = "the Apple ID's password and code", need: String = "signing in to Apple needs an interactive terminal",
         fix: String = "run xless xcode download in a terminal; it never reads the Apple ID, password or code from a pipe, a file or the environment") throws {
        try InputGate.require(what, fix: fix)
        self.stage = stage
        fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0, isatty(fd) == 1 else {
            if fd >= 0 { close(fd) }
            throw XlessError(stage, need, fix: fix)
        }
    }

    deinit { close(fd) }

    // Synchronous: they satisfy both the sign-in's async requirements and the secret store's synchronous ones.

    /// What was typed before the question is shown is no answer to it: it is thrown away (as `askSecret` does).
    func ask(_ prompt: String) throws -> String {
        try lock.withLock {
            tcflush(fd, TCIFLUSH)
            write(prompt)
            return String(decoding: try readLine(), as: UTF8.self)
        }
    }

    func askSecret(_ prompt: String) throws -> SecretBytes {
        try lock.withLock {
            write(prompt)
            var saved = termios()
            guard tcgetattr(fd, &saved) == 0 else { throw noEcho() }
            var quiet = saved
            quiet.c_lflag &= ~tcflag_t(ECHO)
            EchoGuard.arm(fd: fd, saved: saved, quiet: quiet)
            guard tcsetattr(fd, TCSAFLUSH, &quiet) == 0 else { EchoGuard.disarm(); throw noEcho() }
            defer {
                _ = tcsetattr(fd, TCSAFLUSH, &saved)
                EchoGuard.disarm()
                write("\n")
            }
            return try readSecretLine()
        }
    }

    func say(_ line: String) { lock.withLock { write(line + "\n") } }

    private func write(_ s: String) {
        var bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Foundation.write(fd, $0.baseAddress! + off, $0.count - off) }
            if n < 0 { if errno == EINTR { continue }; return }
            off += n
        }
    }

    /// One line's bytes, without the newline. EOF before any byte is an error (the terminal went away).
    private func readLine() throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(1024) // so appending never reallocates and leaves an unzeroed copy of a password behind
        var byte: UInt8 = 0
        while true {
            let n = Foundation.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw XlessError(stage, "cannot read from the terminal", fix: "re-run in an interactive terminal")
            }
            if n == 0 {
                if out.isEmpty { throw XlessError(stage, "the terminal closed before an answer", fix: "re-run in an interactive terminal") }
                return out
            }
            if byte == 0x0A { return out }
            if byte != 0x0D { out.append(byte) }
        }
    }

    /// `readLine` for a secret: the bytes go straight into one zeroed-on-release buffer that never grows (so no stray
    /// copy is left in freed memory); a line longer than it is refused.
    private func readSecretLine() throws -> SecretBytes {
        let line = SecretBytes(count: 1024)
        var length = 0
        var byte: UInt8 = 0
        defer { byte = 0 }
        while true {
            let n = Foundation.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw XlessError(stage, "cannot read from the terminal", fix: "re-run in an interactive terminal")
            }
            if n == 0 {
                if length == 0 { throw XlessError(stage, "the terminal closed before an answer", fix: "re-run in an interactive terminal") }
                return line.prefix(length)
            }
            if byte == 0x0A { return line.prefix(length) }
            if byte == 0x0D { continue }
            guard length < line.count else {
                throw XlessError(stage, "the answer is longer than \(line.count) bytes", fix: "re-run and check what is typed at the prompt")
            }
            line.withUnsafeMutableBytes { $0[length] = byte }
            length += 1
        }
    }

    private func noEcho() -> XlessError {
        XlessError(stage, "cannot turn off the terminal's echo for the secret", fix: "re-run in an interactive terminal")
    }
}

/// While the password is read with echo off: a signal that ends the process (SIGINT, SIGTERM, SIGHUP, SIGQUIT) gives the
/// terminal its echo back first, and Ctrl-Z (SIGTSTP) gives it back while stopped and turns it off again on resume.
private enum EchoGuard {
    nonisolated(unsafe) static var fd: Int32 = -1
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var quiet = termios()
    static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP]

    static func arm(fd: Int32, saved: termios, quiet: termios) {
        Self.fd = fd
        Self.saved = saved
        Self.quiet = quiet
        for sig in signals { install(sig) }
    }

    static func disarm() {
        for sig in signals { xless_signal_default(sig) }
        fd = -1
    }

    private static func install(_ sig: Int32) {
        signal(sig) { EchoGuard.handle($0) }
    }

    /// Async-signal-safe: tcsetattr, sigaction, sigprocmask and raise only.
    private static func handle(_ sig: Int32) {
        if fd >= 0 { _ = tcsetattr(fd, TCSANOW, &saved) }
        // Take the signal's default action now: the process ends here, or (SIGTSTP) stops until SIGCONT.
        xless_signal_default(sig)
        var set = sigset_t()
        #if os(Linux)
        sigemptyset(&set)
        sigaddset(&set, sig)
        #else
        set = sigset_t(1) << sigset_t(sig - 1)
        #endif
        _ = pthread_sigmask(SIG_UNBLOCK, &set, nil)
        _ = raise(sig)
        // Resumed after a stop, still at the password prompt.
        if fd >= 0, sig == SIGTSTP {
            _ = tcsetattr(fd, TCSANOW, &quiet)
            install(sig)
        }
    }
}
#else
/// Prompts on the console only, as elsewhere on /dev/tty: nothing is ever read from stdin, a pipe, a file, an argument or the
/// environment. Where there is no console of this process's, or only the pipes of a Git Bash window, there is nobody to ask.
final class TerminalPrompter: SignInPrompter, PassphrasePrompter, @unchecked Sendable {
    private let console: WindowsConsole
    private let stage: Stage

    init(stage: Stage = .sdk, what: String = "the Apple ID's password and code", need: String = "signing in to Apple needs an interactive terminal",
         fix: String = "run this in a terminal; the Apple ID, password and code are never read from a pipe, a file or the environment") throws {
        try InputGate.require(what, fix: fix)
        self.stage = stage
        do { console = try WindowsConsole() } catch WindowsConsole.Problem.pseudoTerminal {
            throw XlessError(stage, "\(need): \(WindowsConsole.Problem.pseudoTerminal.cause)", fix: WindowsConsole.Problem.pseudoTerminal.fix)
        } catch {
            throw XlessError(stage, need, fix: fix)
        }
    }

    func ask(_ prompt: String) throws -> String { try answer { try console.ask(prompt) } }
    func askSecret(_ prompt: String) throws -> SecretBytes { try answer { try console.askSecret(prompt) } }
    func say(_ line: String) { console.say(line + "\n") }

    private func answer<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let problem as WindowsConsole.Problem { throw XlessError(stage, problem.cause, fix: problem.fix) }
    }
}
#endif

extension TerminalPrompter {
    /// The terminal for the secret store's passphrase.
    static func forSecretStore() throws -> TerminalPrompter {
        try TerminalPrompter(stage: .config, what: "the secret store's passphrase", need: "the secret store's passphrase is read from a terminal, and there is none",
                             fix: "run this in an interactive terminal; the passphrase is never read from a pipe, a file, an argument or the environment")
    }

    /// A yes/no question; anything but y/yes is no.
    func confirm(_ question: String) throws -> Bool {
        let answer = try ask("\(question) [y/N] ").trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}
