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

    @Test func aStopRemovesWhatTheRunHas() async throws {
        let home = home
        let inBuild = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let host = FakeRunHost(answer: home.answer { step in
            if step.words.contains("ps") { return (0, "c0ffee\n") }
            guard step.line.contains("--to finalize") else { return nil }
            inBuild.signal()
            go.wait()
            return (143, "")
        })
        let thread = Thread { _ = try? home.run(["--config", home.overlay], docker: true, host: host) }
        thread.start()
        let code = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                inBuild.wait()
                done.resume(returning: host.askToStop(143))
                go.signal()
            }
        }
        #expect(code == 143)
        #expect(!home.exists(home.secrets))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/locks").isEmpty)
        #expect(host.killed.count == 1, "the step")
        let last = host.allSteps.suffix(2)
        #expect(last.first?.line.hasPrefix("docker ps -aq --filter label=xless.run=4242.") == true && last.last?.line == "docker rm -f c0ffee")
        #expect(!host.allSteps.contains { $0.line.contains("--from sign") }, "and no step after it")
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
        // a link to it does not hide it
        try FileManager.default.createSymbolicLink(atPath: "\(home.root)/link.pem", withDestinationPath: "\(home.root)/ov/key.pem")
        secrets["XLESS_DIST_KEY_FILE"] = "\(home.root)/link.pem"
        try refused(secrets, "is inside the overlay's directory")
        try refused(["XDG_RUNTIME_DIR": "\(home.root)/src"], "which is mounted into the build container; point XDG_RUNTIME_DIR elsewhere")
        try refused(["XLESS_TESTFLIGHT_ENV": home.write("src/x.env", "A=1\n")], "ENV_FILE")
        try refused(["XLESS_SOURCE": home.home], "holds your home directory")
        try refused(["XLESS_SOURCE": home.root], "holds your home directory")
        try refused(["XLESS_SOURCE": "/"], "holds your home directory")
    }

    @Test func theEnvFileIsDataAndWinsOverTheEnvironment() throws {
        let marker = "\(home.root)/ran"
        let file = try home.write("testflight.env", "ASC_KEY_ID=FILEID\nXLESS_IMAGE='img:1'\n")
        let host = FakeRunHost(answer: home.answer())
        var environment = try home.files()
        environment["XLESS_TESTFLIGHT_ENV"] = file
        environment["XLESS_IMAGE"] = "img:0"
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: environment) == 0)
        #expect(containers(host).allSatisfy { $0.words.contains("img:1") } && containers(host)[0].environment["ASC_KEY_ID"] == "FILEID")
        try home.write("testflight.env", "A=1\nB=$(touch \(marker))\n")
        let refused = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay], docker: true, host: refused, environment: environment) == 2)
        #expect(refused.lines.last?.contains("testflight.env, line 2 ") == true && !home.exists(marker) && refused.allSteps.isEmpty)
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

    @Test func differentXlessBuildsInTheTwoImagesAreRefused() throws {
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\n")
        let host = FakeRunHost(answer: home.answer { $0.words.contains("sha256sum") ? (0, $0.line.contains("xless-rn") ? "aaaa  x\n" : "bbbb  x\n") : nil })
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: home.files()) == 2)
        #expect(host.lines.last?.contains("hold different xless builds") == true && containers(host).isEmpty)
    }

    @Test func aFileThatIsNotYAMLIsAConfigurationError() throws {
        try home.write("ov/app.yml", "type: [")
        do {
            _ = try home.run(["--config", home.overlay], docker: true, host: FakeRunHost())
            Issue.record("no error")
        } catch { #expect((error as? XlessError)?.exitCode == 10) }
    }
}
