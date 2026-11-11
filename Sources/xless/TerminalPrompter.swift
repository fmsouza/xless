import Foundation
import XlessAppleID
import XlessCore

/// The sign-in's prompts, on the controlling terminal (`/dev/tty`) only: an Apple ID, password or code is never read from
/// stdin, a pipe, a file, an argument or the environment. The password is read with echo off; a signal at that prompt
/// gives the terminal its echo back (see `EchoGuard`).
final class TerminalPrompter: SignInPrompter, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    init() throws {
        fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0, isatty(fd) == 1 else {
            throw XlessError(.sdk, "signing in to Apple needs an interactive terminal",
                             fix: "run xless xcode download in a terminal; it never reads the Apple ID, password or code from a pipe, a file or the environment")
        }
    }

    deinit { close(fd) }

    func ask(_ prompt: String) async throws -> String {
        try lock.withLock {
            write(prompt)
            return String(decoding: try readLine(), as: UTF8.self)
        }
    }

    func askSecret(_ prompt: String) async throws -> [UInt8] {
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
            return try readLine()
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
                throw XlessError(.sdk, "cannot read from the terminal", fix: "re-run in an interactive terminal")
            }
            if n == 0 {
                if out.isEmpty { throw XlessError(.sdk, "the terminal closed before an answer", fix: "re-run in an interactive terminal") }
                return out
            }
            if byte == 0x0A { return out }
            if byte != 0x0D { out.append(byte) }
        }
    }

    private func noEcho() -> XlessError {
        XlessError(.sdk, "cannot turn off the terminal's echo for the password", fix: "re-run in an interactive terminal")
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
        for sig in signals { signal(sig, SIG_DFL) }
        fd = -1
    }

    private static func install(_ sig: Int32) {
        signal(sig) { EchoGuard.handle($0) }
    }

    /// Async-signal-safe: tcsetattr, signal, sigprocmask and raise only.
    private static func handle(_ sig: Int32) {
        if fd >= 0 { _ = tcsetattr(fd, TCSANOW, &saved) }
        // Take the signal's default action now: the process ends here, or (SIGTSTP) stops until SIGCONT.
        signal(sig, SIG_DFL)
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
        if fd >= 0 {
            _ = tcsetattr(fd, TCSANOW, &quiet)
            install(sig)
        }
    }
}
