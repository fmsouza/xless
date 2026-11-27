import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private let xcode27 = KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
private let xcode26 = KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: [])
private let store = XcodeStore(root: URL(fileURLWithPath: "/n/xcodes"))
private let export26 = URL(fileURLWithPath: "/cache/xless/sdk/xcode26.2-17C52")
private let table: [String: String] = [
    "SWIFT_VERSION": "6.4.0", "XTOOL_VERSION": "1.21.0", "SWIFT_IMAGE": "swift:6.4.0-jammy@sha256:abc",
    "SWB_TAG": "swift-6.4.0-RELEASE", "SWB_SHA256": "swb1", "SWB_DRIVER_SHA256": "swb2", "SWB_SYSTEM_VERSION": "1.5.0",
    "XCODE_SWIFT_27A266a": "6.4.0", "XCODE_SWIFT_17C52": "6.2.3",
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64": "https://example.com/s640-a.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64": "s640a",
    "SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64": "https://example.com/s623-a.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64": "s623a",
    "SWIFT_TOOLCHAIN_6_2_3_URL_X86_64": "https://example.com/s623-x.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_X86_64": "s623x",
]

/// A share with the files the hashes read.
private let share: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-plan-share-\(UUID().uuidString)")
    for path in ["scripts/fit-toolchain.sh", "scripts/pack-swift-build.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
                 "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt", "docker/toolchain/target-os/27A266a.txt",
                 "docker/toolchain/target-os/17C52.txt"] {
        let url = dir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(path.utf8).write(to: url)
    }
    return dir
}()

private let able = PackPlan.Abilities(swiftBuild: true), bare = PackPlan.Abilities(swiftBuild: false)

private func hash(_ part: PackPart, _ x: KnownXcode = xcode26, arch: String = "arm64", table t: [String: String] = table) throws -> String {
    try PackRecipe.hash(part, build: x.build, arch: arch, table: t, share: share)
}

/// The pack of `x` in the store, recording `parts`.
private func pack(_ x: KnownXcode = xcode26, arch: String = "arm64", parts: [String: String]) -> XcodePack {
    let v = XcodeVersion.canonical(x.shortVersion)
    return XcodePack(root: store.directory(xcode: v, build: x.build, arch: arch),
                     manifest: PackManifest(format: PackRecipe.format, xcode: v, build: x.build, arch: arch,
                                            swift: table["XCODE_SWIFT_\(x.build)"]!, mode: PackRecipe.mode(swift: table["XCODE_SWIFT_\(x.build)"]!, table: table), parts: parts))
}

private func plan(_ x: KnownXcode = xcode26, arch: String = "arm64", table t: [String: String] = table, abilities: PackPlan.Abilities = able,
                  current: XcodePack? = nil, existing: @escaping (URL) -> Bool = { _ in true }) throws -> [SetupStep] {
    try PackPlan.make(xcode: x, arch: arch, export: export26, store: store, share: share, table: t, abilities: abilities,
                      current: current, existing: existing)
}

private enum Kind: Equatable { case begin, download, sdk, meta, fit, part(PackPart), swiftBuild, check, commit, other }

private func kinds(_ steps: [SetupStep]) -> [Kind] {
    steps.map { s in
        switch s.action {
        case .packBegin: return .begin
        case .download: return .download
        case .packSDK: return .sdk
        case let .packPart(p, _, _): return .part(p)
        case .packCommit: return .commit
        case .run:
            if s.argv.first == "cp", s.argv.last?.hasSuffix("/toolchain-meta.json") == true { return .meta }
            if s.argv.first?.hasSuffix("/scripts/fit-toolchain.sh") == true { return .fit }
            if s.argv.contains(where: { $0.hasSuffix("/scripts/pack-swift-build.sh") }) { return .swiftBuild }
            if s.argv.first?.hasSuffix("/scripts/pack-check.sh") == true { return .check }
            return .other
        default: return .other
        }
    }
}

