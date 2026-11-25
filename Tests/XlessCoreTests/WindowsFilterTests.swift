import CXlessProcess
import Foundation
import Testing
@testable import XlessCore

/// What the kernel of WSL makes of a tool: the seccomp filter that keeps it from Windows' own sockets (docs/security.md#in-wsl).
/// CI has no such kernel: the filter is put on by `ChildProcess.start`'s internal parameter, which no user of xless reaches.
@Suite struct WindowsFilterTests {
    // MARK: - The program, for both processors, on any system

    private enum Verdict: Equatable { case allowed, refused(UInt32), killed, broken }

    /// What the kernel does with it: classic BPF, as far as it is used.
    private func run(_ filter: UnsafePointer<xless_filter>, arch: UInt32, number: UInt32, argument: UInt64 = 0) -> Verdict {
        // struct seccomp_data, little-endian: nr, arch, instruction_pointer, args[6]
        var data = [UInt8](repeating: 0xAA, count: 64)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + $0.count, with: $0) } }
        put(number, at: 0)
        put(arch, at: 4)
        put(argument, at: 16)
        var accumulator: UInt32 = 0, at = 0
        for _ in 0..<64 {
            guard at < Int(filter.pointee.length), let it = filter.pointee.program?[at] else { return .broken }
            at += 1
            switch it.code {
            case 0x20:
                let k = Int(it.value)
                guard k % 4 == 0, k + 4 <= 64 else { return .broken }
                accumulator = data[k..<k + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
            case 0x15: at += Int(accumulator == it.value ? it.if_true : it.if_false)
            case 0x35: at += Int(accumulator >= it.value ? it.if_true : it.if_false)
            case 0x06:
                switch it.value {
                case 0x7FFF_0000: return .allowed
                case 0x8000_0000: return .killed
                case 0x0005_0000..<0x0006_0000: return .refused(it.value & 0xFFFF)
                default: return .broken
                }
            default: return .broken
            }
        }
        return .broken
    }

    private struct Machine: Sendable { var name: String, arch: UInt32, socket: UInt32, filter: @Sendable () -> UnsafePointer<xless_filter> }
    private let machines = [Machine(name: "x86_64", arch: 0xC000_003E, socket: 41) { xless_windows_filter_x86_64() },
                            Machine(name: "arm64", arch: 0xC000_00B7, socket: 198) { xless_windows_filter_arm64() }]

    @Test func itRefusesTheSocketsOfWindowsAndNoOther() {
        for machine in machines {
            let filter = machine.filter()
            for family in 0..<64 as Range<UInt64> {
                #expect(run(filter, arch: machine.arch, number: machine.socket, argument: family) == (family == 40 ? .refused(13) : .allowed), "\(machine.name) \(family)")
            }
            // an int to the kernel, whatever the rest of the register has
            for high in [1, 0x8000_0000, 0xFFFF_FFFF] as [UInt64] {
                #expect(run(filter, arch: machine.arch, number: machine.socket, argument: high << 32 | 40) == .refused(13))
                #expect(run(filter, arch: machine.arch, number: machine.socket, argument: high << 32 | 1) == .allowed)
            }
        }
    }

    @Test func itRefusesIOUringAndLetsEveryOtherCallBe() {
        for machine in machines {
            let filter = machine.filter()
            for number in 0..<2048 as Range<UInt32> where number != machine.socket {
                // the same argument that the family has: it is socket's alone
                #expect(run(filter, arch: machine.arch, number: number, argument: 40) == (number == 425 ? .refused(13) : .allowed), "\(machine.name) \(number)")
            }
            // a call that a tracer skips is none
            #expect(run(filter, arch: machine.arch, number: 0xFFFF_FFFF, argument: 40) == .allowed)
        }
    }

    @Test func itKillsEveryOtherArchitecture() {
        // i386, ARM, x86_64 and AArch64 (each on the other), MIPS, PowerPC, RISC-V, and 0
        let all: [UInt32] = [0x4000_0003, 0x4000_0028, 0xC000_003E, 0xC000_00B7, 0x8000_0008, 0xC000_0015, 0xC000_00F3, 0]
        for machine in machines {
            for arch in all where arch != machine.arch {
                for number in [0, 41, 102 /* i386: socketcall */, 198, 281 /* ARM: socket */, 359 /* i386: socket */, 425, 0x4000_0029, 0xFFFF_FFFF] as [UInt32] {
                    #expect(run(machine.filter(), arch: arch, number: number) == .killed, "\(machine.name) \(arch) \(number)")
                }
            }
        }
    }

    /// The same architecture to the kernel, other numbers.
    @Test func itKillsTheX32ABI() {
        let filter = xless_windows_filter_x86_64()!
        for number in [0x4000_0000, 0x4000_0029, 0x4000_01A9, 0x4000_0200, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE] as [UInt32] {
            #expect(run(filter, arch: 0xC000_003E, number: number) == .killed)
        }
        #expect(run(filter, arch: 0xC000_003E, number: 0x3FFF_FFFF) == .allowed)
    }

    @Test func eachProcessorHasItsOwn() {
        let own = xless_windows_filter()!
        #if os(Linux) && arch(x86_64)
        #expect(own == xless_windows_filter_x86_64())
        #elseif os(Linux) && arch(arm64)
        #expect(own == xless_windows_filter_arm64())
        #else
        #expect(own.pointee.program == nil && own.pointee.length == 0)
        #endif
    }

    // MARK: - Where

    @Test func theKernelOfWSLIsKnownByItsRelease() {
        for release in ["6.6.87.2-microsoft-standard-WSL2", "5.15.167.4-microsoft-standard-WSL2+", "4.4.0-19041-Microsoft", "6.6.0-MICROSOFT"] {
            #expect(xless_is_wsl_release(release) == 1)
        }
        for release in ["", "6.11.0-1018-azure", "6.10.14-linuxkit", "6.8.0-48-generic", "27.2.0", "6.6.0-micro-soft"] { #expect(xless_is_wsl_release(release) == 0) }
        #if os(Linux)
        // CI's step that takes its kernel for WSL's (.github/workflows/pr.yml) changes `xless_is_wsl_kernel`, and says so.
        let release = (try? String(contentsOfFile: "/proc/sys/kernel/osrelease", encoding: .utf8)) ?? "", taken = ProcessInfo.processInfo.environment["XLESS_TEST_TAKEN_FOR_WSL"] == "1"
        #expect((xless_is_wsl_kernel() == 1) == (taken || release.lowercased().contains("microsoft")))
        #else
        #expect(xless_is_wsl_kernel() == 0)
        #endif
    }

    @Test func aToolIsFilteredOnThatKernelOnly() {
        #expect(ChildProcess.Filter.on(wsl: true)?.pointer == xless_windows_filter())
        #expect(ChildProcess.Filter.on(wsl: false) == nil)
    }

    /// The docker client is the one tool that is let be; and Foundation's way to start a program, which knows no filter, is that of the
    /// shims alone, which run inside a build, under the filter of what started them.
    @Test func noOtherToolIsLetBe() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var found: [String] = [], others: Set<String> = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.hasPrefix("//") {
                if line.replacingOccurrences(of: " ", with: "").contains("confined:false") { found.append("\(file.lastPathComponent): \(line)") }
                if line.contains("Process()") || line.contains("Process.run(") || line.contains("posix_spawn(") { others.insert(file.lastPathComponent) }
            }
        }
        #expect(found.count == 1 && found[0].hasPrefix("Shell.swift: try run(\"docker\", "), "\(found)")
        #expect(others == ["ShimCommands.swift", "ToolchainShims.swift"], "\(others)")
    }

    // MARK: - A tool

    /// Fails closed.
    @Test func aToolWhoseFilterCannotBeSetIsNotStarted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xless-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var none = xless_filter(program: nil, length: 0)
        withUnsafePointer(to: &none) { none in
            do {
                try ChildProcess.start("/bin/sh", ["-c", "touch ran"], environment: ["PATH": "/usr/bin:/bin"], cwd: directory, filter: .init(pointer: none), stage: .build).wait()
                Issue.record("it was started")
            } catch let error as XlessError {
                #expect(error.exitCode == 12 && error.cause.contains("cannot close the sockets of Windows to sh (seccomp: ") && error.fix.contains("WSL 2"), "\(error)")
            } catch { Issue.record(error) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    #if os(Linux)
    private func output(_ words: [String], filter: ChildProcess.Filter?) throws -> String {
        let pipe = Pipe()
        let tool = try ChildProcess.start(words[0], Array(words.dropFirst()), environment: ["PATH": "/usr/bin:/bin"], stdout: pipe.fileHandleForWriting.fileDescriptor,
                                          filter: filter, stage: .build)
        try pipe.fileHandleForWriting.close()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(tool.wait() == 0)
        return out
    }

    private func status(_ name: String, in text: String) -> [String] {
        text.split(separator: "\n").filter { $0.hasPrefix("\(name):") }.map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
    }

    @Test func aToolAndWhatItStartsAreUnderItForGood() throws {
        let words = ["/bin/sh", "-c", "cat /proc/self/status; setsid sh -c 'cat /proc/self/status'"]
        let filtered = try output(words, filter: .windows)
        #expect(status("NoNewPrivs", in: filtered) == ["1", "1"] && status("Seccomp", in: filtered) == ["2", "2"])
        // Without it a tool is as this process is, which may be under a filter of its container's.
        let plain = try output(words, filter: nil), own = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        for name in ["NoNewPrivs", "Seccomp", "Seccomp_filters"] { #expect(Set(status(name, in: plain)) == Set(status(name, in: own)), "\(name)") }
        #expect(status("NoNewPrivs", in: plain).count == 2)
    }

    /// On any kernel but WSL's: as it was.
    @Test(.enabled(if: xless_is_wsl_kernel() == 0, "the kernel is WSL's: every tool is under the filter")) func aToolIsAsItWasElsewhere() throws {
        let text = try Shell.run("cat", ["/proc/self/status"], stage: .build).stdout, own = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        for name in ["NoNewPrivs", "Seccomp", "Seccomp_filters"] { #expect(status(name, in: text) == status(name, in: own), "\(name)") }
    }

    /// On WSL's: by the way that all of xless takes.
    @Test(.enabled(if: xless_is_wsl_kernel() == 1, "the kernel is not WSL's")) func aToolIsUnderItThere() throws {
        let text = try Shell.run("cat", ["/proc/self/status"], stage: .build).stdout
        #expect(status("NoNewPrivs", in: text) == ["1"] && status("Seccomp", in: text) == ["2"])
        #expect(ChildProcess.Filter.here != nil)
    }

    private static let python = ["/usr/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Tries each in a process of its own: what it is refused with, "killed" by the filter (SIGSYS), "fault" for a processor or a
    /// kernel that does not have it, or "done".
    private static let probe = """
    import ctypes, errno, mmap, os, platform, socket, subprocess, sys
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    def call(*a):
        if libc.syscall(*[ctypes.c_long(x) for x in a]) < 0: raise OSError(ctypes.get_errno(), "")
    x86 = platform.machine() == "x86_64"
    def int80():
        # mov eax, 20 (i386: getpid); int 0x80; ret
        code = mmap.mmap(-1, 4096, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
        code.write(bytes.fromhex("b814000000cd80c3"))
        ctypes.CFUNCTYPE(ctypes.c_int)(ctypes.addressof(ctypes.c_char.from_buffer(code)))()
    tries = {
        "vsock": lambda: call(41 if x86 else 198, 40, socket.SOCK_STREAM, 0),
        "vsock, high bits": lambda: call(41 if x86 else 198, 1 << 32 | 40, socket.SOCK_STREAM, 0),
        "vsock, libc": lambda: socket.socket(40, socket.SOCK_STREAM),
        "vsock, datagrams": lambda: call(41 if x86 else 198, 40, socket.SOCK_DGRAM, 0),
        "io_uring": lambda: call(425, 1, 0),
        "unix": lambda: socket.socket(socket.AF_UNIX, socket.SOCK_STREAM),
        "pair": lambda: socket.socketpair(),
        "inet": lambda: socket.socket(socket.AF_INET, socket.SOCK_STREAM),
        "netlink": lambda: socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0),
    }
    if x86:
        tries["x32"] = lambda: call(0x40000000 | 41, 40, socket.SOCK_STREAM, 0)
        tries["x32, another"] = lambda: call(0x40000000 | 39)
        tries["int 0x80"] = int80
    for name, attempt in tries.items():
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                attempt()
                os.write(w, b"done")
            except OSError as e: os.write(w, errno.errorcode.get(e.errno, str(e.errno)).encode())
            os._exit(0)
        os.close(w)
        said = os.read(r, 99).decode()
        status = os.waitpid(pid, 0)[1]
        if os.WIFSIGNALED(status): said = {31: "killed", 11: "fault"}.get(os.WTERMSIG(status), "signal %d" % os.WTERMSIG(status))
        os.close(r)
        print(name + ": " + said, flush=True)
    if sys.argv[1:] == ["again"]: subprocess.run([sys.executable, "-I", sys.argv[0]], check=True)
    """

    /// In Docker's containers the sockets of Windows are refused already, with another error (EPERM).
    @Test(.enabled(if: python != nil, "it needs python3")) func aToolCannotReachWindows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xless-filter-\(UUID().uuidString).py")
        try Self.probe.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        func tried(_ filter: ChildProcess.Filter?, _ more: [String] = []) throws -> [[String: String]] {
            var out: [[String: String]] = []
            for line in try output([Self.python!, "-I", file.path] + more, filter: filter).split(separator: "\n") {
                let parts = line.components(separatedBy: ": ")
                if parts[0] == "vsock" { out.append([:]) }
                out[out.count - 1][parts[0]] = parts[1]
            }
            return out
        }
        let filtered = try tried(.windows, ["again"]), plain = try #require(try tried(nil).first)
        #expect(filtered.count == 2) // it, and what it started
        for result in filtered {
            for name in ["vsock", "vsock, high bits", "vsock, libc", "vsock, datagrams", "io_uring"] { #expect(result[name] == "EACCES", "\(name): \(result[name] ?? "")") }
            for name in ["unix", "pair", "inet", "netlink"] { #expect(result[name] == "done", "\(name): \(result[name] ?? "")") }
            #if arch(x86_64)
            for name in ["x32", "x32, another", "int 0x80"] { #expect(result[name] == "killed", "\(name): \(result[name] ?? "")") }
            #endif
        }
        // It is the filter that does it.
        for (name, what) in plain { #expect(what != "EACCES" && what != "killed", "\(name): \(what)") }
    }

    // MARK: - Core dumps

    /// The limits of a tool that this process, or one whose limits are `before`, starts.
    private static func limits() throws -> [String] {
        let text = try Shell.run("cat", ["/proc/self/limits"], stage: .build).stdout
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Max core file size") })
        return line.dropFirst("Max core file size".count).split(separator: " ").prefix(2).map(String.init)
    }

    /// 1: no file (the kernel wants room for a page), and where core_pattern is a program, that is not started, which it is with 0.
    @Test func aToolsCoreDumpIsNoFileAndGoesToNoProgram() async {
        await #expect(processExitsWith: .success) {
            var now = rlimit()
            guard getrlimit(__rlimit_resource_t(RLIMIT_CORE.rawValue), &now) == 0 else { exit(1) }
            if now.rlim_max == 0 { exit(0) } // (what starts the tests has no dumps, and it may not be raised: the next test)
            guard try WindowsFilterTests.limits() == ["1", "1"] else { exit(2) }
            guard SecretScope.coreFileLimit == 1 else { exit(3) }
        }
    }

    /// A hard limit of 0 is raised by nobody without CAP_SYS_RESOURCE: it stays.
    @Test func aCoreLimitThatMayNotBeRaisedStaysNone() async {
        await #expect(processExitsWith: .success) {
            var none = rlimit(rlim_cur: 0, rlim_max: 0), one = rlimit(rlim_cur: 1, rlim_max: 1)
            let core = __rlimit_resource_t(RLIMIT_CORE.rawValue)
            guard setrlimit(core, &none) == 0 else { exit(1) }
            let mayRaise = setrlimit(core, &one) == 0
            guard setrlimit(core, &none) == 0 else { exit(2) }
            guard try WindowsFilterTests.limits() == (mayRaise ? ["1", "1"] : ["0", "0"]) else { exit(3) }
        }
    }
    #endif
}
