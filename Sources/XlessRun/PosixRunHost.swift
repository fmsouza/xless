#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
import CXlessProcess
import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

/// macOS and Linux.
public final class PosixRunHost: RunHost {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    /// This process's arguments and variables (`NAME=value`) that are not UTF-8, by what Swift makes of them: for a step they are
    /// the bytes that they were.
    private let given: (words: [String: [CChar]], variables: [String: [CChar]])

    public init() {
        func bytes(_ list: UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> [String: [CChar]] {
            var out: [String: [CChar]] = [:]
            var next = list
            while let here = next, let text = here.pointee {
                if String(validatingCString: text) == nil { out[String(cString: text)] = Array(UnsafeBufferPointer(start: text, count: strlen(text) + 1)) }
                next = here + 1
            }
            return out
        }
        given = (bytes(UnsafePointer(CommandLine.unsafeArgv)), bytes(xless_environment()))
        // Output nobody reads any more must not end the run before it has cleaned up.
        signal(SIGPIPE, SIG_IGN)
        // Ignored (xless may have been started so), the system would keep no step's exit code.
        signal(SIGCHLD, SIG_DFL)
    }

    public var processID: Int32 { getpid() }
    public var now: Date { Date() }

    public var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func systemName<T>(_ field: (utsname) -> T) -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "" }
        return withUnsafeBytes(of: field(name)) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    public var hostName: String { systemName { $0.nodename } }