private func begin(_ steps: [SetupStep]) -> (staging: URL, from: URL?, manifest: PackManifest)? {
    for s in steps { if case let .packBegin(staging, from, manifest) = s.action { return (staging, from, manifest) } }
    return nil
}

/// The parts the committed `pack.json` names: those seeded, and those recorded.
private func committedParts(_ steps: [SetupStep]) -> [String] {
    var parts = Set(begin(steps)?.manifest.parts.keys.map { $0 } ?? [])
    for s in steps { if case let .packPart(p, _, _) = s.action { parts.insert(p.rawValue) } }
    return parts.sorted()
}

private let staging26 = "/n/xcodes/26.2-17C52-arm64.partial"

@Test func absentPackPreparesBothParts() throws {
    let steps = try plan()
    #expect(kinds(steps) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .swiftBuild, .part(.swiftBuild), .check, .commit])
    let b = try #require(begin(steps))
    #expect(b.from == nil && b.manifest.parts.isEmpty)
    #expect(b.manifest == PackManifest(format: PackRecipe.format, xcode: "26.2", build: "17C52", arch: "arm64", swift: "6.2.3", mode: .separate, parts: [:]))
    guard case let .download(d) = steps[1].action else { Issue.record("no download"); return }
    #expect(d.kind == .swiftToolchain && d.url.absoluteString == "https://example.com/s623-a.tar.gz" && d.sha256 == "s623a")
    #expect(d.final.path == "\(staging26)/toolchain" && d.partial.path == "\(staging26)/toolchain.partial")
    #expect(steps[2].action == .packSDK(xtoolSDK: export26.appendingPathComponent("arm64/darwin.xtoolsdk"),
                                        config: URL(fileURLWithPath: "\(staging26)/config"), toolchain: URL(fileURLWithPath: "\(staging26)/toolchain")))
    #expect(steps[3].argv == ["cp", "/cache/xless/sdk/xcode26.2-17C52/toolchain-meta.json", "\(staging26)/toolchain-meta.json"])
    #expect(steps[4].argv == [share.appendingPathComponent("scripts/fit-toolchain.sh").path, staging26, "separate",
                              share.appendingPathComponent("docker/toolchain").path])
    #expect(steps[5].action == .packPart(.sdk, hash: try hash(.sdk), staging: URL(fileURLWithPath: staging26)))
    #expect(steps[7].action == .packPart(.swiftBuild, hash: try hash(.swiftBuild), staging: URL(fileURLWithPath: staging26)))
    #expect(steps[8].argv == [share.appendingPathComponent("scripts/pack-check.sh").path, staging26])
    #expect(steps[9].action == .packCommit(staging: URL(fileURLWithPath: staging26), final: URL(fileURLWithPath: "/n/xcodes/26.2-17C52-arm64")))
    #expect(committedParts(steps) == ["sdk", "swift-build"])
}

@Test func swiftBuildIsCompiledWithThePinsTheArchAndTheMode() throws {
    let steps = try plan()
    let compile = try #require(steps.first { kinds([$0]) == [.swiftBuild] })
    #expect(compile.argv == ["env", "SWB_DRIVER_SHA256=swb2", "SWB_SHA256=swb1", "SWB_SYSTEM_VERSION=1.5.0", "SWB_TAG=swift-6.4.0-RELEASE",
                             share.appendingPathComponent("scripts/pack-swift-build.sh").path, staging26, "arm64", "separate"])
    #expect(compile.action == .run)
}

@Test func bareHostPreparesNoSwiftBuild() throws {
    let steps = try plan(abilities: bare)
    #expect(kinds(steps) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .commit])
    #expect(committedParts(steps) == ["sdk"])
}

@Test func currentPackIsNothingToDo() throws {
    let current = pack(parts: ["sdk": try hash(.sdk), "swift-build": try hash(.swiftBuild)])
    #expect(try plan(current: current).isEmpty)
    #expect(try plan(abilities: bare, current: current).isEmpty)
    // A bare host has nothing to add to a pack with only its SDK.
    #expect(try plan(abilities: bare, current: pack(parts: ["sdk": try hash(.sdk)])).isEmpty)
}

