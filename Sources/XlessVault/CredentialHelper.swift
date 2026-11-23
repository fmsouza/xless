import CXlessProcess
import Foundation
import XlessCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// An external credential helper, `xless-credential-<name>` on PATH (`secrets: { backend: helper, helper: <name> }`),
/// and one run of it. The protocol is the Docker credential helpers' (`get | store | erase | list`, JSON on stdin and
/// stdout); `HelperSecretStore` speaks it.
///
/// A run: argv is only the helper's path and the verb; the environment is `environment(from:)`'s allowlist (never a
/// secret variable); the input goes on stdin and the answer comes on stdout, both pipes (a secret is never in argv,
/// the environment or a file); stderr is xless's, so the helper's own messages (gpg's, the keyring's) reach the
/// user. The answer is read into one `SecretBytes` of at most `outputLimit` bytes, zeroed once parsed. A helper that
/// does not finish within `timeout` seconds, or prints more than the limit, is killed with its whole process group.
public struct CredentialHelper: Sendable {
    public static let prefix = "xless-credential-"
    /// The most a helper may print: a secret is at most 1 MiB (`secrets import`), and a listing is names and IDs.
    public static let outputLimit = 4 << 20
    /// Long enough to type a keyring or GPG passphrase into the helper's own prompt.
    public static let defaultTimeout: Double = 120

    public enum Verb: String, Sendable { case get, store, erase, list }

    public struct Answer {
        public let status: Int32
        public let output: SecretBytes
    }

    public let name: String
    /// The real path of the helper, checked by `find`.
    public let executable: String
    let environment: [String: String]
    let timeout: Double

    init(name: String, executable: String, environment: [String: String], timeout: Double = CredentialHelper.defaultTimeout) {
        self.name = name
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    public var command: String { Self.prefix + name }

    /// The helper `name` (a `SecretsBackend.isValidHelperName`): the first `xless-credential-<name>` in PATH's
    /// absolute directories that is an executable regular file. Refused when that file (followed through symlinks),
    /// the directory holding it, or the PATH directory it was found in can be written by the group or others, or
    /// belongs to someone other than root or the user: whoever can change the helper can read every secret.
    public static func find(name: String, env: [String: String] = ProcessInfo.processInfo.environment,
                            timeout: Double = CredentialHelper.defaultTimeout) throws -> CredentialHelper {
        guard SecretsBackend.isValidHelperName(name) else {
            throw VaultError(.helper, "\(name) is not a credential helper name", fix: "set `secrets.helper` in \(UserConfig.file(env: env).path) to a name such as pass or secret-tool")
        }
        let command = prefix + name
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(command)
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(path, X_OK) == 0 else { continue }
            guard let real = realpath(path, nil) else { continue }
            let resolved = String(cString: real)
            free(real)
            try checkWritable(resolved, what: "the credential helper \(command)")
            try checkWritable((resolved as NSString).deletingLastPathComponent, what: "the directory holding \(command)")
            if (dir as NSString).standardizingPath != (resolved as NSString).deletingLastPathComponent {
                try checkWritable(dir, what: "the PATH directory \(dir) where \(command) was found")
            }
            return CredentialHelper(name: name, executable: resolved, environment: environment(from: env), timeout: timeout)
        }
        throw VaultError(.helper, "the credential helper \(command) is not on PATH (secrets.backend is helper, helper \(name))",
                         fix: "install it in a directory on PATH (xless ships pass and secret-tool helpers in share/xless/credential-helpers/), or set `secrets: { backend: vault }` in \(UserConfig.file(env: env).path)")
    }

