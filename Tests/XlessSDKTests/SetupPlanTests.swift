import Testing
import Foundation
import Crypto
@testable import XlessSDK
@testable import XlessCore
@testable import XlessImages

private let xcode27 = KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
private let xcode26 = KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: [])

/// A share directory whose versions.env names 27A266a the default Xcode, as the repository's does, with the files the pack's
/// recipe hashes read and the kits' Dockerfiles.
private let share: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setup-plan-share-\(UUID())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! "XCODE_VERSION=27.0\nXCODE_BUILD=27A266a\nXLESS_VERSION=0.14.0\n".write(to: dir.appendingPathComponent("versions.env"), atomically: true, encoding: .utf8)
    for kit in Kit.allCases {
        try! FileManager.default.createDirectory(at: kit.directory(share: dir), withIntermediateDirectories: true)
        try! "FROM \(kit.rawValue)\n".write(to: kit.directory(share: dir).appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    }
    for path in ["scripts/fit-toolchain.sh", "scripts/pack-swift-build.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
                 "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt", "docker/toolchain/target-os/27A266a.txt",
                 "docker/toolchain/target-os/17C52.txt"] {
        let url = dir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(path.utf8).write(to: url)
    }
    return dir
}()
private let table: [String: String] = [
    "SWIFT_VERSION": "6.4.0", "XTOOL_VERSION": "1.21.0", "SWIFT_IMAGE": "swift:6.4.0-jammy@sha256:abc", "SWB_TAG": "swift-6.4.0-RELEASE",
    "XCODE_SWIFT_27A266a": "6.4.0", "XCODE_SWIFT_17C52": "6.2.3",
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64": "https://example.com/s640-a.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64": "s640a",
    "SWIFT_TOOLCHAIN_6_4_0_URL_X86_64": "https://example.com/s640-x.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_X86_64": "s640x",
    "SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64": "https://example.com/s623-a.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64": "s623a",
]
private let cache = URL(fileURLWithPath: "/cache/xless")
private let bins = ["arm64": URL(fileURLWithPath: "/tmp/bin-arm64/xless"), "amd64": URL(fileURLWithPath: "/tmp/bin-amd64/xless")]
private let xipSource: XcodeSource.Identified = (xcode27, .xip, URL(fileURLWithPath: "/home/u/Downloads/My Xcode.xip"))
private let user = "\(getuid()):\(getgid())"
private let script = share.appendingPathComponent("scripts/docker-images.sh").path

/// The manifest of a current pack of `x` on `arch`, as this xless's recipes make it (a part can be given another hash).
private func current(_ x: KnownXcode = xcode27, arch: String = "arm64", sdk: String? = nil, swiftBuild: String? = nil) -> PackManifest {
    let swift = table["XCODE_SWIFT_\(x.build)"]!
    return PackManifest(format: PackRecipe.format, xcode: XcodeVersion.canonical(x.shortVersion), build: x.build, arch: arch, swift: swift,
                        mode: PackRecipe.mode(swift: swift, table: table),
                        parts: ["sdk": sdk ?? (try! PackRecipe.hash(.sdk, build: x.build, arch: arch, table: table, share: share)),
                                "swift-build": swiftBuild ?? (try! PackRecipe.hash(.swiftBuild, build: x.build, arch: arch, table: table, share: share))])
}

/// A docker with the images of `images`, the pack volumes of `volumes` (a volume's manifest, or nil: it holds none), and one
/// container that reads them (as PackVolumes runs it).
private final class Fake: @unchecked Sendable {
    var images: Set<String> = []
    var volumes: [String: PackManifest?] = [:]
    private(set) var asked: [[String]] = []

