import CXlessProcess
import Foundation
import Testing
@testable import XlessCore

/// The kernel keyring tests need a keyring this process may use: Docker's default seccomp profile (CI's containers)
/// blocks the keyring calls and macOS has none, so there they are skipped. Locally:
/// `docker run --security-opt seccomp=unconfined …` runs them.
private let keyringAvailable = KernelKeyring.isAvailable

/// The probe: a python3 script that looks for a `user` key (raw keyctl, like xless) everywhere a process of the user can
/// reach on its own: its session keyring, the user's default session keyring and the user keyring (both reachable by
/// their special IDs from any session, as possessed), each time linking what it finds into its own session keyring as
/// a thief would. Prints `found <name>` or `missing <name>`. /proc/keys is no probe: Docker masks it.
private let python3 = ["/usr/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }

private func probeScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xless-keyring-probe-\(UUID().uuidString).py")
    try """
    import ctypes, os, platform, sys
    number = {"x86_64": 250, "aarch64": 219}[platform.machine()]
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    for name in sys.argv[1:]:
        # KEYCTL_SEARCH in @s, @us and @u, linking a find into @s
        found = any(libc.syscall(number, 10, spec, b"user", name.encode(), -3) >= 0 for spec in (-3, -5, -4))
        print(("found " if found else "missing ") + name)
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private let canProbe = keyringAvailable && python3 != nil

@Test(.enabled(if: canProbe))
func aChildCannotFindTheRememberedUnlockOrTheKeptSession() throws {
    // Named like the store's remembered unlock and the kept Apple ID session.
    let unlock = "xless-vault:test-\(UUID().uuidString)"
    let session = "xless-apple-session-test-\(UUID().uuidString)"
    let a = try KernelKeyring.store(name: unlock, secret: SecretBytes(utf8: "data-key"), timeout: 120)
    defer { try? KernelKeyring.revoke(a) }
    let b = try KernelKeyring.store(name: session, secret: SecretBytes(utf8: "cookies"), timeout: 120)
    defer { try? KernelKeyring.revoke(b) }
    let probe = try probeScript()
    defer { try? FileManager.default.removeItem(at: probe) }

    // The probe works: a process started the plain way (from this thread, in the user's keyring) finds both.
    let plain = Process()
    plain.executableURL = URL(fileURLWithPath: python3!)
    plain.arguments = ["-I", probe.path, unlock, session]
    let pipe = Pipe()
    plain.standardOutput = pipe
    try plain.run()
    let seen = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    plain.waitUntilExit()
    #expect(seen == "found \(unlock)\nfound \(session)\n")

    // A tool xless runs, and what that tool runs in turn, find neither.
    let out = try Shell.run("sh", ["-c", "\"$0\" -I \"$1\" \"$2\" \"$3\"", python3!, probe.path, unlock, session], stage: .build).stdout
    #expect(out == "missing \(unlock)\nmissing \(session)\n")

    // xless itself keeps them: the later stages still find a remembered unlock.
    #expect(try KernelKeyring.find(name: unlock) == a)
    #expect(try KernelKeyring.find(name: session) == b)
}

@Test(.enabled(if: canProbe))
func aChildStartedDirectlyByChildProcessStartsInAnEmptySessionKeyring() throws {
    let name = "xless-vault:test-\(UUID().uuidString)"
    let key = try KernelKeyring.store(name: name, secret: SecretBytes(utf8: "data-key"), timeout: 120)
    defer { try? KernelKeyring.revoke(key) }
    let probe = try probeScript()
    defer { try? FileManager.default.removeItem(at: probe) }
    let pipe = Pipe()
    let p = try ChildProcess.start(python3!, ["-I", probe.path, name], environment: ProcessInfo.processInfo.environment,
                                   stdout: pipe.fileHandleForWriting.fileDescriptor, stage: .build)
    try pipe.fileHandleForWriting.close()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(p.wait() == 0)
    #expect(out == "missing \(name)\n")
    #expect(try KernelKeyring.find(name: name) == key)
}

@Test func childrenNeverOpenTheSecretStore() throws {
    let out = try Shell.run("env", [], env: ["XLESS_NO_SECRET_STORE": "0"], baseEnvironment: ["PATH": "/usr/bin:/bin"], stage: .build).stdout
    #expect(out.split(separator: "\n").contains("XLESS_NO_SECRET_STORE=1"))
    #expect(!out.contains("XLESS_NO_SECRET_STORE=0"))
}

@Test func theChildEnvironmentIsScrubbedAndMarked() {
    let env = ChildProcess.environment(["PATH": "/bin", "ASC_KEY_P8": "pem", "XLESS_DIST_KEY_FILE": "/k", "KEEP": "1"],
                                       extra: ["KEEP": nil, "ADDED": "x"])
    #expect(env == ["PATH": "/bin", "ADDED": "x", "XLESS_NO_SECRET_STORE": "1"])
}

/// Where the agent of an `xless session` is: no tool is told, whoever adds it.
@Test func noToolIsToldOfWhatIsHeld() throws {
    #expect(ChildProcess.environment(["PATH": "/bin", "XLESS_SESSION": "/x.sock"], extra: ["XLESS_SESSION": "/y.sock"])
        == ["PATH": "/bin", "XLESS_NO_SECRET_STORE": "1"])
    let out = try Shell.run("env", [], env: ["XLESS_SESSION": "/y.sock"], baseEnvironment: ["PATH": "/usr/bin:/bin", "XLESS_SESSION": "/x.sock"], stage: .build).stdout
    #expect(!out.contains("XLESS_SESSION"))
}

@Test func startingAChildEntersTheSecretScope() throws {
    _ = try Shell.run("true", [], stage: .build)
    #expect(SecretScope.coreFileLimit == 0)
    #if os(Linux)
    #expect(SecretScope.isDumpable == false)
    #endif
}

/// A tool is in a POSIX session of its own, and so is everything it starts: a process can only leave a session for a
/// new one, so nothing a build runs is ever again in the terminal's session, which is what the xless agent serves.
@Test func aToolRunsInASessionOfItsOwnWithItsDescendants() throws {
    let pipe = Pipe()
    let tool = try ChildProcess.start("/bin/sh", ["-c", "sleep 60 & echo $!; wait"], environment: ["PATH": "/usr/bin:/bin"],
                                      stdout: pipe.fileHandleForWriting.fileDescriptor, stage: .build)
    try pipe.fileHandleForWriting.close()
    defer { kill(-tool.processIdentifier, SIGKILL); _ = tool.wait() }
    let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
    let grandchild = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(getsid(tool.processIdentifier) == tool.processIdentifier)
    #expect(getsid(grandchild) == tool.processIdentifier)
    #expect(getsid(tool.processIdentifier) != getsid(0))
}

@Test func aToolGetsItsDirectoryEnvironmentOutputAndStatus() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-tool-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = Pipe(), err = Pipe()
    let tool = try ChildProcess.start("/bin/sh", ["-c", "pwd -P; echo \"$KEEP\"; echo oops >&2; exit 7"], environment: ["PATH": "/usr/bin:/bin", "KEEP": "a b"],
                                      cwd: dir, stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor, stage: .build)
    try out.fileHandleForWriting.close()
    try err.fileHandleForWriting.close()
    let real = try #require(realpath(dir.path, nil))
    defer { free(real) }
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "\(String(cString: real))\na b\n")
    #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "oops\n")
    #expect(tool.wait() == 7)
    #expect(tool.wait() == 7) // asked again, the same answer
}

@Test func aToolKilledByASignalReportsTheSignalAndAMissingOneIsAnError() throws {
    let tool = try ChildProcess.start("/bin/sh", ["-c", "kill -KILL $$"], environment: ["PATH": "/usr/bin:/bin"], stage: .build)
    #expect(tool.wait() == SIGKILL)
    #expect(throws: (any Error).self) { try ChildProcess.start("/nonexistent/tool", [], environment: [:], stage: .build) }
    #expect(throws: (any Error).self) {
        try ChildProcess.start("/bin/sh", ["-c", "true"], environment: [:], cwd: URL(fileURLWithPath: "/nonexistent"), stage: .build)
    }
}

/// A tool inherits stdin, stdout and stderr, and no other descriptor of xless's.
@Test func aToolInheritsNoOtherDescriptor() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("xless-fd-\(UUID().uuidString)")
    _ = FileManager.default.createFile(atPath: file.path, contents: Data("secret".utf8))
    defer { try? FileManager.default.removeItem(at: file) }
    let fd = open(file.path, O_RDONLY) // without close-on-exec
    defer { close(fd) }
    let out = Pipe()
    let tool = try ChildProcess.start("/bin/sh", ["-c", "cat /dev/fd/\(fd) 2>/dev/null || echo closed"], environment: ["PATH": "/usr/bin:/bin"],
                                      stdout: out.fileHandleForWriting.fileDescriptor, stage: .build)
    try out.fileHandleForWriting.close()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "closed\n")
    _ = tool.wait()
}

/// Signals are passed on to a tool while it runs (Tests/shell/tool-signals.test.sh), and never to whoever has its number
/// later.
@Test func aToolIsToldSignalsAsLongAsItRuns() throws {
    let tools = try (0..<300).map { i in
        try ChildProcess.start("/bin/sh", ["-c", "exit \(i % 3)"], environment: ["PATH": "/usr/bin:/bin"], stage: .build)
    }
    let running = tools.filter { xless_tool_runs($0.processIdentifier) == 1 }.count
    #expect(running > 100) // not waited for yet: they all have their numbers still
    for (i, tool) in tools.enumerated() {
        #expect(tool.wait() == Int32(i % 3))
        #expect(xless_tool_runs(tool.processIdentifier) == 0)
    }
    #expect(xless_tool_runs(0) == 0)
    // The list is free again, for as many.
    let after = try (0..<100).map { _ in try ChildProcess.start("/bin/sh", ["-c", "exit 4"], environment: ["PATH": "/usr/bin:/bin"], stage: .build) }
    #expect(after.contains { xless_tool_runs($0.processIdentifier) == 1 })
    for tool in after {
        #expect(tool.wait() == 4 && tool.wait() == 4)
        #expect(xless_tool_runs(tool.processIdentifier) == 0)
    }
}
