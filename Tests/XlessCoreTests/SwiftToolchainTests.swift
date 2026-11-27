import Foundation
import Testing
@testable import XlessCore

private func fakeToolchain(_ versionLine: String) throws -> SwiftToolchain {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-tc-\(UUID().uuidString)")
    let swiftc = root.appendingPathComponent("usr/bin/swiftc")
    try FileManager.default.createDirectory(at: swiftc.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ExecutableFile.write("#!/bin/sh\necho '\(versionLine)'\necho 'Target: aarch64-unknown-linux-gnu'\n", to: swiftc, stage: .build)
    return SwiftToolchain(version: "6.2.3", root: root.path)
}

private func meta(swift: String?) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: "2620", xcodeBuild: "17C52", buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler,
                  platforms: [:], swiftVersion: swift)
}

@Test func parsesOpenSourceAndAppleVersions() {
    #expect(SwiftToolchain.parseVersion("Swift version 6.2.3 (swift-6.2.3-RELEASE)\nTarget: aarch64-unknown-linux-gnu") == "6.2.3")
    #expect(SwiftToolchain.parseVersion("swift-driver version: 1.127.14.1 Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)") == "6.2.3")
    #expect(SwiftToolchain.parseVersion("swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)") == "6.4")
    #expect(SwiftToolchain.parseVersion("clang version 17.0.0") == nil)
}

@Test func theMapRuleKeepsMajorMinorAndNoHigherPatch() {
    #expect(SwiftToolchain.matches(openSource: "6.2.3", apple: "6.2.3"))
    #expect(SwiftToolchain.matches(openSource: "6.2.1", apple: "6.2.3"))   // Apple ahead of the open-source releases
    #expect(SwiftToolchain.matches(openSource: "6.4.0", apple: "6.4"))
    #expect(!SwiftToolchain.matches(openSource: "6.2.4", apple: "6.2.3"))
    #expect(!SwiftToolchain.matches(openSource: "6.4", apple: "6.2.3"))
    #expect(!SwiftToolchain.matches(openSource: "6.2.3", apple: "6.4"))
}

@Test func pathPutsTheToolchainRightBeforeTheImagesSwift() {
    let t = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
    #expect(t.path("/opt/xless/shims:/usr/local/bin:/usr/sbin:/usr/bin:/bin")
        == "/opt/xless/shims:/usr/local/bin:/usr/sbin:/opt/xless/toolchains/swift-6.2.3/usr/bin:/usr/bin:/bin")
    #expect(t.path("/a:/b") == "/opt/xless/toolchains/swift-6.2.3/usr/bin:/a:/b")
    #expect(t.path(t.path("/usr/bin")) == "/opt/xless/toolchains/swift-6.2.3/usr/bin:/usr/bin")   // idempotent
    let engine = SwiftToolchain(version: "6.4", root: "/")
    #expect(engine.isEngine && engine.path("/x:/usr/bin") == "/x:/usr/bin")
    #expect(engine.tool("swiftc") == "/usr/bin/swiftc")
    #expect(SwiftToolchain.engineSwift(t) == "/usr/bin/swift" && SwiftToolchain.engineSwift(nil) == "swift")
}

/// An Xcode pack whose Swift is the image's own (mode own) holds a copy of that release, fitted to its SDK: its own tools
/// go on PATH (it is not the engine), but its SwiftPM is the engine's release and builds as the engine's does.
@Test func aCopyOfTheEnginesReleaseBuildsAsTheEngine() {
    let copy = SwiftToolchain(version: "6.4", root: "/xcodes/27.0-27A266a-arm64/toolchain")
    #expect(!copy.isEngine && copy.path("/x:/usr/bin") == "/x:/xcodes/27.0-27A266a-arm64/toolchain/usr/bin:/usr/bin")
    #expect(copy.isEngineRelease("6.4.0") && copy.isEngineRelease("6.4"))
    #expect(!copy.isEngineRelease("6.4.1") && !copy.isEngineRelease("6.2.3") && !copy.isEngineRelease(nil) && !copy.isEngineRelease("main"))
    #expect(!SwiftToolchain(version: "6.2.3", root: "/xcodes/26.2-17C52-arm64/toolchain").isEngineRelease("6.4.0"))
    // The engine's way of building (the triple, no product named) is SwiftPM 6.4's: an older copy never takes it, even
    // where the engine is that release too (a Linux host's own Swift).
    #expect(!SwiftToolchain(version: "6.2.3", root: "/xcodes/26.2-17C52-arm64/toolchain").isEngineRelease("6.2.3"))
    #expect(!SwiftToolchain(version: "6.3.0", root: "/xcodes/26.4-17E1-arm64/toolchain").isEngineRelease("6.3"))
    #expect(SwiftToolchain(version: "6.5", root: "/xcodes/28.0-28A1-arm64/toolchain").isEngineRelease("6.5.0"))
    // The engine itself, whatever its release is measured to be.
    #expect(SwiftToolchain(version: "6.4", root: "/").isEngineRelease(nil) && SwiftToolchain(version: "6.4", root: "/").isEngineRelease("6.2.3"))
}

