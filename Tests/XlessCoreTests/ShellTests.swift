import Testing
import Foundation
@testable import XlessCore

@Test func capturesStdout() throws {
    let r = try Shell.run("echo", ["hi there"], stage: .build)
    #expect(r.stdout == "hi there\n")
}

@Test func failureBecomesStageError() {
    do { try Shell.run("sh", ["-c", "echo boom >&2; exit 3"], stage: .sign); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.cause.contains("exited with 3"))
        #expect(e.cause.contains("boom"))
    } catch { Issue.record("\(error)") }
}

@Test func childProcessesCannotSeeSecrets() throws {
    // Build tools run third-party package code (macros, plugins); they must never inherit signing or API keys.
    let names = ["XLESS_DIST_KEY", "XLESS_DIST_KEY_FILE", "ASC_KEY_P8", "XLESS_DEVID_KEY", "XLESS_INSTALLER_KEY", "XLESS_INSTALLER_KEY_FILE", "ASC_KEY_ID"]
    // Injected, never setenv: glibc's environ is not thread-safe and other tests read the process env in parallel.
    var base = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
    for name in names { base[name] = "secret-\(name)" }
    let r = try Shell.run("sh", ["-c", "echo \"[${XLESS_DIST_KEY-}][${XLESS_DIST_KEY_FILE-}][${ASC_KEY_P8-}][${XLESS_DEVID_KEY-}][${XLESS_INSTALLER_KEY-}][${XLESS_INSTALLER_KEY_FILE-}][${ASC_KEY_ID-}]\""], baseEnvironment: base, stage: .build)
    #expect(r.stdout == "[][][][][][][]\n")
    let all = try Shell.run("env", [], baseEnvironment: base, stage: .build).stdout
    #expect(!all.contains("secret-"))
}

@Test func scrubbedNamesCoverEverySecretAndItsFileVariant() {
    for name in ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "XLESS_DIST_KEY", "XLESS_DEVID_KEY", "XLESS_INSTALLER_KEY"] {
        #expect(Shell.scrubbedEnvironment.contains(name))
        #expect(Shell.scrubbedEnvironment.contains("\(name)_FILE"))
    }
}

@Test func explicitEnvEntriesStillReachTheChild() throws {
    let r = try Shell.run("sh", ["-c", "echo \"$XLESS_DIST_KEY_FILE\""], env: ["XLESS_DIST_KEY_FILE": "/run/k.pem"], stage: .build)
    #expect(r.stdout == "/run/k.pem\n")
}

@Test func errorTailSkipsFilteredNoise() {
    // 30 noise lines after the real error would push it out of a 20-line tail.
    let script = "echo 'error: undefined symbol: _x' >&2; for i in $(seq 30); do echo 'warning: noise' >&2; done; exit 1"
    do { try Shell.run("sh", ["-c", script], stage: .build, keepErrorLine: { !$0.contains("noise") }); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause.contains("undefined symbol: _x"))
        #expect(!e.cause.split(separator: "\n").dropFirst().contains { $0.contains("noise") })   // line 1 is the command
    } catch { Issue.record("\(error)") }
}

/// captureTo keeps everything, in order, including output a background child writes after the process itself exited
/// (the pipe stays open until the last writer closes it); the notary parser depends on the full log.
@Test func captureToKeepsOutputWrittenAfterExit() throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("shell-capture-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let script = "i=0; while [ $i -lt 300 ]; do echo l$i; i=$((i+1)); done; (sleep 0.3; i=0; while [ $i -lt 50 ]; do echo late$i; i=$((i+1)); done; echo tail-err >&2) &"
    try Shell.run("sh", ["-c", script], stage: .package, captureTo: log)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.filter { $0.hasPrefix("l") && !$0.hasPrefix("late") } == (0..<300).map { "l\($0)" })
    #expect(lines.filter { $0.hasPrefix("late") } == (0..<50).map { "late\($0)" })
    #expect(lines.contains("tail-err"))
    #expect(lines.count == 351)
}
