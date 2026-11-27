import Foundation
import Testing
@testable import XlessCore

@Test func theNativeHomeIsTheOverrideThenXDGDataThenHome() {
    #expect(NativeLayout(env: ["XLESS_NATIVE_HOME": "/n", "XDG_DATA_HOME": "/d", "HOME": "/h"]).root.path == "/n")
    #expect(NativeLayout(env: ["XDG_DATA_HOME": "/d", "HOME": "/h"]).root.path == "/d/xless-native")
    #expect(NativeLayout(env: ["XLESS_NATIVE_HOME": "", "XDG_DATA_HOME": "", "HOME": "/h"]).root.path == "/h/.local/share/xless-native")
}

@Test func theLayoutNamesEachToolByVersion() {
    let l = NativeLayout(root: URL(fileURLWithPath: "/n"))
    #expect(l.toolchain(version: "6.4.0").path == "/n/toolchains/swift-6.4.0")
    #expect(l.xtool(version: "1.21.0").path == "/n/tools/xtool-1.21.0")
    #expect(l.rcodesign(version: "0.29.0").path == "/n/tools/rcodesign-0.29.0")
    #expect(l.bin.path == "/n/bin")
    #expect(l.record.path == "/n/swift-toolchain.json")
}

@Test func theNativeToolsGoFirstOnPathEvenAheadOfAnotherSwift() {
    let t = SwiftToolchain(version: "6.4.0", root: "/n/toolchains/swift-6.4.0")
    let bin = URL(fileURLWithPath: "/n/bin")
    #expect(NativeLayout.path("/home/u/.local/share/swiftly/bin:/usr/local/bin:/usr/bin:/bin", toolchain: t, bin: bin)
        == "/n/toolchains/swift-6.4.0/usr/bin:/n/bin:/home/u/.local/share/swiftly/bin:/usr/local/bin:/usr/bin:/bin")
    // Already there (a child of a native xless): moved to the front, never repeated.
    let once = NativeLayout.path("/usr/bin:/n/bin", toolchain: t, bin: bin)
    #expect(once == "/n/toolchains/swift-6.4.0/usr/bin:/n/bin:/usr/bin")
    #expect(NativeLayout.path(once, toolchain: t, bin: bin) == once)
    // The toolchain's own PATH logic then leaves it alone.
    #expect(t.path(once) == once)
}

@Test func withoutAPackTheToolchainIsTheNativeRecord() throws {
    // Only meaningful outside an image (the image's record would win).
    guard !FileManager.default.fileExists(atPath: "/opt/xless/swift-toolchain.json") else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let env = ["XLESS_NATIVE_HOME": root.path, "HOME": "/nonexistent"]
    #expect(try XcodeEnvironment.toolchain(env: env) == nil)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"version":"6.4.0","root":"/n/toolchains/swift-6.4.0","clangFlags":["-fdefine-target-os-macros"]}"#
        .write(to: NativeLayout(env: env).record, atomically: true, encoding: .utf8)
    #expect(try XcodeEnvironment.toolchain(env: env)
        == SwiftToolchain(version: "6.4.0", root: "/n/toolchains/swift-6.4.0", clangFlags: ["-fdefine-target-os-macros"]))
    // XLESS_SWIFT_TOOLCHAIN still wins.
    #expect(throws: XlessError.self) { try XcodeEnvironment.toolchain(env: env.merging(["XLESS_SWIFT_TOOLCHAIN": "/missing.json"]) { $1 }) }
}

// MARK: - Activation from a pack

/// A real directory (macOS: /var is /private/var), as the store lists its packs.
private func realTemp(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let real = realpath(dir.path, nil) else { return dir }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
}

/// A pack with its SDK, metadata and toolchain record (root relative), as `xless setup` lays it out.
@discardableResult
private func packWithToolchain(in store: URL, xcode: String, build: String) throws -> XcodePack {
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

private func packEnvironment(store: URL, _ extra: [String: String] = [:]) throws -> [String: String] {
    let home = try realTemp("native-home"), share = try realTemp("native-share")
    return ["HOME": home.path, "XLESS_NATIVE_HOME": home.appendingPathComponent("native").path, "XLESS_XCODES": store.path,
            "XLESS_SHARE": share.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
}

@Test func onLinuxThePacksToolchainGoesFirst() throws {
    let store = try realTemp("native-store")
    let pack = try packWithToolchain(in: store, xcode: "26.2", build: "17C52")
    let env = try packEnvironment(store: store)
    let bin = NativeLayout(env: env).bin.path
    #expect(NativeLayout.activatedPath(env: env, linux: true) == "\(pack.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin")
    // Already so: nothing to do.
    #expect(NativeLayout.activatedPath(env: env.merging(["PATH": "\(pack.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin"]) { $1 }, linux: true) == nil)
    // A Mac builds with its Xcode: the pack's Linux toolchain is never put on PATH there.
    #expect(NativeLayout.activatedPath(env: env, linux: false) == nil)
    // An image's own record leaves PATH alone.
    #expect(NativeLayout.activatedPath(env: env.merging(["XLESS_SWIFT_TOOLCHAIN": "/opt/xless/swift-toolchain.json"]) { $1 }, linux: true) == nil)
}

@Test func thePinnedPacksToolchainDisplacesTheNewestPacks() throws {
    let store = try realTemp("native-store")
    let older = try packWithToolchain(in: store, xcode: "26.2", build: "17C52")
    let newer = try packWithToolchain(in: store, xcode: "27.0", build: "27A266a")
    let env = try packEnvironment(store: store)
    let bin = NativeLayout(env: env).bin.path
    // A command's start: no pin yet, the newest pack's toolchain.
    let started = try #require(NativeLayout.activatedPath(env: env, linux: true))
    #expect(started == "\(newer.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin")
    // The project pins the older one: its toolchain first, the newer's gone.
    let pinned = env.merging([XcodeEnvironment.pinVariable: "26.2", "PATH": started]) { $1 }
    #expect(NativeLayout.activatedPath(env: pinned, linux: true) == "\(older.toolchain.path)/usr/bin:\(bin):/usr/bin:/bin")
    // A native install's toolchain of before the packs goes too; other directories stay.
    let native = NativeLayout(env: env).toolchain(version: "6.1.0").appendingPathComponent("usr/bin").path
    let mixed = pinned.merging(["PATH": "/opt/tools/bin:\(native):\(started)"]) { $1 }
    #expect(NativeLayout.activatedPath(env: mixed, linux: true) == "\(older.toolchain.path)/usr/bin:\(bin):/opt/tools/bin:/usr/bin:/bin")
}