/// The engine's release is measured from its swiftc, where the images have it (Linux); elsewhere there is none.
@Test func theEnginesReleaseIsMeasured() {
    #if os(Linux)
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc") { #expect(SwiftToolchain.engineRelease.flatMap(DottedVersion.init) != nil) }
    #else
    #expect(SwiftToolchain.engineRelease == nil)
    #endif
}

@Test func loadsTheRecordNamedByTheEnvironment() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("swift-toolchain-\(UUID().uuidString).json")
    try Data(#"{"version":"6.2.3","root":"/opt/xless/toolchains/swift-6.2.3"}"#.utf8).write(to: file)
    let t = try XcodeEnvironment.toolchain(env: ["XLESS_SWIFT_TOOLCHAIN": file.path])
    #expect(t == SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3"))
    #expect(t?.include.path == "/opt/xless/toolchains/swift-6.2.3/usr/include")
    #expect(throws: XlessError.self) { try XcodeEnvironment.toolchain(env: ["XLESS_SWIFT_TOOLCHAIN": "/nope.json"]) }
}

@Test func theBuildChecksTheCompilerAgainstTheXcode() throws {
    let t = try fakeToolchain("Swift version 6.2.3 (swift-6.2.3-RELEASE)")
    let record = try #require(try SwiftToolchain.check(t, meta: meta(swift: "6.2.3"), pin: "26.2"))
    #expect(record == BuildSwiftRecord(version: "6.2.3", root: t.root, compiler: "Swift version 6.2.3 (swift-6.2.3-RELEASE)", xcodeSwiftVersion: "6.2.3"))
    #expect(record.summary == "Swift 6.2.3 (swift-6.2.3-RELEASE) from \(t.root), Xcode's Swift 6.2.3")
    // Metadata from before Ruling R10: the compiler is still verified and recorded.
    #expect(try SwiftToolchain.check(t, meta: meta(swift: nil), pin: nil)?.xcodeSwiftVersion == nil)
    // The image's Xcode ships another Swift.
    do { _ = try SwiftToolchain.check(t, meta: meta(swift: "6.4"), pin: nil); Issue.record("expected a refusal") } catch let e as XlessError {
        #expect(e.stage == .build && e.cause.contains("compiles with Swift 6.2.3") && e.cause.contains("ships Swift 6.4"))
    }
    // swiftc is not the recorded release.
    let other = try fakeToolchain("Swift version 6.4 (swift-6.4-RELEASE)")
    #expect(throws: XlessError.self) { try SwiftToolchain.check(other, meta: nil, pin: nil) }
    // No record: refused for a pinned project, otherwise nothing to check.
    #expect(throws: XlessError.self) { try SwiftToolchain.check(nil, meta: meta(swift: "6.2.3"), pin: "26.2") }
    #expect(try SwiftToolchain.check(nil, meta: nil, pin: nil) == nil)
}

@Test func theSDKRecordCarriesTheCompiler() throws {
    let swift = BuildSwiftRecord(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3", compiler: "Swift version 6.2.3 (swift-6.2.3-RELEASE)", xcodeSwiftVersion: "6.2.3")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-rec-\(UUID().uuidString)")
    try BuildSDKRecord(pin: "26.2", toolchain: meta(swift: "6.2.3"), swift: swift).write(in: dir)
    #expect(BuildSDKRecord.load(in: dir)?.swift == swift)
    // A record written before Ruling R10 still loads.
    try Data(#"{"pin":"26.2","toolchain":{"buildMachineOSBuild":"26A100","compiler":"c","platforms":{},"xcodeBuild":"17C52","xcodeVersion":"2620"}}"#.utf8)
        .write(to: BuildSDKRecord.url(in: dir))
    #expect(BuildSDKRecord.load(in: dir)?.swift == nil)
}
