import Foundation
import Testing
import XlessCore
@testable import XlessRun

@Suite struct ProjectRunTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    private func containers(_ host: FakeRunHost) -> [RunStep] { host.allSteps.filter(\.isContainer) }

    /// No value, path or mount of a secret in anything a step was given.
    private func secretsIn(_ step: RunStep, _ all: [String: String]) -> [String] {
        let secret = Set(SecretEnvironment.names + ["SOME_PASSWORD", "SOME_PASSWORD_FILE", "XLESS_SESSION"])
        var found = step.environment.keys.filter(secret.contains)
        for text in step.words + Array(step.environment.values) {
            for (name, value) in all where secret.contains(name) && text.contains(value) { found.append("\(name) in \(text)") }
            if text.contains("/secrets") { found.append(text) }
        }
        return found
    }

    @Test func inContainersTheBuildIsGivenNoSecret() throws {
        let secrets = try home.files()
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: secrets, session: "/agent") == 0)
        let steps = containers(host)
        try #require(steps.count == 3)
        #expect(secretsIn(steps[1], secrets).isEmpty)
        #expect(steps[1].line.contains("--from build --to finalize"))
        #expect(steps[0].words.contains("next-build") && steps[0].words.contains { $0.contains("asc.p8") } && !steps[0].words.contains { $0.contains("dist.pem") })
        #expect(steps[2].line.contains("--from sign --to upload") && steps[2].words.contains { $0.contains("dist.pem") })
        for step in steps {
            // by name or by path: no value is ever in the words, and docker itself has the two IDs alone
            #expect(!step.words.contains { $0.contains("KEY1") || $0.contains("issuer-1") || $0.contains("-VALUE") })
            #expect(Set(step.environment.keys).isDisjoint(with: ["XLESS_DIST_KEY", "ASC_KEY_P8", "ASC_KEY_P8_FILE", "XLESS_DEMO_PASSWORD", "SOME_PASSWORD", "XLESS_SESSION"]))
            for flag in ["--rm", "--pull=never", "--init"] { #expect(step.words.contains(flag)) }
            #expect(step.words.contains { $0.hasPrefix("xless.run=4242.") } && step.words.contains { $0.hasPrefix("xless.work=") })
            #expect(step.environment["XLESS_BUILD_NUMBER"] == (step == steps[0] ? nil : "42"))
        }
        // the app's files can be read in the containers, and no more
        #expect(steps[1].words.filter { $0.hasPrefix("type=bind") && ($0.contains("dst=/source") || $0.contains("dst=/config")) }.allSatisfy { $0.hasSuffix(",readonly") })
        #expect(!host.allSteps.contains { $0.words[0] == "sh" || $0.words[0] == "bash" })
    }

    @Test func nativelyTheBuildIsGivenNoSecretAndNoSession() throws {
        let secrets = try home.files()
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay], docker: false, host: host, environment: secrets, session: "/agent") == 0)
        let build = try #require(host.allSteps.first { $0.line.contains("--to finalize") })
        #expect(secretsIn(build, secrets).isEmpty)
        #expect(build.environment["XLESS_NO_SECRET_STORE"] == "1" && build.words[0] == "xless")
        // what is held for the session: for the steps that read the store, and nothing else
        let told = host.allSteps.filter { $0.environment["XLESS_SESSION"] == "/agent" }.map { $0.words[1] }
        #expect(told == ["tauri", "ship"])
        let sign = try #require(host.allSteps.last)
        #expect(sign.line.contains("--from sign --to upload") && sign.environment["XLESS_DIST_KEY"] == "DIST-VALUE" && sign.environment["XLESS_NO_SECRET_STORE"] == nil)
        for step in host.allSteps where !["tauri", "ship"].contains(step.words[1]) {
            #expect(Set(step.environment.keys).isDisjoint(with: SecretEnvironment.names + ["XLESS_SESSION"]), "\(step.line)")
        }
    }

    /// Nor one that stops before it signs, which needs none.
    @Test func nativelyABuildThatStopsIsGivenNone() throws {
        var secrets = try home.files()
        secrets["SOME_PASSWORD_FILE"] = "\(home.root)/none" // (which such a run does not read)
        for arguments in [["--config", home.overlay], [home.project]] {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run(arguments + ["--to", "finalize", "--build-number", "1"], docker: false, host: host, environment: secrets) == 0)
            let build = try #require(host.allSteps.first { $0.line.contains("--to finalize") })
            #expect(secretsIn(build, secrets).isEmpty && build.environment["XLESS_NO_SECRET_STORE"] == "1")
            let container = FakeRunHost(answer: home.answer())
            #expect(try home.run(arguments + ["--to", "finalize", "--build-number", "1"], docker: true, host: container, environment: secrets) == 0)
            for step in container.allSteps { #expect(Set(step.environment.keys).isDisjoint(with: SecretEnvironment.names), "\(step.line)") }
            let unknown = FakeRunHost(answer: home.answer { $0.words.contains("named-by") ? (10, "") : nil })
            #expect(try home.run(arguments + ["--to", "finalize", "--build-number", "1"], docker: false, host: unknown, environment: secrets) == 0)
            #expect(unknown.lines.contains { $0.contains("named-by could not tell") && $0.contains("the build step keeps the variable it is in, if any") })
        }
    }

    /// Every secret's variable, with its `_FILE` form, and a password's of the user's own name.
    @Test func theDryRunShowsThatTheBuildHasNone() throws {
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay, "--dry-run"], docker: false, host: host, environment: home.files()) == 0)
        let line = try #require(host.output.first { $0.hasPrefix("env ") })
        for name in SecretEnvironment.names + ["SOME_PASSWORD", "SOME_PASSWORD_FILE", "XLESS_SESSION"] { #expect(line.contains(" -u \(name) ")) }
        #expect(line.contains(" XLESS_NO_SECRET_STORE=1 xless ship "))
        #expect(!host.allSteps.contains { $0.words.contains("ship") })
        #expect(!host.output.joined().contains("-VALUE"))
    }

    @Test func aNativeRunAsksForThePassphraseOnceUpFront() throws {
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run([home.project], docker: false, host: host) == 127) // the fake session does not start
        #expect(host.became == ["xless", "session", "--if-possible", "--purpose", "xless run", "--reason", "reading ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID, XLESS_DIST_KEY", "--", "/x/xless", "run", home.project])
        #expect(host.becameWith["XLESS_RUN_UNLOCKED"] == "1")
        for (session, unlocked) in [(nil, true), ("/agent", false)] as [(String?, Bool)] {
            let inside = FakeRunHost(answer: home.answer())
            #expect(try home.run([home.project], docker: false, host: inside, session: session, unlocked: unlocked) == 0)
            #expect(inside.became == nil)
            let ship = try #require(inside.allSteps.last)
            #expect(ship.words == ["xless", "ship", "--platform", "ios"] && ship.directory == home.project && ship.environment["XLESS_SESSION"] == session)
            #expect(ship.environment["XLESS_RUN_UNLOCKED"] == nil)
        }
    }

    @Test func theStoresSecretsGoContainerByContainer() throws {
        let home = home
        let left = Notes()
        let host = FakeRunHost(answer: home.answer { step in
            guard step.isContainer else { return nil }
            left.add(((try? FileManager.default.contentsOfDirectory(atPath: home.secrets)) ?? []).sorted().joined(separator: " "))
            return nil
        })
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, session: "/agent") == 0)
        #expect(left.lines == ["next sign", "sign", "sign"])
        let steps = containers(host)
        #expect(steps.map { $0.words.filter { $0.contains("dst=/secrets/store") } } == [["type=bind,src=\(home.secrets)/next,dst=/secrets/store,readonly"], [],
                                                                                        ["type=bind,src=\(home.secrets)/sign,dst=/secrets/store,readonly"]])
        let written = try #require(host.allSteps.first { $0.words.contains("materialize") && !$0.words.contains("--check") })
        #expect(written.environment["XLESS_SESSION"] == "/agent")
        #expect(!home.exists(home.secrets), "removed when the run ended")
        // each file, for a fault of the run's own that leaves no time for that
        let files = ["next", "sign"].flatMap { set in ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID"].map { "\(home.secrets)/\(set)/\($0)" } } + ["\(home.secrets)/sign/XLESS_DIST_KEY"]
        #expect(Set(host.removedOnFault) == Set(files + ["", "/next", "/sign"].map { home.secrets + $0 }))
        if case .file(let path) = written.output { #expect(!home.exists(path)) } else { Issue.record("not to a file") }
    }

    @Test func whatFailsEndsTheRunWithItsExitCodeAndNothingLeft() throws {
        let home = home
        let host = FakeRunHost(answer: home.answer { $0.line.contains("--to finalize") ? (17, "") : nil })
        #expect(try home.run(["--config", home.overlay], docker: true, host: host) == 17)
        #expect(containers(host).count == 2 && host.lines.last == "==> xless exited with code 17")
        #expect(!home.exists(home.secrets))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/locks").isEmpty)
        let store = FakeRunHost(answer: home.answer { $0.words.contains("materialize") ? (12, "") : nil })
        #expect(try home.run(["--config", home.overlay], docker: true, host: store) == 12)
        #expect(containers(store).isEmpty && store.lines.last == "==> xless exited with code 12 (the secret store)")
    }

    /// A run that is stopped in its build, with this docker.
    private func stopped(_ docker: @escaping @Sendable (FakeRunHost, RunStep) -> FakeRunHost.Answer?) async -> (FakeRunHost, Int32?) {
        let home = home
        let inBuild = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let well = home.answer()
        let host = FakeRunHost { host, step in
            if let answer = docker(host, step) { return answer }
            guard step.line.contains("--to finalize") else { return well(host, step) }
            inBuild.signal()
            go.wait()
            return (143, "")
        }
        let thread = Thread { _ = try? home.run(["--config", home.overlay], docker: true, host: host) }
        thread.start()
        let code = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                inBuild.wait()
                done.resume(returning: host.askToStop(143))
                go.signal()
            }
        }
        return (host, code)
    }

    @Test func aStopRemovesWhatTheRunHas() async throws {
        let home = home, left = Notes()
        let (host, code) = await stopped { _, step in
            guard step.isCleanUp("ps") else { return nil }
            if home.exists(home.secrets) { left.add("the secrets") }
            return (0, "c0ffee\n")
        }
        #expect(code == 143)
        #expect(left.lines.isEmpty, "they go before anything that may hang")
        #expect(!home.exists(home.secrets))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/locks").isEmpty)
        #expect(host.killed.count == 1, "the step")
        let last = host.allSteps.suffix(2)
        #expect(last.first?.line.hasPrefix("docker ps -aq --filter label=xless.run=4242.") == true && last.last?.line == "docker rm -f c0ffee")
        #expect(!host.allSteps.contains { $0.line.contains("--from sign") }, "and no step after it")
    }

    @Test func aDockerThatHangsHoldsUpNoStop() async throws {
        let (silent, code) = await stopped { _, step in step.isCleanUp("ps") ? (FakeRunHost.hangs, "") : nil }
        #expect(code == 143 && silent.limits == [15] && silent.killed.count == 2, "the step, and that docker")
        #expect(silent.lines.last?.contains("docker does not answer; remove what may be left of this run's containers with: docker rm -f $(docker ps -aq --filter label=xless.run=4242.") == true)
        #expect(!home.exists(home.secrets))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/locks").isEmpty)
        let (slow, _) = await stopped { _, step in step.isCleanUp("ps") ? (0, "c0ffee\n") : step.words.contains("c0ffee") ? (FakeRunHost.hangs, "") : nil }
        #expect(slow.limits == [15, 15] && slow.lines.last == "testflight: could not remove this run's containers; remove them with: docker rm -f c0ffee")
        // asked once more: it ends at once
        let (asked, again) = await stopped { host, step in
            guard step.isCleanUp("ps") else { return nil }
            host.more = 1
            return (0, "c0ffee\n")
        }
        #expect(again == 143 && asked.lines.last?.contains("docker does not answer") == true)
    }

    @Test func noSecretMayBeInWhatTheBuildContainerMounts() throws {
        func refused(_ environment: [String: String], _ what: String) throws {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: environment) == 2)
            #expect(host.lines.last?.contains(what) == true, "\(host.lines)")
            #expect(containers(host).isEmpty && !home.exists(home.secrets))
        }
        var secrets = try home.files()
        secrets["XLESS_DIST_KEY_FILE"] = try home.write("src/key.pem", "k")
        try refused(secrets, "is inside the app source")
        secrets["XLESS_DIST_KEY_FILE"] = try home.write("ov/key.pem", "k")
        try refused(secrets, "is inside the overlay's directory")
        // nor does a name that starts with a mark that combines with the "/" before it
        for mark in ["\u{301}", "\u{200D}", "\u{FE0F}"] {
            for (place, what) in [("src", "is inside the app source"), ("ov", "is inside the overlay's directory")] {
                try FileManager.default.createDirectory(atPath: "\(home.root)/\(place)/\(mark)keys", withIntermediateDirectories: true)
                secrets["XLESS_DIST_KEY_FILE"] = try home.write("\(place)/\(mark)keys/key.pem", "k")
                try refused(secrets, what)
            }
            try FileManager.default.createDirectory(atPath: "\(home.root)/src/\(mark)run", withIntermediateDirectories: true)
            try refused(["XDG_RUNTIME_DIR": "\(home.root)/src/\(mark)run"], "which is mounted into the build container; point XDG_RUNTIME_DIR elsewhere")
        }
        // a link to it does not hide it
        try FileManager.default.createSymbolicLink(atPath: "\(home.root)/link.pem", withDestinationPath: "\(home.root)/ov/key.pem")
        secrets["XLESS_DIST_KEY_FILE"] = "\(home.root)/link.pem"
        try refused(secrets, "is inside the overlay's directory")
        try refused(["XDG_RUNTIME_DIR": "\(home.root)/src"], "which is mounted into the build container; point XDG_RUNTIME_DIR elsewhere")
        try refused(["XLESS_TESTFLIGHT_ENV": home.write("src/x.env", "A=1\n")], "ENV_FILE")
        // what cannot be told is refused: a home that is not there
        try refused(["HOME": "\(home.root)/none"], "cannot tell where your home directory is (HOME: \(home.root)/none, which is not there, or not to be seen)")
        try refused(["HOME": ""], "cannot tell where your home directory is (HOME is empty)")
        try refused(["XLESS_SOURCE": home.home], "holds your home directory")
        try refused(["XLESS_SOURCE": home.root], "holds your home directory")
        try refused(["XLESS_SOURCE": "/"], "holds your home directory")
        #if os(macOS)
        // the data volume, which holds /Users and all the user's: macOS shows its folders in / too
        for volume in ["/System/Volumes/Data", "/System/Volumes", "/System"] { try refused(["XLESS_SOURCE": volume], "holds your home directory") }
        #endif
    }

    @Test func theEnvFileIsDataAndWinsOverTheEnvironment() throws {
        let marker = "\(home.root)/ran"
        let file = try home.write("testflight.env", "ASC_KEY_ID=FILEID\nXLESS_IMAGE='img:1'\n")
        home.images.add(xcode: "26.6", build: "17F113", name: "img:1", layers: ["mine"], id: "sha256:mine")
        let host = FakeRunHost(answer: home.answer())
        var environment = try home.files()
        environment["XLESS_TESTFLIGHT_ENV"] = file
        environment["XLESS_IMAGE"] = "img:0"
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: environment) == 0)
        #expect(containers(host)[1].image == "sha256:mine" && containers(host)[0].environment["ASC_KEY_ID"] == "FILEID")
        try home.write("testflight.env", "A=1\nB=$(touch \(marker))\n")
        let refused = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay], docker: true, host: refused, environment: environment) == 2)
        #expect(refused.lines.last?.contains("testflight.env, line 2 ") == true && !home.exists(marker) && refused.allSteps.isEmpty)
    }

    @Test func aProblemOfTheEnvFileSaysNothingOfAValue() throws {
        let file = try home.write("testflight.env", "A=1\nXLESS_DEMO_PASSWORD=\"hunter$SecretTail9\"\n")
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run([home.project], docker: false, host: host, environment: ["XLESS_TESTFLIGHT_ENV": file]) == 2)
        #expect(host.lines.last?.contains("testflight.env, line 2 ") == true && host.lines.last?.contains("XLESS_DEMO_PASSWORD") == true)
        #expect(!host.lines.joined().contains("Secret") && !host.lines.joined().contains("hunter"))
    }

    /// What is not a file (/dev/null, a pipe) is not read, as if it were not there.
    @Test func anEnvFileIsARegularFile() throws {
        let pipe = "\(home.root)/pipe"
        #expect(mkfifo(pipe, 0o600) == 0)
        for file in ["/dev/null", pipe, home.home] {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run([home.project, "--to", "finalize"], docker: false, host: host, environment: ["XLESS_TESTFLIGHT_ENV": file]) == 0)
            #expect(!host.lines.contains { $0.contains("testflight.env") || $0.hasPrefix("note: ") })
        }
        for arguments in [["--config", "/dev/null"], ["--config", pipe]] {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run(arguments, docker: false, host: host) == 2)
            #expect(host.lines.last?.hasSuffix("not found") == true)
        }
    }

    /// Once per run: not again when it starts anew inside a session.
    @Test func theEnvFileIsNamedAsTheOldWay() throws {
        let file = try home.write("testflight.env", "XLESS_IMAGE=x\n")
        for (unlocked, count) in [(false, 1), (true, 0)] {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run([home.project, "--to", "finalize"], docker: false, host: host, environment: ["XLESS_TESTFLIGHT_ENV": file], unlocked: unlocked) == 0)
            #expect(host.lines.filter { $0.hasPrefix("note: ") && $0.contains(file) && $0.contains("xless secrets import-env") }.count == count)
            #expect(host.output.isEmpty)
        }
        let none = FakeRunHost(answer: home.answer())
        #expect(try home.run([home.project, "--to", "finalize"], docker: false, host: none) == 0)
        #expect(!none.lines.contains { $0.hasPrefix("note: ") })
    }

    @Test func aRunThatStopsBeforeSigningNeedsNoSecret() throws {
        for (arguments, docker) in [(["--config", home.overlay, "--build-number", "3", "--to", "finalize"], true), ([home.project, "--to", "finalize"], false)] {
            let host = FakeRunHost(answer: home.answer())
            #expect(try home.run(arguments, docker: docker, host: host) == 0)
            #expect(host.lines.last == "==> TestFlight: stopped after finalize (--to), nothing delivered")
            #expect(!host.allSteps.contains { $0.words.contains("materialize") })
        }
    }

    @Test func aMacRunShipsItsTwoChannels() throws {
        let host = FakeRunHost(answer: home.answer { step in
            step.line.contains("app-store") ? (0, "x\n/cache/work/a/A.pkg\n") : step.line.contains("--to package") ? (0, "/cache/work/a/A.dmg\n") : nil
        })
        #expect(try home.run(["--config", home.overlay, "--platform", "macos", "--to", "upload"], docker: true, host: host) == 0)
        #expect(host.lines.suffix(3) == ["==> DMG: \(home.home)/.cache/xless/work/a/A.dmg", "==> PKG: \(home.home)/.cache/xless/work/a/A.pkg", "==> DMG build finished"])
        let steps = containers(host)
        #expect(steps.count == 3 && steps[1].line.contains("/sign,dst=/secrets/store") && !steps[1].line.contains("INSTALLER") && steps[2].line.contains("/appstore,dst=/secrets/store"))
    }

    @Test func aFileThatIsNotYAMLIsAConfigurationError() throws {
        try home.write("ov/app.yml", "type: [")
        do {
            _ = try home.run(["--config", home.overlay], docker: true, host: FakeRunHost())
            Issue.record("no error")
        } catch { #expect((error as? XlessError)?.exitCode == 10) }
    }
}
