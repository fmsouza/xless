import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private let xcode27 = KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
private let xcode26 = KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: [])
private let layout = NativeLayout(root: URL(fileURLWithPath: "/n"))
private let store = XcodeStore(root: URL(fileURLWithPath: "/n/xcodes"))
private let cache = URL(fileURLWithPath: "/cache/xless")
private let table: [String: String] = [
    "SWIFT_VERSION": "6.4.0", "XTOOL_VERSION": "1.21.0", "RCODESIGN_VERSION": "0.29.0",
    "XTOOL_SHA256_AARCH64": "xa", "XTOOL_SHA256_X86_64": "xx", "RCODESIGN_SHA256_AARCH64": "ra", "RCODESIGN_SHA256_X86_64": "rx",
    "XCODE_SWIFT_27A266a": "6.4.0", "XCODE_SWIFT_17C52": "6.2.3",
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64": "https://example.com/s640-a.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64": "s640a",
    "SWIFT_TOOLCHAIN_6_4_0_URL_X86_64": "https://example.com/s640-x.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_X86_64": "s640x",
    "SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64": "https://example.com/s623-a.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64": "s623a",
]
private let bare = PackPlan.Abilities(swiftBuild: false)

/// A share with the files the pack's recipe hashes read.
private let share: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("native-plan-share-\(UUID().uuidString)")
    for path in ["scripts/fit-toolchain.sh", "scripts/pack-swift-build.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
                 "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt", "docker/toolchain/target-os/27A266a.txt",
                 "docker/toolchain/target-os/17C52.txt"] {
        let url = dir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(path.utf8).write(to: url)
    }
    return dir
}()

private func plan(_ x: KnownXcode = xcode27, arch: String = "arm64", table t: [String: String] = table, share sh: URL = share, reexport: Bool = false,
                  store s: XcodeStore = store, existing: @escaping (URL) -> Bool = { _ in false }) throws -> [SetupStep] {
    try NativeSetupPlan.make(source: (x, .xip, URL(fileURLWithPath: "/home/u/Downloads/Xcode_27.xip")), arch: arch, share: sh,
                             cacheRoot: cache, layout: layout, store: s, table: t, reexport: reexport, abilities: bare, existing: existing)
}

private func downloads(_ steps: [SetupStep]) -> [NativeDownload] {
    steps.compactMap { if case let .download(d) = $0.action { return d } else { return nil } }
}

private func isPackStep(_ s: SetupStep) -> Bool {
    switch s.action {
    case .packBegin, .packSDK, .packPart, .packCommit: return true
    case .download(let d): return d.kind == .swiftToolchain
    case .run: return s.argv.contains { $0.hasPrefix("/n/xcodes/") }
    default: return false
    }
}

/// A real directory (macOS: /var is /private/var).
private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("native-plan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return dir }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

@Test func aFreshMachineGetsEveryStepInOrder() throws {
    let steps = try plan()
    let d = downloads(steps)
    #expect(d.map(\.kind) == [.appImage, .rcodesign, .swiftToolchain])
    #expect(d[0].url.absoluteString == "https://github.com/xtool-org/xtool/releases/download/1.21.0/xtool-aarch64.AppImage")
    #expect(d[0].sha256 == "xa" && d[0].final.path == "/n/tools/xtool-1.21.0")
    #expect(d[0].partial.path == "/n/tools/xtool-1.21.0.partial")
    #expect(d[1].url.absoluteString == "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-aarch64-unknown-linux-musl.tar.gz")
    #expect(d[1].sha256 == "ra" && d[1].final.path == "/n/tools/rcodesign-0.29.0")
    // The toolchain goes into the pack being prepared, never under the native home's toolchains/.
    #expect(d[2].url.absoluteString == "https://example.com/s640-a.tar.gz" && d[2].sha256 == "s640a")
    #expect(d[2].final.path == "/n/xcodes/27.0-27A266a-arm64.partial/toolchain")
    #expect(!steps.contains { $0.argv.joined(separator: " ").contains("/n/toolchains") })

    // The export runs the native xtool, into the cache the Docker path uses too; nothing runs docker.
    let sdk = "/cache/xless/sdk/xcode27.0-27A266a"
    #expect(steps[2].argv == ["/n/bin/xtool", "sdk", "build", "/home/u/Downloads/Xcode_27.xip", "\(sdk)/arm64.partial"])
    #expect(steps[2].action == .export(partial: URL(fileURLWithPath: "\(sdk)/arm64.partial"), final: URL(fileURLWithPath: "\(sdk)/arm64")))
    #expect(steps[3].action == .meta(xtoolSDK: URL(fileURLWithPath: "\(sdk)/arm64/darwin.xtoolsdk"), out: URL(fileURLWithPath: "\(sdk)/toolchain-meta.json")))
    // Then the pack, from that export: the SDK installed into the staging pack, fitted there (own: the image's Swift).
    let staging = "/n/xcodes/27.0-27A266a-arm64.partial"
    #expect(steps.contains { $0.action == .packSDK(xtoolSDK: URL(fileURLWithPath: "\(sdk)/arm64/darwin.xtoolsdk"),
                                                    config: URL(fileURLWithPath: "\(staging)/config"), toolchain: URL(fileURLWithPath: "\(staging)/toolchain")) })
    #expect(steps.contains { $0.argv == ["\(share.path)/scripts/fit-toolchain.sh", staging, "own", "\(share.path)/docker/toolchain"] })
    #expect(steps.last?.action == .packCommit(staging: URL(fileURLWithPath: staging), final: URL(fileURLWithPath: "/n/xcodes/27.0-27A266a-arm64")))
    #expect(!steps.contains { $0.argv.first == "docker" })
}

