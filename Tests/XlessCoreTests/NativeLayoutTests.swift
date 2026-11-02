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

@Test func loadFallsBackToTheNativeRecord() throws {
    // Only meaningful outside an image (the image's record would win).
    guard !FileManager.default.fileExists(atPath: SwiftToolchain.imageFile) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let env = ["XLESS_NATIVE_HOME": root.path, "HOME": "/nonexistent"]
    #expect(try SwiftToolchain.load(env: env) == nil)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"version":"6.4.0","root":"/n/toolchains/swift-6.4.0","clangFlags":["-fdefine-target-os-macros"]}"#
        .write(to: NativeLayout(env: env).record, atomically: true, encoding: .utf8)
    #expect(try SwiftToolchain.load(env: env)
        == SwiftToolchain(version: "6.4.0", root: "/n/toolchains/swift-6.4.0", clangFlags: ["-fdefine-target-os-macros"]))
    // XLESS_SWIFT_TOOLCHAIN still wins.
    #expect(throws: XlessError.self) { try SwiftToolchain.load(env: env.merging(["XLESS_SWIFT_TOOLCHAIN": "/missing.json"]) { $1 }) }
}
