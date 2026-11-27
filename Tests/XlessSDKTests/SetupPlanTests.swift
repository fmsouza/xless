import Testing
import Foundation
import Crypto
@testable import XlessSDK
@testable import XlessCore
import XlessImages

private let xcode27 = KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
private let xcode26 = KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: [])

/// A share directory whose versions.env names 27A266a the default Xcode, as the repository's does.
private let share: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setup-plan-share-\(UUID())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! "XCODE_VERSION=27.0\nXCODE_BUILD=27A266a\nXLESS_VERSION=0.14.0\n".write(to: dir.appendingPathComponent("versions.env"), atomically: true, encoding: .utf8)
    for kit in Kit.allCases {
        try! FileManager.default.createDirectory(at: kit.directory(share: dir), withIntermediateDirectories: true)
        try! "FROM \(kit.rawValue)\n".write(to: kit.directory(share: dir).appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    }
    return dir
}()
private let cache = URL(fileURLWithPath: "/cache/xless")
private let bins = ["arm64": URL(fileURLWithPath: "/tmp/bin-arm64/xless"), "amd64": URL(fileURLWithPath: "/tmp/bin-amd64/xless")]
private let xipSource: XcodeSource.Identified = (xcode27, .xip, URL(fileURLWithPath: "/home/u/Downloads/My Xcode.xip"))

private func plan(_ source: XcodeSource.Identified = xipSource, archs: [String] = ["arm64"], reexport: Bool = false, kits: [Kit] = [],
                  existing: @escaping (URL) -> Bool = { _ in false }) -> [SetupStep] {
    try! SetupPlan.make(source: source, archs: archs, hostArch: "arm64", share: share, cacheRoot: cache, xlessBinaries: bins,
                        reexport: reexport, kits: kits, builder: "colima", existing: existing)
}

/// Each step's kind, from its argv: tools/image (docker-images.sh), export (xtool), meta, kit, rm.
private func kinds(_ steps: [SetupStep]) -> [String] {
    steps.map { s in
        if s.argv.first?.hasSuffix("scripts/docker-images.sh") == true { return s.argv[1] }
        if s.argv.contains("xtool") { return "export" }
        if s.argv.starts(with: ["xless", "sdk", "meta"]) { return "meta" }
        if s.argv.starts(with: ["docker", "build"]) { return "kit" }
        if s.argv.starts(with: ["docker", "image", "rm"]) { return "rm" }
        return "?"
    }
}

@Test func hostArchPlanBuildsOneImageForThatArch() {
    let steps = plan()
    #expect(kinds(steps) == ["tools", "export", "meta", "image", "rm"])
    for s in steps {
        let line = s.argv.joined(separator: " ")
        #expect(line.contains("arm64"), "\(s.title): \(line)")
        #expect(!line.contains("amd64"), "\(s.title): \(line)")
        #expect(!s.title.isEmpty && !s.estimate.isEmpty)
    }
    let script = share.appendingPathComponent("scripts/docker-images.sh").path
    #expect(steps[0].argv == [script, "tools", "--arch", "arm64"])
    let export = steps[1]
    #expect(export.argv.contains("linux/arm64") && export.argv.contains("--pull=never"))
    #expect(export.argv.contains("xless:local-arm64-setup"))
    #expect(Array(export.argv.suffix(5)) == ["xtool", "sdk", "build", "/xcode/My Xcode.xip", "/out"])
    #expect(export.action == .export(partial: cache.appendingPathComponent("sdk/xcode27.0-27A266a/arm64.partial"),
                                     final: cache.appendingPathComponent("sdk/xcode27.0-27A266a/arm64")))
    #expect(export.argv.contains("\(cache.path)/sdk/xcode27.0-27A266a/arm64.partial:/out"))
    // The .xip is unpacked in the cache first: the estimate names that peak, not only what stays.
    #expect(export.estimate.contains("~15 GB in the cache"))
    #expect(steps[2].action == .meta(xtoolSDK: cache.appendingPathComponent("sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk"),
                                     out: cache.appendingPathComponent("sdk/xcode27.0-27A266a/toolchain-meta.json")))
    // The image takes the export and this arch's linux xless, and gets its one tag.
    #expect(steps[3].title == "xless:0.14.0-arm64")
    #expect(steps[3].argv == [script, "image", "--arch", "arm64", "--xcode", "27.0", "--xcode-build", "27A266a",
                              "--sdk-dir", "\(cache.path)/sdk/xcode27.0-27A266a", "--xless-bin", "/tmp/bin-arm64/xless"])
    #expect(steps[4].action == .tidy && steps[4].argv.last == "xless:local-arm64-setup")
}

@Test func theKitsAskedForComeLast() {
    let steps = plan(kits: [.tauri, .reactNative])
    #expect(kinds(steps) == ["tools", "export", "meta", "image", "rm", "kit", "kit"])
    #expect(steps[5].action == .kit(.tauri, arch: "arm64", xcode: "") && steps[6].action == .kit(.reactNative, arch: "arm64", xcode: ""))
    // all of the command that runs: the ID is known once the image is built
    let recipe = try! Kit.reactNative.recipe(share: share)
    #expect(steps[6].argv == ["docker", "build", "--builder", "colima", "--platform", "linux/arm64", "--pull=false", "--provenance=false", "--build-arg", "XLESS_IMAGE=xless:0.14.0-arm64",
                              "--label", "dev.xless.kit=react-native", "--label", "dev.xless.kit.base=<the ID of xless:0.14.0-arm64>", "--label", "dev.xless.kit.recipe=\(recipe)",
                              "-t", "xless:0.14.0-arm64-react-native", "\(share.path)/docker/react-native"])
    #expect(steps[6].title == "xless:0.14.0-arm64-react-native: Node, pnpm, Ruby, Bundler and hermesc, for React Native and Expo apps")
}