    func answer(_ words: [String]) -> (code: Int32, output: String) {
        asked.append(words)
        if words.starts(with: ["image", "ls"]) { return (0, images.sorted().joined(separator: "\n") + "\n") }
        if words.starts(with: ["image", "inspect"]) {
            let name = words.last!
            guard images.contains(name) else { return (1, "") }
            let arch = name.hasSuffix("amd64") ? "amd64" : "arm64"
            let json: [String: Any] = ["Id": "sha256:id-\(name)", "Architecture": arch,
                                       "Config": ["Labels": ["org.xless.image": "true", "dev.xless.arch": arch, "dev.xless.version": "0.14.0", "dev.xless.image": "v0.14.0-0123456789ab"]],
                                       "RootFS": ["Type": "layers", "Layers": ["a", "b"]]]
            return (0, String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        }
        if words.starts(with: ["volume", "ls"]) { return (0, volumes.keys.sorted().map { $0 + "\n" }.joined()) }
        if words.first == "run" {
            var out = ""
            let mounted = words.filter { $0.hasPrefix("type=volume,") }.map { String($0.split(separator: ",")[1].dropFirst(4)) }
            for (i, volume) in mounted.enumerated() {
                out += "\n\(PackVolumes.marker) /v/\(i)/\(volume.dropFirst(PackVolumes.prefix.count))/pack.json\n"
                if let m = volumes[volume] ?? nil {
                    let enc = JSONEncoder()
                    out += String(decoding: try! enc.encode(m), as: UTF8.self) + "\n"
                }
            }
            return (0, out)
        }
        return (1, "")
    }

    var reads: Int { asked.filter { $0.first == "run" }.count }
}

private func plan(_ source: XcodeSource.Identified? = xipSource, archs: [String] = ["arm64"], docker: Fake = Fake(), store: PackStore = .volumes,
                  read: Bool = true, rootless: Bool = false, reexport: Bool = false, kits: [Kit] = [], binaries: [String: URL] = bins,
                  environment: [String: String] = [:], existing: @escaping (URL) -> Bool = { _ in false }) -> SetupPlan.Docker {
    try! SetupPlan.make(source: source, archs: archs, hostArch: "arm64", share: share, cacheRoot: cache, table: table, xlessBinaries: binaries,
                        store: store, docker: { docker.answer($0) }, readVolumes: read, rootless: rootless, reexport: reexport, kits: kits,
                        builder: "colima", environment: environment, existing: existing)
}

/// Each step's kind, from its argv: image (docker-images.sh), volume (create), owner (the volume made the user's), pack (the
/// image's xless setup), kit.
private func kinds(_ steps: [SetupStep]) -> [String] {
    steps.map { s in
        if s.argv.first?.hasSuffix("scripts/docker-images.sh") == true { return s.argv[1] }
        if s.argv.starts(with: ["docker", "volume", "create"]) { return "volume" }
        if s.argv.starts(with: ["docker", "run"]), s.argv.contains("chown") || s.argv.contains(where: { $0.contains("chown") }) { return "owner" }
        if s.argv.starts(with: ["docker", "run"]), s.argv.suffix(4).contains("setup") { return "pack" }
        if s.argv.starts(with: ["docker", "build"]) { return "kit" }
        return "?"
    }
}

private func pack(_ d: SetupPlan.Docker) -> SetupStep { d.steps.first { kinds([$0]) == ["pack"] }! }

/// The values of `option` in `argv` (`--mount`, `-e`).
private func values(_ option: String, _ argv: [String]) -> [String] {
    argv.indices.filter { argv[$0] == option && $0 + 1 < argv.count }.map { argv[$0 + 1] }
}

@Test func imageThenPackThenKits() {
    let d = plan(kits: [.tauri])
    #expect(kinds(d.steps) == ["image", "volume", "owner", "pack", "kit"])
    // The image takes this arch's linux xless, and no Xcode.
    #expect(d.steps[0].title == "xless:0.14.0-arm64")
    #expect(d.steps[0].argv == [script, "image", "--arch", "arm64", "--xless-bin", "/tmp/bin-arm64/xless"])
    #expect(d.steps[1].argv == ["docker", "volume", "create", "--label", "org.xless.pack=true", "xless-xcode-27.0-27A266a-arm64"])
    // The volume is made the calling user's, unless it is writable for them already; its failure stops the setup.
    let owner = d.steps[2]
    #expect(owner.argv.starts(with: ["docker", "run", "--rm", "--pull=never", "--platform", "linux/arm64", "--network", "none",
                                     "--mount", "type=volume,src=xless-xcode-27.0-27A266a-arm64,dst=/xcodes", "xless:0.14.0-arm64", "sh", "-c"]))
    #expect(Array(owner.argv.suffix(3)) == ["sh", "\(getuid())", "\(getgid())"])
    #expect(!owner.argv.contains("--user"))
    // The pack: the image's own setup, from the .xip, into the volume.
    #expect(pack(d).argv == ["docker", "run", "--rm", "--pull=never", "--platform", "linux/arm64", "--user", user, "-e", "HOME=/tmp",
                             "--mount", "type=bind,src=/home/u/Downloads/My Xcode.xip,dst=/xcode/My Xcode.xip,readonly",
                             "--mount", "type=bind,src=/cache/xless/sdk/xcode27.0-27A266a,dst=/cache/xless/sdk/xcode27.0-27A266a",
                             "-e", "XDG_CACHE_HOME=/cache",
                             "--mount", "type=volume,src=xless-xcode-27.0-27A266a-arm64,dst=/xcodes",
                             "xless:0.14.0-arm64", "xless", "setup", "--xcode", "/xcode/My Xcode.xip"])
    // The export lands in the host's cache: its directory is made first, as the calling user.
    #expect(pack(d).action == .packRun(SetupStep.PackRun(directories: [cache.appendingPathComponent("sdk/xcode27.0-27A266a")], unlessCurrent: nil)))
    #expect(pack(d).estimate.contains("~6 min"))
    // The kit is built on the image built before it.
    #expect(d.steps[4].action == .kit(.tauri, arch: "arm64"))
    #expect(d.steps[4].argv.contains("XLESS_IMAGE=xless:0.14.0-arm64") && d.steps[4].argv.contains("dev.xless.kit.base=<the ID of xless:0.14.0-arm64>"))
    for s in d.steps { #expect(!s.title.isEmpty && !s.estimate.isEmpty) }
    // Nothing runs on the host but the image's script: no export, no toolchain-meta.json.
    #expect(!d.steps.contains { $0.argv.contains("xtool") || $0.argv.starts(with: ["xless", "sdk", "meta"]) })
}