@Test func staleSwiftBuildAloneIsRecompiled() throws {
    let current = pack(parts: ["sdk": try hash(.sdk), "swift-build": "other"])
    let steps = try plan(current: current)
    #expect(kinds(steps) == [.begin, .swiftBuild, .part(.swiftBuild), .check, .commit])
    let b = try #require(begin(steps))
    #expect(b.from == current.root)
    #expect(b.manifest.parts == ["sdk": try hash(.sdk)])
    // The dry run shows the seeding: the sdk part's entries, linked.
    #expect(steps[0].argv.contains { $0.contains("cp -al") })
    #expect(Array(steps[0].argv.suffix(5)) == ["toolchain", "config", "toolchain-meta.json", "swift-toolchain.json", "include"]
        .map { current.root.appendingPathComponent($0).path })
    #expect(!steps[0].argv.contains(current.root.appendingPathComponent("swift-build").path))
}

@Test func missingSwiftBuildIsAdded() throws {
    let current = pack(parts: ["sdk": try hash(.sdk)])   // prepared on a bare host
    let steps = try plan(current: current)
    #expect(kinds(steps) == [.begin, .swiftBuild, .part(.swiftBuild), .check, .commit])
    #expect(begin(steps)?.manifest.parts == ["sdk": try hash(.sdk)])
    #expect(committedParts(steps) == ["sdk", "swift-build"])
}

/// The decision on `swift-build` after `sdk`: its hash covers the toolchain's sha256 and nothing of the fit, so an `sdk`
/// prepared again from the same toolchain keeps a current `swift-build`.
@Test func staleSdkKeepsACurrentSwiftBuild() throws {
    let current = pack(parts: ["sdk": "other", "swift-build": try hash(.swiftBuild)])
    let steps = try plan(current: current)
    #expect(kinds(steps) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .check, .commit])
    let b = try #require(begin(steps))
    let swiftBuild = try hash(.swiftBuild)
    #expect(b.from == current.root && b.manifest.parts == ["swift-build": swiftBuild])
    #expect(Array(steps[0].argv.suffix(1)) == [current.root.appendingPathComponent("swift-build").path])
    #expect(!steps[0].argv.contains(current.root.appendingPathComponent("toolchain").path))
    // On a bare host too: the part it could not compile is kept, and nothing checks it.
    #expect(kinds(try plan(abilities: bare, current: current)) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .commit])
    #expect(committedParts(try plan(abilities: bare, current: current)) == ["sdk", "swift-build"])
}

@Test func aNewToolchainPreparesBothParts() throws {
    let current = pack(parts: ["sdk": try hash(.sdk), "swift-build": try hash(.swiftBuild)])
    var t = table
    t["SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64"] = "new"
    #expect(kinds(try plan(table: t, current: current)) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .swiftBuild, .part(.swiftBuild), .check, .commit])
    #expect(begin(try plan(table: t, current: current))?.from == nil)
    // A bare host prepares the SDK, and leaves out the stale Swift Build it cannot compile.
    #expect(committedParts(try plan(table: t, abilities: bare, current: current)) == ["sdk"])
}

@Test func aPartWithAMissingEntryIsPreparedAgain() throws {
    let current = pack(parts: ["sdk": try hash(.sdk), "swift-build": try hash(.swiftBuild)])
    let steps = try plan(current: current, existing: { $0.lastPathComponent != "include" })
    #expect(kinds(steps) == [.begin, .download, .sdk, .meta, .fit, .part(.sdk), .check, .commit])
    #expect(begin(steps)?.manifest.parts.keys.sorted() == ["swift-build"])
}

@Test func aPackOfAnotherFormatIsPreparedWhole() throws {
    var current = pack(parts: ["sdk": try hash(.sdk), "swift-build": try hash(.swiftBuild)])
    current = XcodePack(root: current.root, manifest: { var m = current.manifest; m.format = PackRecipe.format + 1; return m }())
    #expect(begin(try plan(current: current))?.from == nil)
    #expect(kinds(try plan(current: current)).count == 10)
}

