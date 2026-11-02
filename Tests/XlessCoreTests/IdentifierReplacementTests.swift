import Testing
import Foundation
@testable import XlessCore

private let map = IdentifierReplacement(["com.other.app": "com.example.app", "com.other.app.share": "com.example.share"])

@Test func identifierReplacementIsOnePassLongestMatchFirst() {
    #expect(map.apply(to: "group.com.other.app") == "group.com.example.app")
    #expect(map.apply(to: "ABCDE12345.com.other.app.share.keys") == "ABCDE12345.com.example.share.keys")
    // A replacement that contains a key is not rewritten again.
    let chain = IdentifierReplacement(["com.a.b": "com.a.b.c", "com.a.b.c": "x.y"])
    #expect(chain.apply(to: "com.a.b") == "com.a.b.c")
    #expect(IdentifierReplacement.none.apply(to: "com.other.app") == "com.other.app")
    // The sign stage's entitlement rewrites apply the same map.
    #expect(EntitlementRewrites(replace: map.map).apply(to: "group.com.other.app") == "group.com.example.app")
}

@Test func identifierReplacementRewritesNestedPlistStringsAndNamesTheKeyPaths() throws {
    let plist: [String: Any] = [
        "SharedContainerGroup": "group.com.other.app",
        "CFBundleIdentifier": "com.example.app",
        "Count": 3, "Flag": true, "Blob": Data([1, 2]),
        "NSExtension": ["NSExtensionAttributes": ["Groups": ["group.com.other.app", "unrelated"]]],
        "CFBundleURLTypes": [["CFBundleURLSchemes": ["com.other.app.share", "x"]]],
        // Dictionary keys are never rewritten.
        "com.other.app": "value",
    ]
    var changed: [String] = []
    let out = try #require(map.rewrite(plist, changed: &changed) as? [String: Any])
    #expect(changed == ["CFBundleURLTypes[0].CFBundleURLSchemes[0]", "NSExtension.NSExtensionAttributes.Groups[0]", "SharedContainerGroup"])
    #expect(out["SharedContainerGroup"] as? String == "group.com.example.app")
    #expect(((out["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])?["Groups"] as? [String] == ["group.com.example.app", "unrelated"])
    #expect(((out["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]) == ["com.example.share", "x"])
    #expect(out["com.other.app"] as? String == "value" && out["Count"] as? Int == 3 && out["Flag"] as? Bool == true && out["Blob"] as? Data == Data([1, 2]))
}

/// Ruling M3: a key matches only where an identifier ends (the next character is not a letter, digit or `-`).
@Test func aKeyMatchesOnlyAtAnIdentifierBoundary() {
    let m = IdentifierReplacement(["com.other.app": "com.example.app"])
    let cases: [(String, String)] = [
        ("com.other.app", "com.example.app"),                          // the end of the string
        ("group.com.other.app", "group.com.example.app"),
        ("ABCDE12345.com.other.app.share", "ABCDE12345.com.example.app.share"),   // '.'
        ("com.other.app:/callback", "com.example.app:/callback"),      // a URL scheme
        ("https://x/com.other.app/y", "https://x/com.example.app/y"),  // '/'
        ("com.other.app_x com.other.app", "com.example.app_x com.example.app"),   // '_' and ' ' end an identifier
        ("com.other.apple", "com.other.apple"),                        // a letter continues it
        ("com.other.appkit.sdk", "com.other.appkit.sdk"),
        ("com.other.app2", "com.other.app2"),                          // a digit
        ("com.other.app-beta", "com.other.app-beta"),                  // '-'
        ("com.other.apple com.other.app", "com.other.apple com.example.app"),
    ]
    for (input, want) in cases { #expect(m.apply(to: input) == want, "\(input)") }
    // Longest match first, each at a boundary: the longer key does not match here, the shorter one does.
    #expect(map.apply(to: "com.other.app.shared") == "com.example.app.shared")
    #expect(map.apply(to: "com.other.app.share") == "com.example.share")
    #expect(map.ownsBundleID("com.other.app.kit") && map.ownsBundleID("com.other.app") && !map.ownsBundleID("com.other.apple.kit") && !map.ownsBundleID("org.kit"))
}

/// An app with an extension, a third-party framework, the other team's own framework, a resource bundle and a loose
/// `Info.plist` that is no bundle's.
private func appTree() throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("ids-\(UUID())/App.app")
    func put(_ rel: String, _ plist: [String: Any], _ format: PropertyListSerialization.PropertyListFormat) throws {
        let u = app.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: u)
    }
    try put("Info.plist", ["CFBundleIdentifier": "com.example.app", "SharedContainerGroup": "group.com.other.app"], .binary)
    try put("PlugIns/Share.appex/Info.plist", ["CFBundleIdentifier": "com.example.app.Share",
                                               "NSExtension": ["Group": "group.com.other.app"]], .xml)
    try put("Frameworks/Kit.framework/Info.plist", ["CFBundleIdentifier": "org.kit", "KitKeychain": "ABCDE12345.com.other.app.share"], .binary)
    try put("Frameworks/OtherKit.framework/Info.plist", ["CFBundleIdentifier": "com.other.app.OtherKit", "Group": "group.com.other.app"], .binary)
    try put("Kit.bundle/Info.plist", ["CFBundleIdentifier": "org.kit.res", "Note": "nothing to replace"], .xml)
    try put("Assets/Info.plist", ["Stray": "group.com.other.app"], .xml)
    return app
}

