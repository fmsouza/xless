import Testing
import Foundation
@testable import XlessReactNative
@testable import XlessCore
import XlessTauri
import XlessXcode

let rnYAML = """
type: react-native
source: ~/src/app
app: { dir: apps/client }
env: { FEATURE_X: enabled, REGION: eu }
scheme: MyApp
configuration: Release
bundleIDs:
  MyApp: com.example.app
  MyExtension: com.example.app.MyExtension
teamID: ABCDE12345
build: dated
prepare: { run: ["bash tools/gen.sh"] }
allowMissingCommands: [PlistBuddy]
usesNonExemptEncryption: false
testflight: { groups: [Internal] }
"""

@Test func parsesAFullReactNativeOverlay() throws {
    let o = try ReactNativeOverlay.parse(yaml: rnYAML, name: "app")
    #expect(o.name == "app" && o.source == "~/src/app" && o.appDir == "apps/client")
    #expect(o.env == ["FEATURE_X": "enabled", "REGION": "eu"])
    #expect(o.scheme == "MyApp" && o.configuration == "Release" && o.teamID == "ABCDE12345" && o.build == "dated" && o.version == nil)
    #expect(o.bundleIDs == ["MyApp": "com.example.app", "MyExtension": "com.example.app.MyExtension"])
    #expect(o.prepareRun == ["bash tools/gen.sh"] && o.allowMissingCommands == ["PlistBuddy"])
    #expect(o.usesNonExemptEncryption == false && o.testflight?.groups == ["Internal"])
    #expect(o.appTargetGuess == "MyApp")
}

@Test func parsesIdentifierReplacementsAndEntitlementRemovals() throws {
    let yaml = rnYAML + """

    identifiers:
      replace: { com.other.app: com.example.app }
    entitlements:
      remove: [com.apple.developer.declared-age-range]
    """
    let o = try ReactNativeOverlay.parse(yaml: yaml, name: "app")
    #expect(o.identifiers == IdentifierReplacement(["com.other.app": "com.example.app"]))
    #expect(o.entitlementsRemove == ["com.apple.developer.declared-age-range"])
    // The sign stage's view: the same map for the entitlements, plus the removals.
    #expect(o.entitlements == EntitlementRewrites(replace: ["com.other.app": "com.example.app"], remove: ["com.apple.developer.declared-age-range"]))
    let plain = try ReactNativeOverlay.parse(yaml: rnYAML, name: "app")
    #expect(plain.entitlements == .none && plain.identifiers == .none && plain.xcode == nil)
}

@Test func theUnreleasedEntitlementsReplaceKeyIsRefusedWithWhereItWent() {
    let yaml = rnYAML + "\nentitlements: { replace: { com.other.app: com.example.app }, remove: [x.y] }\n"
    let e = #expect(throws: XlessError.self) { try ReactNativeOverlay.parse(yaml: yaml, name: "a") }
    #expect(e?.stage == .config)
    #expect(e?.cause == "overlay a: entitlements.replace is now identifiers.replace")
    #expect(e?.fix.contains("identifiers: { replace:") == true && e?.fix.contains("Info.plist") == true)
}

@Test func parsesTheXcodePin() throws {
    for (value, want) in [("\"26.2\"", "26.2"), ("26.2", "26.2"), ("'27.0'", "27.0"), ("27.0.1", "27.0.1"), ("27", "27")] {
        let o = try ReactNativeOverlay.parse(yaml: rnYAML + "\nversion: 1.0.0\nxcode: \(value)\n", name: "a")
        #expect(o.xcode == want, "xcode: \(value)")
        #expect(try ReactNativeProject.resolve(overlay: o, source: URL(fileURLWithPath: "/nonexistent"), work: URL(fileURLWithPath: "/nonexistent")).config.xcode == want)
    }
    for bad in ["latest", "\"26.2b\"", "\"\"", "26.2.1.4"] {
        let e = #expect(throws: XlessError.self) { try ReactNativeOverlay.parse(yaml: rnYAML + "\nxcode: \(bad)\n", name: "a") }
        #expect(e?.stage == .config && e?.cause.contains("is not an Xcode version") == true, "xcode: \(bad)")
    }
}