@Test func stagingIsBesideTheDestination() throws {
    let steps = try plan()
    #expect(begin(steps)?.staging.path == "/n/xcodes/26.2-17C52-arm64.partial")
    #expect(PackPlan.staging(of: URL(fileURLWithPath: "/n/xcodes/26.2-17C52-arm64")).path == "/n/xcodes/26.2-17C52-arm64.partial")
}

/// Nothing is written outside the staging directory before the commit: every path under the store that a step names
/// (in its command or its action) is in the staging directory, until the last step.
@Test func onlyTheStagingDirectoryIsWrittenBeforeTheCommit() throws {
    let current = pack(parts: ["sdk": "other", "swift-build": "other"])
    let steps = try plan(current: current)
    for s in steps.dropLast() {
        var paths = s.argv
        switch s.action {
        case let .download(d): paths += [d.final.path, d.partial.path]
        case let .packSDK(_, config, toolchain): paths += [config.path, toolchain.path]
        case let .packPart(_, _, staging): paths.append(staging.path)
        case let .packBegin(staging, _, _): paths.append(staging.path)
        default: break
        }
        for p in paths where p.hasPrefix(store.root.path) {
            #expect(p.hasPrefix(staging26), "\(s.title): \(p)")
        }
    }
}

@Test func ownModeForTheImagesSwift() throws {
    let steps = try plan(xcode27)
    let fit = try #require(steps.first { kinds([$0]) == [.fit] })
    #expect(fit.argv[1] == "/n/xcodes/27.0-27A266a-arm64.partial" && fit.argv[2] == "own")
    #expect(begin(steps)?.manifest.mode == .own && begin(steps)?.manifest.swift == "6.4.0")
    #expect(try plan().first { kinds([$0]) == [.fit] }?.argv[2] == "separate")
}

@Test func amd64TakesTheX86Toolchain() throws {
    let steps = try plan(arch: "amd64")
    guard case let .download(d) = steps[1].action else { Issue.record("no download"); return }
    #expect(d.sha256 == "s623x" && d.final.path == "/n/xcodes/26.2-17C52-amd64.partial/toolchain")
    #expect(steps[2].action == .packSDK(xtoolSDK: export26.appendingPathComponent("amd64/darwin.xtoolsdk"),
                                        config: URL(fileURLWithPath: "/n/xcodes/26.2-17C52-amd64.partial/config"),
                                        toolchain: URL(fileURLWithPath: "/n/xcodes/26.2-17C52-amd64.partial/toolchain")))
}

@Test func aMissingPinIsNamed() throws {
    var t = table
    t["SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64"] = nil
    #expect { try plan(table: t) } throws: { ($0 as? XlessError)?.cause.contains("SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64") == true }
    // A table that cannot compile Swift Build still prepares the SDK on a bare host.
    var noSWB = table
    noSWB["SWB_TAG"] = nil
    #expect(committedParts(try plan(table: noSWB, abilities: bare)) == ["sdk"])
    #expect(throws: XlessError.self) { try plan(table: noSWB) }
}

@Test func abilitiesFollowTheShims() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-plan-shims-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("file")
    try Data().write(to: file)
    #expect(PackPlan.abilities(env: [:]) == bare)
    #expect(PackPlan.abilities(env: ["XLESS_SHIM_DIR": ""]) == bare)
    #expect(PackPlan.abilities(env: ["XLESS_SHIM_DIR": dir.appendingPathComponent("none").path]) == bare)
    #expect(PackPlan.abilities(env: ["XLESS_SHIM_DIR": file.path]) == bare)
    #expect(PackPlan.abilities(env: ["XLESS_SHIM_DIR": dir.path]) == able)
}