@Test func anImageThatIsHereIsNotBuiltAgain() {
    let docker = Fake()
    docker.images = ["xless:0.14.0-arm64"]
    let d = plan(docker: docker, kits: [.reactNative])
    #expect(kinds(d.steps) == ["volume", "owner", "pack", "kit"])
    // The kit is planned on the image as it is: its ID is known.
    let recipe = try! Kit.reactNative.recipe(share: share)
    #expect(d.steps[3].argv == ["docker", "build", "--builder", "colima", "--platform", "linux/arm64", "--pull=false", "--provenance=false", "--build-arg", "XLESS_IMAGE=xless:0.14.0-arm64",
                                "--label", "dev.xless.kit=react-native", "--label", "dev.xless.kit.base=sha256:id-xless:0.14.0-arm64", "--label", "dev.xless.kit.recipe=\(recipe)",
                                "-t", "xless:0.14.0-arm64-react-native", "\(share.path)/docker/react-native"])
    #expect(d.steps[3].title == "xless:0.14.0-arm64-react-native: Node, pnpm, Ruby, Bundler and hermesc, for React Native and Expo apps")
    // A checkout's xless with no binary given: the image compiles it (no --xless-bin).
    #expect(plan(binaries: [:]).steps[0].argv == [script, "image", "--arch", "arm64"])
}

@Test func currentPackIsSkipped() {
    let docker = Fake()
    docker.images = ["xless:0.14.0-arm64"]
    docker.volumes = ["xless-xcode-27.0-27A266a-arm64": current()]
    let d = plan(docker: docker, kits: [.tauri])
    #expect(kinds(d.steps) == ["kit"])
    #expect(d.notes.contains { $0.contains("the pack 27.0-27A266a-arm64") && $0.contains("is current") })
    #expect(docker.reads == 1)
    // A new xless with the same recipes: the same. One part stale: the image's setup prepares it (only it), and says why.
    docker.volumes = ["xless-xcode-27.0-27A266a-arm64": current(swiftBuild: "0ld")]
    let stale = plan(docker: docker)
    #expect(kinds(stale.steps) == ["owner", "pack"])
    #expect(stale.notes.contains { $0.contains("swift-build part was prepared by another recipe") && !$0.contains("sdk part") })
    #expect(pack(stale).action == .packRun(SetupStep.PackRun(directories: [cache.appendingPathComponent("sdk/xcode27.0-27A266a")], unlessCurrent: nil)))
    // A volume that holds no pack yet: prepared, and not created again.
    docker.volumes = ["xless-xcode-27.0-27A266a-arm64": Optional<PackManifest>.none]
    #expect(kinds(plan(docker: docker).steps) == ["owner", "pack"])
    // --reexport: the export is asked for, so the container runs even over a current pack.
    docker.volumes = ["xless-xcode-27.0-27A266a-arm64": current()]
    let again = plan(docker: docker, reexport: true)
    #expect(kinds(again.steps) == ["owner", "pack"] && pack(again).argv.suffix(3) == ["--xcode", "/xcode/My Xcode.xip", "--reexport"])
}

