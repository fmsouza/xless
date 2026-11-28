import Foundation
import Testing
import XlessCore
@testable import XlessXcode

// The Swift Build environment as a stage reads it from an Xcode pack on disk (`XcodeEnvironment`).

/// A real directory (macOS: /var is /private/var), as the store lists its packs.
private func realTemp(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return dir }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

/// A pack as `xless setup` lays it out: the SDK, the metadata, the toolchain and its record (root relative), and, as
/// asked, the include directory and Swift Build.
private func makePack(in store: URL, swiftBuild: Bool = true, include: Bool = true) throws -> XcodePack {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "amd64"
    #endif
    let fm = FileManager.default
    let pack = XcodePack(root: store.appendingPathComponent(XcodePack.name(xcode: "26.2", build: "17C52", arch: arch)),
                         manifest: PackManifest(format: 1, xcode: "26.2", build: "17C52", arch: arch, swift: "6.2.3", mode: .separate,
                                                parts: swiftBuild ? ["sdk": "h", "swift-build": "h"] : ["sdk": "h"]))
    try fm.createDirectory(at: pack.sdkBundle, withIntermediateDirectories: true)
    try fm.createDirectory(at: pack.toolchain.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
    try Data(#"{"xcodeBuild":"17C52"}"#.utf8).write(to: pack.meta)
    try Data(#"{"version":"6.2.3","root":"toolchain","clangFlags":["-fdefine-target-os-macros"]}"#.utf8).write(to: pack.record)
    if include { try fm.createDirectory(at: pack.include.appendingPathComponent("swift"), withIntermediateDirectories: true) }
    if swiftBuild {
        try fm.createDirectory(at: pack.swiftBuild, withIntermediateDirectories: true)
        try ExecutableFile.write("#!/bin/sh\n", to: pack.swiftBuild.appendingPathComponent("swbuild"), stage: .build)
    }
    try pack.manifest.write(to: pack.manifestFile)
    return pack
}

/// This machine as a stage sees it: its shims, the store and an empty share (nothing is stale).
private func environment(store: URL, _ extra: [String: String] = [:]) throws -> [String: String] {
    let home = try realTemp("swb-home"), share = try realTemp("swb-share")
    return ["HOME": home.path, "PATH": "/usr/bin:/bin", "XLESS_XCODES": store.path, "XLESS_SHARE": share.path, "XLESS_SHIM_DIR": "/opt/xless/shims"]
        .merging(extra) { $1 }
}

@Test func theSwiftBuildEnvironmentIsThePacks() throws {
    let store = try realTemp("swb-store")
    let pack = try makePack(in: store)
    let e = try SwiftBuildEnvironment.fromProcess(try environment(store: store), stage: .build)
    #expect(e.sdk.bundle.path == pack.sdkBundle.path)
    #expect(e.toolchainInclude.path == pack.include.path)
    #expect(e.swbuild?.path == pack.swiftBuild.appendingPathComponent("swbuild").path)
    #expect(e.swift == SwiftToolchain(version: "6.2.3", root: pack.toolchain.path, clangFlags: ["-fdefine-target-os-macros"]))
    #expect(e.shimDirectory.path == "/opt/xless/shims")
    // Swift Build is the pack's, whatever is on PATH.
    #expect(try SwiftBuildRunner.swbuild(e, path: "/usr/bin:/bin", stage: .build).path == pack.swiftBuild.appendingPathComponent("swbuild").path)
}

@Test func theSwiftBuildEnvironmentNamesWhatIsMissing() throws {
    let store = try realTemp("swb-store")
    _ = try makePack(in: store, swiftBuild: false)
    // No shims on this machine.
    var env = try environment(store: store)
    env["XLESS_SHIM_DIR"] = nil
    let noShims = #expect(throws: XlessError.self) { try SwiftBuildEnvironment.fromProcess(env, stage: .build) }
    #expect(noShims?.cause == "the Xcode tool shims are not installed on this machine (XLESS_SHIM_DIR)")
    #expect(noShims?.fix == "build in Docker, where the xless image has them: xless setup --docker --xcode <path to Xcode's .xip>, then xless run --docker")
    // A pack without Swift Build: refused with the setup that prepares it, as a usage error.
    let noSwiftBuild = #expect(throws: XlessError.self) { try SwiftBuildEnvironment.fromProcess(try environment(store: store), stage: .build) }
    #expect(noSwiftBuild?.cause.contains("has no Swift Build") == true && noSwiftBuild?.stage == .build && noSwiftBuild?.exitCode == 2)
    // (the fix is the setup that prepares the part, which only a pack prepared in the image has: a native setup prepares none)
    #expect(noSwiftBuild?.fix.hasPrefix("only a pack prepared in xless's image has Swift Build: xless setup --docker --sdk ") == true
            && noSwiftBuild?.fix.contains("/xless/sdk/xcode") == true && noSwiftBuild?.fix.contains("xless run --docker") == true, "\(noSwiftBuild?.fix ?? "")")
}

@Test func theSwiftBuildEnvironmentNeedsThePacksIncludeDirectory() throws {
    let store = try realTemp("swb-store")
    _ = try makePack(in: store, include: false)
    let e = #expect(throws: XlessError.self) { try SwiftBuildEnvironment.fromProcess(try environment(store: store), stage: .build) }
    #expect(e?.cause.hasPrefix("the Swift toolchain's include directory is not known") == true)
}

@Test func swiftBuildIsThePacksElseTheOneOnPath() throws {
    let bin = try realTemp("swb-bin")
    let onPath = bin.appendingPathComponent("swbuild")
    try ExecutableFile.write("#!/bin/sh\n", to: onPath, stage: .build)
    let sdk = DarwinSDK(bundle: URL(fileURLWithPath: "/sdk/darwin.artifactbundle"))
    let packs = SwiftBuildEnvironment(sdk: sdk, shimDirectory: URL(fileURLWithPath: "/s"), toolchainInclude: URL(fileURLWithPath: "/i"),
                                      swbuild: URL(fileURLWithPath: "/pack/swift-build/swbuild"))
    #expect(try SwiftBuildRunner.swbuild(packs, path: bin.path, stage: .build).path == "/pack/swift-build/swbuild")
    let none = SwiftBuildEnvironment(sdk: sdk, shimDirectory: URL(fileURLWithPath: "/s"), toolchainInclude: URL(fileURLWithPath: "/i"))
    #expect(try SwiftBuildRunner.swbuild(none, path: "/usr/bin:\(bin.path)", stage: .build).path == onPath.path)
    let e = #expect(throws: XlessError.self) { try SwiftBuildRunner.swbuild(none, path: "/nonexistent", stage: .prepare) }
    #expect(e?.stage == .prepare && e?.cause == "Swift Build is not here: the Xcode pack has no swbuild, and none is on PATH")
    // a native setup prepares no Swift Build part: the fix is the image's
    #expect(e?.fix.hasPrefix("only a pack prepared in xless's image has Swift Build: xless setup --docker") == true, "\(e?.fix ?? "")")
}
