import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private func makeSource(project: String = "project.yml", tauri: String? = nil, ios: String? = nil) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tauri-\(UUID().uuidString)")
    let apple = root.appendingPathComponent("src-tauri/gen/apple")
    try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
    try fixture(project).write(to: apple.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
    let conf = root.appendingPathComponent("src-tauri/tauri.conf.json")
    try (tauri ?? #"{"productName":"Hello","version":"1.0.0","identifier":"com.example.hello","build":{"beforeBuildCommand":"node build.mjs","frontendDist":"../dist"}}"#).write(to: conf, atomically: true, encoding: .utf8)
    if let ios = ios { try ios.write(to: root.appendingPathComponent("src-tauri/tauri.ios.conf.json"), atomically: true, encoding: .utf8) }
    return root
}

private func overlay(_ extra: String = "") throws -> TauriOverlay {
    try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.hello.linux\nteamID: ABCDE12345\n\(extra)", name: "hello")
}

@Test func mergesIOSConfigAndResolves() throws {
    let src = try makeSource(ios: #"{"bundle":{"iOS":{"minimumSystemVersion":"16.0"}}}"#)
    let r = try TauriProject.resolve(overlay: overlay(), source: src)
    #expect(r.config.bundleID == "com.example.hello.linux")
    #expect(r.config.teamID == "ABCDE12345")
    #expect(r.config.version == "1.0.0")
    #expect(r.config.platforms[.ios]?.minimumOS == "16.0")
    #expect(r.config.platforms[.ios]?.product == "HelloTauri")
    #expect(r.tauri.beforeBuildCommand == "node build.mjs" && r.tauri.frontendDist == "../dist")
    #expect(r.tauri.identifier == "com.example.hello" && r.tauri.iosMinimumSystemVersion == "16.0")
    #expect(r.tauriDir == "src-tauri" && r.appleDir == "src-tauri/gen/apple")
    #expect(r.config.platforms[.ios]?.entitlements == "src-tauri/gen/apple/hello-tauri_iOS/hello-tauri_iOS.entitlements")
    #expect(r.config.infoPlist == "src-tauri/gen/apple/hello-tauri_iOS/Info.plist")
    #expect(r.config.assets == "src-tauri/gen/apple/Assets.xcassets")
    #expect(r.config.launchStoryboard == "src-tauri/gen/apple/LaunchScreen.storyboard")
}

@Test func productNameComesFromProjectYml() throws {
    let src = try makeSource()
    let r = try TauriProject.resolve(overlay: overlay(), source: src)
    #expect(r.config.platforms[.ios]?.product == "HelloTauri")   // PRODUCT_NAME beats productName
    #expect(r.config.platforms[.ios]?.minimumOS == "16.0")       // deployment target fallback
}

@Test func datedBuildUsesPlaceholder() throws {
    let r = try TauriProject.resolve(overlay: overlay(), source: makeSource())
    #expect(r.config.buildScheme == .dated && r.config.build == "1.0.0.2000010101")
    let fixed = try TauriProject.resolve(overlay: overlay("build: 7\n"), source: makeSource())
    #expect(fixed.config.buildScheme == .fixed && fixed.config.build == "7")
}

@Test func overlayOverridesWin() throws {
    let o = try overlay("version: 2.0.0\nios: { product: Custom, minimumOS: \"17.0\", entitlements: e.entitlements }\nassets: A.xcassets\nlaunchStoryboard: L.storyboard\ninfoPlist: I.plist\nusesNonExemptEncryption: false\ntestflight: { groups: [Internal] }\n")
    let r = try TauriProject.resolve(overlay: o, source: makeSource())
    #expect(r.config.version == "2.0.0" && r.config.platforms[.ios]?.product == "Custom" && r.config.platforms[.ios]?.minimumOS == "17.0")
    #expect(r.config.platforms[.ios]?.entitlements == "e.entitlements" && r.config.assets == "A.xcassets")
    #expect(r.config.launchStoryboard == "L.storyboard" && r.config.infoPlist == "I.plist")
    #expect(r.config.usesNonExemptEncryption == false && r.config.testflight?.groups == ["Internal"])
}

@Test func versionFromPackageJson() throws {
    let src = try makeSource(tauri: #"{"version":"../package.json","identifier":"com.example.hello","productName":"Hello"}"#)
    try #"{"name":"x","version":"3.1.4"}"#.write(to: src.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    #expect(try TauriProject.resolve(overlay: overlay(), source: src).config.version == "3.1.4")
}

@Test func versionFallsBackToInfoPlistProperty() throws {
    let src = try makeSource(project: "project-acme.yml", tauri: #"{"identifier":"com.example.acme"}"#)
    let r = try TauriProject.resolve(overlay: overlay(), source: src)
    #expect(r.config.version == "2.3.4" && r.config.platforms[.ios]?.product == "Acme" && r.config.platforms[.ios]?.minimumOS == "15.0")
}

@Test func missingTauriConfigIsPrepareError() throws {
    let src = try makeSource()
    try FileManager.default.removeItem(at: src.appendingPathComponent("src-tauri/tauri.conf.json"))
    do { _ = try TauriProject.resolve(overlay: overlay(), source: src); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .prepare) }
}

@Test func missingProjectYmlIsPrepareError() throws {
    let src = try makeSource()
    try FileManager.default.removeItem(at: src.appendingPathComponent("src-tauri/gen/apple/project.yml"))
    do { _ = try TauriProject.resolve(overlay: overlay(), source: src); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .prepare && e.fix.contains("tauri ios init")) }
}

// MARK: macOS

private func makeMacSource(tauri: String? = nil, mac: String? = #"{"bundle":{"macOS":{"minimumSystemVersion":"11.0"}}}"#) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tauri-mac-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("src-tauri")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)   // no gen/apple, no project.yml
    try (tauri ?? #"{"productName":"Hello","version":"1.0.0","identifier":"com.example.hello"}"#).write(to: dir.appendingPathComponent("tauri.conf.json"), atomically: true, encoding: .utf8)
    if let mac { try mac.write(to: dir.appendingPathComponent("tauri.macos.conf.json"), atomically: true, encoding: .utf8) }
    return root
}

@Test func resolveMacMergesMacOSConfigWithoutAnXcodeProject() throws {
    let r = try TauriProject.resolveMac(overlay: overlay(), source: makeMacSource())
    let p = try #require(r.config.platforms[.macos])
    #expect(r.config.platforms.count == 1 && p.minimumOS == "11.0" && p.product == "Hello" && p.distribution == .developerID)
    #expect(r.config.bundleID == "com.example.hello.linux" && r.config.version == "1.0.0")
    #expect(r.config.buildScheme == .dated && r.config.build == "1.0.0.200001010000")
    #expect(r.config.assets == nil && r.config.launchStoryboard == nil && r.config.privacyManifest == nil)
    #expect(r.tauriDir == "src-tauri" && r.mainBinaryName == nil)
}

@Test func resolveMacDefaultsAndOverrides() throws {
    let bare = try TauriProject.resolveMac(overlay: overlay(), source: makeMacSource(mac: nil))
    #expect(bare.config.platforms[.macos]?.minimumOS == "10.13")   // Tauri's default
    let o = try overlay("macos: { product: Custom, minimumOS: \"12.0\", entitlements: /abs/o.entitlements }\nbuild: 7\n")
    let r = try TauriProject.resolveMac(overlay: o, source: makeMacSource(tauri: #"{"productName":"Hello","version":"1.0.0","identifier":"x.y","mainBinaryName":"hello-bin"}"#))
    let p = try #require(r.config.platforms[.macos])
    #expect(p.minimumOS == "12.0" && p.product == "Custom" && p.entitlements == "/abs/o.entitlements")
    #expect(r.config.build == "7" && r.config.buildScheme == .fixed && r.mainBinaryName == "hello-bin")
}

@Test func resolveMacTauriEntitlementsComeFirstRelativeToTauriDir() throws {
    let o = try overlay("macos: { entitlements: /abs/o.entitlements }\n")
    let src = try makeMacSource(mac: #"{"bundle":{"macOS":{"entitlements":"Entitlements.plist"}}}"#)
    #expect(try TauriProject.resolveMac(overlay: o, source: src).config.platforms[.macos]?.entitlements == "src-tauri/Entitlements.plist")
}

/// resolveMac takes `macos.infoPlist` only; the top-level `infoPlist` (the iOS target's) is never used for macOS.
@Test func resolveMacUsesOnlyMacOSInfoPlist() throws {
    let src = try makeMacSource()
    #expect(try TauriProject.resolveMac(overlay: overlay("infoPlist: ios/Info.plist\n"), source: src).config.infoPlist == nil)
    let both = try overlay("infoPlist: ios/Info.plist\nmacos: { infoPlist: /abs/mac/Info.plist }\n")
    #expect(try TauriProject.resolveMac(overlay: both, source: src).config.infoPlist == "/abs/mac/Info.plist")
    #expect(try TauriProject.resolve(overlay: both, source: makeSource()).config.infoPlist == "ios/Info.plist")
}

@Test func resolveMacNeedsAProductName() throws {
    let src = try makeMacSource(tauri: #"{"version":"1.0.0","identifier":"com.example.hello"}"#)
    #expect(throws: XlessError.self) { try TauriProject.resolveMac(overlay: overlay(), source: src) }
}

@Test func provisioningUpdatesReachTheConfigOfBothPlatforms() throws {
    let src = try makeSource()
    for (extra, want) in [("", true), ("provisioningUpdates: false\n", false)] {
        #expect(try TauriProject.resolve(overlay: overlay(extra), source: src).config.provisioningUpdates == want)
        #expect(try TauriProject.resolveMac(overlay: overlay(extra), source: src).config.provisioningUpdates == want)
    }
    // Tauri overlays ignore keys they do not know: a misspelt restriction is refused.
    #expect(throws: XlessError.self) { _ = try overlay("provisioning_updates: false\n") }
    for line in ["provisioningUpdates:\n", "provisionUpdates: false\n", "ios: { provisioningUpdates: false }\n", "testflight: { provisioningUpdates: false }\n"] {
        #expect(throws: XlessError.self, "\(line)") { _ = try overlay(line) }
    }
}