@Test func reactNativeOverlayDefaults() throws {
    let o = try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: A\nbundleIDs: { App: com.example.a }\nteamID: ABCDE12345\nversion: 2.1\nbuild: 7\n", name: "a")
    #expect(o.appDir == "." && o.configuration == "Release" && o.env.isEmpty && o.prepareRun.isEmpty && o.allowMissingCommands.isEmpty)
    #expect(o.version == "2.1" && o.build == "7" && o.source == nil && o.privacyManifest == nil)
    // Only one entry: it is the app, whatever the scheme is called.
    #expect(o.appTargetGuess == "App")
}

@Test func theAppTargetIsTheEntryEveryExtensionIDExtends() throws {
    // A committed ios/ whose scheme is named unlike its app target: no entry named like the scheme.
    func guess(_ ids: String, scheme: String = "Shipping") throws -> String? {
        try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: \(scheme)\nbundleIDs: { \(ids) }\nteamID: ABCDE12345\nbuild: 7\n", name: "a").appTargetGuess
    }
    #expect(try guess("App: com.example.a, Share: com.example.a.Share, Widget: com.example.a.Widget") == "App")
    #expect(try guess("Share: com.example.a.share, App: com.example.a") == "App")
    #expect(try guess("App: com.example.a, Share: com.example.a.Share", scheme: "App") == "App")   // named like the scheme (Expo)
    // No unique root: unknown until the Xcode project exists.
    #expect(try guess("A: com.example.a, B: com.example.b") == nil)                     // unrelated IDs
    #expect(try guess("App: com.example.a, Share: com.example.ab.Share") == nil)        // a prefix without the '.'
    #expect(try guess("App: com.example.a, Share: com.example.a.Share, Other: com.example.b") == nil)
}

@Test func aCommittedIOSWithAnotherSchemeNameResolvesBeforePrepare() throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("rn-guess-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let o = try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: Shipping\nbundleIDs: { App: com.example.a, Share: com.example.a.Share }\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: 7\n", name: "a")
    let r = try ReactNativeProject.resolve(overlay: o, source: work, work: work)
    #expect(r.appTarget == "App" && r.config.bundleID == "com.example.a")
}

@Test func theCommittedHelloRNOverlayParses() throws {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let url = dir.appendingPathComponent("samples/HelloRN/xless.overlay.yml")
    let (o, source, work) = try ReactNativeOverlay.load(from: url, env: ["HOME": "/h", "XLESS_WORK_ROOT": "/w"])
    #expect(o.scheme == "HelloRN" && o.bundleIDs["HelloExtension"] == "com.example.hellorn.HelloExtension" && o.teamID == "ABCDE12345")
    #expect(source.path == dir.appendingPathComponent("samples/HelloRN").standardizedFileURL.path)
    #expect(work.path == "/w/xless.overlay")
}

@Test(arguments: [
    ("type: react-native", "type: tauri"),                                   // another overlay type
    ("teamID: ABCDE12345", "teamID: abc"),                                    // team ID shape
    ("build: dated", "build: dated\nbundleIds: {}"),                          // unknown key (misspelt)
    ("app: { dir: apps/client }", "app: { directory: apps/client }"),         // unknown nested key
    ("app: { dir: apps/client }", "app: { dir: ../mobile }"),                 // app dir escaping the source
    ("app: { dir: apps/client }", "app: { dir: /abs }"),
    ("configuration: Release", "configuration: Debug"),                       // debug builds need Metro
    ("MyExtension: com.example.app.MyExtension", "MyExtension: com.other.ext"),   // extension outside the app's ID
    ("MyExtension: com.example.app.MyExtension", "MyExtension: com.example.app"), // the same ID twice
    ("MyApp: com.example.app", "MyApp: not_an_id"),
    ("FEATURE_X: enabled", "PATH: /x"),                                         // set by xless
    ("FEATURE_X: enabled", "SWIFT_VERSION: '5'"),
    ("FEATURE_X: enabled", "ASC_KEY_P8: k"),                                    // a secret never reaches app tooling
    ("FEATURE_X: enabled", "\"BAD-NAME\": x"),
    ("build: dated", "build: dated\nversion: 1.0.0-beta"),
    ("build: dated", "build: soon"),
    ("prepare: { run: [\"bash tools/gen.sh\"] }", "prepare: { run: [\" \"] }"),
    ("allowMissingCommands: [PlistBuddy]", "allowMissingCommands: [\"\"]"),
    ("scheme: MyApp", "scheme: a/b"),
    ("build: dated", "build: dated\nentitlements: { rename: {} }"),            // unknown entitlements.* key
    ("build: dated", "build: dated\nidentifiers: { remove: [x.y] }"),           // unknown identifiers.* key
    ("build: dated", "build: dated\nidentifiers: { replace: { \"\": x } }"),     // nothing to replace
    ("build: dated", "build: dated\nidentifiers: { replace: { com: org } }"),       // too broad: under 4 characters
    ("build: dated", "build: dated\nidentifiers: { replace: { example: other } }"), // too broad: no '.'
    ("build: dated", "build: dated\nidentifiers: { replace: { com.other.app: \"\" } }"), // empty replacement
    ("build: dated", "build: dated\nentitlements: { replace: { com.other.app: com.example.app } }"), // moved to identifiers
    ("build: dated", "build: dated\nentitlements: { remove: [\"\"] }"),
    ("build: dated", "build: dated\nxcode: soon"),
])
func refusesBadReactNativeOverlays(_ swap: (String, String)) {
    #expect(rnYAML.contains(swap.0))
    let e = #expect(throws: XlessError.self) { try ReactNativeOverlay.parse(yaml: rnYAML.replacingOccurrences(of: swap.0, with: swap.1), name: "a") }
    #expect(e?.stage == .config)
}

