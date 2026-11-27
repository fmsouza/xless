import Foundation
import Testing
@testable import XlessCore

private var fm: FileManager { FileManager.default }

/// Without symbolic links (macOS: /var is /private/var), as the store lists its packs.
private func tempDir(_ name: String = "xcode-env") throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return dir }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

private var hostArch: String {
    #if arch(arm64)
    "arm64"
    #else
    "amd64"
    #endif
}

private func write(_ text: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A pack on disk as `xless setup` lays it out: the SDK bundle, the metadata, the toolchain with its record (root
/// relative), the include directory and, with the part, Swift Build.
@discardableResult
private func makePack(in store: URL, xcode: String = "26.2", build: String = "17C52", arch: String = hostArch,
                      parts: [String: String] = ["sdk": "h", "swift-build": "h"]) throws -> URL {
    let dir = store.appendingPathComponent(XcodePack.name(xcode: xcode, build: build, arch: arch))
    let pack = XcodePack(root: dir, manifest: PackManifest(format: 1, xcode: xcode, build: build, arch: arch, swift: "6.2.3", mode: .separate, parts: parts))
    try fm.createDirectory(at: pack.sdkBundle, withIntermediateDirectories: true)
    try write(#"{"xcodeBuild":"\#(build)"}"#, to: pack.meta)
    try fm.createDirectory(at: pack.toolchain.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
    try write(#"{"version":"6.2.3","root":"toolchain","clangFlags":["-fdefine-target-os-macros"]}"#, to: pack.record)
    try fm.createDirectory(at: pack.include.appendingPathComponent("swift"), withIntermediateDirectories: true)
    if parts["swift-build"] != nil {
        try fm.createDirectory(at: pack.swiftBuild, withIntermediateDirectories: true)
        try ExecutableFile.write("#!/bin/sh\n", to: pack.swiftBuild.appendingPathComponent("swbuild"), stage: .build)
    }
    try pack.manifest.write(to: pack.manifestFile)
    return dir
}

/// An environment that sees nothing of this machine: its own home, store and (empty) share.
private func isolated(store: URL? = nil, _ extra: [String: String] = [:]) throws -> [String: String] {
    let home = try tempDir("xcode-env-home"), share = try tempDir("xcode-env-share")
    return ["HOME": home.path, "PATH": "/usr/bin:/bin", "XLESS_XCODES": (store ?? home.appendingPathComponent("xcodes")).path,
            "XLESS_SHARE": share.path].merging(extra) { $1 }
}

private func problem(_ body: () throws -> Any) -> XcodeProblem? {
    do { _ = try body(); return nil } catch { return error as? XcodeProblem }
}

@Test func packSuppliesEveryPart() throws {
    let store = try tempDir()
    let root = try makePack(in: store)
    let x = try XcodeEnvironment.current(env: try isolated(store: store))
    let pack = try #require(x.pack)
    #expect(pack.root.path == root.path)
    #expect(x.sdkBundle.path == pack.sdkBundle.path)
    #expect(x.meta.path == pack.meta.path)
    let toolchain = try #require(x.toolchain)
    #expect(toolchain.root == root.appendingPathComponent("toolchain").path && toolchain.root.hasPrefix("/"))
    #expect(toolchain.version == "6.2.3" && toolchain.clangFlags == ["-fdefine-target-os-macros"])
    #expect(x.include?.path == pack.include.path)
    #expect(x.swbuild?.path == root.appendingPathComponent("swift-build/swbuild").path)
    // SwiftPM finds the SDK through --swift-sdks-path; XDG_CONFIG_HOME stays the user's (and writable).
    #expect(x.swiftSDKsArguments == ["--swift-sdks-path", root.appendingPathComponent("config/swiftpm/swift-sdks").path])
}

@Test func overridesWinPartByPart() throws {
    let store = try tempDir(), records = try tempDir()
    let root = try makePack(in: store)
    let record = records.appendingPathComponent("swift-toolchain.json")
    try write(#"{"version":"6.2.3","root":"/opt/elsewhere/swift-6.2.3"}"#, to: record)
    let x = try XcodeEnvironment.current(env: try isolated(store: store, ["XLESS_TOOLCHAIN_META": "/m.json"]))
    #expect(x.meta.path == "/m.json")
    #expect(x.sdkBundle.path == root.appendingPathComponent("config/swiftpm/swift-sdks/darwin.artifactbundle").path)
    #expect(x.toolchain?.root == root.appendingPathComponent("toolchain").path)
    // An absolute root (an old record, XLESS_SWIFT_TOOLCHAIN's) stays as it is.
    let y = try XcodeEnvironment.current(env: try isolated(store: store, ["XLESS_SWIFT_TOOLCHAIN": record.path]))
    #expect(y.toolchain?.root == "/opt/elsewhere/swift-6.2.3")
    #expect(y.meta.path == root.appendingPathComponent("toolchain-meta.json").path && y.pack != nil)
}

@Test func xdgConfigHomeIsTheSDKOverrideOnlyWhenItHoldsAnSDK() throws {
    let store = try tempDir(), xdg = try tempDir("xcode-env-xdg"), meta = try tempDir().appendingPathComponent("meta.json")
    let root = try makePack(in: store)
    let packSDK = root.appendingPathComponent("config/swiftpm/swift-sdks/darwin.artifactbundle").path
    // Set for other reasons (very common on a host): the pack's SDK.
    let x = try XcodeEnvironment.current(env: try isolated(store: store, ["XDG_CONFIG_HOME": xdg.path]))
    #expect(x.sdkBundle.path == packSDK)
    // Holding an SDK (left by the native setup of before the packs) beside a found pack, alone: still the pack's, never
    // that SDK with the pack's metadata and toolchain (two Xcodes).
    let bundle = xdg.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle")
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    let y = try XcodeEnvironment.current(env: try isolated(store: store, ["XDG_CONFIG_HOME": xdg.path]))
    #expect(y.sdkBundle.path == packSDK && y.pack?.root.path == root.path)
    #expect(y.meta.path == root.appendingPathComponent("toolchain-meta.json").path)
    // With its metadata (an explicit override, as the images give): that SDK and that metadata.
    let z = try XcodeEnvironment.current(env: try isolated(store: store, ["XDG_CONFIG_HOME": xdg.path, "XLESS_TOOLCHAIN_META": meta.path]))
    #expect(z.sdkBundle.path == bundle.path && z.meta.path == meta.path && z.pack?.root.path == root.path)
    // No pack found: the SDK there is the override it names.
    let alone = try isolated(["XDG_CONFIG_HOME": xdg.path])
    let none = try XcodeEnvironment.current(env: alone)
    #expect(none.pack == nil && none.sdkBundle.path == bundle.path)
    // Nothing else is named: no metadata (reading it names the store, where a setup puts the packs), no toolchain record,
    // no include directory, and nothing read from where an image of before the packs kept them.
    #expect(none.meta.path == URL(fileURLWithPath: alone["XLESS_XCODES"]!).appendingPathComponent("toolchain-meta.json").path)
    #expect(!fm.fileExists(atPath: none.meta.path) && none.record == nil && none.include == nil && none.toolchain == nil)
    let include = try XcodeEnvironment.current(env: try isolated(["XLESS_TOOLCHAIN_INCLUDE": "/i"]))
    #expect(include.pack == nil && include.include?.path == "/i" && include.record == nil)
}

@Test func overridesAloneNeedNoPack() throws {
    let xdg = try tempDir("xcode-env-xdg"), files = try tempDir()
    try fm.createDirectory(at: xdg.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle"), withIntermediateDirectories: true)
    let record = files.appendingPathComponent("swift-toolchain.json")
    try write(#"{"version":"6.2.3","root":"/opt/xless/toolchains/swift-6.2.3"}"#, to: record)
    let env = try isolated(["XDG_CONFIG_HOME": xdg.path, "XLESS_TOOLCHAIN_META": files.appendingPathComponent("meta.json").path,
                            "XLESS_SWIFT_TOOLCHAIN": record.path, "XLESS_TOOLCHAIN_INCLUDE": "/opt/xless/toolchain/usr/include"])
    let x = try XcodeEnvironment.current(env: env, needs: [.sdk, .swiftBuild])
    #expect(x.pack == nil)
    #expect(x.sdkBundle.path == xdg.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle").path)
    #expect(x.meta.path == files.appendingPathComponent("meta.json").path)
    #expect(x.toolchain?.root == "/opt/xless/toolchains/swift-6.2.3")
    #expect(x.include?.path == "/opt/xless/toolchain/usr/include")
    // A store whose pack does not fit changes nothing then: every part is overridden.
    let store = try tempDir()
    try makePack(in: store, parts: ["sdk": "h"])
    let y = try XcodeEnvironment.current(env: env.merging(["XLESS_XCODES": store.path]) { $1 }, needs: [.sdk, .swiftBuild])
    #expect(y.pack == nil && y.meta.path == x.meta.path)
}

@Test func noPackNamesTheSetup() throws {
    let env = try isolated()
    let e = problem { try XcodeEnvironment.current(env: env) }
    #expect(e?.cause.contains("there is no pack for any Xcode") == true)
    #expect(e?.fix.contains("else xless setup --xcode") == true)
    let pinned = problem { try XcodeEnvironment.current(env: env.merging([XcodeEnvironment.pinVariable: "26.2"]) { $1 }) }
    #expect(pinned?.cause.contains("Xcode 26.2") == true && pinned?.fix.contains("Xcode 26.2's") == true)
    // In a stage: the cause and the setup, with the usage exit code.
    let staged = try #require(e).stageError(.build)
    #expect(staged.stage == .build && staged.exitCode == 2 && staged.fix == e?.fix)
    // Asked whether there is one at all: no. The toolchain alone is then none (the `swift` on PATH compiles).
    #expect(try XcodeEnvironment.lookup(env: env) == nil)
    #expect(try XcodeEnvironment.toolchain(env: env) == nil)
}

@Test func relativeRecordRootResolves() throws {
    let dir = try tempDir()
    let record = dir.appendingPathComponent("swift-toolchain.json")
    try write(#"{"version":"6.2.3","root":"toolchain"}"#, to: record)
    #expect(try SwiftToolchain.load(record: record).root == dir.appendingPathComponent("toolchain").path)
    try write(#"{"version":"6.2.3","root":"../tc"}"#, to: record)
    #expect(try SwiftToolchain.load(record: record).root == dir.deletingLastPathComponent().appendingPathComponent("tc").path)
    try write(#"{"version":"6.4","root":"/"}"#, to: record)
    let engine = try SwiftToolchain.load(record: record)
    #expect(engine.root == "/" && engine.isEngine)
    try write("{", to: record)
    #expect(throws: XlessError.self) { try SwiftToolchain.load(record: record) }
    #expect(throws: XlessError.self) { try SwiftToolchain.load(record: dir.appendingPathComponent("none.json")) }
}

@Test func movedPackStillResolves() throws {
    let store = try tempDir(), elsewhere = try tempDir()
    let root = try makePack(in: store)
    let moved = elsewhere.appendingPathComponent("moved")
    try fm.moveItem(at: root, to: moved)
    let x = try XcodeEnvironment.current(env: try isolated(store: store, ["XLESS_XCODE": moved.path]))
    #expect(x.pack?.root.path == moved.path)
    #expect(x.toolchain?.root == moved.appendingPathComponent("toolchain").path)
    #expect(x.sdkBundle.path == moved.appendingPathComponent("config/swiftpm/swift-sdks/darwin.artifactbundle").path)
    #expect(x.swbuild?.path == moved.appendingPathComponent("swift-build/swbuild").path)
}

@Test func thePinComesFromTheEnvironment() throws {
    let store = try tempDir()
    try makePack(in: store, xcode: "26.2", build: "17C52")
    try makePack(in: store, xcode: "27.0", build: "27A266a")
    #expect(try XcodeEnvironment.current(env: try isolated(store: store)).pack?.manifest.xcode == "27.0")
    let pinned = try XcodeEnvironment.current(env: try isolated(store: store, [XcodeEnvironment.pinVariable: "26.2"]))
    #expect(pinned.pack?.manifest.build == "17C52" && pinned.meta.path.contains("26.2-17C52-"))
}

@Test func aLoadedProjectGivesItsPinToTheEnvironment() {
    // A stage run by hand takes the project's `xcode:`, as `xless run` gives it.
    #expect(XcodeEnvironment.pin(configured: "26.2", env: [:]) == "26.2")
    #expect(XcodeEnvironment.pin(configured: "26.2", env: [XcodeEnvironment.pinVariable: ""]) == "26.2")
    // A value already in the environment wins (a run has set it).
    #expect(XcodeEnvironment.pin(configured: "26.2", env: [XcodeEnvironment.pinVariable: "27.0"]) == nil)
    // No pin sets nothing.
    #expect(XcodeEnvironment.pin(configured: nil, env: [:]) == nil)
    #expect(XcodeEnvironment.pin(configured: nil, env: [XcodeEnvironment.pinVariable: "27.0"]) == nil)
}

@Test func swiftBuildIsOnPathWhenThePackHasNone() throws {
    let store = try tempDir(), bin = try tempDir("xcode-env-bin")
    try makePack(in: store, parts: ["sdk": "h"])
    #expect(try XcodeEnvironment.current(env: try isolated(store: store)).swbuild == nil)
    try ExecutableFile.write("#!/bin/sh\n", to: bin.appendingPathComponent("swbuild"), stage: .build)
    let x = try XcodeEnvironment.current(env: try isolated(store: store, ["PATH": "\(bin.path):/usr/bin:/bin"]))
    #expect(x.swbuild?.path == bin.appendingPathComponent("swbuild").path)
    // A command that needs Swift Build: the pack must have it.
    let e = problem { try XcodeEnvironment.current(env: try isolated(store: store), needs: [.sdk, .swiftBuild]) }
    #expect(e?.cause.contains("has no Swift Build") == true)
}

@Test func theNativeInstallOfBeforeThePacksIsNeverRead() throws {
    // A native install of before the packs: the SDK under ~/.swiftpm, the metadata under ~/.config/xless, the record in NativeLayout.
    let env = try isolated()
    let home = URL(fileURLWithPath: env["HOME"]!)
    let bundle = home.appendingPathComponent(".swiftpm/swift-sdks/darwin.artifactbundle")
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    try write("{}", to: home.appendingPathComponent(".config/xless/toolchain-meta.json"))
    try write(#"{"version":"6.4.0","root":"/n/toolchains/swift-6.4.0"}"#, to: NativeLayout(env: env).record)
    // No pack: no Xcode at all, and the problem names the setup (which reports that install).
    #expect(try XcodeEnvironment.lookup(env: env) == nil)
    #expect(try XcodeEnvironment.toolchain(env: env) == nil)
    let e = problem { try XcodeEnvironment.current(env: env) }
    #expect(e?.cause.contains("there is no pack for any Xcode") == true && e?.fix.contains("else xless setup --xcode") == true)
    // With a pack, the pack's parts.
    let store = URL(fileURLWithPath: env["XLESS_XCODES"]!)
    let root = try makePack(in: store)
    let y = try XcodeEnvironment.current(env: env)
    #expect(y.pack?.root.path == root.path && y.sdkBundle.path.hasPrefix(root.path) && y.meta.path.hasPrefix(root.path))
    #expect(y.toolchain?.root.hasPrefix(root.path) == true)
    // A store whose packs do not fit is the answer.
    let f = problem { try XcodeEnvironment.current(env: env.merging([XcodeEnvironment.pinVariable: "27.0"]) { $1 }) }
    #expect(f?.cause.contains("no pack for Xcode 27.0") == true)
}

@Test func aPackLeftAsideByAStoppedSetupIsNoPackAndABuildLeavesItThere() throws {
    // A setup stopped between its two renames: the pack is at <name>.old and nothing is in its place.
    let store = try tempDir()
    let root = try makePack(in: store)
    let aside = store.appendingPathComponent(root.lastPathComponent + ".old")
    try fm.moveItem(at: root, to: aside)
    let env = try isolated(store: store)
    let e = problem { try XcodeEnvironment.current(env: env) }
    #expect(e?.cause.contains("there is no pack for any Xcode") == true && e?.fix.contains("else xless setup --xcode") == true)
    #expect(try XcodeEnvironment.lookup(env: env) == nil)
    // Nothing was renamed: setup puts it back.
    #expect(fm.fileExists(atPath: aside.appendingPathComponent("pack.json").path) && !fm.fileExists(atPath: root.path))
}

@Test func aStalePackIsRefused() throws {
    // The share of this checkout: the recipe hashes of this xless.
    let share = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let table = KnownXcodes.parseEnv(try String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8))
    let store = try tempDir()
    try makePack(in: store, parts: ["sdk": "stale"])
    let env = try isolated(store: store, ["XLESS_SHARE": share.path])
    #expect(problem { try XcodeEnvironment.current(env: env) }?.cause.contains("was prepared by another recipe") == true)
    try fm.removeItem(at: store.appendingPathComponent(XcodePack.name(xcode: "26.2", build: "17C52", arch: hostArch)))
    let hash = try PackRecipe.hash(.sdk, build: "17C52", arch: hostArch, table: table, share: share)
    try makePack(in: store, parts: ["sdk": hash])
    #expect(try XcodeEnvironment.current(env: env).pack?.manifest.parts["sdk"] == hash)
}

/// As a run's pack choice: a share that lacks a recipe input cannot tell whether the pack is current, which stops the
/// lookup; a pack of an Xcode this xless has no recipe for is used as it is.
@Test func aShareThatCannotTellStopsAndAnUnknownXcodeIsUsedAsItIs() throws {
    let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let versions = try String(contentsOf: checkout.appendingPathComponent("versions.env"), encoding: .utf8)
    let share = try tempDir("xcode-env-share")
    try write(versions, to: share.appendingPathComponent("versions.env"))   // and none of the scripts the recipe reads
    let store = try tempDir()
    try makePack(in: store, parts: ["sdk": "h"])
    let env = try isolated(store: store, ["XLESS_SHARE": share.path])
    let e = problem { try XcodeEnvironment.current(env: env) }
    #expect(e?.cause.hasPrefix("cannot tell whether the pack 26.2-17C52-\(hostArch) is current: ") == true, "\(String(describing: e))")
    let unknown = try tempDir()
    try makePack(in: unknown, xcode: "26.9", build: "99Z99", parts: ["sdk": "h"])
    #expect(try XcodeEnvironment.current(env: try isolated(store: unknown, ["XLESS_SHARE": share.path])).pack?.manifest.build == "99Z99")
}

@Test func toolEnvironmentPointsXtoolAtThePack() throws {
    let store = try tempDir(), cache = try tempDir("xcode-env-cache")
    let root = try makePack(in: store)
    let env = try isolated(store: store, ["XDG_CONFIG_HOME": "/home/u/.config", "XDG_CACHE_HOME": cache.path])
    let x = try XcodeEnvironment.current(env: env)
    let before = try fm.subpathsOfDirectory(atPath: root.path).sorted()
    let tools = try x.toolEnvironment(env)
    // xtool finds the SDK only under XDG_CONFIG_HOME: a scratch configuration whose swift-sdks is the pack's.
    let config = cache.appendingPathComponent("xless/xtool-config").appendingPathComponent(root.lastPathComponent)
    let link = config.appendingPathComponent("swiftpm/swift-sdks")
    #expect(tools["XDG_CONFIG_HOME"] == config.path)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == root.appendingPathComponent("config/swiftpm/swift-sdks").path)
    #expect(fm.fileExists(atPath: link.appendingPathComponent("darwin.artifactbundle").path))
    #expect(tools["PATH"] == root.appendingPathComponent("toolchain/usr/bin").path + ":/usr/bin:/bin")
    #expect(tools["HOME"] == env["HOME"])
    // A second call reuses it.
    let made = try fm.attributesOfItem(atPath: link.path)[.systemFileNumber] as? Int
    #expect(try x.toolEnvironment(env)["XDG_CONFIG_HOME"] == config.path)
    #expect(try fm.attributesOfItem(atPath: link.path)[.systemFileNumber] as? Int == made)
    // Nothing is written under the pack.
    #expect(try fm.subpathsOfDirectory(atPath: root.path).sorted() == before)
    // A moved pack: the link follows it.
    let moved = try tempDir("xcode-env-moved").appendingPathComponent(root.lastPathComponent)
    try fm.moveItem(at: root, to: moved)
    let y = try XcodeEnvironment.current(env: env.merging(["XLESS_XCODE": moved.path]) { $1 })
    #expect(try y.toolEnvironment(env)["XDG_CONFIG_HOME"] == config.path)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == moved.appendingPathComponent("config/swiftpm/swift-sdks").path)
    #expect(fm.fileExists(atPath: link.appendingPathComponent("darwin.artifactbundle").path))
}

@Test func toolEnvironmentLeavesAnSDKOverrideAlone() throws {
    let store = try tempDir(), config = try tempDir("xcode-env-config"), cache = try tempDir("xcode-env-cache")
    try makePack(in: store)
    try fm.createDirectory(at: config.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle"), withIntermediateDirectories: true)
    let env = try isolated(store: store, ["XDG_CONFIG_HOME": config.path, "XDG_CACHE_HOME": cache.path, "XLESS_TOOLCHAIN_META": "/m.json"])
    let tools = try XcodeEnvironment.current(env: env).toolEnvironment(env)
    #expect(tools["XDG_CONFIG_HOME"] == config.path)
    #expect(!fm.fileExists(atPath: cache.appendingPathComponent("xless").path))
    // Without the metadata that SDK is a leftover beside the pack: xtool gets the pack's, through the scratch configuration.
    var leftover = env
    leftover["XLESS_TOOLCHAIN_META"] = nil
    let pack = try XcodeEnvironment.current(env: leftover)
    #expect(try pack.toolEnvironment(leftover)["XDG_CONFIG_HOME"]?.hasPrefix(cache.appendingPathComponent("xless/xtool-config").path) == true)
}

@Test func aMissingToolchainOverrideIsAnErrorOfItsOwn() throws {
    let store = try tempDir()
    try makePack(in: store)
    let x = try XcodeEnvironment.current(env: try isolated(store: store, ["XLESS_SWIFT_TOOLCHAIN": "/missing.json"]))
    #expect(x.toolchain == nil)
    let e = #expect(throws: XlessError.self) { try x.loadToolchain(stage: .prepare) }
    #expect(e?.stage == .prepare && e?.cause == "XLESS_SWIFT_TOOLCHAIN names /missing.json, which does not exist")
    // Without one, no record is no toolchain (the `swift` on PATH compiles).
    let none = try XcodeEnvironment.current(env: try isolated(["XLESS_TOOLCHAIN_META": "/m.json"]))
    #expect(try none.loadToolchain() == nil)
}

@Test func theToolsProfileIsTheXcodesMetadatas() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent("toolchain-meta.json")
    try ToolchainMeta(xcodeVersion: "2620", xcodeBuild: "17C52", buildMachineOSBuild: "25B78", compiler: ToolchainMeta.clangCompiler, platforms: [:])
        .write(to: url)
    #expect(try XcodeToolsProfile.forImage(env: try isolated(["XLESS_TOOLCHAIN_META": url.path]), stage: .ib).xcodeBuild == "17C52")
    // No metadata: refused in the asking stage, never a default profile.
    let missing = #expect(throws: XlessError.self) {
        try XcodeToolsProfile.forImage(env: try isolated(["XLESS_TOOLCHAIN_META": dir.appendingPathComponent("none.json").path]), stage: .assets)
    }
    #expect(missing?.stage == .assets)
    #expect(missing?.cause.contains("toolchain metadata not found") == true)
    let nothing = #expect(throws: XlessError.self) { try XcodeToolsProfile.forImage(env: try isolated(), stage: .ib) }
    #expect(nothing?.stage == .ib && nothing?.fix.contains("else xless setup --xcode") == true)
}

@Test func xtoolsConfigurationIsRepairedAndSharedByBuildsAtOnce() throws {
    let store = try tempDir(), cache = try tempDir("xcode-env-cache")
    let root = try makePack(in: store)
    let env = try isolated(store: store, ["XDG_CACHE_HOME": cache.path])
    let x = try XcodeEnvironment.current(env: env)
    let link = cache.appendingPathComponent("xless/xtool-config/\(root.lastPathComponent)/swiftpm/swift-sdks")
    let target = root.appendingPathComponent("config/swiftpm/swift-sdks").path
    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A directory where the link goes: replaced.
    try fm.createDirectory(at: link.appendingPathComponent("stray"), withIntermediateDirectories: true)
    _ = try x.toolEnvironment(env)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target)
    // A stale link, seen by many builds at once: none fails, and the link is right after.
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/gone/config/swiftpm/swift-sdks")
    let failures = Failures()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        do { _ = try x.toolEnvironment(env) } catch { failures.add("\(error)") }
    }
    #expect(failures.all.isEmpty)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target)
    // Nothing but the link is left in its directory.
    #expect(try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == ["swift-sdks"])
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

@Test func theDarwinSDKFallsBackOnlyWithoutAnyXcode() throws {
    // Nothing at all: where a native setup puts it, so that what needs it names a path.
    let none = try isolated()
    #expect(try DarwinSDK(env: none).bundle.path == DarwinSDKLocator.bundle(env: none).path)
    // A pack: its SDK.
    let store = try tempDir()
    let root = try makePack(in: store)
    #expect(try DarwinSDK(env: try isolated(store: store)).bundle.path == root.appendingPathComponent("config/swiftpm/swift-sdks/darwin.artifactbundle").path)
    // A store with no pack for the pin: that problem, never the fallback.
    let e = #expect(throws: XcodeProblem.self) { try DarwinSDK(env: try isolated(store: store, [XcodeEnvironment.pinVariable: "27.0"])) }
    #expect(e?.cause.contains("no pack for Xcode 27.0") == true)
}
