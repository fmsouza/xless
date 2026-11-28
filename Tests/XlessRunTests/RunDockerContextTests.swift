import Foundation
import Testing
import XlessCore
@testable import XlessRun

/// The docker context of a run in containers, chosen as every xless command chooses it (`DockerContext`): a DOCKER_CONTEXT that
/// docker does not have stops the run before anything of docker is used, and says where it was set.
@Suite struct RunDockerContextTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    /// A docker with these contexts; what it was asked for them, and in what environment.
    private func host(contexts: String, listed: Notes) -> FakeRunHost {
        FakeRunHost(answer: home.answer { step in
            guard step.words.suffix(4) == ["context", "ls", "--format", "{{.Name}}"] else { return nil }
            listed.add(step.environment["DOCKER_CONTEXT"] ?? "-")
            return (0, contexts)
        })
    }

    private func dockerSteps(_ host: FakeRunHost) -> [RunStep] {
        host.allSteps.filter { $0.words.first == "docker" && !$0.words.contains("context") }
    }

    @Test func aContextDockerDoesNotHaveStopsTheRunBeforeAnything() throws {
        let listed = Notes()
        let host = host(contexts: "colima\ndefault\n", listed: listed)
        let code = try home.run(["--config", home.overlay], docker: true, host: host, environment: try home.files().merging(["DOCKER_CONTEXT": "colima-xless"]) { $1 })
        #expect(code == 2, "\(host.lines)")
        #expect(host.lines.last == "testflight: DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default; "
            + "set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists and DOCKER_HOST is not set, else docker's current one", "\(host.lines)")
        // before anything of docker is used, and before a secret is written for the containers
        #expect(host.allSteps.filter { $0.words.first == "docker" }.map(\.line) == ["docker context ls --format {{.Name}}"], "\(host.allSteps.map(\.line))")
        #expect(!host.allSteps.contains { $0.words.contains("materialize") } && !home.exists(home.secrets))
        // docker is asked for its contexts without the variable, which it would list as one of its own
        #expect(listed.lines == ["-"])
    }

    @Test func theFileOfTheRunIsNamedWhenItSetIt() throws {
        let file = try home.write("testflight.env", "DOCKER_CONTEXT=gone\n")
        let host = host(contexts: "default\n", listed: Notes())
        let code = try home.run(["--config", home.overlay], docker: true, host: host,
                                environment: try home.files().merging(["XLESS_TESTFLIGHT_ENV": file, "DOCKER_CONTEXT": "default"]) { $1 })
        #expect(code == 2, "\(host.lines)")
        #expect(host.lines.last?.hasPrefix("testflight: DOCKER_CONTEXT is gone (set in \(file)), but docker has no context of that name; its contexts: default; ") == true, "\(host.lines)")
    }

    @Test func aContextDockerHasIsUsedByEveryDockerCommand() throws {
        let host = host(contexts: "colima-xless\nmine\n", listed: Notes())
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: try home.files().merging(["DOCKER_CONTEXT": "mine"]) { $1 }) == 0, "\(host.lines)")
        let steps = dockerSteps(host)
        #expect(!steps.isEmpty)
        for step in steps { #expect(step.words.starts(with: ["docker", "--context", "mine"]), "\(step.line)") }
    }

    @Test func unsetItIsColimaXlessWhenDockerHasIt() throws {
        let host = host(contexts: "default\ncolima-xless\n", listed: Notes())
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: try home.files()) == 0, "\(host.lines)")
        for step in dockerSteps(host) { #expect(step.words.starts(with: ["docker", "--context", "colima-xless"]), "\(step.line)") }
        let other = self.host(contexts: "default\ncolima\n", listed: Notes())
        #expect(try home.run(["--config", home.overlay], docker: true, host: other, environment: try home.files()) == 0, "\(other.lines)")
        for step in dockerSteps(other) { #expect(!step.words.contains("--context"), "\(step.line)") }
    }

    /// A DOCKER_HOST that is set is kept when no DOCKER_CONTEXT is (docker's current one, with it); a DOCKER_CONTEXT that is set wins,
    /// and docker is then called without DOCKER_HOST, as the scripts call it.
    @Test func aDockerHostIsKeptUnlessAContextIsSet() throws {
        let kept = host(contexts: "default\ncolima-xless\n", listed: Notes())
        #expect(try home.run(["--config", home.overlay], docker: true, host: kept,
                             environment: try home.files().merging(["DOCKER_HOST": "tcp://build:2376"]) { $1 }) == 0, "\(kept.lines)")
        #expect(!dockerSteps(kept).isEmpty)
        for step in dockerSteps(kept) {
            #expect(!step.words.contains("--context") && step.environment["DOCKER_HOST"] == "tcp://build:2376", "\(step.line)")
        }
        let chosen = host(contexts: "default\nmine\n", listed: Notes())
        #expect(try home.run(["--config", home.overlay], docker: true, host: chosen,
                             environment: try home.files().merging(["DOCKER_HOST": "tcp://build:2376", "DOCKER_CONTEXT": "mine"]) { $1 }) == 0, "\(chosen.lines)")
        for step in dockerSteps(chosen) {
            #expect(step.words.starts(with: ["docker", "--context", "mine"]) && step.environment["DOCKER_HOST"] == nil, "\(step.line)")
        }
    }
}
