import Foundation
import Testing
@testable import XlessRun

@Suite struct PosixRunHostTests {
    let host = PosixRunHost()
    let environment = ["PATH": "/usr/bin:/bin", "ONLY": "this"]

    private func run(_ words: [String], directory: String? = nil, output: RunStep.Output = .captured, quiet: Bool = false) throws -> (code: Int32, output: String) {
        host.finish(try host.start(RunStep(words, environment: environment, directory: directory, output: output, quiet: quiet)))
    }

    @Test func aStepsWordsReachItAsTheyAre() throws {
        let r = try run(["printf", "%s\n", "a b", "$HOME", "'; touch x", ""])
        #expect(r.code == 0 && r.output == "a b\n$HOME\n'; touch x\n\n")
    }

    @Test func aStepHasTheGivenEnvironmentAndNothingElse() throws {
        let names = try run(["env"]).output.split(separator: "\n").map { String($0.prefix { $0 != "=" }) }
        #expect(Set(names) == ["PATH", "ONLY"])
    }

    /// What is not UTF-8 in this process's environment is the same bytes in a step's.
    @Test func variablesThatAreNotUTF8ReachAStepAsTheyAre() async {
        await #expect(processExitsWith: .success) {
            let bytes: [UInt8] = Array("caf".utf8) + [0xE9, 0xFF] + Array("x".utf8) + [0]
            for name in ["KEPT", "CHANGED", "REMOVED"] { bytes.withUnsafeBufferPointer { b in b.withMemoryRebound(to: CChar.self) { _ = setenv(name, $0.baseAddress!, 1) } } }
            var environment = ProcessInfo.processInfo.environment
            environment["CHANGED"] = "other"
            environment["REMOVED"] = nil
            let host = PosixRunHost()
            let step = try host.start(RunStep(["sh", "-c", "printf '%s|%s|%s' \"$KEPT\" \"$CHANGED\" \"${REMOVED-none}\" | od -An -tx1 | tr -d ' \\n'"], environment: environment, output: .captured))
            guard host.finish(step).output == "636166e9ff78" + "7c6f74686572" + "7c6e6f6e65" else { exit(1) }
        }
    }

    /// Two names that differ only there are two.
    @Test func variablesWhoseNamesAreNotUTF8AreKeptApart() async {
        await #expect(processExitsWith: .success) {
            func set(_ name: [UInt8], _ value: String) { (Array("N".utf8) + name + [0]).withUnsafeBufferPointer { b in b.withMemoryRebound(to: CChar.self) { _ = setenv($0.baseAddress!, value, 1) } } }
            for (name, value): ([UInt8], String) in [([0xFF], "1"), ([0xFE], "1"), ([0xFD], "2"), (Array("\u{FFFD}".utf8), "3")] { set(name, value) }
            let host = PosixRunHost()
            func kept(_ environment: [String: String]) throws -> [[UInt8]] { // without a shell: it would drop them
                let file = try host.temporaryFile()
                defer { host.removeFile(file) }
                _ = host.finish(try host.start(RunStep(["env"], environment: environment, output: .file(file))))
                return try Data(contentsOf: URL(fileURLWithPath: file)).split(separator: 10).map(Array.init).filter { $0.count > 1 && $0[0] == 0x4E && $0[1] >= 0x80 }
            }
            let mine = ProcessInfo.processInfo.environment
            guard try Set(kept(mine)) == [[0x4E, 0xFF, 0x3D, 0x31], [0x4E, 0xFE, 0x3D, 0x31], [0x4E, 0xFD, 0x3D, 0x32], [0x4E, 0xEF, 0xBF, 0xBD, 0x3D, 0x33]] else { exit(1) }
            guard try kept(["PATH": mine["PATH"] ?? "/usr/bin:/bin"]).isEmpty else { exit(2) }
        }
    }

    /// Arguments that differ only in bytes that are not UTF-8 are two.
    @Test func argumentsThatAreNotUTF8AreKeptApart() {
        func texts(_ words: [[UInt8]]) -> [String] { PosixRunHost.texts(words) }
        let a = Array("--a=".utf8)
        #expect(texts([Array("xless".utf8), a + [0xFF]]) == ["xless", "--a=\u{FFFD}"])
        #expect(texts([a + [0xFF], a + [0xFF]]) == ["--a=\u{FFFD}", "--a=\u{FFFD}"]) // the same
        let cases: [[[UInt8]]] = [[a + [0xFF], a + [0xFE]], [a + [0xFF], a + [0xFE], a + [0xFD], a + [0xFE]], [a + [0xFF], Array("--a=\u{FFFD}".utf8)],
                                  [a + [0xFF], a + [0xFE], Array("--a=\u{FFFD}\u{FFFD}".utf8)], [Array("e\u{301}".utf8) + [0xFF], Array("\u{e9}".utf8) + [0xFF]]]
        for words in cases {
            let texts = texts(words).map { Array($0.utf8) }
            for i in words.indices {
                for j in words.indices { #expect((words[i] == words[j]) == (texts[i] == texts[j]), "\(words)") }
                if PosixRunHost.utf8(words[i]) != nil { #expect(texts[i] == words[i], "\(words)") }
            }
        }
        #expect(PosixRunHost.arguments == CommandLine.arguments)
    }

    @Test func aStepHasNothingToReadAndNoDescriptorOfTheRuns() throws {
        let file = try host.temporaryFile()
        defer { host.removeFile(file) }
        let opened = open(file, O_RDONLY)
        let descriptor = fcntl(opened, F_DUPFD, 200)  // not close-on-exec; and not one that the shell itself uses
        close(opened)
        try #require(descriptor >= 200)
        defer { close(descriptor) }
        let r = try run(["sh", "-c", "cat; (: <&\(descriptor)) 2>/dev/null && echo open; true"])
        #expect(r.output.isEmpty && r.code == 0)
    }

    @Test func aStepIgnoresTheInterruptTheRunStopsItFor() throws {
        #expect(try run(["sh", "-c", "kill -INT $$; kill -QUIT $$; echo on"]).output == "on\n")
        #expect(try run(["sh", "-c", "kill -TERM $$; echo on"]) == (143, ""))
    }

    @Test func exitCodesAreTheSteps() throws {
        #expect(try run(["sh", "-c", "exit 24"]).code == 24)
        #expect(throws: (any Error).self) { try run(["no-such-program-here"]) }
        #expect(throws: (any Error).self) { try run(["true"], directory: "/no/such/directory") }
    }

    @Test func aStepsDirectoryAndOutput() throws {
        #expect(try run(["pwd"], directory: "/").output == "/\n")
        let file = try host.temporaryFile()
        defer { host.removeFile(file) }
        #expect(try run(["sh", "-c", "echo kept; echo no >&2"], output: .file(file), quiet: true) == (0, ""))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "kept\n")
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
    }

    /// A fault of the run's own is cleaned up after too; the secrets go even when that cannot be done.
    @Test(arguments: [true, false]) func aFaultOfItsOwnLeavesNothing(cleansUp: Bool) async throws {
        let file = try host.temporaryFile(), secret = try host.temporaryFile()
        defer { host.removeFile(file); host.removeFile(secret) }
        await #expect(processExitsWith: .failure) { [cleansUp = cleansUp as Bool, file = file as String, secret = secret as String] in
            let host = PosixRunHost()
            host.removeOnFault(secret, isDirectory: false)
            if cleansUp {
                try host.onStop { code in
                    host.removeFile(file)
                    host.end(code)
                }
                host.pause(0.2)
            }
            UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1
            exit(0)
        }
        #expect(!FileManager.default.fileExists(atPath: secret))
        #expect(FileManager.default.fileExists(atPath: file) != cleansUp)
    }

    /// Nor does a stack that overflows, in any thread that said what to remove.
    @Test func aStackThatOverflowsLeavesNothing() async throws {
        let first = try host.temporaryFile(), second = try host.temporaryFile()
        defer { host.removeFile(first); host.removeFile(second) }
        await #expect(processExitsWith: .failure) { [first = first as String, second = second as String] in
            let host = PosixRunHost()
            host.removeOnFault(first, isDirectory: false)
            Thread.detachNewThread {
                host.removeOnFault(second, isDirectory: false)
                func deep(_ n: Int) -> Int { n < 0 ? n : deep(n + 1) &+ deep(n + 2) }
                exit(deep(0) == 1 ? 0 : 0)
            }
            host.pause(60)
            exit(0)
        }
        #expect(!FileManager.default.fileExists(atPath: first) && !FileManager.default.fileExists(atPath: second))
    }

    /// Started with SIGCHLD ignored (some supervisors do), where the system keeps no process's end.
    @Test func anIgnoredSIGCHLDLosesNoExitCode() async {
        await #expect(processExitsWith: .success) {
            signal(SIGCHLD, SIG_IGN)
            let host = PosixRunHost()
            let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
            for code: Int32 in [0, 3] {
                let step = try host.start(RunStep(["sh", "-c", "exit \(code)"], environment: environment))
                let end = host.finish(step).code
                guard end == code else { exit(100 + end) }
            }
        }
    }

    @Test func aStepIsWaitedForSoLong() throws {
        func start(_ script: String) throws -> StartedStep { try host.start(RunStep(["sh", "-c", script], environment: environment, output: .captured)) }
        let quick = try #require(try host.finish(start("echo a; sleep 0.1; echo b; exit 3"), within: 20) { false })
        #expect(quick.code == 3 && quick.output == "a\nb\n")
        let much = try #require(try host.finish(start("i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done"), within: 20) { false })
        #expect(much.code == 0 && much.output.utf8.count == 220_000)
        let gone = try #require(try host.finish(start("kill -9 $$"), within: 20) { false })
        #expect(gone.code == 137)
        // one whose output another process still has
        let held = try #require(try host.finish(start("sleep 5 & echo a"), within: 20) { false })
        #expect(held.code == 0 && held.output == "a\n")
        let closed = try start("exec >&-; exec sleep 30")
        #expect(host.finish(closed, within: 0.2) { false } == nil)
        let slow = try start("exec sleep 30")
        #expect(host.finish(slow, within: 20) { true } == nil)
        for step in [closed, slow] {
            host.terminate(step.pid)
            #expect(host.finish(StartedStep(pid: step.pid, reading: nil, shows: false)).code == 143)
        }
    }

    @Test func theProcessTable() throws {
        let step = try host.start(RunStep(["sleep", "30"], environment: environment))
        #expect(host.isRunning(step.pid))
        let started = host.started(step.pid), children = host.children()
        if !started.isEmpty { // empty where ps cannot run
            #expect(started == host.started(step.pid) && started.contains(":"))
            #expect(children[host.processID]?.contains(step.pid) == true)
            #expect(host.commandLine(step.pid).contains("sleep"))
        }
        let mark = host.mark(step.pid)
        #expect(!mark.isEmpty && mark == host.mark(step.pid) && mark != host.mark(host.processID))
        #expect(host.programFile(step.pid).contains("/"))
        host.terminate(step.pid)
        #expect(host.finish(step).code == 143)
        #expect(!host.isRunning(step.pid) && host.started(step.pid).isEmpty && host.mark(step.pid).isEmpty)
        #expect(!host.isRunning(0) && !host.isRunning(-1) && host.mark(0).isEmpty && host.programFile(0).isEmpty)
        // not this user's (or init itself, where that is this user's): it runs all the same
        #expect(host.isRunning(1))
    }

    /// What tells this machine from another one is not its name, nor its own ID, which is nobody else's to know.
    @Test func thisMachine() throws {
        let machine = host.machine
        #expect(machine.utf8.count == 32 && machine.allSatisfy { "0123456789abcdef".contains($0) } && machine == PosixRunHost().machine)
        var ids = ["/etc/machine-id", "/proc/sys/kernel/random/boot_id"].compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        #if os(macOS)
        var id = [UInt8](repeating: 0, count: 16), wait = timespec(tv_sec: 5, tv_nsec: 0)
        try #require(gethostuuid(&id, &wait) == 0)
        ids.append(id.map { String(format: "%02x", $0) }.joined())
        #endif
        for id in ids { #expect(id.lowercased().filter(\.isHexDigit) != machine) }
        #expect(PosixRunHost.machine("a", "b") == PosixRunHost.machine("a", "b") && PosixRunHost.machine("a", "b") != PosixRunHost.machine("a", "c"))
        #expect(PosixRunHost.machine("") .isEmpty && PosixRunHost.machine("a", "b") != PosixRunHost.machine("ab", ""))
    }

    /// The system's mark of a process is of this start of it too, where that can be told; and PIDs are of a namespace.
    @Test func thisStartOfTheSystem() {
        let mark = host.mark(host.processID).split(separator: " ").map(String.init)
        #if os(Linux)
        #expect(mark.count == 2 && mark.first == host.boot)
        #expect(host.namespace.hasPrefix("pid:[") && host.namespace.hasSuffix("]"))
        #else
        #expect(mark.count == 1 && host.boot.isEmpty && host.namespace.isEmpty)
        #endif
        #expect(PosixRunHost.mark(12, boot: "b", isMac: false) == "b 12" && PosixRunHost.mark(12, boot: "", isMac: false).isEmpty)
        #expect(PosixRunHost.mark(12, boot: "", isMac: true) == "12" && PosixRunHost.mark(0, boot: "b", isMac: false).isEmpty)
    }

    @Test func whatIsThisUsersAlone() throws {
        let file = try host.temporaryFile(), root = try #require(host.realPath(FileManager.default.temporaryDirectory.path)) + "/xless-own-\(UUID().uuidString)"
        defer { host.removeFile(file); host.removeTree(root) }
        try #require(mkdir(root, 0o700) == 0)
        #expect(host.isPrivateDirectory(root) && !host.isPrivateDirectory(root + "/") && !host.isPrivateDirectory(root + "/none") && !host.isPrivateDirectory(file))
        for mode: mode_t in [0o755, 0o710, 0o701, 0o500] {
            chmod(root, mode)
            #expect(!host.isPrivateDirectory(root), "\(mode)")
        }
        chmod(root, 0o700)
        try Data("first\nsecond\n".utf8).write(to: URL(fileURLWithPath: root + "/file"))
        for (link, to) in [("/link", "file"), ("/self", ".")] { try FileManager.default.createSymbolicLink(atPath: root + link, withDestinationPath: to) }
        #expect(!host.isPrivateDirectory(root + "/self"))
        #expect(host.ownFile(root + "/file") == "first\nsecond\n")
        try #require(mkfifo(root + "/fifo", 0o600) == 0)
        for name in ["/link", "/self", "/fifo", "/none", ""] { #expect(host.ownFile(root + name) == nil, "\(name)") }
        if geteuid() != 0 { #expect(host.ownFile("/etc/passwd") == nil && !host.isPrivateDirectory("/root")) }
    }

    @Test func files() throws {
        let a = try host.temporaryFile(), b = a + ".b"
        defer { host.removeFile(a); host.removeFile(b) }
        #expect(host.link(a, b) && !host.link(a, b) && host.isSame(a, b) == true && host.isSame(a, "/") == false)
        #expect(host.realPath(a + ".none") == nil && host.realPath("/usr/../") == "/")
        #expect(host.makeDirectory(a + ".d") && !host.makeDirectory(a + ".d"))
        host.removeEmptyDirectory(a + ".d")
        #expect(!FileManager.default.fileExists(atPath: a + ".d"))
        #expect(host.program("sh", path: "/nowhere:/bin") == "/bin/sh" && host.program("/bin", path: nil) == nil && host.program("no-such", path: "/bin") == nil)
    }
}
