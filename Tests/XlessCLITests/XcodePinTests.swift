import Foundation
import Testing
import XlessCore
@testable import xless

/// A real directory (macOS: /var is /private/var), as the store lists its packs.
private func realTemp(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return dir }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

/// A pack with its SDK, metadata and toolchain record (root relative).
private func pack(in store: URL, xcode: String, build: String) throws -> XcodePack {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "amd64"
    #endif
    let fm = FileManager.default
    let pack = XcodePack(root: store.appendingPathComponent(XcodePack.name(xcode: xcode, build: build, arch: arch)),
                         manifest: PackManifest(format: 1, xcode: xcode, build: build, arch: arch, swift: "6.2.3", mode: .separate, parts: ["sdk": "h"]))
    try fm.createDirectory(at: pack.sdkBundle, withIntermediateDirectories: true)
    try fm.createDirectory(at: pack.toolchain.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
    try Data(#"{"xcodeBuild":"\#(build)"}"#.utf8).write(to: pack.meta)
    try Data(#"{"version":"6.2.3","root":"toolchain","clangFlags":[]}"#.utf8).write(to: pack.record)
    try pack.manifest.write(to: pack.manifestFile)
    return pack
}

/// What `Context.pinXcode` sets, in order.
private func pinning(_ configured: String?, env: [String: String], linux: Bool = true) -> [String: String] {
    var set: [String: String] = [:]
    Context.pinXcode(configured, env: env, linux: linux) { set[$0] = $1 }
    return set
}

@Test func aStageRunByHandTakesThePinnedXcodesToolchainFirst() throws {
    let store = try realTemp("pin-store"), home = try realTemp("pin-home"), share = try realTemp("pin-share")
    let older = try pack(in: store, xcode: "26.2", build: "17C52")
    let newer = try pack(in: store, xcode: "27.0", build: "27A266a")
    let native = home.appendingPathComponent("native")
    let bin = native.appendingPathComponent("bin").path
    // As the command's start left it: the newest pack's toolchain first.
    let env = ["HOME": home.path, "XLESS_NATIVE_HOME": native.path, "XLESS_XCODES": store.path, "XLESS_SHARE": share.path,
               "PATH": "\(newer.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin"]
    let set = pinning("26.2", env: env)
    #expect(set[XcodeEnvironment.pinVariable] == "26.2")
    #expect(set["PATH"] == "\(older.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin")
    // Not on Linux: the pin only (a Mac builds with its Xcode).
    #expect(pinning("26.2", env: env, linux: false) == [XcodeEnvironment.pinVariable: "26.2"])
    // A pin already in the environment wins (a run set it, and the command's start activated its toolchain): nothing is set.
    #expect(pinning("26.2", env: env.merging([XcodeEnvironment.pinVariable: "27.0"]) { $1 }).isEmpty)
    // No pin sets nothing.
    #expect(pinning(nil, env: env).isEmpty)
}