// MARK: - The in-process steps, on disk

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-plan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A pack on disk with both parts: a file in each entry, a relative link in the toolchain, a read-only directory.
private func packOnDisk(in root: URL) throws -> URL {
    let fm = FileManager.default
    let p = root.appendingPathComponent("26.2-17C52-arm64")
    for dir in ["toolchain/usr/bin", "config/swiftpm/swift-sdks/darwin.artifactbundle", "include/swift", "swift-build/SwiftBuild_SWBCore.resources"] {
        try fm.createDirectory(at: p.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try Data("swiftc".utf8).write(to: p.appendingPathComponent("toolchain/usr/bin/swiftc"))
    try fm.createSymbolicLink(atPath: p.appendingPathComponent("toolchain/usr/bin/clang").path, withDestinationPath: "clang-17")
    try Data("{}".utf8).write(to: p.appendingPathComponent("toolchain-meta.json"))
    try Data("{}".utf8).write(to: p.appendingPathComponent("swift-toolchain.json"))
    try Data("b".utf8).write(to: p.appendingPathComponent("include/swift/bridging"))
    try Data("toolset".utf8).write(to: p.appendingPathComponent("config/swiftpm/swift-sdks/darwin.artifactbundle/toolset-swb.json"))
    try Data("swbuild".utf8).write(to: p.appendingPathComponent("swift-build/swbuild"))
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: p.appendingPathComponent("include/swift").path)
    try pack(parts: ["sdk": "s", "swift-build": "old"]).manifest.write(to: p.appendingPathComponent("pack.json"))
    return p
}

private func inode(_ url: URL) throws -> UInt64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

private func cleanUp(_ dir: URL) {
    // Read-only directories are made writable first, so they can be removed.
    if let e = FileManager.default.enumerator(atPath: dir.path) {
        for case let p as String in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(p).path) }
    }
    try? FileManager.default.removeItem(at: dir)
}

@Test func beginSeedsTheCurrentPartsOnlyWithHardLinks() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let current = try packOnDisk(in: root)
    let staging = root.appendingPathComponent("26.2-17C52-arm64.partial")
    // A leftover of an interrupted setup is removed, never reused.
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("swift-build"), withIntermediateDirectories: true)
    let manifest = pack(parts: ["sdk": "s"]).manifest
    try PackPlan.begin(staging: staging, from: current, manifest: manifest)

    #expect(try PackManifest.load(from: staging.appendingPathComponent("pack.json")) == manifest)
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("swift-build").path))
    for f in ["toolchain/usr/bin/swiftc", "toolchain-meta.json", "swift-toolchain.json", "include/swift/bridging",
              "config/swiftpm/swift-sdks/darwin.artifactbundle/toolset-swb.json"] {
        #expect(try inode(staging.appendingPathComponent(f)) == inode(current.appendingPathComponent(f)), "\(f) is not linked")
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("toolchain/usr/bin/clang").path) == "clang-17")
    let mode = try FileManager.default.attributesOfItem(atPath: staging.appendingPathComponent("include/swift").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o555)
    // The pack in use is untouched.
    #expect(try PackManifest.load(from: current.appendingPathComponent("pack.json")).parts == ["sdk": "s", "swift-build": "old"])
}

@Test func beginCopiesWhereLinkingFails() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let current = try packOnDisk(in: root)
    let staging = root.appendingPathComponent("26.2-17C52-arm64.partial")
    try PackPlan.begin(staging: staging, from: current, manifest: pack(parts: ["swift-build": "h"]).manifest, link: { _, _ in false })
    let f = "swift-build/swbuild"
    #expect(try Data(contentsOf: staging.appendingPathComponent(f)) == Data("swbuild".utf8))
    #expect(try inode(staging.appendingPathComponent(f)) != inode(current.appendingPathComponent(f)))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("toolchain").path))
}

@Test func beginWithNothingCurrentStartsEmpty() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let staging = root.appendingPathComponent("xcodes/26.2-17C52-arm64.partial")
    try PackPlan.begin(staging: staging, from: nil, manifest: pack(parts: [:]).manifest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["pack.json"])
}

