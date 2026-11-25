import Foundation
import Testing
@testable import XlessCore

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

@Test func theBuildSDKRecordRoundTripsAndSummarises() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkrec-\(UUID())")
    #expect(BuildSDKRecord.load(in: dir) == nil)
    let r = BuildSDKRecord(pin: "26.2", toolchain: meta("2620", "17C52", sdk: "26.2"))
    try r.write(in: dir)
    #expect(BuildSDKRecord.load(in: dir) == r)
    #expect(r.summary(platform: .ios) == "Xcode 26.2 (17C52), iphoneos26.2 SDK (23C50), pinned by xcode: \"26.2\"")
}