@Test func packStepsFollowTheTools() throws {
    let steps = try plan()
    let first = try #require(steps.firstIndex(where: isPackStep))
    // The tools, the export and its metadata, then the pack's steps and nothing else.
    #expect(steps[..<first].allSatisfy { !isPackStep($0) })
    #expect(steps[first...].allSatisfy(isPackStep))
    #expect(steps[first].action == .packBegin(staging: URL(fileURLWithPath: "/n/xcodes/27.0-27A266a-arm64.partial"), from: nil,
                                              manifest: PackManifest(format: PackRecipe.format, xcode: "27.0", build: "27A266a", arch: "arm64",
                                                                     swift: "6.4.0", mode: .own, parts: [:])))
    #expect(first == 4)
    // A bare host (no shims): no Swift Build, no check; the pack records the sdk part alone.
    #expect(!steps.contains { $0.argv.contains { $0.hasSuffix("pack-swift-build.sh") || $0.hasSuffix("pack-check.sh") } })
    let parts: [PackPart] = steps.compactMap { if case let .packPart(p, _, _) = $0.action { return p } else { return nil } }
    #expect(parts == [.sdk])
}

@Test func secondXcodeAddsAPack() throws {
    // Xcode 26.2's pack is in the store and current: a setup of 27.0 prepares 27.0's beside it and touches nothing of it.
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = XcodeStore(root: root.appendingPathComponent("xcodes"))
    let hash = try PackRecipe.hash(.sdk, build: "17C52", arch: "arm64", table: table, share: share)
    let p26 = XcodePack(root: s.directory(xcode: "26.2", build: "17C52", arch: "arm64"),
                        manifest: PackManifest(format: PackRecipe.format, xcode: "26.2", build: "17C52", arch: "arm64", swift: "6.2.3",
                                               mode: .separate, parts: ["sdk": hash]))
    try p26.manifest.write(to: p26.manifestFile)
    for entry in PackPlan.entries(of: .sdk) {
        try FileManager.default.createDirectory(at: p26.root.appendingPathComponent(entry), withIntermediateDirectories: true)
    }
    let all: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) || $0.path.hasPrefix("/n/") || $0.path.hasPrefix("/cache/") }
    // 26.2 again: nothing to do (its pack is current, the tools and the export are there).
    #expect(try plan(xcode26, store: s, existing: all).isEmpty)
    let steps = try plan(xcode27, store: s, existing: all)
    #expect(!steps.isEmpty)
    #expect(!steps.contains { $0.argv.joined(separator: " ").contains("26.2-17C52") || $0.title.contains("26.2-17C52") })
    #expect(steps.first?.action == .packBegin(staging: PackPlan.staging(of: s.directory(xcode: "27.0", build: "27A266a", arch: "arm64")),
                                              from: nil, manifest: PackManifest(format: PackRecipe.format, xcode: "27.0", build: "27A266a", arch: "arm64",
                                                                                swift: "6.4.0", mode: .own, parts: [:])))
    #expect(steps.last?.action == .packCommit(staging: PackPlan.staging(of: s.directory(xcode: "27.0", build: "27A266a", arch: "arm64")),
                                              final: s.directory(xcode: "27.0", build: "27A266a", arch: "arm64")))
}

