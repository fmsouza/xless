import Foundation
import Testing
import XlessCore
@testable import xless

/// The docker of `xless setup`, `xless clean` and `xless sdk export`: chosen as `xless run` chooses it (`DockerContext`), with the
/// DOCKER_CONTEXT of the environment or of the run's file of settings.
@Suite struct HostDockerTests {
    /// A docker with these contexts; the environments it was asked in.
    final class Docker: @unchecked Sendable {
        let contexts: String, code: Int32
        private(set) var asked: [(arguments: [String], environment: [String: String])] = []
        init(_ contexts: String, code: Int32 = 0) { self.contexts = contexts; self.code = code }
        func ask(_ arguments: [String], _ environment: [String: String]) -> (code: Int32, output: String) {
            asked.append((arguments, environment))
            return (code, contexts)
        }
    }

    private func decide(_ environment: [String: String], file: String? = nil, docker: Docker) throws(DockerContext.Problem) -> String? {
        try HostDocker.decide(environment: environment, read: { $0 == "/h/.config/xless/testflight.env" ? file : nil }, ask: docker.ask)
    }

    @Test func aContextDockerDoesNotHaveIsRefusedWithWhereItWasSet() {
        let docker = Docker("colima\ndefault\n")
        do {
            _ = try decide(["HOME": "/h", "DOCKER_CONTEXT": "colima-xless"], docker: docker)
            Issue.record("used")
        } catch {
            #expect(error.cause.hasPrefix("DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default"))
        }
        // listed without the variable, which docker would list as a context of its own
        #expect(docker.asked.map(\.arguments) == [DockerContext.listing] && docker.asked.allSatisfy { $0.environment["DOCKER_CONTEXT"] == nil && $0.environment["HOME"] == "/h" })
    }

    @Test func theRunsFileOfSettingsIsReadAsTheRunReadsIt() throws {
        do {
            _ = try decide(["HOME": "/h", "DOCKER_CONTEXT": "default"], file: "A=1\nexport DOCKER_CONTEXT='gone'\n", docker: Docker("default\n"))
            Issue.record("used")
        } catch {
            #expect(error.cause.contains("DOCKER_CONTEXT is gone (set in /h/.config/xless/testflight.env)"))
        }
        #expect(try decide(["HOME": "/h"], file: "DOCKER_CONTEXT=mine\n", docker: Docker("default\nmine\n")) == "mine")
        // XLESS_TESTFLIGHT_ENV names the file, as for the run; a file the run would refuse sets nothing here (the run says why)
        #expect(try HostDocker.decide(environment: ["HOME": "/h", "XLESS_TESTFLIGHT_ENV": "/other.env"], read: { $0 == "/other.env" ? "DOCKER_CONTEXT=mine\n" : nil },
                                      ask: Docker("mine\n").ask) == "mine")
        #expect(try decide(["HOME": "/h"], file: "DOCKER_CONTEXT=$(nope)\n", docker: Docker("default\ncolima-xless\n")) == "colima-xless")
    }

    @Test func unsetItIsColimaXlessWhenDockerHasItElseDockersOwn() throws {
        #expect(try decide(["HOME": "/h"], docker: Docker("default\ncolima-xless\n")) == "colima-xless")
        #expect(try decide(["HOME": "/h"], docker: Docker("default\ncolima\n")) == nil)
        // a DOCKER_HOST that is set is kept: docker's current one
        #expect(try decide(["HOME": "/h", "DOCKER_HOST": "tcp://build:2376"], docker: Docker("default\ncolima-xless\n")) == nil)
        // a docker that does not answer: a set context goes to docker as it is
        #expect(try decide(["HOME": "/h", "DOCKER_CONTEXT": "x"], docker: Docker("", code: 127)) == "x")
    }

    /// What setup runs that calls docker itself (scripts/docker-images.sh) gets the same docker: the context as `--context` gives
    /// it, which DOCKER_HOST does not override.
    @Test func aScriptsEnvironmentNamesTheContext() {
        #expect(HostDocker.environment(["A": "1", "DOCKER_HOST": "tcp://x", "DOCKER_CONTEXT": "old"], context: "colima-xless") == ["A": "1", "DOCKER_CONTEXT": "colima-xless"])
        #expect(HostDocker.environment(["A": "1", "DOCKER_HOST": "tcp://x"], context: nil) == ["A": "1", "DOCKER_HOST": "tcp://x"])
    }

    @Test func theRefusalIsAConfigurationFaultOfExitCodeTwo() {
        let error = HostDocker.error(DockerContext.Problem(cause: "c", fix: "f"))
        #expect(error.exitCode == 2 && error.cause == "c" && error.fix == "f")
    }
}
