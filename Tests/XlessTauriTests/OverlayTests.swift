import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

let overlayYAML = """
type: tauri
source: ~/src/app
tauri: { dir: src-tauri, features: [ipad] }
bundleID: com.example.app.linux
teamID: ABCDE12345
build: dated
linkFlags: ["-ObjC"]
binaryDependencies:
  - url: https://example.com/a.zip
    sha256: \(String(repeating: "a", count: 64))
    extract: a.xcframework
    to: src-tauri/gen/apple/Pods/a/a.xcframework
    fixes: { minimumOSVersion: "16.0" }
    linkFlags: ["-lc++", "-weak_framework", "CoreML"]
scripts: { "Patch Thing": ignore }
usesNonExemptEncryption: false
testflight: { groups: [Internal] }
"""

@Test func parsesFullOverlay() throws {
    let o = try TauriOverlay.parse(yaml: overlayYAML, name: "app")
    #expect(o.name == "app" && o.source == "~/src/app")
    #expect(o.tauriDir == "src-tauri" && o.features == ["ipad"] && o.build == "dated" && o.version == nil)
    #expect(o.linkFlags == ["-ObjC"])
    #expect(o.binaryDependencies.first?.fixes?.minimumOSVersion == "16.0")
    #expect(o.binaryDependencies.first?.linkFlags == ["-lc++", "-weak_framework", "CoreML"])
    #expect(o.scripts["Patch Thing"] == .ignore)
    #expect(o.usesNonExemptEncryption == false && o.testflight?.groups == ["Internal"])
}

@Test func defaultsApply() throws {
    let o = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.a\nteamID: ABCDE12345\n", name: "a")
    #expect(o.tauriDir == "src-tauri" && o.features.isEmpty && o.build == "dated" && o.linkFlags.isEmpty)
    #expect(o.binaryDependencies.isEmpty && o.scripts.isEmpty && o.source == nil && o.ios == nil)
}

@Test func tauriVersionKeywordMeansNil() throws {
    let o = try TauriOverlay.parse(yaml: overlayYAML + "\nversion: tauri", name: "a")
    #expect(o.version == nil)
    let p = try TauriOverlay.parse(yaml: overlayYAML + "\nversion: 2.1.0", name: "a")
    #expect(p.version == "2.1.0")
}

@Test func refusesWrongTypeBadHashAndEscapingPaths() {
    #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: overlayYAML.replacingOccurrences(of: "type: tauri", with: "type: swiftpm"), name: "a") }
    #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: overlayYAML.replacingOccurrences(of: String(repeating: "a", count: 64), with: "abc"), name: "a") }
    #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: overlayYAML.replacingOccurrences(of: "to: src-tauri", with: "to: ../src-tauri"), name: "a") }
    #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: overlayYAML.replacingOccurrences(of: "https://", with: "http://"), name: "a") }
    #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: overlayYAML.replacingOccurrences(of: "to: src-tauri", with: "to: /abs"), name: "a") }
}

@Test func parsesTheShippedExampleOverlay() throws {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let url = dir.appendingPathComponent("samples/HelloTauri/xless.overlay.example.yml")
    let text = try String(contentsOf: url, encoding: .utf8)
    let o = try TauriOverlay.parse(yaml: text, name: "xless.overlay.example")
    #expect(o.source == "." && o.bundleID == "com.example.hellotauri" && o.teamID == "ABCDE12345")
    #expect(o.privacyManifest == "PrivacyInfo.xcprivacy")
    let loc = try OverlayLocation.load(from: url, env: ["HOME": "/home/u"])
    #expect(loc.overlay.privacyManifest == dir.appendingPathComponent("samples/HelloTauri/PrivacyInfo.xcprivacy").standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: loc.overlay.privacyManifest ?? ""))
}

/// `privacyManifest:` resolves like `source:` (overlay directory, `~`), so it can live outside the app repository.
@Test func locationResolvesPrivacyManifest() throws {
    let env = ["HOME": "/home/u"]
    let url = try writeOverlay(minimal + "source: /src\nprivacyManifest: ../shared/PrivacyInfo.xcprivacy\n")
    let rel = try OverlayLocation.load(from: url, env: env)
    #expect(rel.overlay.privacyManifest == url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/PrivacyInfo.xcprivacy").path)
    let home = try OverlayLocation.load(from: writeOverlay(minimal + "source: /src\nprivacyManifest: ~/p/PrivacyInfo.xcprivacy\n"), env: env)
    #expect(home.overlay.privacyManifest == "/home/u/p/PrivacyInfo.xcprivacy")
    #expect(try OverlayLocation.load(from: writeOverlay(minimal + "source: /src\n"), env: env).overlay.privacyManifest == nil)
}

private func writeOverlay(_ yaml: String, named file: String = "my.overlay.yml") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(file)
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private let minimal = "type: tauri\nbundleID: com.example.a\nteamID: ABCDE12345\n"