@Test func aMacGetsTheSignersOwnReleaseByItsOwnPin() throws {
    var t = table
    #expect(throws: XlessError.self) { try NativeSetupPlan.rcodesign(arch: "arm64", mac: true, table: t, layout: layout) } // never Linux's pin
    t["RCODESIGN_SHA256_DARWIN_AARCH64"] = "da"
    t["RCODESIGN_SHA256_DARWIN_X86_64"] = "dx"
    let arm = try NativeSetupPlan.rcodesign(arch: "arm64", mac: true, table: t, layout: layout)
    #expect(arm.url.absoluteString == "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-aarch64-apple-darwin.tar.gz")
    #expect(arm.sha256 == "da" && arm.kind == .rcodesign && arm.final.path == "/n/tools/rcodesign-0.29.0")
    let x86 = try NativeSetupPlan.rcodesign(arch: "amd64", mac: true, table: t, layout: layout)
    #expect(x86.url.lastPathComponent == "apple-codesign-0.29.0-x86_64-apple-darwin.tar.gz" && x86.sha256 == "dx")
}

@Test func amd64DownloadsTheX86Pins() throws {
    let d = downloads(try plan(arch: "amd64"))
    #expect(d[0].url.lastPathComponent == "xtool-x86_64.AppImage" && d[0].sha256 == "xx")
    #expect(d[1].url.lastPathComponent == "apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz" && d[1].sha256 == "rx")
    #expect(d[2].sha256 == "s640x")
}

@Test func anotherSwiftReleaseIsFittedAsSeparate() throws {
    let steps = try plan(xcode26)
    #expect(downloads(steps).last?.final.path == "/n/xcodes/26.2-17C52-arm64.partial/toolchain")
    let fit = try #require(steps.first { $0.argv.first?.hasSuffix("/scripts/fit-toolchain.sh") == true })
    #expect(fit.argv[1] == "/n/xcodes/26.2-17C52-arm64.partial" && fit.argv[2] == "separate")
}

@Test func installedToolsAndAnExistingExportAreSkipped() throws {
    let present: Set<String> = ["/n/bin/xtool", "/n/bin/rcodesign",
                                "/cache/xless/sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk", "/cache/xless/sdk/xcode27.0-27A266a/toolchain-meta.json"]
    // No pack yet: the pack's steps alone.
    let steps = try plan { present.contains($0.path) }
    #expect(steps.allSatisfy(isPackStep))
    if case .packBegin = steps.first?.action {} else { Issue.record("first step is not the pack's: \(steps.first?.title ?? "none")") }
    // A tool unpacked but not linked into bin/ (a run stopped in between): installed again.
    let unlinked = try plan { present.subtracting(["/n/bin/xtool"]).contains($0.path) }
    #expect(downloads(unlinked).map(\.final.path) == ["/n/tools/xtool-1.21.0", "/n/xcodes/27.0-27A266a-arm64.partial/toolchain"])
    // --reexport: the export first, then its metadata.
    let again = try plan(reexport: true) { present.contains($0.path) }
    if case .export = again[0].action {} else { Issue.record("first step is not the export: \(again[0].title)") }
    if case .meta = again[1].action {} else { Issue.record("second step is not the metadata: \(again[1].title)") }
}

@Test func pinnedToolOnPathIsNotDownloaded() throws {
    // Executables that print a version, as xtool (`xtool 1.21.0`) and rcodesign (`apple-codesign 0.29.0`) do; the check runs them.
    let dir = try tempDir(), pinned = dir.appendingPathComponent("pinned"), other = dir.appendingPathComponent("other")
    for (bin, xtool, rcodesign) in [(pinned, "1.21.0", "0.29.0"), (other, "1.20.0", "0.28.0")] {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try ExecutableFile.write("#!/bin/sh\n[ \"$1\" = --version ] && echo 'xtool \(xtool)'\n", to: bin.appendingPathComponent("xtool"), stage: .sdk)
        try ExecutableFile.write("#!/bin/sh\n[ \"$1\" = --version ] && echo 'apple-codesign \(rcodesign)'\n", to: bin.appendingPathComponent("rcodesign"), stage: .sdk)
    }
    #expect(NativeSetupPlan.pinnedOnPath("xtool", version: "1.21.0", path: "\(other.path):\(pinned.path)") == nil) // the first one found is another version
    #expect(NativeSetupPlan.pinnedOnPath("xtool", version: "1.21.0", path: pinned.path)?.path == pinned.appendingPathComponent("xtool").path)
    #expect(NativeSetupPlan.pinnedOnPath("rcodesign", version: "0.29.0", path: pinned.path)?.path == pinned.appendingPathComponent("rcodesign").path)
    #expect(NativeSetupPlan.pinnedOnPath("rcodesign", version: "0.29.0", path: other.path) == nil)
    #expect(NativeSetupPlan.pinnedOnPath("xtool", version: "1.21", path: pinned.path) == nil) // a whole word, not a prefix
    #expect(NativeSetupPlan.pinnedOnPath("xtool", version: "1.21.0", path: dir.path) == nil)  // not there
    // One that does not run (exits non-zero) is not installed, whatever it prints.
    let broken = dir.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try ExecutableFile.write("#!/bin/sh\necho 'xtool 1.21.0'\nexit 1\n", to: broken.appendingPathComponent("xtool"), stage: .sdk)
    #expect(NativeSetupPlan.pinnedOnPath("xtool", version: "1.21.0", path: broken.path) == nil)

    func make(_ path: String) throws -> [SetupStep] {
        try NativeSetupPlan.make(source: (xcode27, .xip, URL(fileURLWithPath: "/home/u/Downloads/Xcode_27.xip")), arch: "arm64", share: share,
                                 cacheRoot: cache, layout: layout, store: store, table: table, reexport: false, abilities: bare,
                                 installed: { NativeSetupPlan.pinnedOnPath($0, version: $1, path: path) }, existing: { _ in false })
    }
    // Both pinned on PATH (an image): neither is downloaded into the native home, and the export runs the one on PATH.
    let steps = try make(pinned.path)
    #expect(downloads(steps).map(\.kind) == [.swiftToolchain])
    #expect(!steps.contains { $0.argv.joined(separator: " ").contains("/n/tools") || $0.argv.contains("/n/bin/xtool") })
    let export = try #require(steps.first { if case .export = $0.action { true } else { false } })
    #expect(export.argv.first == pinned.appendingPathComponent("xtool").path)
    // Another version on PATH: downloaded, and the export runs the downloaded one.
    let older = try make(other.path)
    #expect(downloads(older).map(\.kind) == [.appImage, .rcodesign, .swiftToolchain])
    #expect(older.first { if case .export = $0.action { true } else { false } }?.argv.first == "/n/bin/xtool")
}