@Test func everyBundlesInfoPlistIsFoundAndNoOtherFile() throws {
    let app = try appTree()
    #expect(IdentifierReplacement.infoPlists(in: app) == [
        "Frameworks/Kit.framework/Info.plist", "Frameworks/OtherKit.framework/Info.plist", "Info.plist", "Kit.bundle/Info.plist",
        "PlugIns/Share.appex/Info.plist",
    ])
}

/// Only components below the app count: an app inside a directory named `*.framework` has no bundle in `Resources/`.
@Test func infoPlistDiscoveryLooksAtBundleRelativePathsOnly() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("ids-\(UUID())/Work.framework/App.app")
    for rel in ["Info.plist", "Resources/Info.plist", "Frameworks/M.framework/Versions/A/Resources/Info.plist", "Mac.app/Contents/Info.plist"] {
        let u = app.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "x.y"], format: .xml, options: 0).write(to: u)
    }
    #expect(IdentifierReplacement.infoPlists(in: app) == ["Frameworks/M.framework/Versions/A/Resources/Info.plist", "Info.plist", "Mac.app/Contents/Info.plist"])
}

@Test func infoPlistsAreRewrittenInPlaceInTheirOwnFormat() throws {
    let app = try appTree()
    let untouched = try Data(contentsOf: app.appendingPathComponent("Kit.bundle/Info.plist"))
    let stray = try Data(contentsOf: app.appendingPathComponent("Assets/Info.plist"))
    let thirdParty = try Data(contentsOf: app.appendingPathComponent("Frameworks/Kit.framework/Info.plist"))
    let report = try map.rewriteInfoPlists(in: app, stage: .finalize)
    #expect(report == ["Frameworks/OtherKit.framework/Info.plist: Group", "Info.plist: SharedContainerGroup",
                       "PlugIns/Share.appex/Info.plist: NSExtension.Group"])
    func read(_ rel: String) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent(rel)), options: [], format: &format)
        return (try #require(p as? [String: Any]), format)
    }
    let (main, mainFormat) = try read("Info.plist")
    #expect(main["SharedContainerGroup"] as? String == "group.com.example.app" && main["CFBundleIdentifier"] as? String == "com.example.app")
    #expect(mainFormat == .binary)
    let (ext, extFormat) = try read("PlugIns/Share.appex/Info.plist")
    #expect((ext["NSExtension"] as? [String: Any])?["Group"] as? String == "group.com.example.app" && extFormat == .xml)
    // A third-party framework (its bundle ID is none of the replaced identifiers) is left byte for byte, although it
    // names one; the other team's own framework is rewritten, its CFBundleIdentifier kept.
    #expect(try Data(contentsOf: app.appendingPathComponent("Frameworks/Kit.framework/Info.plist")) == thirdParty)
    let (kit, kitFormat) = try read("Frameworks/OtherKit.framework/Info.plist")
    #expect(kit["Group"] as? String == "group.com.example.app" && kit["CFBundleIdentifier"] as? String == "com.other.app.OtherKit" && kitFormat == .binary)
    // Nothing replaced: the file is left byte for byte; a file that is no bundle's Info.plist is never read.
    #expect(try Data(contentsOf: app.appendingPathComponent("Kit.bundle/Info.plist")) == untouched)
    #expect(try Data(contentsOf: app.appendingPathComponent("Assets/Info.plist")) == stray)
    // No map: nothing is read or written.
    #expect(try IdentifierReplacement.none.rewriteInfoPlists(in: app, stage: .finalize).isEmpty)
}

@Test func aReplacementThatWouldChangeABundleIDIsRefused() throws {
    let app = try appTree()
    let e = #expect(throws: XlessError.self) { try IdentifierReplacement(["com.example.app": "com.x.y"]).rewriteInfoPlists(in: app, stage: .finalize) }
    #expect(e?.stage == .finalize && e?.cause.contains("CFBundleIdentifier") == true && e?.fix.contains("bundleIDs") == true)
    // For the other team's own framework the bundle ID is kept instead: with nothing else to replace, it is untouched.
    let other = try appTree()
    let kit = try Data(contentsOf: other.appendingPathComponent("Frameworks/OtherKit.framework/Info.plist"))
    #expect(try IdentifierReplacement(["com.other.app.OtherKit": "com.x.y"]).rewriteInfoPlists(in: other, stage: .finalize).isEmpty)
    #expect(try Data(contentsOf: other.appendingPathComponent("Frameworks/OtherKit.framework/Info.plist")) == kit)
}

