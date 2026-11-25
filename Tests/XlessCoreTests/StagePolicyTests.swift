import Foundation
import Testing
@testable import XlessCore

// MARK: simulator builds stop at build (StagePolicy, what the CLI asks)

@Test(arguments: [Stage.assets, .finalize, .sign, .package, .upload])
func everyStageAfterBuildRefusesASimulatorBuildWithItsOwnExitCode(stage: Stage) throws {
    let app = URL(fileURLWithPath: "/w/.xless/build/ios-simulator/app")
    let e = #expect(throws: XlessError.self) { try StagePolicy.requireDevice(stage, simulator: true, appDir: app) }
    #expect(e?.stage == stage)
    #expect(e?.cause.contains("--destination simulator builds stop at build") == true)
    #expect(e?.fix.contains("/w/.xless/build/ios-simulator/app/<App>.app") == true)
    // A device build passes.
    try StagePolicy.requireDevice(stage, simulator: false, appDir: app)
}

@Test func aSimulatorShipDefaultsToBuildAndRefusesAnyLaterStage() {
    #expect(StagePolicy.lastStage(to: nil, simulator: true) == .build)
    #expect(StagePolicy.lastStage(to: nil, simulator: false) == .upload)
    #expect(StagePolicy.lastStage(to: .finalize, simulator: true) == .finalize)
    #expect(StagePolicy.shipRangeProblem(from: .build, last: .build, simulator: true) == nil)
    #expect(StagePolicy.shipRangeProblem(from: .prepare, last: .prepare, simulator: true) == nil)
    for last in [Stage.assets, .finalize, .sign, .package, .upload] {
        #expect(StagePolicy.shipRangeProblem(from: .build, last: last, simulator: true)
                == "--to \(last.rawValue): --destination simulator builds stop at build (prepare, build)")
        #expect(StagePolicy.shipRangeProblem(from: .build, last: last, simulator: false) == nil)
    }
    // --from past build implies --to past build: refused too.
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: StagePolicy.lastStage(to: nil, simulator: true), simulator: true)
            == "--to build comes before --from sign")
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: .sign, simulator: true) != nil)
}

@Test func shipRefusesStagesOutsideThePipeline() {
    for stage in [Stage.config, .sdk, .ib] {
        #expect(StagePolicy.shipRangeProblem(from: stage, last: .upload, simulator: false)
                == "--from \(stage.rawValue): `\(stage.rawValue)` is not a ship pipeline stage; use one of: prepare, build, assets, finalize, sign, package, upload")
        #expect(StagePolicy.shipRangeProblem(from: .build, last: stage, simulator: false)?.hasPrefix("--to \(stage.rawValue): ") == true)
    }
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: .finalize, simulator: false) == "--to finalize comes before --from sign")
}

/// `ship` uploads a Mac app only when the command line says so and it is built for the App Store.
@Test func shipUploadsAMacAppOnlyWhenAskedAndBuiltForTheAppStore() {
    func stages(to: Stage?, platform: Platform = .macos, distribution: Distribution, from: Stage = .sign, prepare: Bool = false) -> [Stage] {
        StagePolicy.shipStages(from: from, to: to, simulator: false, hasPrepare: prepare, platform: platform, distribution: distribution)
    }
    #expect(stages(to: .upload, distribution: .appStore) == [.sign, .package, .upload])
    #expect(stages(to: .upload, distribution: .appStore, from: .upload) == [.upload])
    #expect(stages(to: nil, distribution: .appStore) == [.sign, .package])
    #expect(stages(to: .package, distribution: .appStore) == [.sign, .package])
    #expect(stages(to: .upload, distribution: .developerID) == [.sign, .package])
    #expect(stages(to: nil, distribution: .developerID) == [.sign, .package])
    #expect(stages(to: nil, platform: .ios, distribution: .appStore) == [.sign, .package, .upload])
    #expect(stages(to: .upload, platform: .ios, distribution: .appStore, from: .build) == [.build, .assets, .finalize, .sign, .package, .upload])
    // An overlay build without a freshly synced work copy is never right: starting at build includes prepare.
    #expect(stages(to: .build, platform: .ios, distribution: .appStore, from: .build, prepare: true) == [.prepare, .build])
    #expect(stages(to: .build, platform: .ios, distribution: .appStore, from: .prepare) == [.build])
    #expect(stages(to: .finalize, platform: .ios, distribution: .appStore, from: .assets, prepare: true) == [.assets, .finalize])
    #expect(StagePolicy.shipStages(from: .build, to: nil, simulator: true, hasPrepare: true, platform: .ios, distribution: .appStore) == [.prepare, .build])
}

