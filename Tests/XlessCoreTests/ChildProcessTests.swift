import Foundation
import Testing
@testable import XlessCore

/// The kernel keyring tests need a keyring this process may use: Docker's default seccomp profile (CI's containers)
/// blocks the keyring calls and macOS has none, so there they are skipped. Locally:
/// `docker run --security-opt seccomp=unconfined …` runs them.
private let keyringAvailable = KernelKeyring.isAvailable

/// The probe: a python3 script that searches its session keyring for a `user` key (raw keyctl, like xless) and prints
/// `found` or `missing`. /proc/keys is no probe: Docker masks it.
private let python3 = ["/usr/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }

private func probeScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xless-keyring-probe-\(UUID().uuidString).py")
    try """
    import ctypes, os, platform, sys
    number = {"x86_64": 250, "aarch64": 219}[platform.machine()]
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    for name in sys.argv[1:]:
        serial = libc.syscall(number, 10, -3, b"user", name.encode(), 0)  # KEYCTL_SEARCH in KEY_SPEC_SESSION_KEYRING
        print(("found " if serial >= 0 else "missing ") + name)
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python3!)
    p.arguments = ["-I", probe.path, name]
    let pipe = Pipe()
    p.standardOutput = pipe
    try ChildProcess.start(p, stage: .build)
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
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

@Test func startingAChildEntersTheSecretScope() throws {
    _ = try Shell.run("true", [], stage: .build)
    #expect(SecretScope.coreFileLimit == 0)
    #if os(Linux)
    #expect(SecretScope.isDumpable == false)
    #endif
}
