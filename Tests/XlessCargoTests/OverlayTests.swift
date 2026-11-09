import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore

private let rev = "3d9ab3a132ed0eff457e424226a435a901da30d3"

private let fullYAML = """
type: cargo
source: ..
bundleID: com.example.hello
teamID: ABCDE12345
version: cargo
build: dated
usesNonExemptEncryption: false
privacyManifest: PrivacyInfo.xcprivacy
testflight: { groups: [Internal], whatToTest: "Try it" }
xcode: "26.2"
rust:
  toolchain: "1.97.0"
env:
  FONTS_REQUIRED: "1"
inputs:
  - { name: fonts, git: https://example.com/fonts.git, rev: \(rev), env: FONTS_DIR }
plistVars: { CHANNEL: beta }
ios:
  package: hello-mobile
  bin: hello-ios
  features: []
  product: Hello
  minimumOS: "17.0"
  infoPlist: apps/mobile/ios/Info.plist
  assets: assets/ios/Assets.xcassets
  entitlements: ios.entitlements
macos:
  bundleID: com.example.hello.mac
  package: hello
  bin: hello
  features: [heif]
  product: Hello
  minimumOS: "11.0"
  infoPlist: packaging/macos/Info.plist.in
  icon: assets/hello.icns
  entitlements: packaging/macos/entitlements.plist
  resources:
    - { from: input:fonts/OFL.txt, to: Licenses/OFL.txt }
    - { from: LICENSE-MIT, to: Licenses/ }
"""

private let minimalIOS = """
type: cargo
bundleID: com.example.hello
teamID: ABCDE12345
ios:
  package: hello-mobile
  product: Hello
  minimumOS: "17.0"
  assets: Assets.xcassets

"""