@Test func overlayTypeIsReadBeforeParsing() {
    #expect(OverlayPaths.type(of: rnYAML) == "react-native")
    #expect(OverlayPaths.type(of: "type: tauri\n") == "tauri")
    #expect(OverlayPaths.type(of: "bundleID: x\n") == nil)
}

@Test func prepareEnvironmentScrubsSwiftAndAddsTheShims() throws {
    let o = try ReactNativeOverlay.parse(yaml: rnYAML, name: "a")
    let env = ReactNativeEnvironment.prepare(overlay: o, shimDirectory: URL(fileURLWithPath: "/opt/xless/shims"),
                                             base: ["PATH": "/usr/bin", "SWIFT_VERSION": "swift-6.4.0-RELEASE", "SWIFT_BRANCH": "b", "HOME": "/root"])
    #expect(env["SWIFT_VERSION"] == .some(nil) && env["SWIFT_BRANCH"] == .some(nil) && env["HOME"] == nil)
    #expect(env["PATH"] == "/opt/xless/shims/prepare:/usr/bin")
    #expect(env["TAR_OPTIONS"] == "--warning=no-unknown-keyword --exclude=._*" && env["FEATURE_X"] == "enabled" && env["EXPO_NO_TELEMETRY"] == "1")
    let build = ReactNativeEnvironment.build(overlay: o)
    #expect(build["FEATURE_X"] == "enabled" && build["PATH"] == nil)
    // Per-target values are never command-line settings (which would apply to every target and win over them).
    let perTarget = Set(ReactNativeEnvironment.targetSettings(bundleID: "a.b", version: "1", build: "1").keys)
    #expect(perTarget.isDisjoint(with: ReactNativeEnvironment.buildSettings(overlay: o).keys))
    let linux = SwiftBuildEnvironment(sdk: DarwinSDK(bundle: URL(fileURLWithPath: "/b")), shimDirectory: URL(fileURLWithPath: "/s"),
                                      toolchainInclude: URL(fileURLWithPath: "/i"))
    #expect(perTarget.isDisjoint(with: linux.overrides(toolset: URL(fileURLWithPath: "/t.json")).keys))
    #expect(ReactNativeEnvironment.buildSettings(overlay: o) == ["DEVELOPMENT_TEAM": "ABCDE12345", "HERMES_CLI_PATH": "/usr/local/bin/hermesc"])
}

@Test func provisioningUpdatesReachTheConfig() throws {
    let base = "type: react-native\nscheme: A\nbundleIDs: { A: com.example.a }\nteamID: ABCDE12345\nversion: \"1.0\"\n"
    for (extra, want) in [("", true), ("provisioningUpdates: false\n", false)] {
        let o = try ReactNativeOverlay.parse(yaml: base + extra, name: "a")
        let nowhere = URL(fileURLWithPath: "/nonexistent")
        #expect(try ReactNativeProject.resolve(overlay: o, source: nowhere, work: nowhere).config.provisioningUpdates == want)
    }
    for line in ["provisioningUpdates:\n", "provisionUpdates: false\n", "testflight: { provisioningUpdates: false }\n", "7: a\nprovisionUpdates: false\n"] {
        #expect(throws: XlessError.self, "\(line)") { _ = try ReactNativeOverlay.parse(yaml: base + line, name: "a") }
    }
}