@Test func theSimulatorIsRefusedForTauriAndXlessYMLProjects() throws {
    let e = #expect(throws: XlessError.self) { try StagePolicy.requireReactNativeForSimulator(simulator: true, isReactNative: false) }
    #expect(e?.stage == .config && e?.stage.exitCode == 10)
    #expect(e?.description == "[config] --destination simulator builds React Native overlays only — drop --destination, or build a type: react-native overlay")
    try StagePolicy.requireReactNativeForSimulator(simulator: true, isReactNative: true)
    try StagePolicy.requireReactNativeForSimulator(simulator: false, isReactNative: false)
}

// MARK: the build stage's SDK and Swift checks (BuildSDKCheck, StageRunner.checkSDK and prepare)

private func meta(_ code: String, _ build: String, sdk: String, swift: String? = nil) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: code, xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [
        "iphoneos": .init(sdkName: "iphoneos\(sdk)", sdkVersion: sdk, sdkBuild: "23C50", platformName: "iphoneos", platformVersion: sdk, platformBuild: "23C50"),
    ], swiftVersion: swift)
}

private func tempDir(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func writeMeta(_ m: ToolchainMeta, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("toolchain-meta.json")
    try m.write(to: url)
    return url
}

/// A toolchain record whose `swiftc --version` prints `line`.
private func fakeToolchain(version: String, line: String) throws -> SwiftToolchain {
    let root = try tempDir("sdkcheck-tc")
    let swiftc = root.appendingPathComponent("usr/bin/swiftc")
    try FileManager.default.createDirectory(at: swiftc.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ExecutableFile.write("#!/bin/sh\necho '\(line)'\n", to: swiftc, stage: .build)
    return SwiftToolchain(version: version, root: root.path)
}

private func noToolchain() throws -> SwiftToolchain? { nil }

@Test func aMismatchedSDKIsRefusedAtBuildAndLeavesNoRecord() throws {
    let stage = try tempDir("sdkcheck-stage"), dir = try tempDir("sdkcheck-meta")
    // A stale record from an earlier build is removed before the check.
    try BuildSDKRecord(pin: "26.2", toolchain: meta("2620", "17C52", sdk: "26.2")).write(in: stage)
    let url = try writeMeta(meta("2700", "27A266a", sdk: "27.0"), in: dir)
    let e = #expect(throws: XlessError.self) {
        try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: "26.2", platform: .ios, file: "the overlay", metaURL: url, loadToolchain: noToolchain)
    }
    #expect(e?.stage == .build && e?.stage.exitCode == 12)
    #expect(e?.cause == "the overlay pins xcode: \"26.2\", but this image has the iphoneos27.0 SDK from Xcode 27.0 (27A266a)")
    #expect(BuildSDKRecord.load(in: stage) == nil)
    #expect(!FileManager.default.fileExists(atPath: BuildSDKRecord.url(in: stage).path))
}

@Test func aPinWithoutMetadataIsRefusedAndNoPinWithoutMetadataRecordsNothing() throws {
    let stage = try tempDir("sdkcheck-stage")
    let missing = stage.appendingPathComponent("none/toolchain-meta.json")
    try BuildSDKRecord(pin: nil, toolchain: meta("2700", "27A266a", sdk: "27.0")).write(in: stage)
    let e = #expect(throws: XlessError.self) {
        try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: "26.2", platform: .ios, file: "xless.yml", metaURL: missing, loadToolchain: noToolchain)
    }
    #expect(e?.stage == .build && e?.cause.hasPrefix("xcode: \"26.2\" is pinned, but toolchain metadata not found") == true)
    #expect(BuildSDKRecord.load(in: stage) == nil)
    // No pin, no metadata, no toolchain: nothing to check, nothing recorded (the stale record is still removed).
    try BuildSDKRecord(pin: nil, toolchain: meta("2700", "27A266a", sdk: "27.0")).write(in: stage)
    let (result, record) = try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: nil, platform: .ios, file: "xless.yml", metaURL: missing, loadToolchain: noToolchain)
    #expect(result.meta == nil && result.swift == nil && record == nil)
    #expect(BuildSDKRecord.load(in: stage) == nil)
}