private func expectConfig(_ yaml: String, mentioning needle: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try CargoOverlay.parse(yaml: yaml, name: "a")
        Issue.record("expected a config error", sourceLocation: sourceLocation)
    } catch let e as XlessError {
        #expect(e.stage == .config, sourceLocation: sourceLocation)
        if let needle { #expect(e.cause.contains(needle), "cause: \(e.cause)", sourceLocation: sourceLocation) }
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

private func writeOverlay(_ yaml: String, named file: String = "my.overlay.yml") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovl-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(file)
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func parsesFullOverlay() throws {
    let o = try CargoOverlay.parse(yaml: fullYAML, name: "hello")
    #expect(o.name == "hello" && o.source == "..")
    #expect(o.ios?.package == "hello-mobile" && o.ios?.bin == "hello-ios")
    #expect(o.macos?.bundleID == "com.example.hello.mac" && o.macos?.features == ["heif"])
    #expect(o.ios?.bundleID == nil && o.ios?.features == [])
    #expect(o.toolchain == "1.97.0" && o.build == "dated" && o.version == nil)
    #expect(o.inputs == [.git(name: "fonts", url: "https://example.com/fonts.git", rev: rev, env: "FONTS_DIR")])
    #expect(o.env == ["FONTS_REQUIRED": "1"] && o.plistVars == ["CHANNEL": "beta"])
    #expect(o.usesNonExemptEncryption == false && o.testflight?.groups == ["Internal"] && o.xcode == "26.2")
    #expect(o.macos?.icon == "assets/hello.icns" && o.macos?.assets == nil)
    #expect(o.macos?.resources == [CargoResource(from: "input:fonts/OFL.txt", to: "Licenses/OFL.txt"), CargoResource(from: "LICENSE-MIT", to: "Licenses/")])
    #expect(o.inputs.first?.name == "fonts" && o.inputs.first?.env == "FONTS_DIR")
}

@Test func defaultsApply() throws {
    let o = try CargoOverlay.parse(yaml: minimalIOS, name: "a")
    #expect(o.build == "dated" && o.version == nil && o.toolchain == nil && o.env.isEmpty && o.inputs.isEmpty && o.plistVars.isEmpty)
    #expect(o.macos == nil && o.ios?.bin == nil && o.ios?.resources.isEmpty == true && o.privacyManifest == nil)
}

@Test func parsesPathInputsAndMacOSWithNoIcon() throws {
    let yaml = minimalIOS + """
    inputs:
      - { name: fonts, path: ../fonts, env: FONTS_DIR }
    macos: { package: hello, product: Hello, minimumOS: "11.0" }
    """
    let o = try CargoOverlay.parse(yaml: yaml, name: "a")
    #expect(o.inputs == [.path(name: "fonts", path: "../fonts", env: "FONTS_DIR")])
    #expect(o.macos?.icon == nil && o.macos?.assets == nil)
}

@Test func versionAndBuildForms() throws {
    #expect(try CargoOverlay.parse(yaml: minimalIOS + "version: cargo\n", name: "a").version == nil)
    #expect(try CargoOverlay.parse(yaml: minimalIOS + "version: 1.2.0\n", name: "a").version == "1.2.0")
    #expect(try CargoOverlay.parse(yaml: minimalIOS + "version: 1.2.0-beta.1\n", name: "a").version == "1.2.0-beta.1")
    #expect(try CargoOverlay.parse(yaml: minimalIOS + "build: 42\n", name: "a").build == "42")
    #expect(try CargoOverlay.parse(yaml: minimalIOS + "build: \"1.2\"\n", name: "a").build == "1.2")
    expectConfig(minimalIOS + "version: latest\n", mentioning: "version")
    expectConfig(minimalIOS + "build: soon\n", mentioning: "build")
}

@Test func refusesEmptyOrBlankProduct() {
    for blank in ["\"\"", "\"   \""] {
        expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: \(blank)"), mentioning: "ios.product")
    }
}

@Test func refusesUnknownKey() {
    expectConfig(minimalIOS + "bundleId: com.example.x\n", mentioning: "bundleId")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  feature: [a]"), mentioning: "ios.feature")
    expectConfig(minimalIOS + "rust: { toolchian: stable }\n", mentioning: "rust.toolchian")
    expectConfig(minimalIOS + "inputs:\n  - { name: a, path: ../a, env: A_DIR, rv: x }\n", mentioning: "rv")
}

@Test func refusesWrongTypeAndMissingRequired() {
    expectConfig(minimalIOS.replacingOccurrences(of: "type: cargo", with: "type: tauri"), mentioning: "tauri")
    expectConfig(minimalIOS.replacingOccurrences(of: "teamID: ABCDE12345", with: "teamID: short"), mentioning: "teamID")
    expectConfig(minimalIOS.replacingOccurrences(of: "com.example.hello", with: "nodots"), mentioning: "bundleID")
    expectConfig(minimalIOS.replacingOccurrences(of: "  minimumOS: \"17.0\"\n", with: ""), mentioning: "minimumOS")
    expectConfig(minimalIOS.replacingOccurrences(of: "  minimumOS: \"17.0\"", with: "  minimumOS: tomorrow"), mentioning: "minimumOS")
    expectConfig(minimalIOS + "xcode: latest\n", mentioning: "xcode")
}

@Test func refusesNoPlatform() {
    expectConfig("type: cargo\nbundleID: com.example.hello\nteamID: ABCDE12345\n", mentioning: "ios")
}

@Test func refusesIconOnIOSAndMissingAssets() {
    expectConfig(minimalIOS.replacingOccurrences(of: "  assets: Assets.xcassets", with: "  icon: icon.icns"), mentioning: "ios.icon")
    expectConfig(minimalIOS.replacingOccurrences(of: "  assets: Assets.xcassets\n", with: ""), mentioning: "ios.assets")
}

@Test func refusesIconAndAssetsOnMacOS() {
    let both = minimalIOS + "macos: { package: hello, product: Hello, minimumOS: \"11.0\", icon: a.icns, assets: A.xcassets }\n"
    expectConfig(both, mentioning: "macos")
    let assetsOnly = minimalIOS + "macos: { package: hello, product: Hello, minimumOS: \"11.0\", assets: A.xcassets }\n"
    #expect((try? CargoOverlay.parse(yaml: assetsOnly, name: "a"))?.macos?.assets == "A.xcassets")
}

@Test func refusesSecretEnv() {
    for name in ["ASC_KEY_P8", "ASC_KEY_P8_FILE", "XLESS_DIST_KEY", "XLESS_DEVID_KEY_FILE", "XLESS_INSTALLER_KEY", "XLESS_BUILD_NUMBER", "SWIFT_EXEC", "PATH", "SDKROOT"] {
        expectConfig(minimalIOS + "env: { \(name): x }\n", mentioning: name)
    }
    expectConfig(minimalIOS + "env: { \"BAD NAME\": x }\n", mentioning: "BAD NAME")
    expectConfig(minimalIOS + "inputs:\n  - { name: a, path: ../a, env: ASC_KEY_P8 }\n", mentioning: "ASC_KEY_P8")
}

@Test func refusesBadRev() {
    func git(_ rev: String, url: String = "https://example.com/f.git") -> String {
        minimalIOS + "inputs:\n  - { name: f, git: \(url), rev: \(rev), env: F_DIR }\n"
    }
    expectConfig(git("main"), mentioning: "rev")
    expectConfig(git(String(repeating: "a", count: 39)), mentioning: "rev")
    expectConfig(git(String(repeating: "a", count: 41)), mentioning: "rev")
    expectConfig(git(rev, url: "http://example.com/f.git"), mentioning: "https")
    expectConfig(git(rev, url: "git@example.com:f.git"), mentioning: "https")
    expectConfig(minimalIOS + "inputs:\n  - { name: f, git: https://example.com/f.git, env: F_DIR }\n", mentioning: "rev")
    #expect((try? CargoOverlay.parse(yaml: git(rev), name: "a")) != nil)
}

@Test func refusesBadInputs() {
    expectConfig(minimalIOS + "inputs:\n  - { name: f, path: ../f, git: https://example.com/f.git, rev: \(rev), env: F_DIR }\n", mentioning: "both")
    expectConfig(minimalIOS + "inputs:\n  - { name: f, env: F_DIR }\n", mentioning: "path")
    expectConfig(minimalIOS + "inputs:\n  - { name: f, path: ../f }\n")
    expectConfig(minimalIOS + "inputs:\n  - { name: f/x, path: ../f, env: F_DIR }\n", mentioning: "f/x")
    expectConfig(minimalIOS + "inputs:\n  - { name: f, path: ../f, env: F_DIR }\n  - { name: f, path: ../g, env: G_DIR }\n", mentioning: "f")
    expectConfig(minimalIOS + "inputs:\n  - { name: f, path: ../f, env: F_DIR }\n  - { name: g, path: ../g, env: F_DIR }\n", mentioning: "F_DIR")
    expectConfig(minimalIOS + "env: { F_DIR: x }\ninputs:\n  - { name: f, path: ../f, env: F_DIR }\n", mentioning: "F_DIR")
}

@Test func refusesEscapingAndAbsolutePaths() {
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: ../outside.plist"), mentioning: "ios.infoPlist")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: a/../../outside.plist"), mentioning: "ios.infoPlist")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  entitlements: /etc/x.plist"), mentioning: "ios.entitlements")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  entitlements: ~/x.plist"), mentioning: "ios.entitlements")
    expectConfig(minimalIOS.replacingOccurrences(of: "assets: Assets.xcassets", with: "assets: \"\""), mentioning: "ios.assets")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  resources: [{ from: ../x, to: y }]"), mentioning: "resources")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  resources: [{ from: x, to: ../y }]"), mentioning: "resources")
    expectConfig(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  resources: [{ from: x, to: /y }]"), mentioning: "resources")
    // Inside the root after normalisation: fine.
    let ok = minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: a/../b/Info.plist")
    #expect((try? CargoOverlay.parse(yaml: ok, name: "a")) != nil)
}

