import Foundation
import Testing
import XlessCore
import XlessImages
@testable import XlessRun

/// The Xcode pack of a run in containers: the pinned Xcode's (else the newest), current for this xless, read-only in every container.
@Suite struct RunPackTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    private static let base = "xless:0.14.0-arm64"
    private static let pack262 = ["--mount", "type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/xcodes,readonly", "-e", "XLESS_XCODE=/xcodes/26.2-17C52-arm64"]
    private static let pack270 = ["--mount", "type=volume,src=xless-xcode-27.0-27A266a-arm64,dst=/xcodes,readonly", "-e", "XLESS_XCODE=/xcodes/27.0-27A266a-arm64"]

    private func run(_ arguments: [String]? = nil, _ environment: [String: String] = [:], home: RunHome? = nil) throws -> (host: FakeRunHost, code: Int32) {
        let home = home ?? self.home
        let host = FakeRunHost(answer: home.answer())
        let code = try home.run(arguments ?? ["--config", home.overlay], docker: true, host: host, environment: home.files().merging(environment) { $1 })
        return (host, code)
    }

    private func has(_ words: [String], _ part: [String]) -> Bool {
        words.indices.contains { words[$0...].starts(with: part) }
    }

    /// docker's command in `words` (`docker [--context <name>] <command> …`).
    private func dockerCommand(_ words: [String]) -> String? {
        guard words.first == "docker" else { return nil }
        var i = 1
        while i < words.count, words[i].hasPrefix("-") { i += words[i] == "--context" ? 2 : 1 }
        return i < words.count ? words[i] : nil
    }

    /// Every mount option of a container's arguments, whatever its form (`--mount v`, `--mount=v`, `-v v`, `-v=v`, `--volume v`,
    /// `--volume=v`), and whether it is read-only: `readonly`/`ro` in a `--mount`, `ro` in the options of a `-v`.
    private func mountOptions(_ words: [String]) -> [(value: String, readOnly: Bool)] {
        var found: [(String, Bool)] = []
        for (i, word) in words.enumerated() {
            var value: String?, long = false
            if ["--mount", "-v", "--volume"].contains(word), i + 1 < words.count { value = words[i + 1]; long = word == "--mount" }
            for prefix in ["--mount=", "--volume=", "-v="] where word.hasPrefix(prefix) { value = String(word.dropFirst(prefix.count)); long = prefix == "--mount=" }
            guard let value else { continue }
            let readOnly = long ? value.split(separator: ",").contains { ["readonly", "ro", "readonly=true", "ro=true", "readonly=1", "ro=1"].contains($0) }
                                : value.split(separator: ":").dropFirst(2).first.map { $0.split(separator: ",").contains("ro") } ?? false
            found.append((value, readOnly))
        }
        return found
    }

    /// The option mounts a pack, a pack volume or the store: `store`, the directory store, if any.
    private func mountsAPack(_ value: String, store: String?) -> Bool {
        value.contains("xless-xcode-") || value.contains("dst=/xcodes") || value.contains(":/xcodes") || store.map { value.contains($0) } == true
    }

    @Test func pinChoosesItsPack() throws {
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.2\"\n")
        let (host, code) = try run()
        #expect(code == 0)
        let steps = host.allSteps.filter(\.isContainer)
        try #require(steps.count == 3)
        for step in steps { #expect(has(step.words, Self.pack262) && !has(step.words, Self.pack270), "\(step.line)") }
        #expect(host.lines.contains("==> xcode: \"26.2\" (pinned): Xcode 26.2 (17C52), build \(Self.base)-tauri, signing and upload \(Self.base)"))
        // the pack is named outright: nothing in a container is given the pin to choose with
        #expect(!host.allSteps.contains { $0.environment[XcodeEnvironment.pinVariable] != nil || $0.line.contains(XcodeEnvironment.pinVariable) })
        // no pin: the newest
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\n")
        let (newest, newestCode) = try run()
        #expect(newestCode == 0 && newest.allSteps.filter(\.isContainer).allSatisfy { has($0.words, Self.pack270) })
        #expect(newest.lines.contains { $0.hasPrefix("==> no xcode: is pinned, so the newest Xcode there is a pack of: Xcode 27.0 (27A266a), ") })
        #expect(home.packs.prepared.isEmpty)
    }

    /// The most important property of a run: no container of it can write the pack, which the steps with the secrets read after the
    /// build ran the app's code. Every container (each `docker run` and `docker create`, whatever its options) of a Tauri and of a React
    /// Native overlay run to `upload`, and of a Swift-only project, with xless's image and with one of its own, in both kinds of store.
    @Test(arguments: [false, true])
    func everyContainerGetsThePackReadOnly(directory: Bool) throws {
        var environment: [String: String] = [:]
        var expected = Self.pack262
        let store = directory ? "\(home.root)/xcodes" : nil
        if let store {
            for x in RunHome.xcodes { try home.packs.write(home.packs.current(x.xcode, x.build), in: store) }
            home.packs.removeAll()
            environment["XLESS_XCODES"] = store
            expected = ["--mount", "type=bind,src=\(store)/26.2-17C52-arm64,dst=/xcodes/26.2-17C52-arm64,readonly", "-e", "XLESS_XCODE=/xcodes/26.2-17C52-arm64"]
        }
        home.images.add(xcode: "26.6", build: "17F113", name: "mine:1", layers: ["mine"], id: "sha256:mine")
        // (what to write, the run's arguments, how many containers of steps it starts)
        let matrix: [(file: String, text: String, arguments: [String], steps: Int)] = [
            ("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.2\"\n", ["--config", home.overlay, "--to", "upload"], 3),
            ("ov/app.yml", "type: react-native\nsource: ../src\nxcode: \"26.2\"\n", ["--config", home.overlay, "--to", "upload"], 3),
            ("proj/xless.yml", "name: App\nxcode: \"26.2\"\n", [home.project], 1),
            ("proj/xless.yml", "name: App\nxcode: \"26.2\"\n", [home.project, "--to", "finalize"], 1),
            ("proj/xless.yml", "name: App\nxcode: \"26.2\"\nimage: mine:1\n", [home.project], 2),
        ]
        var all: [RunStep] = []
        for row in matrix {
            try home.write(row.file, row.text)
            let (host, code) = try run(row.arguments, environment)
            #expect(code == 0, "\(row.arguments): \(host.lines)")
            let containers = host.allSteps.filter { ["run", "create"].contains(dockerCommand($0.words)) }
            let steps = containers.filter { step in !step.words.contains { $0.contains("--- xless pack") } }
            #expect(steps.count == row.steps, "\(row.text) \(row.arguments): \(steps.map(\.line))")
            for step in steps {
                // a step: the pack, named outright, once
                #expect(has(step.words, expected), "\(step.line)")
                #expect(step.words.filter { $0.hasPrefix("XLESS_XCODE=") }.count == 1, "\(step.line)")
            }
            all += containers
        }
        #expect(!all.isEmpty)
        for step in all {
            // whatever mounts a pack, a pack volume or the store, in any form, read-only
            for mount in mountOptions(step.words) where mountsAPack(mount.value, store: store) {
                #expect(mount.readOnly, "\(mount.value) in \(step.line)")
            }
            #expect(!step.isPackSetup && !step.words.contains { $0.contains("chown") }, "nothing was prepared: \(step.line)")
            if step.words.contains(where: { $0.contains("--- xless pack") }) {
                // the reading of the volumes: no network, nothing of a project
                #expect(!directory && step.words.contains("--network") && step.words.contains("none") && !step.words.contains { $0.contains("/work") || $0.contains("/source") }, "\(step.line)")
            }
        }
        // the census sees a writable -v of a pack, and a container without --rm
        let planted = ["docker", "create", "-v", "xless-xcode-26.2-17C52-arm64:/xcodes", "img"]
        #expect(dockerCommand(planted) == "create" && mountOptions(planted).contains { mountsAPack($0.value, store: nil) && !$0.readOnly })
        #expect(mountOptions(["docker", "run", "--volume=xless-xcode-1:/x:ro"]).allSatisfy { $0.readOnly })
    }

    @Test func stalePartIsPreparedFromTheCachedExport() throws {
        let volume = "xless-xcode-27.0-27A266a-arm64"
        let current = try #require(home.packs.manifest(volume))
        home.packs.change(volume) { $0.parts["swift-build"] = String(repeating: "0", count: 64) }
        try home.export("27.0", "27A266a")
        // (the secrets are in the store: the run writes them for its steps)
        let host = FakeRunHost(answer: home.answer())
        let code = try home.run(["--config", home.overlay], docker: true, host: host, environment: ["XLESS_DIST_KEY": "DIST-VALUE"], session: "/agent")
        #expect(code == 0, "\(host.lines)")
        #expect(home.packs.manifest(volume) == current, "the part that was stale is prepared")
        let runs = host.allSteps.filter(\.isDockerRun)
        let setup = try #require(runs.firstIndex { $0.isPackSetup })
        let first = try #require(runs.firstIndex { $0.isContainer })
        #expect(setup < first && runs.filter(\.isPackSetup).count == 1)
        // before it, only the reading of the volumes (and the check that the volume is the user's)
        #expect(runs[..<setup].allSatisfy { $0.words.contains("--network") && $0.words.contains("none") })
        // Task 11's container: the export read-only, the store writable, nothing of a project, no secret; the run's label
        let words = runs[setup].words
        // (the export's path as Foundation spells it: /private/var is /var)
        let export = URL(fileURLWithPath: "\(home.exports)/xcode27.0-27A266a").standardizedFileURL.path
        #expect(has(words, ["--mount", "type=bind,src=\(export),dst=/cache/xless/sdk/xcode27.0-27A266a,readonly"]), "\(words)")
        #expect(has(words, ["--mount", "type=volume,src=\(volume),dst=/xcodes", Self.base, "xless", "setup", "--sdk", "/cache/xless/sdk/xcode27.0-27A266a"]))
        #expect(words.contains { $0.hasPrefix("xless.run=4242.") } && !words.contains("--init"))
        #expect(!words.contains { $0.contains("/work") || $0.contains("/source") || $0.contains("/config") || $0.contains("secrets") || $0.contains(".pem") || $0.contains(".p8") })
        #expect(Set(runs[setup].environment.keys).isDisjoint(with: SecretEnvironment.names + ["XLESS_SESSION", "SOME_PASSWORD"]))
        // before any secret is written
        let materialize = try #require(host.allSteps.firstIndex { $0.words.contains("materialize") && !$0.words.contains("--check") })
        #expect(host.allSteps.firstIndex(of: runs[setup])! < materialize)
        // it said what, why, and how long
        #expect(host.lines.contains { $0.hasPrefix("==> preparing the pack 27.0-27A266a-arm64 of Xcode 27.0 (27A266a) first (the pack 27.0-27A266a-arm64 in the volume \(volume) is not current (its swift-build part was prepared by another recipe (000000000000, this xless's is ") && $0.hasSuffix("): its swift-build part (~10 min: Swift Build compiled, ~1 GB of sources and objects in a temporary directory), from the SDK export \(home.exports)/xcode27.0-27A266a") }, "\(host.lines)")
        #expect(host.lines.contains("==> the pack 27.0-27A266a-arm64 is current"))
        for step in runs where step.isContainer { #expect(has(step.words, Self.pack270)) }
        // once current, a run prepares nothing
        let (again, _) = try run()
        #expect(!again.allSteps.contains { $0.isPackSetup })
    }

    /// A pack that a running container has mounted (another run's build, or a setup) is not replaced under it: the run stops and
    /// names it; once nothing uses it, the run prepares it. A volume is asked about by its name.
    @Test func aPackInUseIsNotReplaced() throws {
        let volume = "xless-xcode-27.0-27A266a-arm64"
        home.packs.change(volume) { $0.parts["swift-build"] = String(repeating: "0", count: 64) }
        let stale = home.packs.manifest(volume)
        try home.export("27.0", "27A266a")
        home.packs.running = [.init(name: "busy_build", run: "77.1700000000", volumes: [volume]), .init(name: "other", volumes: ["xless-xcode-26.2-17C52-arm64"])]
        let (host, code) = try run()
        #expect(code == 2, "\(host.lines)")
        #expect(host.lines.last == "testflight: the pack 27.0-27A266a-arm64 in the volume \(volume) is used by a running container: busy_build (xless:0.14.0-arm64-tauri); "
            + "preparing it now would replace it under it; wait for that run to end, or stop it (docker stop busy_build), then run this again", "\(host.lines)")
        #expect(!host.allSteps.contains { $0.isPackSetup || $0.isContainer } && home.packs.manifest(volume) == stale && !home.exists(home.secrets))
        #expect(home.packs.askedUsers.contains(["ps", "--filter", "volume=\(volume)", "--format", "{{.Names}}\t{{.Image}}\t{{.Label \"xless.run\"}}"]))
        // the container gone, it prepares
        home.packs.running = [.init(name: "other", volumes: ["xless-xcode-26.2-17C52-arm64"])]
        let (again, againCode) = try run()
        #expect(againCode == 0, "\(again.lines)")
        #expect(again.allSteps.contains { $0.isPackSetup } && home.packs.manifest(volume)?.parts["swift-build"] != stale?.parts["swift-build"])
    }

    /// A directory store: the running containers' mounts are inspected, once, for the pack's directory (or the store, or what holds it).
    @Test func aPackInUseInADirectoryStoreIsNotReplaced() throws {
        let store = "\(home.root)/xcodes"
        try home.packs.write(home.packs.current("26.2", "17C52", parts: [.sdk]), in: store)
        try home.export("26.2", "17C52")
        try home.write("proj/xless.yml", "name: App\nxcode: \"26.2\"\n")
        home.packs.running = [.init(name: "elsewhere", directories: ["/somewhere/else"]), .init(name: "builds", directories: ["\(store)/26.2-17C52-arm64"])]
        let (host, code) = try run([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(code == 2, "\(host.lines)")
        #expect(host.lines.last?.hasPrefix("testflight: the pack 26.2-17C52-arm64 in \(store)/26.2-17C52-arm64 is used by a running container: builds (xless:0.14.0-arm64-tauri); ") == true, "\(host.lines)")
        #expect(home.packs.prepared.isEmpty)
        #expect(home.packs.askedUsers.contains { $0 == ["ps", "-q"] } && home.packs.askedUsers.contains { $0.first == "inspect" && $0.suffix(2) == ["id0", "id1"] })
        // a container of another directory does not hold it
        home.packs.running = [.init(name: "elsewhere", directories: ["/somewhere/else"])]
        let (again, againCode) = try run([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(againCode == 0 && home.packs.prepared == ["type=bind,src=\(store),dst=/xcodes"], "\(again.lines)")
    }

    @Test func stalePartWithoutExportStops() throws {
        home.packs.change("xless-xcode-27.0-27A266a-arm64") { $0.parts["swift-build"] = "old" }
        let (host, code) = try run()
        #expect(code == 2)
        let last = host.lines.last ?? ""
        #expect(last.hasPrefix("testflight: the pack 27.0-27A266a-arm64 in the volume xless-xcode-27.0-27A266a-arm64 is not current (its swift-build part was prepared by another recipe"), "\(last)")
        #expect(last.contains("and there is no SDK export of Xcode 27.0 for arm64 in \(home.exports) to prepare it from; xless setup --docker --xcode <path to Xcode 27.0's .xip or Xcode.app>"), "\(last)")
        #expect(!host.allSteps.contains { $0.isContainer || $0.isPackSetup } && !home.exists(home.secrets))
        // a pin with no pack at all, the same
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.3\"\n")
        let (none, noneCode) = try run()
        #expect(noneCode == 2 && none.lines.last?.hasPrefix("testflight: \(home.overlay) pins xcode: \"26.3\", but there is no pack of Xcode 26.3 for arm64 in the pack volumes") == true, "\(none.lines)")
        #expect(none.lines.last?.hasSuffix("; xless setup --docker --xcode <path to Xcode 26.3's .xip or Xcode.app>") == true)
    }

    /// A pack of a directory store that a native setup prepared with its SDK alone gets Swift Build, by the image's setup.
    @Test func missingSwiftBuildIsAdded() throws {
        let store = "\(home.root)/xcodes"
        try home.packs.write(home.packs.current("26.2", "17C52", parts: [.sdk]), in: store)
        try home.export("26.2", "17C52")
        try home.write("proj/xless.yml", "name: App\nxcode: \"26.2\"\n")
        let (host, code) = try run([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(code == 0, "\(host.lines)")
        #expect(home.packs.prepared == ["type=bind,src=\(store),dst=/xcodes"], "the store, writable, in the setup container alone")
        #expect(host.lines.contains { $0.contains("is not current (it has no swift-build part)): its swift-build part (~10 min: Swift Build compiled") && !$0.contains("its sdk part") })
        let pack = try #require(try XcodePack.open(URL(fileURLWithPath: "\(store)/26.2-17C52-arm64")))
        #expect(pack.has(.swiftBuild))
        let step = try #require(host.allSteps.first { $0.isContainer })
        #expect(has(step.words, ["--mount", "type=bind,src=\(store)/26.2-17C52-arm64,dst=/xcodes/26.2-17C52-arm64,readonly", "-e", "XLESS_XCODE=/xcodes/26.2-17C52-arm64"]))
    }

    /// Spec goal 4: a new xless whose recipes are the same prepares nothing. The images are the new one's; the packs are the ones there.
    @Test func newXlessVersionOverACurrentPackPreparesNothing() throws {
        let newer = try RunHome(version: "0.15.0")
        newer.packs.removeAll()
        for x in RunHome.xcodes { newer.packs.add(try #require(home.packs.manifest("xless-xcode-\(x.xcode)-\(x.build)-arm64"))) }
        try newer.export("27.0", "27A266a")
        let (host, code) = try run(nil, [:], home: newer)
        #expect(code == 0, "\(host.lines)")
        #expect(!host.allSteps.contains { $0.isPackSetup } && newer.packs.prepared.isEmpty)
        #expect(host.allSteps.filter(\.isContainer).allSatisfy { has($0.words, Self.pack270) })
        #expect(host.lines.contains("==> no xcode: is pinned, so the newest Xcode there is a pack of: Xcode 27.0 (27A266a), build xless:0.15.0-arm64-tauri, signing and upload xless:0.15.0-arm64"))
    }

    /// A pack of an Xcode this xless has no recipe for: said, and used as it is; nothing is prepared.
    @Test func aPackOfAnXcodeWithoutARecipeIsSaidAndUsed() throws {
        home.packs.add(PackManifest(format: PackRecipe.format, xcode: "99.0", build: "99Z99", arch: "arm64", swift: "6.4.0", mode: .own, parts: ["sdk": "s", "swift-build": "w"]))
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"99.0\"\n")
        let (host, code) = try run()
        #expect(code == 0, "\(host.lines)")
        #expect(host.lines.contains("==> note: the pack 99.0-99Z99-arm64 in the volume xless-xcode-99.0-99Z99-arm64 is of Xcode 99.0 (99Z99), which this xless has no recipe for "
            + "(versions.env maps it to no Swift toolchain, XCODE_SWIFT_99Z99): it is used as it is, and whether it is current is not checked"), "\(host.lines)")
        #expect(!host.allSteps.contains { $0.isPackSetup } && host.allSteps.filter(\.isContainer).allSatisfy { $0.words.contains("XLESS_XCODE=/xcodes/99.0-99Z99-arm64") })
    }

    /// A share that lacks a recipe input cannot tell whether a pack is current: the run stops with the error, before any container.
    @Test func aShareWithoutARecipeInputStops() throws {
        try FileManager.default.removeItem(at: home.share.appendingPathComponent("scripts/pack-swift-build.sh"))
        let (host, code) = try run()
        #expect(code == 2, "\(host.lines)")
        #expect(host.lines.last == "testflight: cannot tell whether the pack 27.0-27A266a-arm64 in the volume xless-xcode-27.0-27A266a-arm64 is current: "
            + "xless's scripts/pack-swift-build.sh is missing from \(home.share.path); install xless again, or set XLESS_SHARE to its share directory", "\(host.lines)")
        #expect(!host.allSteps.contains { $0.isContainer || $0.isPackSetup } && !home.exists(home.secrets))
    }

    @Test func dryRunWithoutAPackGoesOn() throws {
        home.packs.removeAll()
        try home.write("ov/app.yml", "type: tauri\nsource: ../src\nxcode: \"26.2\"\n")
        let (host, code) = try run(["--config", home.overlay, "--dry-run"])
        #expect(code == 0, "\(host.lines)")
        #expect(host.lines.contains("==> note: \(home.overlay) pins xcode: \"26.2\", but there is no pack of Xcode 26.2 for arm64 in the pack volumes (docker volume ls --filter label=org.xless.pack), and there is no SDK export of Xcode 26.2 for arm64 in \(home.exports) to prepare it from: a run would stop here (xless setup --docker --xcode <path to Xcode 26.2's .xip or Xcode.app>)"), "\(host.lines)")
        #expect(host.allSteps.allSatisfy { !$0.isDockerRun }, "a dry run starts no container")
        #expect(host.output.contains { $0.contains(" xless ship ") && $0.contains("XLESS_XCODE=/xcodes/26.2-17C52-arm64") })
        // with the export, it shows the preparation
        try home.export("26.2", "17C52")
        let (prepares, preparesCode) = try run(["--config", home.overlay, "--dry-run"])
        #expect(preparesCode == 0 && prepares.allSteps.allSatisfy { !$0.isDockerRun })
        #expect(prepares.lines.contains { $0.hasPrefix("==> would prepare the pack 26.2-17C52-arm64 of Xcode 26.2 (17C52) first (there is no pack of Xcode 26.2 for arm64 in ")
            && $0.contains("): its sdk part (~3 min: the Swift toolchain (~2 min; a ~1.1 GB download, ~4 GB unpacked) and the Darwin SDK (~1 min; ~3 GB on disk)) and its swift-build part (~10 min: ") })
        #expect(prepares.output.contains("docker volume create --label org.xless.pack=true xless-xcode-26.2-17C52-arm64 "), "\(prepares.output)")
        #expect(prepares.output.contains { $0.contains(" xless setup --sdk /cache/xless/sdk/xcode26.2-17C52") && $0.contains("type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/xcodes ") })
        #expect(home.packs.manifest("xless-xcode-26.2-17C52-arm64") == nil && home.packs.prepared.isEmpty)
    }
}