@Test func aPackThatCannotBeReadYetIsCheckedWhenTheStepRuns() {
    // The image is built by this setup (a new xless), or this is a dry run: the volume is read once the image is there.
    let docker = Fake()
    docker.volumes = ["xless-xcode-27.0-27A266a-arm64": current()]
    let d = plan(docker: docker)
    #expect(kinds(d.steps) == ["image", "owner", "pack"])
    #expect(docker.reads == 0)
    let check = SetupStep.PackCheck(volume: "xless-xcode-27.0-27A266a-arm64", pack: "27.0-27A266a-arm64", arch: "arm64", image: "xless:0.14.0-arm64",
                                    build: "27A266a", expected: current().parts)
    #expect(d.steps[1].action == .packRun(SetupStep.PackRun(directories: [], unlessCurrent: check)))
    #expect(pack(d).action == .packRun(SetupStep.PackRun(directories: [cache.appendingPathComponent("sdk/xcode27.0-27A266a")], unlessCurrent: check)))
    #expect(pack(d).title.contains("unless the pack is current"))
    #expect(d.notes.contains { $0.contains("read once the image xless:0.14.0-arm64 is built") })
    // A dry run never starts the reading container, even with the image here.
    docker.images = ["xless:0.14.0-arm64"]
    let dry = plan(docker: docker, read: false)
    #expect(kinds(dry.steps) == ["owner", "pack"] && docker.reads == 0)
    #expect(dry.notes.contains { $0.contains("read when the setup runs") })
    // What the step reads: current, or why not.
    #expect(SetupPlan.staleness(current(), check: check).isEmpty)
    #expect(SetupPlan.staleness(current(sdk: "x"), check: check) == ["its sdk part was prepared by another recipe (x, this xless's is \(current().parts["sdk"]!.prefix(12)))"])
    #expect(SetupPlan.staleness(nil, check: check) == ["it holds no pack yet"])
    var other = current(); other.format = 0
    #expect(SetupPlan.staleness(other, check: check).first?.contains("format 0") == true)
    var noSwiftBuild = current(); noSwiftBuild.parts["swift-build"] = nil
    #expect(SetupPlan.staleness(noSwiftBuild, check: check) == ["it has no swift-build part"])
}

@Test func packContainerHasNoProjectAndNoSecret() {
    let env = ["ASC_KEY_ID": "K", "XLESS_SIGN_P12_PASSWORD": "p", "HOME": "/home/u", "PWD": "/home/u/project", "XLESS_SETUP_NATIVE_GB": "0", "SSH_AUTH_SOCK": "/s"]
    for source in [xipSource, (xcode27, .export, URL(fileURLWithPath: "/exports/x27")) as XcodeSource.Identified] {
        let argv = pack(plan(source, environment: env)).argv
        // Exactly the mounts of the pack: the Xcode (read-only), its export, the store.
        let mounts = values("--mount", argv).map { m in m.split(separator: ",").first { $0.hasPrefix("dst=") }.map { String($0.dropFirst(4)) } ?? m }
        #expect(Set(mounts).isSubset(of: ["/xcode/My Xcode.xip", "/cache/xless/sdk/xcode27.0-27A266a", "/xcodes"]), "\(mounts)")
        #expect(!argv.contains("-v") && !argv.contains("--volume") && !argv.contains("-w") && !argv.contains("--env-file"))
        #expect(!argv.contains { $0.contains("/work") || $0.contains("/secrets") || $0.contains("/home/u/project") || $0.contains("SSH_AUTH_SOCK") })
        // Only HOME, the cache, and the host's disk figures go in: nothing of the environment else.
        #expect(values("-e", argv) == ["HOME=/tmp", "XDG_CACHE_HOME=/cache", "XLESS_SETUP_NATIVE_GB=0"])
    }
}