@Test func recordAddsAPartAndCommitSwapsThePackWhole() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let current = try packOnDisk(in: root)
    let staging = root.appendingPathComponent("26.2-17C52-arm64.partial")
    try PackPlan.begin(staging: staging, from: current, manifest: pack(parts: ["sdk": "s"]).manifest)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("swift-build"), withIntermediateDirectories: true)
    try Data("new".utf8).write(to: staging.appendingPathComponent("swift-build/swbuild"))
    try PackPlan.record(.swiftBuild, hash: "new", staging: staging)
    #expect(try PackManifest.load(from: staging.appendingPathComponent("pack.json")).parts == ["sdk": "s", "swift-build": "new"])
    // Until the commit the pack in use is the old one; the staging directory is no pack of the store.
    #expect(XcodeStore(root: root).packs().map(\.root.lastPathComponent) == ["26.2-17C52-arm64"])
    #expect(try XcodePack.open(current)?.manifest.parts["swift-build"] == "old")

    try PackPlan.commit(staging: staging, final: current)
    #expect(try XcodePack.open(current)?.manifest.parts == ["sdk": "s", "swift-build": "new"])
    #expect(try Data(contentsOf: current.appendingPathComponent("swift-build/swbuild")) == Data("new".utf8))
    #expect(try Data(contentsOf: current.appendingPathComponent("toolchain/usr/bin/swiftc")) == Data("swiftc".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["26.2-17C52-arm64"])
}

@Test func commitIntoAnEmptyPlace() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let final = root.appendingPathComponent("26.2-17C52-arm64"), staging = PackPlan.staging(of: final)
    try PackPlan.begin(staging: staging, from: nil, manifest: pack(parts: [:]).manifest)
    try PackPlan.record(.sdk, hash: "s", staging: staging)
    try PackPlan.commit(staging: staging, final: final)
    #expect(try XcodePack.open(final)?.manifest.parts == ["sdk": "s"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["26.2-17C52-arm64"])
}

@Test func commitRefusesAStagingDirectoryWithoutAManifest() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let current = try packOnDisk(in: root)
    let staging = PackPlan.staging(of: current)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    #expect(throws: XlessError.self) { try PackPlan.commit(staging: staging, final: current) }
    #expect(try XcodePack.open(current)?.manifest.parts["swift-build"] == "old")
}

// MARK: - What --dry-run prints does what the step does

private func sh(_ argv: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = argv
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

@Test func theRecordAndCommitCommandsDoWhatTheirStepsDo() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let current = try packOnDisk(in: root)
    let staging = PackPlan.staging(of: current)
    try PackPlan.begin(staging: staging, from: current, manifest: pack(parts: ["sdk": "s"]).manifest)
    #expect(try sh(PackPlan.recordArgv(.swiftBuild, hash: "h2", staging: staging)) == 0)
    #expect(try PackManifest.load(from: staging.appendingPathComponent("pack.json")).parts == ["sdk": "s", "swift-build": "h2"])
    #expect(try sh(PackPlan.commitArgv(staging: staging, final: current)) == 0)
    #expect(try XcodePack.open(current)?.manifest.parts == ["sdk": "s", "swift-build": "h2"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["26.2-17C52-arm64"])
}

@Test func theBeginCommandWritesTheManifestOfItsStep() throws {
    let root = try tempDir()
    defer { cleanUp(root) }
    let staging = root.appendingPathComponent("26.2-17C52-arm64.partial")
    let manifest = pack(parts: [:]).manifest
    #expect(try sh(PackPlan.beginArgv(staging: staging, from: nil, manifest: manifest)) == 0)
    #expect(try PackManifest.load(from: staging.appendingPathComponent("pack.json")) == manifest)
    #if os(Linux)
    // GNU cp -al: the seeded form links what the step links.
    let current = try packOnDisk(in: root)
    let seeded = pack(parts: ["sdk": "s"]).manifest
    #expect(try sh(PackPlan.beginArgv(staging: staging, from: current, manifest: seeded)) == 0)
    #expect(try PackManifest.load(from: staging.appendingPathComponent("pack.json")) == seeded)
    #expect(try inode(staging.appendingPathComponent("toolchain/usr/bin/swiftc")) == inode(current.appendingPathComponent("toolchain/usr/bin/swiftc")))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("swift-build").path))
    #endif
}