@Test func inputPathsNeedADeclaredInputAndStayInsideIt() {
    let base = minimalIOS + "inputs:\n  - { name: fonts, path: ../fonts, env: FONTS_DIR }\n"
    func withPlist(_ p: String) -> String { base.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: \(p)") }
    #expect((try? CargoOverlay.parse(yaml: withPlist("input:fonts/Info.plist"), name: "a")) != nil)
    expectConfig(withPlist("input:other/Info.plist"), mentioning: "other")
    expectConfig(withPlist("input:fonts/../../Info.plist"), mentioning: "ios.infoPlist")
    expectConfig(withPlist("input:fonts/.."), mentioning: "ios.infoPlist")
    expectConfig(withPlist("input:/Info.plist"), mentioning: "ios.infoPlist")
}

@Test func loadResolvesPrivacyManifestAgainstOverlay() throws {
    let url = try writeOverlay(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: ios/Info.plist")
        + "source: /src\nprivacyManifest: ../shared/PrivacyInfo.xcprivacy\n")
    let loaded = try CargoOverlay.load(from: url, sourceOverride: nil, env: ["HOME": "/home/u"])
    let expected = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/PrivacyInfo.xcprivacy").path
    #expect(loaded.overlay.privacyManifest == expected)
    #expect(loaded.overlay.ios?.infoPlist == "ios/Info.plist")
    #expect(loaded.sourceRoot.path == "/src")
}

@Test func loadResolvesSourceAndWorkRoot() throws {
    let env = ["HOME": "/home/u"]
    let url = try writeOverlay(minimalIOS + "source: ~/src/app\n")
    let loaded = try CargoOverlay.load(from: url, sourceOverride: nil, env: env)
    #expect(loaded.sourceRoot.path == "/home/u/src/app" && loaded.workRoot.path == "/home/u/.cache/xless/work/my.overlay")
    #expect(loaded.overlay.privacyManifest == nil)
    #expect(try CargoOverlay.load(from: url, sourceOverride: "/other", env: env).sourceRoot.path == "/other")
    #expect(try CargoOverlay.load(from: url, sourceOverride: nil, env: env.merging(["XLESS_WORK_ROOT": "/w"]) { $1 }).workRoot.path == "/w/my.overlay")
    #expect(throws: XlessError.self) { try CargoOverlay.load(from: writeOverlay(minimalIOS), sourceOverride: nil, env: env) }
    #expect(throws: XlessError.self) { try CargoOverlay.load(from: url.appendingPathExtension("missing"), sourceOverride: nil, env: env) }
}

/// Ruling R6: the assets and sign stages read `assets` and `entitlements` from the work copy, so those may not name an input.
@Test func refusesInputPathForAssetsAndEntitlements() {
    let inputs = "inputs:\n  - { name: fonts, path: ../fonts, env: FONTS_DIR }\n"
    let mac = """
    macos:
      package: hello
      product: Hello
      minimumOS: "11.0"

    """
    func expectRefused(_ yaml: String, _ key: String) {
        do {
            _ = try CargoOverlay.parse(yaml: yaml, name: "a")
            Issue.record("expected a config error for \(key)")
        } catch let e as XlessError {
            #expect(e.stage == .config)
            #expect(e.cause.contains(key), "cause: \(e.cause)")
            #expect(e.fix.contains("repository"), "fix: \(e.fix)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
    expectRefused(minimalIOS.replacingOccurrences(of: "assets: Assets.xcassets", with: "assets: input:fonts/Assets.xcassets") + inputs, "ios.assets")
    expectRefused(minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  entitlements: input:fonts/ios.entitlements") + inputs, "ios.entitlements")
    expectRefused(minimalIOS + inputs + mac.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  assets: input:fonts/Mac.xcassets"), "macos.assets")
    expectRefused(minimalIOS + inputs + mac.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  entitlements: input:fonts/mac.entitlements"), "macos.entitlements")
    // infoPlist, icon and resources keep accepting input: paths.
    let ok = minimalIOS.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  infoPlist: input:fonts/Info.plist") + inputs
        + mac.replacingOccurrences(of: "  product: Hello", with: "  product: Hello\n  icon: input:fonts/hello.icns\n  resources: [{ from: input:fonts/OFL.txt, to: Licenses/OFL.txt }]")
    #expect((try? CargoOverlay.parse(yaml: ok, name: "a")) != nil)
}

/// Ruling R6: `xless cargo inputs` prints `name<TAB>path` lines, so a path input may not hold a tab or a line break.
@Test func refusesControlCharactersInInputPath() {
    for bad in ["a\\tb", "a\\nb", "a\\rb", "a\\r\\nb"] {
        expectConfig(minimalIOS + "inputs:\n  - { name: fonts, path: \"../\(bad)\", env: FONTS_DIR }\n", mentioning: "fonts")
    }
    #expect((try? CargoOverlay.parse(yaml: minimalIOS + "inputs:\n  - { name: fonts, path: \"../my fonts\", env: FONTS_DIR }\n", name: "a")) != nil)
}

/// The overlay shipped with samples/HelloCargo parses, and every file it names is in the sample.
@Test func parsesTheShippedExampleOverlay() throws {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let sample = dir.appendingPathComponent("samples/HelloCargo")
    let url = sample.appendingPathComponent("xless.overlay.example.yml")
    let loaded = try CargoOverlay.load(from: url, env: ["HOME": "/home/u"])
    let o = loaded.overlay
    #expect(o.name == "xless.overlay.example" && o.bundleID == "com.example.hellocargo" && o.teamID == "ABCDE12345")
    #expect(o.toolchain == nil && o.version == nil && o.build == "dated" && o.inputs.isEmpty)
    #expect(o.ios?.package == "hello-cargo" && o.ios?.product == "HelloCargo" && o.ios?.minimumOS == "17.0" && o.ios?.bundleID == nil)
    #expect(o.macos?.package == "hello-cargo" && o.macos?.bundleID == "com.example.hellocargo.mac")
    #expect(o.macos?.assets == "Assets.xcassets" && o.macos?.icon == nil)
    #expect(loaded.sourceRoot.standardizedFileURL.path == sample.standardizedFileURL.path)
    #expect(o.privacyManifest == sample.appendingPathComponent("PrivacyInfo.xcprivacy").standardizedFileURL.path)
    // The files it names exist: relative to the source root, except the privacy manifest.
    let named = [o.ios?.infoPlist, o.ios?.assets, o.macos?.infoPlist, o.macos?.assets].compactMap { $0 }
    for path in named { #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent(path).path), "\(path)") }
    #expect(FileManager.default.fileExists(atPath: o.privacyManifest ?? ""))
    // The toolchain is pinned by rust-toolchain.toml, not by the overlay.
    #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("rust-toolchain.toml").path))
    #expect(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Cargo.lock").path))
}