@Test func directoryStoreIsABindMount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setup-plan-store-\(UUID())")
    let d = plan(store: .directory(dir))
    #expect(kinds(d.steps) == ["image", "pack"])
    #expect(values("--mount", pack(d).argv).last == "type=bind,src=\(dir.path),dst=/xcodes")
    // The directory is made first, as the calling user (and so is the export's).
    #expect(pack(d).action == .packRun(SetupStep.PackRun(directories: [cache.appendingPathComponent("sdk/xcode27.0-27A266a"), dir], unlessCurrent: nil)))
    // A current pack there, read on the host: nothing to do.
    let place = dir.appendingPathComponent("27.0-27A266a-arm64")
    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
    try current().write(to: place.appendingPathComponent("pack.json"))
    let docker = Fake()
    docker.images = ["xless:0.14.0-arm64"]
    let here = plan(docker: docker, store: .directory(dir), read: false, existing: { FileManager.default.fileExists(atPath: $0.path) || $0.path.hasPrefix(place.path) })
    #expect(here.steps.isEmpty && here.notes.contains { $0.contains("is current") })
    #expect(!docker.asked.contains { $0.first == "volume" || $0.first == "run" })
    // A part of it missing on disk: prepared again.
    let lacking = plan(docker: docker, store: .directory(dir), existing: { !$0.path.hasSuffix("/swift-build") && $0.path.hasPrefix(place.path) })
    #expect(kinds(lacking.steps) == ["pack"])
}

@Test func exportFromXipMountsTheXipReadOnly() {
    let argv = pack(plan()).argv
    #expect(values("--mount", argv).contains("type=bind,src=/home/u/Downloads/My Xcode.xip,dst=/xcode/My Xcode.xip,readonly"))
    // The export is written, into the host's cache.
    #expect(values("--mount", argv).contains("type=bind,src=/cache/xless/sdk/xcode27.0-27A266a,dst=/cache/xless/sdk/xcode27.0-27A266a"))
    #expect(Array(argv.suffix(2)) == ["--xcode", "/xcode/My Xcode.xip"])
    // An Xcode.app, and a renamed .xip that still mounts as a .xip.
    let app = pack(plan((xcode27, .app, URL(fileURLWithPath: "/home/u/Xcode-beta.app")))).argv
    #expect(values("--mount", app).first == "type=bind,src=/home/u/Xcode-beta.app,dst=/xcode/Xcode-beta.app,readonly")
    #expect(Array(app.suffix(2)) == ["--xcode", "/xcode/Xcode-beta.app"])
    #expect(pack(plan((xcode27, .xip, URL(fileURLWithPath: "/d/Xcode_27")))).argv.contains("type=bind,src=/d/Xcode_27,dst=/xcode/Xcode_27.xip,readonly"))
    // An export of it in the cache already: read from there, and the Xcode is not mounted.
    let done = cache.appendingPathComponent("sdk/xcode27.0-27A266a")
    let reused = pack(plan(existing: { $0.path.hasPrefix(done.path) })).argv
    #expect(!reused.contains { $0.contains("/xcode/") } && Array(reused.suffix(2)) == ["--sdk", "/cache/xless/sdk/xcode27.0-27A266a"])
    // Only half of an export (no toolchain-meta.json): exported again.
    #expect(pack(plan(existing: { $0.path.hasSuffix("darwin.xtoolsdk") })).argv.contains("--xcode"))
}

@Test func exportSourceMountsTheCacheReadOnly() {
    // An export reused in place of the Xcode (xless setup --sdk, or the cache's one export): read-only, never exported.
    let export = URL(fileURLWithPath: "/exports/x27")
    let d = plan((xcode27, .export, export), archs: ["arm64", "amd64"])
    #expect(kinds(d.steps) == ["image", "volume", "owner", "pack", "image", "volume", "owner", "pack"])
    for s in d.steps where kinds([s]) == ["pack"] {
        #expect(values("--mount", s.argv).first == "type=bind,src=/exports/x27,dst=/cache/xless/sdk/xcode27.0-27A266a,readonly")
        #expect(Array(s.argv.suffix(2)) == ["--sdk", "/cache/xless/sdk/xcode27.0-27A266a"])
        #expect(s.action == .packRun(SetupStep.PackRun(directories: [], unlessCurrent: nil)))
    }
    // The cache's own export: the same, read-only.
    let cached = cache.appendingPathComponent("sdk/xcode27.0-27A266a")
    #expect(values("--mount", pack(plan((xcode27, .export, cached))).argv).first == "type=bind,src=\(cached.path),dst=/cache/xless/sdk/xcode27.0-27A266a,readonly")
}

