import Foundation
import Testing
import XlessCore
import XlessImages
@testable import XlessRun

/// Which image each step of a run in containers is in.
@Suite struct RunImagesTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    private static let base = "xless:local-arm64-xcode26.6"

    private func containers(_ host: FakeRunHost) -> [RunStep] { host.allSteps.filter(\.isContainer) }
    /// The names of the images the containers are of: each is started by the ID of the image that was checked, which no tag moves.
    private func names(_ host: FakeRunHost) -> [String] { containers(host).map { home.images.name($0.image) } }
    private func builds(_ host: FakeRunHost) -> [RunStep] { host.allSteps.filter { $0.words.contains("build") && $0.words.contains("--pull=false") } }

    private func run(_ arguments: [String]? = nil, _ environment: [String: String] = [:]) throws -> (host: FakeRunHost, code: Int32) {
        let host = FakeRunHost(answer: home.answer())
        let code = try home.run(arguments ?? ["--config", home.overlay], docker: true, host: host, environment: home.files().merging(environment) { $1 })
        return (host, code)
    }

    private func refused(_ arguments: [String]? = nil, _ environment: [String: String] = [:]) throws -> String {
        let (host, code) = try run(arguments, environment)
        #expect(code == 2)
        #expect(containers(host).isEmpty && builds(host).isEmpty && !home.exists(home.secrets), "nothing ran, and no secret was written")
        return host.lines.last ?? ""
    }

    /// The custom image of the tests, as a person builds one on xless's.
    private func mine(layers: [String] = ["mine"]) { home.images.add(xcode: "26.6", build: "17F113", name: "mine:1", layers: layers, id: "sha256:mine") }

    // MARK: - The kits

    /// The steps with the secrets are in xless's own image, which has no toolchain of another language; the build is in the kit's.
    @Test(arguments: [("tauri", "tauri"), ("cargo", "tauri"), ("react-native", "react-native")])
    func theBuildStepAloneIsInTheKitsImage(type: String, kit: String) throws {
        try home.write("ov/app.yml", "type: \(type)\nsource: ../src\n")
        let (host, code) = try run()
        #expect(code == 0)
        #expect(names(host) == [Self.base, "\(Self.base)-\(kit)", Self.base])
        #expect(builds(host).isEmpty)
        #expect(host.lines.contains("==> no xcode: is pinned, so the newest Xcode there is an image of: build \(Self.base)-\(kit), signing and upload \(Self.base)"))
    }

    @Test func thePinnedXcodesImagesAreUsed() throws {
        home.images.add(xcode: "27.0", build: "27A266a")
        try home.images.add(.tauri, xcode: "27.0", share: home.share)
        let (newest, _) = try run()
        #expect(names(newest).first == "xless:local-arm64-xcode27.0")
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.6\"\n")
        let (host, code) = try run()
        #expect(code == 0 && names(host) == [Self.base, "\(Self.base)-tauri", Self.base])
        #expect(host.lines.contains("==> xcode: \"26.6\" (pinned): build \(Self.base)-tauri, signing and upload \(Self.base)"))
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.2\"\n")
        #expect(try refused() == "testflight: \(home.overlay) pins xcode: \"26.2\", but the image xless:local-arm64-xcode26.2 is missing; build it from Xcode 26.2: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64")
        #expect(try home.run(["--config", home.overlay, "--dry-run"], docker: true, host: FakeRunHost(answer: home.answer())) == 2)
    }

    @Test(arguments: [true, false])
    func aKitThatIsMissingOrStaleIsBuiltBeforeAnythingElse(stale: Bool) throws {
        let kit = "\(Self.base)-tauri"
        if stale { try home.write("share/docker/tauri/Dockerfile", "FROM newer\n") } else { home.images.remove(kit) }
        // (the secrets are in the store)
        let host = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: ["BUILDX_BUILDER": "other", "DOCKER_BUILDKIT": "0", "XLESS_DIST_KEY": "DIST-VALUE"], session: "/agent") == 0)
        let build = try #require(builds(host).first)
        #expect(builds(host).count == 1)
        #expect(build.words == ["docker"] + (try Kit.tauri.build(on: LocalImage(name: Self.base, id: "sha256:base26.6", architecture: "arm64", labels: [ImageLabel.xcode: "26.6"], layers: []), share: home.share, builder: "here")))
        // it sees no secret, and docker's own builder builds it (another could not see the local image)
        #expect(Set(build.environment.keys).isDisjoint(with: SecretEnvironment.names + ["SOME_PASSWORD", "XLESS_SESSION", "BUILDX_BUILDER", "DOCKER_BUILDKIT"]))
        let order = host.allSteps.map { $0 == build ? "build" : $0.words.contains("materialize") && !$0.words.contains("--check") ? "secrets" : $0.isContainer ? "container" : "" }.filter { !$0.isEmpty }
        #expect(order == ["build", "secrets", "container", "container", "container"])
        let why = stale ? "xless's Dockerfile for it has changed" : "there is none yet"
        #expect(host.lines.contains("==> building the image \(kit) (\(why)): Node, pnpm and Rust's installer, for Tauri and Cargo apps; ~1 min, once"))
        let (again, _) = try run()
        #expect(builds(again).isEmpty)
    }

    @Test func aNewBaseImageMakesTheKitStale() throws {
        home.images.add(xcode: "26.6", build: "17F113", id: "sha256:new")
        let (host, code) = try run()
        #expect(code == 0 && builds(host).count == 1 && builds(host)[0].words.contains("\(ImageLabel.kitBase)=sha256:new"))
    }

    @Test func aDryRunBuildsNothingAndSaysWhatItWould() throws {
        home.images.remove("\(Self.base)-react-native")
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\n")
        let (host, code) = try run(["--config", home.overlay, "--dry-run"])
        #expect(code == 0 && builds(host).isEmpty && containers(host).isEmpty)
        #expect(host.lines.contains("==> would build the image \(Self.base)-react-native first (there is none yet): Node, pnpm, Ruby, Bundler and hermesc, for React Native and Expo apps; ~3 min, once"))
        #expect(host.output.contains { $0.contains("docker build --builder here --platform linux/arm64 --pull=false ") })
        #expect(host.output.contains { $0.contains("\(Self.base)-react-native xless ship") })
        // with no image at all it shows what there would be
        home.images.remove(Self.base)
        let (none, noneCode) = try run(["--config", home.overlay, "--dry-run"])
        #expect(noneCode == 0 && none.output.contains { $0.contains(" xless:local-arm64-xcode27.0 xless next-build ") })
        #expect(none.lines.contains { $0.hasPrefix("==> note: there is no xless image on this machine") })
        #expect(try refused().hasPrefix("testflight: there is no xless image on this machine"))
    }

    @Test func aBuildThatFailsOrIsNotOnTheLocalImageEndsTheRun() throws {
        home.images.remove("\(Self.base)-tauri")
        home.images.buildFails = true
        var (host, code) = try run()
        #expect(code == 2 && containers(host).isEmpty && host.lines.last == "testflight: \(Self.base)-tauri was not built (docker build exited with code 1); its output is above: it needs buildx (docker buildx version), the network and room on Docker's disk")
        home.images.buildFails = false
        home.images.buildIsElsewhere = true
        (host, code) = try run()
        #expect(code == 2 && containers(host).isEmpty && host.lines.last?.hasPrefix("testflight: \(Self.base)-tauri is not on \(Self.base): ") == true)
        #expect(!home.exists(home.secrets))
    }

    /// A run that signs what is built already needs no kit.
    @Test func onlyTheBuildStepNeedsTheKit() throws {
        home.images.remove("\(Self.base)-tauri")
        let (host, code) = try run(["--config", home.overlay, "--from", "sign"])
        #expect(code == 0 && builds(host).isEmpty && names(host) == [Self.base])
        #expect(host.lines.contains("==> no xcode: is pinned, so the newest Xcode there is an image of: \(Self.base)"))
    }

    // MARK: - A project's own image

    @Test func aProjectsOwnImageIsForTheBuildStepAlone() throws {
        mine()
        for (file, environment) in [("image: mine:1\n", [:]), ("", ["XLESS_IMAGE": "mine:1"]), ("image: other:1\n", ["XLESS_IMAGE": "mine:1"])] as [(String, [String: String])] {
            for type in ["tauri", "react-native"] {
                try home.write("ov/app.yml", "type: \(type)\nsource: ../src\n\(file)")
                let (host, code) = try run(nil, environment)
                #expect(code == 0)
                #expect(names(host) == [Self.base, "mine:1", Self.base], "\(file)\(environment)")
                // its Dockerfile is the project's code: never built here
                #expect(builds(host).isEmpty)
            }
        }
        // nor is the kit's, which nothing would use
        for kit in Kit.allCases { home.images.remove(kit.image(on: LocalImage(name: "", id: "", architecture: "arm64", labels: [ImageLabel.xcode: "26.6"], layers: []))) }
        let (host, code) = try run(nil, ["XLESS_IMAGE": "mine:1"])
        #expect(code == 0 && builds(host).isEmpty && names(host) == [Self.base, "mine:1", Self.base])
    }

    /// A dry run shows the names; a run starts what they were when it checked them.
    @Test func aRunStartsTheImagesItChecked() throws {
        let host = FakeRunHost(answer: home.answer { [images = home.images] step in
            if step.words.contains("next-build") { images.add(xcode: "26.6", build: "17F113", id: "sha256:moved") } // between the steps
            return nil
        })
        #expect(try home.run(["--config", home.overlay], docker: true, host: host, environment: home.files()) == 0)
        #expect(containers(host).map(\.image) == ["sha256:base26.6", "sha256:tauri26.6", "sha256:base26.6"])
        home.images.add(xcode: "26.6", build: "17F113")
        home.images.remove("\(Self.base)-tauri")
        let (built, code) = try run() // the one it just built, too
        #expect(code == 0 && containers(built).map(\.image) == ["sha256:base26.6", "sha256:tauri26.6", "sha256:base26.6"])
        let (dry, _) = try run(["--config", home.overlay, "--dry-run"])
        #expect(dry.output.contains { $0.contains(" \(Self.base) xless tauri next-build ") } && dry.output.contains { $0.contains(" \(Self.base)-tauri xless ship ") })
        #expect(!dry.output.contains { $0.contains(" sha256:") && $0.contains(" run ") })
    }

    /// A project directory is one container, with the secrets; with an image of its own it is two, and the one that builds has none.
    @Test func aProjectDirectoryWithItsOwnImageBuildsWithoutTheSecrets() throws {
        mine()
        let (one, oneCode) = try run([home.project])
        #expect(oneCode == 0 && names(one) == [Self.base] && containers(one)[0].words.contains { $0.contains("dist.pem") })
        #expect(containers(one)[0].line.hasSuffix(" sha256:base26.6 xless ship --platform ios") && containers(one)[0].line.contains(" -w /work "))
        try home.write("proj/xless.yml", "name: App\nimage: mine:1\n")
        let (host, code) = try run([home.project, "--verbose"])
        #expect(code == 0 && host.lines.last == "==> TestFlight delivery finished")
        let steps = containers(host)
        try #require(names(host) == ["mine:1", Self.base])
        #expect(steps[0].line.hasSuffix("-w /work -e XLESS_BUILD_NUMBER sha256:mine xless ship --platform ios --from build --to finalize --verbose"))
        // nothing the build can write is the directory it runs in
        #expect(steps[1].line.contains(" -w / ") && !steps[1].line.contains(" -w /work"))
        #expect(steps[1].line.hasSuffix(" -e XLESS_BUILD_NUMBER sha256:base26.6 xless ship --project /work --platform ios --from sign --to upload --verbose"))
        #expect(!steps[0].words.contains { $0.contains("secrets") || $0.contains(".p8") || $0.contains(".pem") || $0.contains("ASC_") })
        #expect(Set(steps[0].environment.keys).isDisjoint(with: SecretEnvironment.names))
        #expect(steps[1].words.contains { $0.contains("dist.pem") })
        // where the project is on this machine: for the container that uploads, and no other
        #expect(steps.map { $0.words.contains("XLESS_PROJECT_ORIGIN=\(home.project)") } == [false, true])
        for step in steps { #expect(step.words.contains("type=bind,src=\(home.project),dst=/work") && step.environment["XLESS_BUILD_NUMBER"] == steps[1].environment["XLESS_BUILD_NUMBER"]) }
        let (early, earlyCode) = try run([home.project, "--to", "finalize"])
        #expect(earlyCode == 0 && names(early) == ["mine:1"])
        let (late, lateCode) = try run([home.project, "--from", "upload"])
        #expect(lateCode == 0 && names(late) == [Self.base] && containers(late)[0].line.hasSuffix("--from upload --to upload"))
        // what it mounts is the project alone, and holds no secret
        for directory in [home.home, home.root] {
            try Data("name: App\nimage: mine:1\n".utf8).write(to: URL(fileURLWithPath: "\(directory)/xless.yml"))
            #expect(try refused([directory]).contains("would be mounted into the build container, and it is / or holds your home directory; keep the project in its own directory"), "\(directory)")
        }
        try FileManager.default.createDirectory(atPath: "\(home.home)/.cache/xless", withIntermediateDirectories: true)
        try home.write("home/.cache/xless/xless.yml", "name: App\nimage: mine:1\n")
        let kept = FakeRunHost(answer: home.answer()) // (the secrets are in the store)
        #expect(try home.run(["\(home.home)/.cache/xless"], docker: true, host: kept, environment: ["XLESS_DIST_KEY": "DIST-VALUE"], session: "/agent") == 2)
        #expect(containers(kept).isEmpty && !home.exists(home.secrets) && kept.lines.last?.contains("which holds the xless.yml of this run, is inside the project") == true)
        let hidden = FakeRunHost(answer: home.answer())
        hidden.unseen = ["\(home.home)/.cache/xless/run"]
        #expect(try home.run([home.project], docker: true, host: hidden, environment: ["XLESS_DIST_KEY": "DIST-VALUE"], session: "/agent") == 2)
        #expect(containers(hidden).isEmpty && !home.exists(home.secrets) && hidden.lines.last?.contains("cannot tell where \(home.home)/.cache/xless/run is") == true, "\(hidden.lines)")
        let key = try home.write("proj/key.pem", "k")
        #expect(try refused([home.project], ["XLESS_DIST_KEY_FILE": key]).contains("is inside the project \(home.project), which is mounted into the build container"))
        let store = FakeRunHost(answer: home.answer())
        #expect(try home.run([home.project], docker: true, host: store, environment: ["XDG_RUNTIME_DIR": home.project]) == 2)
        #expect(containers(store).isEmpty && store.lines.last?.contains("which is mounted into the build container") == true)
        // xless's own image is what runs without one, too
        try home.write("proj/xless.yml", "name: App\nimage: \(Self.base)\n")
        #expect(try names(run([home.project]).host) == [Self.base])
    }

    /// What docker itself is started with: no secret and no session, whatever it is asked, the questions about images and the build of a
    /// kit included; the two IDs for the containers with the secrets alone, and not in a run that stops before it signs.
    @Test(arguments: [[], ["--to", "finalize"], ["--from", "sign"]])
    func noDockerIsGivenASecret(_ span: [String]) throws {
        mine()
        try home.write("proj/xless.yml", "name: App\nimage: mine:1\n")
        home.images.remove("\(Self.base)-tauri")
        for target in [["--config", home.overlay], [home.project]] {
            let host = FakeRunHost(answer: home.answer())
            let secrets = try home.files().merging(["ASC_KEY_P8": "P8-VALUE"]) { $1 }
            #expect(try home.run(target + span + ["--build-number", "1"], docker: true, host: host, environment: secrets, session: "/agent") == 0)
            if target[0] == "--config", span.first != "--from" { #expect(builds(host).count == 1) }
            let docker = host.allSteps.filter { $0.words[0] == "docker" }
            #expect(docker.contains { $0.words.contains("inspect") } && docker.contains { $0.isCleanUp("ps") })
            let ids = ["ASC_KEY_ID", "ASC_ISSUER_ID"]
            for step in docker {
                let signs = step.isContainer && step.words.contains { $0.contains("dist.pem") }
                #expect(!signs || span.first != "--to", "\(step.line)")
                #expect(Set(step.environment.keys).isDisjoint(with: Set(SecretEnvironment.names + ["XLESS_SESSION"]).subtracting(signs ? ids : [])), "\(step.line)")
                #expect(!step.environment.values.contains { $0.hasSuffix("-VALUE") && $0 != "OWN-VALUE" } && !step.line.contains("-VALUE"), "\(step.line)")
                // (what a password of the user's own is named is known to a run that uploads)
                #expect(span.first == "--to" || step.environment["SOME_PASSWORD"] == nil, "\(step.line)")
            }
        }
    }

    /// A run that is stopped while docker builds a kit, or in the build container of a project with an image of its own.
    @Test(arguments: [true, false])
    func aStopLeavesNothingOfABuild(ofAKit: Bool) async throws {
        mine()
        try home.write("proj/xless.yml", "name: App\nimage: mine:1\n")
        home.images.remove("\(Self.base)-tauri")
        let home = home, left = Notes(), well = home.answer()
        let inBuild = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let host = FakeRunHost { host, step in
            if step.isCleanUp("ps") {
                if home.exists(home.secrets) { left.add("the secrets") }
                return (0, "c0ffee\n")
            }
            guard ofAKit ? step.words.contains("--pull=false") : step.line.contains("--to finalize") else { return well(host, step) }
            if !ofAKit { left.add(home.exists(home.secrets) ? "had secrets" : "had none") }
            inBuild.signal()
            go.wait()
            return (143, "")
        }
        let thread = Thread { _ = try? home.run(ofAKit ? ["--config", home.overlay] : [home.project], docker: true, host: host) }
        thread.start()
        let code = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                inBuild.wait()
                done.resume(returning: host.askToStop(143))
                go.signal()
            }
        }
        #expect(code == 143 && host.killed.count == 1, "the docker that builds")
        #expect(left.lines == (ofAKit ? [] : ["had secrets"]), "the secrets go before anything that may hang")
        #expect(!home.exists(home.secrets) && host.allSteps.last?.line == "docker rm -f c0ffee")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/locks")) ?? []).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: "\(home.home)/.cache/xless/run")) ?? []).isEmpty, "the run's xless.yml")
        #expect(!host.allSteps.contains { $0.line.contains("--from sign") }, "and no step after it")
        if !ofAKit {
            let copy = host.removedOnFault.filter { $0.hasPrefix("\(home.home)/.cache/xless/run/") }
            #expect(copy.count == 2 && copy[1] == "\(copy[0])/xless.yml", "also for a fault that leaves no time for a clean-up: \(copy)")
        }
    }

    /// What the two containers of a project mount is told apart by its bytes: a name may start with a mark that combines with the "/"
    /// before it. A place that cannot be told is refused.
    @Test(arguments: ["\u{301}", "\u{200D}", "\u{FE0F}"])
    func aNameHidesNoSecretFromTheCheckOfTheProject(mark: String) throws {
        mine()
        let project = "\(home.root)/\(mark)proj"
        for directory in [project, "\(project)/\(mark)keys", "\(project)/\(mark)run", "\(project)/\(mark)home"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try home.write("\(mark)proj/xless.yml", "name: App\nimage: mine:1\n")
        let (host, code) = try run([project])
        #expect(code == 0 && names(host) == ["mine:1", Self.base])
        for step in containers(host) { #expect(step.words.contains("type=bind,src=\(project),dst=/work")) }
        #expect(containers(host)[1].words.contains("XLESS_PROJECT_ORIGIN=\(project)"))
        let key = try home.write("\(mark)proj/\(mark)keys/key.pem", "k")
        #expect(try refused([project], ["XLESS_DIST_KEY_FILE": key]).contains("is inside the project \(project), which is mounted into the build container"))
        let store = FakeRunHost(answer: home.answer())
        #expect(try home.run([project], docker: true, host: store, environment: ["XDG_RUNTIME_DIR": "\(project)/\(mark)run"]) == 2)
        #expect(containers(store).isEmpty && store.lines.last?.contains("which is mounted into the build container") == true)
        #expect(try refused([project], ["HOME": "\(project)/\(mark)home"]).contains("or holds your home directory"))
        #expect(try refused([project], ["HOME": "\(home.root)/none"]).contains("cannot tell where "))
        #expect(!home.exists("\(home.root)/none"), "nothing is made there")
    }

    /// What the build writes does not decide in the step with the secrets: both have the xless.yml that was read when the run began.
    @Test func theBuildDoesNotChangeTheConfigurationOfTheStepsWithTheSecrets() throws {
        mine()
        let text = "name: App\nimage: mine:1\n"
        try home.write("proj/xless.yml", text)
        let project = home.project, seen = Notes()
        let host = FakeRunHost(answer: home.answer { step in
            guard step.isContainer else { return nil }
            let mount = step.words.first { $0.hasSuffix(",dst=/work/xless.yml,readonly") }
            let file = String((mount ?? "type=bind,src=,").dropFirst("type=bind,src=".count).prefix { $0 != "," })
            let mode = { (try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int).flatMap { $0 } ?? 0 }
            seen.add("\((try? String(contentsOfFile: file, encoding: .utf8)) ?? "none")|\(String(mode(RunFiles.parent(file)), radix: 8))|\(file.hasPrefix(project) ? "inside" : "outside")")
            // the build: the host's file is written past the mount (on a Mac, under another spelling of its name)
            try? Data("name: Evil\nteamID: EVILEVIL12\n".utf8).write(to: URL(fileURLWithPath: "\(project)/xless.yml"))
            try? Data("evil = 1\n".utf8).write(to: URL(fileURLWithPath: "\(project)/rcodesign.toml"))
            return nil
        })
        #expect(try home.run([home.project], docker: true, host: host, environment: home.files()) == 0)
        #expect(names(host) == ["mine:1", Self.base])
        #expect(seen.lines == ["\(text)|700|outside", "\(text)|700|outside"])
        #expect(host.lines.contains("==> warning: \(home.project)/xless.yml is not what it was when this run began. The run keeps to what it was; look at what changed it before you run this project again"))
        let left = try FileManager.default.subpathsOfDirectory(atPath: home.home).filter { $0.hasSuffix("xless.yml") }
        #expect(left.isEmpty, "nothing is left of it: \(left)")
    }

    /// One reading decides it all: the xless.yml that chose the images is the one that the containers get, whatever the project's holds by then.
    @Test func theContainersHaveTheConfigurationThatChoseTheImages() throws {
        mine()
        let text = "name: App\nimage: mine:1\n"
        try home.write("proj/xless.yml", text)
        let home = home, seen = Notes()
        let host = FakeRunHost(answer: home.answer { step in
            guard step.isContainer else {
                if step.words.contains("inspect") { _ = try? home.write("proj/xless.yml", "name: Evil\nimage: evil:1\n") }
                return nil
            }
            let mount = step.words.first { $0.hasSuffix(",dst=/work/xless.yml,readonly") } ?? "type=bind,src=,"
            seen.add((try? String(contentsOfFile: String(mount.dropFirst("type=bind,src=".count).prefix { $0 != "," }), encoding: .utf8)) ?? "none")
            return nil
        })
        #expect(try home.run([home.project], docker: true, host: host, environment: home.files()) == 0)
        #expect(names(host) == ["mine:1", Self.base] && seen.lines == [text, text])
    }

    /// Docker mounts over what a link names in the container, which may be a file of the image: an xless.yml that is a link is refused
    /// before anything is done.
    @Test func aConfigurationThatIsALinkIsRefused() throws {
        mine()
        let pin = "\(home.project)/xless.yml"
        try FileManager.default.removeItem(atPath: pin)
        try FileManager.default.createSymbolicLink(atPath: pin, withDestinationPath: "shared.yml")
        for text in ["name: App\n", "name: App\nimage: mine:1\n"] {
            try home.write("proj/shared.yml", text)
            for span in [[], ["--to", "finalize"], ["--from", "sign"], ["--dry-run"]] {
                let host = FakeRunHost(answer: home.answer())
                #expect(try home.run([home.project] + span, docker: true, host: host, environment: home.files()) == 2)
                #expect(host.allSteps.allSatisfy { $0.words[0] != "docker" }, "\(host.allSteps.map(\.line))")
                #expect(host.lines.last == "testflight: \(pin) is a link, and the containers get the xless.yml of a project as a file of its own: put the file itself there", "\(host.lines)")
            }
        }
        // natively nothing is mounted
        #expect(try home.run([home.project, "--to", "finalize"], docker: false, host: FakeRunHost()) == 0)
    }

    /// So is one that the build put in its place (on a Mac, under another spelling of its name), before there is a container with a secret.
    @Test(arguments: ["a link", "a directory", "a pipe", "nothing"])
    func aConfigurationThatTheBuildReplacedIsNotMountedWithTheSecrets(by what: String) throws {
        mine()
        let pin = try home.write("proj/xless.yml", "name: App\nimage: mine:1\n")
        let host = FakeRunHost(answer: home.answer { step in
            guard step.isContainer else { return nil }
            try? FileManager.default.removeItem(atPath: pin)
            switch what {
            case "a link": try? FileManager.default.createSymbolicLink(atPath: pin, withDestinationPath: "/usr/local/bin/xless")
            case "a directory": try? FileManager.default.createDirectory(atPath: pin, withIntermediateDirectories: true)
            case "a pipe": mkfifo(pin, 0o600)
            default: break
            }
            return nil
        })
        #expect(try home.run([home.project], docker: true, host: host, environment: home.files()) == 2)
        #expect(names(host) == ["mine:1"], "no container with the secrets")
        #expect(host.lines.last == "testflight: \(pin) is not a file any more: the build replaced it, so nothing is signed. Look at what did that before you run this project again", "\(host.lines)")
        #expect(!home.exists(home.secrets))
    }

    /// Where no container comes after the build, it is said.
    @Test func aConfigurationThatABuildReplacedIsSaid() throws {
        let pin = "\(home.project)/xless.yml"
        for (image, code) in [("", Int32(0)), ("image: mine:1\n", 0), ("image: mine:1\n", 5)] {
            mine()
            try? FileManager.default.removeItem(atPath: pin)
            try home.write("proj/xless.yml", "name: App\n\(image)")
            let host = FakeRunHost(answer: home.answer { step in
                guard step.isContainer else { return nil }
                try? FileManager.default.removeItem(atPath: pin)
                mkfifo(pin, 0o600)
                return code == 0 ? nil : (code, "")
            })
            #expect(try home.run([home.project] + (code == 0 ? ["--to", "finalize"] : []), docker: true, host: host, environment: home.files()) == code)
            #expect(host.lines.contains { $0.hasPrefix("==> warning: \(pin) is not what it was when this run began.") }, "\(host.lines)")
        }
    }

    /// Also where the build is all there is to the run, and in the one container of a project without an image of its own: what the
    /// build leaves in the project is what the next run reads.
    @Test func everyContainerOfAProjectHasItsConfigurationReadOnly() throws {
        for arguments in [[home.project], [home.project, "--to", "finalize"], [home.project, "--from", "sign"]] {
            let (host, code) = try run(arguments)
            #expect(code == 0 && containers(host).count == 1)
            #expect(containers(host)[0].words.contains { $0.hasSuffix(",dst=/work/xless.yml,readonly") }, "\(arguments)")
            #expect(!host.lines.contains { $0.contains("warning") })
        }
        // one container, so there is nothing to keep apart: a project that holds the home directory still runs, as it always did
        try home.write("home/xless.yml", "name: App\n")
        let (host, code) = try run([home.home])
        #expect(code == 0 && containers(host).count == 1 && !containers(host)[0].words.contains { $0.hasSuffix(",dst=/work/xless.yml,readonly") })
        let (dry, _) = try run([home.project, "--dry-run"])
        #expect(dry.output.contains { $0.contains("src=\(home.home)/.cache/xless/run/<run>/xless.yml,dst=/work/xless.yml,readonly") })
        #expect(!home.exists("\(home.home)/.cache/xless/run/<run>"))
    }

    @Test func aMismatchedImageIsRefusedBeforeAnythingRuns() throws {
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\nimage: mine:1\nxcode: \"26.6\"\n")
        #expect(try refused() == "testflight: image: in \(home.overlay) names mine:1, which is not on this machine (images are never pulled from a registry); build it first: docker build -t mine:1 <its folder>")
        home.images.add(xcode: "27.0", build: "27A266a", name: "mine:1", layers: ["mine"])
        #expect(try refused().hasPrefix("testflight: image: in \(home.overlay) names mine:1, which holds the SDK of Xcode 27.0 (27A266a), not Xcode 26.6's; build it on the image of Xcode 26.6: docker build --pull=false --build-arg XLESS_IMAGE=\(Self.base)"))
        mine()
        home.images.change("mine:1") { $0.layers = ["os", "copied-labels"] }
        #expect(try refused().contains("which is not built on \(Self.base) as it is now"))
        mine()
        home.images.change("mine:1") { $0.labels[ImageLabel.version] = "0.1.0" }
        #expect(try refused().contains("which holds xless 0.1.0, and this xless needs"))
        mine()
        home.images.change("mine:1") { $0.architecture = "amd64" }
        #expect(try refused().contains("which is for amd64, not arm64"))
        // a dry run refuses it too
        let (_, code) = try run(["--config", home.overlay, "--dry-run"])
        #expect(code == 2)
    }

    @Test func whatIsWrittenAsAnImageIsNeverAnOptionOfDocker() throws {
        for value in ["\"--privileged\"", "-v", "\"a b\"", "[mine]", "{a: b}"] {
            try home.write("ov/app.yml", "type: tauri\nsource: ../src\nimage: \(value)\n")
            #expect(try refused().contains("image: in \(home.overlay)"), "\(value)")
            #expect(try home.run(["--config", home.overlay, "--dry-run"], docker: true, host: FakeRunHost(answer: home.answer())) == 2, "\(value)")
        }
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nimage:\n")
        #expect(try run().code == 0)
        // natively there is no image
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nimage: \"--privileged\"\n")
        #expect(try home.run(["--config", home.overlay], docker: false, host: FakeRunHost(answer: home.answer()), environment: home.files(), session: "/agent") == 0)
    }

    // MARK: - The old names

    /// It names xless's own image, as without it: no code of the project, nor of a language's toolchain, is next to the keys.
    @Test func theSignImageVariableStillWorksForReactNative() throws {
        mine()
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\n")
        let (host, code) = try run(nil, ["XLESS_SIGN_IMAGE": Self.base])
        #expect(code == 0 && names(host) == [Self.base, "\(Self.base)-react-native", Self.base])
        #expect(host.lines.contains("note: XLESS_SIGN_IMAGE still works, but nothing needs it any more: without it the steps with the secrets run in xless's own image of the same Xcode"))
        for name in ["mine:1", "\(Self.base)-react-native", "\(Self.base)-tauri"] {
            #expect(try refused(nil, ["XLESS_SIGN_IMAGE": name]) == "testflight: XLESS_SIGN_IMAGE names \(name), which has more in it than xless's own image \(Self.base), and the steps with the secrets run in that one alone; unset XLESS_SIGN_IMAGE", "\(name)")
        }
        // nor with what the build's image is made of, when that is another one
        #expect(try refused(nil, ["XLESS_SIGN_IMAGE": "mine:1", "XLESS_IMAGE": "mine:1"]).contains("has more in it than xless's own image"))
        home.images.change("mine:1") { $0.layers = ["x"] }
        #expect(try refused(nil, ["XLESS_SIGN_IMAGE": "mine:1"]).contains("XLESS_SIGN_IMAGE names mine:1, which is not built on \(Self.base) as it is now"))
        // xless's own image of another build of the same Xcode
        home.images.add(xcode: "26.6", build: "17F200", name: "\(Self.base)-17F200", id: "sha256:other")
        #expect(try refused(nil, ["XLESS_SIGN_IMAGE": "\(Self.base)-17F200"]) == "testflight: XLESS_SIGN_IMAGE names \(Self.base)-17F200, and the build's image is \(Self.base) or built on it; unset XLESS_SIGN_IMAGE")
        // the others never had it
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\n")
        #expect(try names(run(nil, ["XLESS_SIGN_IMAGE": "mine:1"]).host) == [Self.base, "\(Self.base)-tauri", Self.base])
    }

    @Test func thePlainTagStillWorksWithANotice() throws {
        for name in [Self.base, "\(Self.base)-tauri"] { home.images.remove(name) }
        home.images.add(xcode: "26.6", build: "17F113", name: "xless:local-arm64")
        let (host, code) = try run([home.project])
        #expect(code == 0 && names(host) == ["xless:local-arm64"])
        #expect(host.lines.contains { $0.hasPrefix("note: xless:local-arm64 is used for Xcode 26.6; the tag without an Xcode goes away") })
        // an image of an older xless has no labels: not used
        home.images.change("xless:local-arm64") { $0.labels = [:] }
        #expect(try refused([home.project]).contains("; those of an older xless, as xless:local-arm64, are not used: xless clean --old removes them)"))
    }
}
