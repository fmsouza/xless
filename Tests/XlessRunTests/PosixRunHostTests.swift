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