@Test func aMatchingImageIsRecordedWithItsSwift() throws {
    let stage = try tempDir("sdkcheck-stage"), dir = try tempDir("sdkcheck-meta")
    let m = meta("2620", "17C52", sdk: "26.2", swift: "6.2.3")
    let url = try writeMeta(m, in: dir)
    let tc = try fakeToolchain(version: "6.2.3", line: "Swift version 6.2.3 (swift-6.2.3-RELEASE)")
    let (result, record) = try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: "26.2", platform: .ios, file: "the overlay", metaURL: url, loadToolchain: { tc })
    #expect(result.toolchain == tc)
    #expect(record?.swift?.version == "6.2.3" && record?.swift?.compiler == "Swift version 6.2.3 (swift-6.2.3-RELEASE)")
    #expect(BuildSDKRecord.load(in: stage) == record && record?.toolchain == m && record?.pin == "26.2")
}

@Test func aSwiftToolchainOtherThanTheXcodesIsRefused() throws {
    let stage = try tempDir("sdkcheck-stage"), dir = try tempDir("sdkcheck-meta")
    let url = try writeMeta(meta("2620", "17C52", sdk: "26.2", swift: "6.2.3"), in: dir)
    // The image compiles with 6.4, but Xcode 26.2 ships 6.2.3 (Ruling R10).
    let tc = try fakeToolchain(version: "6.4", line: "Swift version 6.4 (swift-6.4-RELEASE)")
    let e = #expect(throws: XlessError.self) {
        try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: nil, platform: .ios, file: "the overlay", metaURL: url, loadToolchain: { tc })
    }
    #expect(e?.stage == .build && e?.cause.contains("compiles with Swift 6.4, but its SDK's Xcode 26.2 (17C52) ships Swift 6.2.3") == true)
    #expect(BuildSDKRecord.load(in: stage) == nil)
    // A pinned project in an image without a toolchain record (from before Ruling R10) is refused.
    let e2 = #expect(throws: XlessError.self) {
        try BuildSDKCheck.checkAndRecord(stageRoot: stage, pin: "26.2", platform: .ios, file: "the overlay", metaURL: url, loadToolchain: noToolchain)
    }
    #expect(e2?.stage == .build && e2?.cause.contains("records no Swift toolchain") == true)
    // A toolchain record that cannot be read is the stage's error too.
    let e3 = #expect(throws: XlessError.self) {
        try BuildSDKCheck.check(pin: nil, platform: .ios, file: "the overlay", stage: .prepare, metaURL: url,
                                loadToolchain: { try SwiftToolchain.load(env: ["XLESS_SWIFT_TOOLCHAIN": "/nope.json"]) })
    }
    #expect(e3?.stage == .prepare)
}

@Test func prepareRunsTheSameChecksWithItsOwnStageAndRecordsNothing() throws {
    let dir = try tempDir("sdkcheck-meta")
    let url = try writeMeta(meta("2700", "27A266a", sdk: "27.0"), in: dir)
    let e = #expect(throws: XlessError.self) {
        try BuildSDKCheck.check(pin: "26.2", platform: .ios, file: "the overlay", stage: .prepare, metaURL: url, loadToolchain: noToolchain)
    }
    #expect(e?.stage == .prepare && e?.stage.exitCode == 19 && e?.cause.contains("pins xcode: \"26.2\"") == true)
    let missing = dir.appendingPathComponent("none.json")
    let e2 = #expect(throws: XlessError.self) {
        try BuildSDKCheck.check(pin: "26.2", platform: .ios, file: "the overlay", stage: .prepare, metaURL: missing, loadToolchain: noToolchain)
    }
    #expect(e2?.stage == .prepare)
    // A matching pin passes (27 is 27.0).
    let ok = try BuildSDKCheck.check(pin: "27", platform: .ios, file: "the overlay", stage: .prepare, metaURL: url,
                                     loadToolchain: { try fakeToolchain(version: "6.4", line: "Swift version 6.4 (swift-6.4-RELEASE)") })
    #expect(ok.meta?.xcodeBuild == "27A266a" && ok.swift?.version == "6.4")
}