@Test func rootlessDockerRunsAsItsOwnRoot() {
    // Its root is the calling user: no --user, and no step to make the volume the user's.
    let d = plan(rootless: true)
    #expect(kinds(d.steps) == ["image", "volume", "pack"])
    #expect(!pack(d).argv.contains("--user"))
}

@Test func twoArchsPrepareAPackEach() {
    let d = plan(archs: ["arm64", "amd64"], kits: [.tauri])
    #expect(kinds(d.steps) == ["image", "volume", "owner", "pack", "kit", "image", "volume", "owner", "pack", "kit"])
    #expect(d.steps[5].argv.contains("/tmp/bin-amd64/xless") && d.steps[5].title == "xless:0.14.0-amd64")
    #expect(d.steps[6].argv.last == "xless-xcode-27.0-27A266a-amd64")
    #expect(d.steps[8].argv.contains("linux/amd64") && d.steps[8].argv.contains("xless:0.14.0-amd64"))
    // The other arch runs under emulation: its estimates say so.
    #expect(d.steps[5].estimate.contains("emulat") && d.steps[8].estimate.contains("emulat") && d.steps[9].estimate.contains("emulat"))
    #expect(!d.steps[3].estimate.contains("emulat"))
    // A patch release keeps its patch, and a version without one has none (26.2.0).
    let patch = KnownXcode(build: "17A400", shortVersion: "26.0.1", appleSwift: "6.2", buildMachineOSBuild: "26A434", xipSHA256: [])
    var t = table
    t["XCODE_SWIFT_17A400"] = "6.4.0"
    try! "x".write(to: share.appendingPathComponent("docker/toolchain/target-os/17A400.txt"), atomically: true, encoding: .utf8)
    let p = try! SetupPlan.make(source: (patch, .app, URL(fileURLWithPath: "/x/X.app")), archs: ["arm64"], hostArch: "arm64", share: share, cacheRoot: cache,
                                table: t, xlessBinaries: bins, store: .volumes, docker: { Fake().answer($0) }, readVolumes: true, rootless: false,
                                reexport: false, existing: { _ in false })
    #expect(p.steps.contains { $0.argv.last == "xless-xcode-26.0.1-17A400-arm64" })
    #expect(plan((xcode26, .app, URL(fileURLWithPath: "/x/X.app"))).steps.contains { $0.argv.last == "xless-xcode-26.2-17C52-arm64" })
}

@Test func noXcodeBuildsTheImageAndTheKitsAlone() {
    let d = plan(nil, kits: [.tauri])
    #expect(kinds(d.steps) == ["image", "kit"])
    let docker = Fake()
    docker.images = ["xless:0.14.0-arm64"]
    #expect(kinds(plan(nil, docker: docker, kits: [.tauri]).steps) == ["kit"])
    #expect(plan(nil, docker: docker).steps.isEmpty)
}

@Test func anXcodeThatXlessCannotPrepareIsRefusedFirst() throws {
    let known = [xcode27, xcode26]
    try XcodeSupport.require(xcode27, known: known, table: table, share: share)
    // No Swift of its own in versions.env.
    var t = table
    t["XCODE_SWIFT_17C52"] = nil
    #expect(problem { try XcodeSupport.require(xcode26, known: known, table: t, share: share) }
            == "versions.env maps Xcode 26.2 (17C52) to no Swift toolchain (XCODE_SWIFT_17C52); use an Xcode this xless supports (Xcode 27.0 (27A266a)), or an xless that supports this one")
    // No target-OS fixture.
    let beta = KnownXcode(build: "27A5218g", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
    t = table
    t["XCODE_SWIFT_27A5218g"] = "6.4.0"
    #expect(problem { try XcodeSupport.require(beta, known: known + [beta], table: t, share: share) }.hasPrefix("xless has no target-OS fixture for Xcode 27.0 (27A5218g)"))
    // No measured asset tools: refused before the six minutes of preparing it.
    try "x".write(to: share.appendingPathComponent("docker/toolchain/target-os/27A5218g.txt"), atomically: true, encoding: .utf8)
    let message = problem { try XcodeSupport.require(beta, known: known + [beta], table: t, share: share) }
    #expect(message.hasPrefix("xless has not measured the asset catalog and storyboard tools of Xcode 27.0 (27A5218g)"))
    #expect(message.contains("(Xcode 27.0 (27A266a), Xcode 26.2 (17C52))"))
}