    /// By the machine's own ID, which stays as it is when its name follows the network. A container (it has a PID namespace of its
    /// own) has none but what its image may have: it is known by the system it is on and its name.
    public var machine: String {
        #if os(macOS)
        var id = [UInt8](repeating: 0, count: 16), wait = timespec(tv_sec: 1, tv_nsec: 0)
        return gethostuuid(&id, &wait) == 0 ? Self.machine(id.map { String(format: "%02x", $0) }.joined()) : ""
        #else
        let firstNamespace = "pid:[4026531836]" // PROC_PID_INIT_INO, the same on every Linux
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/ns/pid")) == firstNamespace {
            let id = Self.word("/etc/machine-id")
            if id.wholeMatch(of: /[0-9a-f]{32}/) != nil { return Self.machine(id) }
        }
        let boot = Self.word("/proc/sys/kernel/random/boot_id")
        return boot.isEmpty ? "" : Self.machine(boot, hostName)
        #endif
    }

    /// A hash, as machine-id(5) asks for: the ID itself is nobody else's to know.
    static func machine(_ ids: String...) -> String {
        if ids == [""] { return "" }
        let code = HMAC<SHA256>.authenticationCode(for: Data("xless: the machine of a work copy's lock".utf8), using: SymmetricKey(data: Data(ids.joined(separator: "\n").utf8)))
        return String(code.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The first word of a file; empty: there is none.
    private static func word(_ file: String) -> String {
        ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    public var architecture: String { ["arm64", "aarch64"].contains(systemName { $0.machine }) ? "arm64" : "amd64" }

    public var currentDirectory: String {
        let pwd = ProcessInfo.processInfo.environment["PWD"] ?? ""
        return RunText.isAbsolute(pwd) && isSame(pwd, ".") == true ? pwd : FileManager.default.currentDirectoryPath
    }

    public func show(_ line: String) { write(Array("\(line)\n".utf8), to: 1) }
    public func say(_ line: String) { write(Array("\(line)\n".utf8), to: 2) }

    private func write(_ bytes: [UInt8], to descriptor: Int32) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { systemWrite(descriptor, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            sent += n
        }
    }

    public func program(_ name: String, path: String?) -> String? {
        func runs(_ file: String) -> Bool { isFile(file) && access(file, X_OK) == 0 }
        if name.utf8.contains(UInt8(ascii: "/")) { return runs(name) ? name : nil }
        for directory in RunText.cut(path ?? "/usr/bin:/bin", at: ":", keepingEmpty: true) {
            let file = (directory.isEmpty ? "." : directory) + "/" + name
            if runs(file) { return file }
        }
        return nil
    }

    public func start(_ step: RunStep) throws -> StartedStep {
        guard let path = program(step.words[0], path: step.environment["PATH"]) else { throw Failure(code: ENOENT) }
        var out: Int32 = -1, reading: Int32 = -1, quiet: Int32 = -1
        defer { for descriptor in [out, quiet] where descriptor >= 0 { close(descriptor) } }
        var shows = false
        switch step.output {
        case .shown: break
        case .file(let file):
            out = open(file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard out >= 0 else { throw Failure(code: errno) }
        case .captured, .both:
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw Failure(code: errno) }
            (reading, out) = (ends[0], ends[1])
            for descriptor in ends { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            shows = step.output == .both
        }
        if step.quiet { quiet = open("/dev/null", O_WRONLY | O_CLOEXEC) }
        var pid: Int32 = 0
        let code = withStrings(step.words, given.words) { words in
            withStrings(step.environment.map { "\($0.key)=\($0.value)" }, given.variables) { environment in
                xless_spawn_step(path, words, environment, step.directory, out, quiet, &pid)
            }
        }
        guard code == 0 else {
            if reading >= 0 { close(reading) }
            throw Failure(code: code)
        }
        return StartedStep(pid: pid, reading: reading >= 0 ? reading : nil, shows: shows)
    }

    public func finish(_ step: StartedStep) -> (code: Int32, output: String) {
        var output: [UInt8] = []
        if let reading = step.reading {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(reading, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                if step.shows { write(Array(buffer[..<n]), to: 1) }
                output += buffer[..<n]
            }
            close(reading)
        }
        var status: Int32 = 0
        while waitpid(step.pid, &status, 0) < 0 { if errno != EINTR { return (1, String(decoding: output, as: UTF8.self)) } }
        return (code(status), String(decoding: output, as: UTF8.self))
    }

    private func code(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    public func finish(_ step: StartedStep, within seconds: Double, unless stopped: () -> Bool) -> (code: Int32, output: String)? {
        var output: [UInt8] = [], reading = step.reading
        if let reading { _ = fcntl(reading, F_SETFL, O_NONBLOCK) }
        defer { if let reading { close(reading) } }
        var buffer = [UInt8](repeating: 0, count: 16384)
        /// Takes what is there.
        func take() {
            while let descriptor = reading {
                let n = read(descriptor, &buffer, buffer.count)
                if n > 0 {
                    output += buffer[..<n]
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(descriptor)
                    reading = nil
                } else if errno == EAGAIN { return }
            }
        }
        let start = xless_clock_awake_ms()
        while true {
            var status: Int32 = 0
            let ended = waitpid(step.pid, &status, WNOHANG)
            take()
            if ended == step.pid { return (code(status), String(decoding: output, as: UTF8.self)) }
            if ended < 0, errno != EINTR { return (1, String(decoding: output, as: UTF8.self)) }
            if stopped() || Double(xless_clock_awake_ms() - start) >= seconds * 1000 { return nil }
            pause(0.02)
        }
    }

    public func become(_ words: [String], environment: [String: String]) -> String {
        guard let path = program(words[0], path: environment["PATH"]) else { return String(cString: strerror(ENOENT)) }
        withStrings(words, given.words) { words in
            withStrings(environment.map { "\($0.key)=\($0.value)" }, given.variables) { environment in
                signal(SIGPIPE, SIG_DFL)
                _ = execve(path, words, environment)
            }
        }
        return String(cString: strerror(errno))
    }

    private func withStrings<R>(_ strings: [String], _ given: [String: [CChar]], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { text in given[text].map { strdup($0) } ?? strdup(text) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    public func onStop(_ stop: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = xless_take_stop_signals()
        guard descriptor >= 0 else { throw Failure(code: -descriptor) }
        Thread.detachNewThread {
            xless_cleans_up()
            var signal: UInt8 = 0
            while true {
                let n = read(descriptor, &signal, 1)
                if n == 1 { stop(128 + Int32(signal)) } else if !(n < 0 && errno == EINTR) { return }
            }
        }
    }

    public var stopping: Bool { xless_stop_signal() != 0 }
    public var stops: Int { Int(xless_stops()) }
    public func end(_ code: Int32) -> Never { xless_end_run(code) }
    public func removeOnFault(_ path: String, isDirectory: Bool) { _ = xless_remove_when_ended(path, isDirectory ? 1 : 0) }

    public func isRunning(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) && !ps(["-o", "stat=", "-p", "\(pid)"]).hasPrefix("Z")
    }

    public func started(_ pid: Int32) -> String { ps(["-o", "lstart=", "-p", "\(pid)"]) }
    public func commandLine(_ pid: Int32) -> String { ps(["-o", "command=", "-p", "\(pid)"]) }

    public func mark(_ pid: Int32) -> String {
        let start = xless_process_start(pid)
        guard start != 0 else { return "" }
        // On Linux it counts from the start of the system.
        let boot = Self.word("/proc/sys/kernel/random/boot_id")
        return boot.isEmpty ? "\(start)" : "\(boot) \(start)"
    }

    public func programFile(_ pid: Int32) -> String {
        var path = [UInt8](repeating: 0, count: 4096)
        let n = path.withUnsafeMutableBytes { xless_process_program(pid, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count) }
        return n > 0 ? String(decoding: path[..<n], as: UTF8.self) : ""
    }

    public func children() -> [Int32: [Int32]] {
        var out: [Int32: [Int32]] = [:]
        for line in RunText.lines(ps(["-A", "-o", "pid=,ppid="])) {
            let ids = line.split(separator: " ").compactMap { Int32($0) }
            if ids.count == 2 { out[ids[1], default: []].append(ids[0]) }
        }
        return out
    }

    /// Empty where `ps` cannot be run, as when the process is not there.
    private func ps(_ arguments: [String]) -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let step = RunStep(["ps"] + arguments, environment: ["PATH": path, "LC_ALL": "C", "TZ": "UTC0"], output: .captured, quiet: true)
        guard let started = try? start(step) else { return "" }
        return finish(started).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func terminate(_ pid: Int32) { if pid > 1 { kill(pid, SIGTERM) } }
    public func pause(_ seconds: Double) { usleep(UInt32(seconds * 1_000_000)) }

    public func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    public func physicalPath(_ path: String) -> String? {
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return xless_physical_path(path, &buffer, buffer.count) > 0 ? String(validatingCString: buffer) : nil
        #else
        return realPath(path)
        #endif
    }

    public func isSame(_ a: String, _ b: String) -> Bool? {
        var x = stat(), y = stat()
        guard stat(a, &x) == 0, stat(b, &y) == 0 else { return nil }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    public func isReadable(_ path: String) -> Bool { access(path, R_OK) == 0 }

    public func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    public func temporaryFile() throws -> String {
        let given = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
        let directory = given.isEmpty ? "/tmp" : given.utf8.last == UInt8(ascii: "/") && given != "/" ? String(given.dropLast()) : given
        var template = Array("\(directory)/xless-run.XXXXXXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw Failure(code: errno) }
        close(descriptor)
        return String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func link(_ file: String, _ path: String) -> Bool { systemLink(file, path) == 0 }
    public func rename(_ file: String, _ path: String) -> Bool { systemRename(file, path) == 0 }
    public func makeDirectory(_ path: String) -> Bool { mkdir(path, 0o777) == 0 }
    public func removeFile(_ path: String) { unlink(path) }
    public func removeEmptyDirectory(_ path: String) { rmdir(path) }
    public func removeTree(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
}

// The methods above have the names of these.
private func systemLink(_ a: String, _ b: String) -> Int32 { link(a, b) }
private func systemRename(_ a: String, _ b: String) -> Int32 { rename(a, b) }
private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int { write(descriptor, bytes, count) }
#endif