@Test func locationResolvesSourceAndWorkRoot() throws {
    let env = ["HOME": "/home/u"]
    let abs = try OverlayLocation.load(from: writeOverlay(minimal + "source: ~/src/app\n"), env: env)
    #expect(abs.overlay.name == "my.overlay")
    #expect(abs.sourceRoot.path == "/home/u/src/app")
    #expect(abs.workRoot.path == "/home/u/.cache/xless/work/my.overlay")

    let url = try writeOverlay(minimal + "source: ../app\n")
    let rel = try OverlayLocation.load(from: url, env: env.merging(["XLESS_WORK_ROOT": "/w"]) { $1 })
    #expect(rel.sourceRoot == url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("app").standardizedFileURL)
    #expect(rel.workRoot.path == "/w/my.overlay")

    let over = try OverlayLocation.load(from: url, sourceOverride: "/elsewhere", env: env)
    #expect(over.sourceRoot.path == "/elsewhere")
}

@Test func locationNeedsASource() throws {
    #expect(throws: XlessError.self) { try OverlayLocation.load(from: writeOverlay(minimal), env: [:]) }
    #expect(throws: XlessError.self) { try OverlayLocation.load(from: URL(fileURLWithPath: "/nonexistent/x.yml"), env: [:]) }
}

/// `macos:` parses; its `entitlements` resolves against the overlay file like `privacyManifest`.
@Test func macosBlockParsesAndResolvesEntitlements() throws {
    let o = try TauriOverlay.parse(yaml: overlayYAML + "\nmacos: { product: My App, minimumOS: \"12.0\", entitlements: mac.entitlements }\n", name: "app")
    #expect(o.macos == OverlayMac(product: "My App", minimumOS: "12.0", entitlements: "mac.entitlements"))
    #expect(try TauriOverlay.parse(yaml: overlayYAML, name: "app").macos == nil)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ov-\(UUID().uuidString)/overlays", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("app.yml")
    try (overlayYAML + "\nmacos: { entitlements: ../shared/mac.entitlements }\n").write(to: url, atomically: true, encoding: .utf8)
    let loc = try OverlayLocation.load(from: url, sourceOverride: "/src", env: ["HOME": "/home/u"])
    #expect(loc.overlay.macos?.entitlements == dir.deletingLastPathComponent().appendingPathComponent("shared/mac.entitlements").standardizedFileURL.path)
}

/// `macos.infoPlist` resolves against the overlay file like `macos.entitlements`; the top-level (iOS) `infoPlist` is untouched.
@Test func macosInfoPlistResolvesAgainstTheOverlay() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ov-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("app.yml")
    try (overlayYAML + "\ninfoPlist: src-tauri/gen/apple/app_iOS/Info.plist\nmacos: { infoPlist: mac/Info.plist }\n").write(to: url, atomically: true, encoding: .utf8)
    let o = try OverlayLocation.load(from: url, sourceOverride: "/src", env: ["HOME": "/home/u"]).overlay
    #expect(o.macos?.infoPlist == dir.appendingPathComponent("mac/Info.plist").standardizedFileURL.path)
    #expect(o.infoPlist == "src-tauri/gen/apple/app_iOS/Info.plist")
}

/// `macos.features` replaces `tauri.features` for the macOS build (an empty list too); absent, `tauri.features` applies.
@Test func macosFeaturesReplaceTauriFeatures() throws {
    let base = try TauriOverlay.parse(yaml: overlayYAML, name: "app")   // tauri.features: [ipad]
    #expect(base.macos?.features == nil && base.macFeatures == ["ipad"])
    let empty = try TauriOverlay.parse(yaml: overlayYAML + "\nmacos: { features: [] }\n", name: "app")
    #expect(empty.macos?.features == [] && empty.macFeatures == [] && empty.features == ["ipad"])
    let own = try TauriOverlay.parse(yaml: overlayYAML + "\nmacos: { features: [desktop-tray, updater] }\n", name: "app")
    #expect(own.macFeatures == ["desktop-tray", "updater"])
    #expect(TauriBuilder.macCargoArguments(target: "aarch64-apple-darwin", features: empty.macFeatures)[3] == "tauri/custom-protocol")
}

@Test func tauriOverlaysTakeAnXcodePin() throws {
    #expect(try TauriOverlay.parse(yaml: minimal, name: "a").xcode == nil)
    #expect(try TauriOverlay.parse(yaml: minimal + "xcode: \"26.2\"\n", name: "a").xcode == "26.2")
    let e = #expect(throws: XlessError.self) { try TauriOverlay.parse(yaml: minimal + "xcode: newest\n", name: "a") }
    #expect(e?.stage == .config && e?.cause == "xcode 'newest' in overlay a is not an Xcode version")
}

@Test func iosExtensionsAreDeclaredInTheIOSBlock() throws {
    let o = try TauriOverlay.parse(yaml: """
    type: tauri
    bundleID: com.example.a
    teamID: ABCDE12345
    ios:
      extensions:
        - { path: PlugIns/Widget.appex, bundleID: com.example.a.widget, entitlements: src-tauri/Widget.entitlements }
    """, name: "a")
    #expect(o.ios?.extensions == [ExtensionConfig(path: "PlugIns/Widget.appex", bundleID: "com.example.a.widget", entitlements: "src-tauri/Widget.entitlements")])
}

@Test func anExtensionOutsideTheAppsBundleIDNamesTheOverlaysKey() {
    #expect { _ = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.a\nteamID: ABCDE12345\nios:\n  extensions:\n    - { path: PlugIns/W.appex, bundleID: com.other.w }\n", name: "a") } throws: {
        ($0 as? XlessError)?.cause == "overlay a: ios.extensions[0].bundleID 'com.other.w' is not under the app's com.example.a"
    }
}