/// Fix wave M4: sign refuses a map other than the one finalize applied to the Info.plists (`--from sign` after an edit).
@Test func signRefusesAMapEditedSinceFinalize() throws {
    let final = FileManager.default.temporaryDirectory.appendingPathComponent("ids-final-\(UUID())")
    try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
    // Nothing recorded, no map: an app finalized without identifiers.replace (and every Tauri or xless.yml app).
    try IdentifierReplacement.none.checkFinalized(in: final)
    // A map added after finalize.
    var e = #expect(throws: XlessError.self) { try map.checkFinalized(in: final) }
    #expect(e?.stage == .sign && e?.stage.exitCode == 15 && e?.cause.contains("finalize replaced: none") == true && e?.fix.contains("--from finalize") == true)
    try map.record(in: final)
    try map.checkFinalized(in: final)
    // A value changed, a key added or removed, the map dropped: refused.
    for other in [IdentifierReplacement(["com.other.app": "com.example.other", "com.other.app.share": "com.example.share"]),
                  IdentifierReplacement(["com.other.app": "com.example.app"]), IdentifierReplacement.none] {
        e = #expect(throws: XlessError.self) { try other.checkFinalized(in: final) }
        #expect(e?.stage == .sign && e?.cause.contains("finalize replaced: com.other.app, com.other.app.share") == true)
    }
    // Recording an empty map removes the record.
    try IdentifierReplacement.none.record(in: final)
    try IdentifierReplacement.none.checkFinalized(in: final)
    try "nonsense".write(to: final.appendingPathComponent(IdentifierReplacement.recordName), atomically: true, encoding: .utf8)
    #expect(throws: XlessError.self) { try IdentifierReplacement.none.checkFinalized(in: final) }
}

// MARK: xcode pin (Ruling R8)

private func meta(_ code: String, _ build: String, sdk: String) -> ToolchainMeta {
    ToolchainMeta(xcodeVersion: code, xcodeBuild: build, buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler, platforms: [
        "iphoneos": .init(sdkName: "iphoneos\(sdk)", sdkVersion: sdk, sdkBuild: "23C50", platformName: "iphoneos", platformVersion: sdk, platformBuild: "23C50"),
    ])
}

@Test func theXcodeVersionIsDecodedFromDTXcode() {
    #expect(XcodePin.xcodeVersion(meta("2700", "27A266a", sdk: "27.0")) == "27.0")
    #expect(XcodePin.xcodeVersion(meta("2620", "17C52", sdk: "26.2")) == "26.2")
    #expect(XcodePin.xcodeVersion(meta("2601", "17A400", sdk: "26.0")) == "26.0.1")
}

@Test func aPinMatchesTheImagesXcodeOnly() throws {
    let m27 = meta("2700", "27A266a", sdk: "27.0"), m262 = meta("2620", "17C52", sdk: "26.2")
    #expect(XcodePin.matches(pin: "27.0", meta: m27) && XcodePin.matches(pin: "27", meta: m27) && XcodePin.matches(pin: "27.0.0", meta: m27))
    #expect(!XcodePin.matches(pin: "26.2", meta: m27) && !XcodePin.matches(pin: "27.0.1", meta: m27) && XcodePin.matches(pin: "26.2", meta: m262))
    try XcodePin.check(pin: nil, meta: m27, platform: .ios, file: "the overlay")
    try XcodePin.check(pin: "27.0", meta: m27, platform: .ios, file: "the overlay")
    let e = #expect(throws: XlessError.self) { try XcodePin.check(pin: "26.2", meta: m27, platform: .ios, file: "the overlay") }
    #expect(e?.description == "[build] the overlay pins xcode: \"26.2\", but this image has the iphoneos27.0 SDK from Xcode 27.0 (27A266a) — "
            + "install Xcode 26.2 natively (`xless setup --xcode <path to Xcode 26.2's .xip>`, which replaces the installed one), or build with --docker "
            + "in the images made from it (`xless setup --docker --xcode …`, tags *-xcode26.2; xless run --docker selects them from the pin), or change the pin to 27.0")
    for bad in ["26.2b", "", "x", "1.2.3.4", "26..2"] {
        #expect(throws: XlessError.self) { try XcodePin.validate(bad, file: "xless.yml") }
    }
}

@Test func theBuildSDKRecordRoundTripsAndSummarises() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkrec-\(UUID())")
    #expect(BuildSDKRecord.load(in: dir) == nil)
    let r = BuildSDKRecord(pin: "26.2", toolchain: meta("2620", "17C52", sdk: "26.2"))
    try r.write(in: dir)
    #expect(BuildSDKRecord.load(in: dir) == r)
    #expect(r.summary(platform: .ios) == "Xcode 26.2 (17C52), iphoneos26.2 SDK (23C50), pinned by xcode: \"26.2\"")
}

@Test func xlessYMLTakesAnXcodePin() throws {
    let yaml = "bundleID: a.b.c\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: 1\nplatforms: { ios: { minimumOS: \"17.0\", product: X } }\n"
    #expect(try ProjectConfig.parse(yaml: yaml).xcode == nil)
    #expect(try ProjectConfig.parse(yaml: yaml + "xcode: \"26.2\"\n").xcode == "26.2")
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: yaml + "xcode: latest\n") }
}