/// What `body` throws, as `cause; fix`.
private func problem(_ body: () throws -> Void) -> String {
    do { try body(); return "" } catch let e as XlessError { return "\(e.cause); \(e.fix)" } catch { return "\(error)" }
}

@Test func cacheRootFollowsXDG() {
    let home = URL(fileURLWithPath: "/home/u")
    #expect(SetupPlan.cacheRoot(env: ["XDG_CACHE_HOME": "/c"], home: home).path == "/c/xless")
    #expect(SetupPlan.cacheRoot(env: [:], home: home).path == "/home/u/.cache/xless")
    #expect(SetupPlan.cacheRoot(env: ["XDG_CACHE_HOME": ""], home: home).path == "/home/u/.cache/xless")
}

// MARK: - The release download of another arch's xless (Ruling R1)

@Test func releaseNamesUseUnameArchs() throws {
    #expect(XlessRelease.tarballName(version: "0.1.0", dockerArch: "amd64") == "xless-0.1.0-linux-x86_64.tar.gz")
    #expect(XlessRelease.tarballName(version: "0.1.0", dockerArch: "arm64") == "xless-0.1.0-linux-arm64.tar.gz")
    #expect(XlessRelease.url(version: "0.1.0", file: "SHA256SUMS").absoluteString
            == "https://github.com/fmsouza/xless/releases/download/v0.1.0/SHA256SUMS")
}

private func makeTarball(version: String, arch: String, in dir: URL) throws -> URL {
    let top = "xless-\(version)-linux-\(arch)"
    let bin = dir.appendingPathComponent("src/\(top)/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!fake xless\n".utf8).write(to: bin.appendingPathComponent("xless"))
    let tarball = dir.appendingPathComponent("\(top).tar.gz")
    try Shell.run("tar", ["-czf", tarball.path, "-C", dir.appendingPathComponent("src").path, top], stage: .sdk)
    return tarball
}

@Test func aVerifiedTarballYieldsAFileNamedXless() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID())")
    let tarball = try makeTarball(version: "0.1.0", arch: "x86_64", in: dir)
    let sum = SHA256.hash(data: try Data(contentsOf: tarball)).map { String(format: "%02x", $0) }.joined()
    let sums = "\(String(repeating: "0", count: 64))  xless-0.1.0-linux-arm64.tar.gz\n\(sum)  xless-0.1.0-linux-x86_64.tar.gz\n"
    try XlessRelease.verify(tarball: tarball, name: "xless-0.1.0-linux-x86_64.tar.gz", sums: sums)
    let out = dir.appendingPathComponent("out")
    let bin = try XlessRelease.extractBinary(tarball: tarball, version: "0.1.0", dockerArch: "amd64", into: out)
    #expect(bin.lastPathComponent == "xless")
    #expect(try String(contentsOf: bin, encoding: .utf8) == "#!fake xless\n")
}

@Test func aTarballThatDoesNotMatchSHA256SUMSThrows() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-bad-\(UUID())")
    let tarball = try makeTarball(version: "0.1.0", arch: "arm64", in: dir)
    let sums = "\(String(repeating: "a", count: 64))  xless-0.1.0-linux-arm64.tar.gz\n"
    #expect(throws: XlessError.self) { try XlessRelease.verify(tarball: tarball, name: "xless-0.1.0-linux-arm64.tar.gz", sums: sums) }
    // Not listed at all.
    #expect(throws: XlessError.self) { try XlessRelease.verify(tarball: tarball, name: "xless-0.1.0-linux-arm64.tar.gz", sums: "") }
}

@Test func elfMachineNamesTheArch() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("elf-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func elf(_ machine: UInt16) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0...3] = [0x7f, 0x45, 0x4c, 0x46]; bytes[4] = 2; bytes[5] = 1
        bytes[18] = UInt8(machine & 0xff); bytes[19] = UInt8(machine >> 8)
        let url = dir.appendingPathComponent("elf-\(machine)")
        try Data(bytes).write(to: url)
        return url
    }
    #expect(XlessRelease.elfDockerArch(try elf(183)) == "arm64")
    #expect(XlessRelease.elfDockerArch(try elf(62)) == "amd64")
    #expect(XlessRelease.elfDockerArch(try elf(3)) == nil)
    let text = dir.appendingPathComponent("text")
    try Data("not an elf at all, just text".utf8).write(to: text)
    #expect(XlessRelease.elfDockerArch(text) == nil)
}