@Test func anExportSourceIsInstalledFromWhereItIsAndNeverExported() throws {
    let export = URL(fileURLWithPath: "/exports/x27")
    let tools: Set<String> = ["/n/bin/xtool", "/n/bin/rcodesign"]
    let steps = try NativeSetupPlan.make(source: (xcode27, .export, export), arch: "arm64", share: share, cacheRoot: cache, layout: layout,
                                         store: store, table: table, reexport: false, abilities: bare, existing: { tools.contains($0.path) })
    for s in steps { if case .export = s.action { Issue.record("an export source was exported again: \(s.title)") } }
    #expect(steps[0].action == .meta(xtoolSDK: URL(fileURLWithPath: "/exports/x27/arm64/darwin.xtoolsdk"),
                                     out: URL(fileURLWithPath: "/exports/x27/toolchain-meta.json")))
    #expect(steps.contains { $0.action == .packSDK(xtoolSDK: URL(fileURLWithPath: "/exports/x27/arm64/darwin.xtoolsdk"),
                                                    config: URL(fileURLWithPath: "/n/xcodes/27.0-27A266a-arm64.partial/config"),
                                                    toolchain: URL(fileURLWithPath: "/n/xcodes/27.0-27A266a-arm64.partial/toolchain")) })
    #expect(steps.contains { $0.argv == ["cp", "/exports/x27/toolchain-meta.json", "/n/xcodes/27.0-27A266a-arm64.partial/toolchain-meta.json"] })
    #expect(steps.allSatisfy { !$0.argv.joined(separator: " ").contains("/cache/xless") })
}

@Test func aMissingPinIsRefusedNamingIt() throws {
    var t = table; t["SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64"] = nil
    #expect { try plan(table: t) } throws: { ($0 as? XlessError)?.cause.contains("SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64") == true }
    #expect { try plan(xcode26, arch: "amd64") } throws: { ($0 as? XlessError)?.cause.contains("SWIFT_TOOLCHAIN_6_2_3_URL_X86_64") == true }
    var u = table; u["XCODE_SWIFT_27A266a"] = nil
    #expect { try plan(table: u) } throws: { ($0 as? XlessError)?.cause.contains("XCODE_SWIFT_27A266a") == true }
}

@Test func theRepositorysVersionsEnvPinsEverySupportedXcodeForBothArchitectures() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let t = KnownXcodes.parseEnv(try String(contentsOf: root.appendingPathComponent("versions.env"), encoding: .utf8))
    for x in try KnownXcodes.load(versionsEnv: root.appendingPathComponent("versions.env")) {
        for a in ["arm64", "amd64"] { #expect(throws: Never.self) { try plan(x, arch: a, table: t, share: root) } }
    }
}

/// docs/native-install.md gives the same packages that setup's own messages name (the Swift toolchain needs
/// libncurses6, which an ubuntu:24.04 base lacks).
@Test func theNativeInstallDocListsTheAptPackages() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let doc = try String(contentsOf: root.appendingPathComponent("docs/native-install.md"), encoding: .utf8)
    #expect(NativeSetupPlan.aptPackages.contains("libncurses6"))
    #expect(doc.contains(NativeSetupPlan.aptLine + "\n"))
}
