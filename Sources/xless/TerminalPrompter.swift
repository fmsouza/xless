import Foundation
import XlessAppleID
import XlessCore

/// The sign-in's prompts, on the controlling terminal (`/dev/tty`) only: an Apple ID, password or code is never read from
/// stdin, a pipe, a file, an argument or the environment. The password is read with echo off; Ctrl-C while echo is off
/// restores the terminal before exiting.
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
            EchoGuard.arm(fd: fd, saved: saved)
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

/// Restores the terminal's echo when the user presses Ctrl-C at the password prompt.
private enum EchoGuard {
    nonisolated(unsafe) static var fd: Int32 = -1
    nonisolated(unsafe) static var saved = termios()

    static func arm(fd: Int32, saved: termios) {
        Self.fd = fd
        Self.saved = saved
        signal(SIGINT) { _ in
            if EchoGuard.fd >= 0 { _ = tcsetattr(EchoGuard.fd, TCSAFLUSH, &EchoGuard.saved) }
            _exit(130)
        }
    }

    static func disarm() {
        signal(SIGINT, SIG_DFL)
        fd = -1
    }
}

/// Keeps the sign-in's secrets out of core dumps (`ulimit -c 0` for this process).
enum CoreDumps {
    static func disable() {
        var none = rlimit(rlim_cur: 0, rlim_max: 0)
        #if canImport(Glibc)
        _ = setrlimit(__rlimit_resource_t(RLIMIT_CORE.rawValue), &none)
        #else
        _ = setrlimit(RLIMIT_CORE, &none)
        #endif
    }
}