@Test func theSourceIsMountedReadOnly() {
    let export = plan().first { $0.argv.contains("xtool") }!
    #expect(export.argv.contains("/home/u/Downloads/My Xcode.xip:/xcode/My Xcode.xip:ro"))
    let app: XcodeSource.Identified = (xcode27, .app, URL(fileURLWithPath: "/home/u/Xcode-beta.app"))
    let appExport = plan(app).first { $0.argv.contains("xtool") }!
    #expect(appExport.argv.contains("/home/u/Xcode-beta.app:/xcode/Xcode-beta.app:ro"))
    #expect(Array(appExport.argv.suffix(2)) == ["/xcode/Xcode-beta.app", "/out"])
    // A renamed .xip still mounts as a .xip.
    let renamed: XcodeSource.Identified = (xcode27, .xip, URL(fileURLWithPath: "/d/Xcode_27"))
    #expect(plan(renamed).first { $0.argv.contains("xtool") }!.argv.contains("/d/Xcode_27:/xcode/Xcode_27.xip:ro"))
}

@Test func theExportRunsAsTheCallingUser() {
    let export = plan().first { $0.argv.contains("xtool") }!
    let i = export.argv.firstIndex(of: "--user")
    #expect(i != nil)
    if let i { #expect(export.argv[i + 1] == "\(getuid()):\(getgid())") }
}

@Test func anExistingExportIsReusedUnlessReexport() {
    let done = cache.appendingPathComponent("sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk")
    var asked: [URL] = []
    let reused = plan(existing: { asked.append($0); return $0 == done })
    #expect(asked.contains(done))
    #expect(kinds(reused) == ["meta", "image"])
    #expect(kinds(plan(reexport: true, existing: { $0 == done })).contains("export"))
}

@Test func anExportSourceIsReadWhereItIsAndNeverExported() {
    // An export reused in place of the Xcode (xless setup --sdk, or the cache's one export): no Xcode to export from,
    // so no export step even for an arch the plan finds missing (setup refuses that before planning).
    let export = URL(fileURLWithPath: "/exports/x27")
    let steps = plan((xcode27, .export, export), archs: ["arm64", "amd64"])
    #expect(kinds(steps) == ["meta", "image", "image"])
    #expect(steps[0].action == .meta(xtoolSDK: export.appendingPathComponent("arm64/darwin.xtoolsdk"),
                                     out: export.appendingPathComponent("toolchain-meta.json")))
    let sdk = steps[1].argv
    #expect(sdk.firstIndex(of: "--sdk-dir").map { sdk[$0 + 1] } == "/exports/x27")
    #expect(sdk.firstIndex(of: "--xcode-build").map { sdk[$0 + 1] } == "27A266a")
    // The export is read, not written (it may be read-only): its toolchain-meta.json is written only when it has none.
    let meta = export.appendingPathComponent("toolchain-meta.json")
    let kept = plan((xcode27, .export, export), existing: { $0 == meta })
    #expect(kinds(kept) == ["image"])
    #expect(SetupPlan.sdkDir(source: (xcode27, .export, export), cacheRoot: cache) == export)
    #expect(SetupPlan.sdkDir(source: xipSource, cacheRoot: cache) == cache.appendingPathComponent("sdk/xcode27.0-27A266a"))
}

@Test func aPartialExportIsNeverReused() {
    // Only paths under a .partial directory exist: the interrupted run's leftovers.
    let steps = plan(existing: { $0.path.contains(".partial") })
    #expect(kinds(steps).contains("export"))
}

@Test func twoArchsBuildAnImageEach() {
    let steps = plan(archs: ["arm64", "amd64"], kits: [.tauri])
    #expect(kinds(steps) == ["tools", "export", "meta", "image", "rm", "kit", "tools", "export", "image", "rm", "kit"])
    #expect(steps[8].argv.contains("/tmp/bin-amd64/xless") && steps[8].argv.contains("amd64"))
    #expect(steps[7].argv.contains("linux/amd64"))
    // The other arch runs under emulation: its estimates say so.
    #expect(steps[8].estimate.contains("emulat") && steps[10].estimate.contains("emulat"))
    #expect(!steps[3].estimate.contains("emulat"))
    // A patch release keeps its patch, and a version without one has none (26.2.0).
    let patch = KnownXcode(build: "17A400", shortVersion: "26.0.1", appleSwift: "6.2", buildMachineOSBuild: "26A434", xipSHA256: [])
    // ADAPTER(packs): removed in the setup/run tasks. The image is the same whatever the Xcode
    #expect(plan((patch, .app, URL(fileURLWithPath: "/x/X.app"))).contains { $0.title == "xless:0.14.0-arm64" })
    #expect(plan((xcode26, .app, URL(fileURLWithPath: "/x/X.app"))).contains { $0.title == "xless:0.14.0-arm64" })
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
