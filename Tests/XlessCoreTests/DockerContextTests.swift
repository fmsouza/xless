import Testing
@testable import XlessCore

/// The docker context of every xless command that talks to docker: DOCKER_CONTEXT when set, else docker's current one when
/// DOCKER_HOST is set, else colima-xless when docker has it, else docker's current one; a DOCKER_CONTEXT that docker does not have
/// stops the command.
@Suite struct DockerContextTests {
    private let environment = DockerContext.Setting(name: "colima-xless", source: DockerContext.environmentSource)

    @Test func aSetContextThatDockerHasIsUsed() throws {
        #expect(try DockerContext.choose(DockerContext.Setting(name: "colima", source: DockerContext.environmentSource), contexts: ["colima", "default"], host: nil) == "colima")
    }

    @Test func aSetContextThatDockerDoesNotHaveStopsWithWhatToDo() {
        do {
            _ = try DockerContext.choose(environment, contexts: ["colima", "default"], host: nil)
            Issue.record("a missing context was used")
        } catch {
            #expect(error.cause == "DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default")
            #expect(error.fix == "set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists and DOCKER_HOST is not set, else docker's current one")
        }
    }

    @Test func theFileThatSetItIsNamed() {
        let setting = DockerContext.Setting(name: "gone", source: "/home/u/.config/xless/testflight.env")
        do {
            _ = try DockerContext.choose(setting, contexts: ["default"], host: nil)
            Issue.record("a missing context was used")
        } catch {
            #expect(error.cause.contains("DOCKER_CONTEXT is gone (set in /home/u/.config/xless/testflight.env)"))
            #expect(error.fix.contains("in /home/u/.config/xless/testflight.env, or remove it there"))
        }
    }

    @Test func unsetPrefersColimaXlessWhenDockerHasIt() throws {
        #expect(try DockerContext.choose(nil, contexts: ["default", "colima-xless"], host: nil) == "colima-xless")
        #expect(try DockerContext.choose(nil, contexts: ["default", "colima"], host: nil) == nil)
    }

    /// A DOCKER_HOST that is set is a docker someone chose: kept (docker's current one, which DOCKER_HOST makes its own), unless a
    /// DOCKER_CONTEXT names another; an empty one is unset, as for docker.
    @Test func aSetDockerHostIsKeptUnlessAContextIsSet() throws {
        #expect(try DockerContext.choose(nil, contexts: ["default", "colima-xless"], host: "tcp://build:2376") == nil)
        #expect(try DockerContext.choose(nil, contexts: ["default", "colima-xless"], host: "") == "colima-xless")
        #expect(try DockerContext.choose(DockerContext.Setting(name: "colima", source: DockerContext.environmentSource), contexts: ["colima", "default"],
                                         host: "tcp://build:2376") == "colima")
    }

    @Test func whenDockerCannotListItsContextsASetOneIsUsedUnchecked() throws {
        #expect(try DockerContext.choose(environment, contexts: nil, host: nil) == "colima-xless")
        #expect(try DockerContext.choose(nil, contexts: nil, host: nil) == nil)
    }

    @Test func theListingIsReadLineByLineAndAnEmptyOneTellsNothing() {
        #expect(DockerContext.listed("colima\ndefault\n") == ["colima", "default"])
        #expect(DockerContext.listed("\n") == nil)
        #expect(DockerContext.listed("") == nil)
        // docker 23.0.0 and 23.0.1 marked the current context with " *" even with --format
        #expect(DockerContext.listed("default *\ncolima-xless\n") == ["default", "colima-xless"])
    }

    @Test func theSettingsFileWinsOverTheEnvironmentAsInARun() {
        let file = "/h/.config/xless/testflight.env"
        #expect(DockerContext.setting(environment: ["DOCKER_CONTEXT": "a"], file: (file, "b")) == DockerContext.Setting(name: "b", source: file))
        #expect(DockerContext.setting(environment: ["DOCKER_CONTEXT": "a"], file: (file, nil)) == DockerContext.Setting(name: "a", source: "the environment"))
        #expect(DockerContext.setting(environment: ["DOCKER_CONTEXT": ""], file: nil) == nil)
        #expect(DockerContext.setting(environment: [:], file: (file, "")) == nil)
    }

    @Test func theWordsOfDocker() {
        #expect(DockerContext.arguments(nil) == [])
        #expect(DockerContext.arguments("colima") == ["--context", "colima"])
    }
}