    static func checkWritable(_ path: String, what: String) throws {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw VaultError(.helper, "cannot inspect \(path) (\(what)): \(String(cString: strerror(errno)))", fix: "check the path")
        }
        if st.st_mode & 0o022 != 0 {
            throw VaultError(.helper, "\(what), \(path), can be written by other users (mode \(String(st.st_mode & 0o777, radix: 8))), so it could be made to hand them your secrets",
                             fix: "chmod go-w \(path), and consider whether it was changed")
        }
        if st.st_uid != 0, st.st_uid != geteuid() {
            throw VaultError(.helper, "\(what), \(path), belongs to another user (uid \(st.st_uid))",
                             fix: "install the helper as yourself or as root")
        }
    }

    /// What a helper may see of xless's environment: where things are (home, XDG directories, the D-Bus session, the
    /// display, GnuPG and pass settings) and the locale; nothing else, and never a secret variable.
    public static func environment(from env: [String: String]) -> [String: String] {
        let names: Set<String> = [
            "PATH", "HOME", "USER", "LOGNAME", "LANG", "LANGUAGE", "TZ", "TERM", "TMPDIR",
            "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
            "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "GNUPGHOME", "GPG_TTY",
        ]
        return env.filter { name, _ in
            !SecretEnvironment.isSecret(name) && (names.contains(name) || name.hasPrefix("LC_") || name.hasPrefix("PASSWORD_STORE_"))
        }
    }

    /// Runs `<helper> <verb>` with `input` on its stdin (then closed). Throws when it cannot start, outlives the
    /// timeout or prints too much; otherwise returns its exit status and output, whatever they are.
    public func run(_ verb: Verb, input: SecretBytes?) throws -> Answer {
        let argv = [executable, verb.rawValue]
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: Int32 = 0, inFD: Int32 = -1, outFD: Int32 = -1
        // When xless is the terminal's foreground, the helper is for as long as it runs: it can prompt on /dev/tty
        // (a password manager's own prompt) without being stopped, and Ctrl-C reaches it.
        let tty = Self.foregroundTerminal()
        defer {
            if tty >= 0 {
                xless_terminal_restore(tty)
                close(tty)
            }
        }
        var started: Int32 = 0
        // ETXTBSY: another thread's fork still held the helper open for writing (a helper written just now); it passes.
        for attempt in 0..<20 {
            started = withCStrings(argv) { a in withCStrings(envp) { e in xless_spawn_piped(executable, a, e, tty, &pid, &inFD, &outFD) } }
            guard started == ETXTBSY, attempt < 19 else { break }
            usleep(50_000)
        }
        guard started == 0 else {
            throw VaultError(.helper, "cannot start \(executable): \(String(cString: strerror(started)))", fix: "check that it is an executable script or program")
        }
        let output = SecretBytes(count: Self.outputLimit + 1)
        var outCount = 0
        var written = 0
        let inputCount = input?.count ?? 0
        var inOpen = true, outOpen = true
        let deadline = Date().addingTimeInterval(timeout)
        func stop() {
            _ = kill(-pid, SIGKILL)
            var code: Int32 = 0
            _ = xless_reap(pid, 0, &code)
            if inOpen { close(inFD) }
            if outOpen { close(outFD) }
        }
        if inputCount == 0 { close(inFD); inOpen = false }
        while outOpen {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                stop()
                throw VaultError(.helper, "\(command) \(verb.rawValue) did not finish within \(Int(timeout)) s; it was stopped",
                                 fix: "check that \(command) works on its own (`\(command) list`); a keyring may be waiting to be unlocked")
            }
            var fds = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)]
            if inOpen { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(left, 1) * 1000) + 1)
            if ready < 0, errno != EINTR { stop(); throw VaultError(.helper, "cannot talk to \(command): \(String(cString: strerror(errno)))", fix: "re-run") }
            if inOpen, fds.count > 1, fds[1].revents != 0 {
                let n = input!.withUnsafeBytes { xless_write_nosigpipe(inFD, $0.baseAddress! + written, inputCount - written) }
                if n > 0 { written += n }
                if n < 0, errno != EAGAIN, errno != EINTR { written = inputCount } // EPIPE: it stopped reading
                if written == inputCount { close(inFD); inOpen = false }
            }
            if fds[0].revents != 0 {
                let n = output.withUnsafeMutableBytes { read(outFD, $0.baseAddress! + outCount, $0.count - outCount) }
                if n > 0 {
                    outCount += n
                    if outCount > Self.outputLimit {
                        stop()
                        throw VaultError(.helper, "\(command) \(verb.rawValue) printed more than \(Self.outputLimit >> 20) MiB; it was stopped",
                                         fix: "check what \(command) prints (`\(command) list`)")
                    }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    close(outFD)
                    outOpen = false
                }
            }
        }
        if inOpen { close(inFD); inOpen = false }
        // Its stdout is closed: it is exiting, or a child of it closed it. Wait for it until the deadline, then kill.
        var code: Int32 = 0
        while true {
            let r = xless_reap(pid, 1, &code)
            if r == 1 { break }
            if r < 0 { throw VaultError(.helper, "cannot wait for \(command): \(String(cString: strerror(errno)))", fix: "re-run") }
            if deadline.timeIntervalSinceNow <= 0 {
                stop()
                throw VaultError(.helper, "\(command) \(verb.rawValue) did not finish within \(Int(timeout)) s; it was stopped",
                                 fix: "check that \(command) works on its own (`\(command) list`)")
            }
            usleep(5_000)
        }
        defer { output.wipe() }
        return Answer(status: code, output: output.prefix(outCount))
    }
}

extension CredentialHelper {
    /// The controlling terminal, open, when this process's group is its foreground; else -1.
    static func foregroundTerminal() -> Int32 {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        guard tcgetpgrp(fd) == getpgrp() else { close(fd); return -1 }
        return fd
    }
}

/// `body` with `strings` as a NULL-terminated C array.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
