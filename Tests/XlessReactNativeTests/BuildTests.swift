import Testing
import Foundation
@testable import XlessReactNative
@testable import XlessXcode
@testable import XlessCore
import XlessASC
import XlessTauri

private var fm: FileManager { .default }

private func tmp(_ tag: String) throws -> URL {
    let u = fm.temporaryDirectory.appendingPathComponent("rn-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func write(_ url: URL, _ text: String) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Tests/XlessXcodeTests/Fixtures/<name> (HelloRN's prebuild output; ExtPkg: app + appex + Swift package).
private func fixture(_ name: String) -> URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { dir.deleteLastPathComponent() }
    return dir.appendingPathComponent("XlessXcodeTests/Fixtures/\(name)")
}

/// A writable copy of the HelloRN fixture with what `pod install` and the extension plugin would add: the Pods
/// xcconfigs the app's configurations are based on, and entitlements files.
private func helloRN() throws -> (root: URL, ws: Workspace) {
    let root = try tmp("hellorn").appendingPathComponent("ios")
    try fm.copyItem(at: fixture("HelloRN"), to: root)
    // The fixture has no Pods project; the workspace lists the app's only.
    try write(root.appendingPathComponent("HelloRN.xcworkspace/contents.xcworkspacedata"), """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0"><FileRef location = "group:HelloRN.xcodeproj"></FileRef></Workspace>
        """)
    let ws0 = try XcodeWorkspace.load(root.appendingPathComponent("HelloRN.xcworkspace"))
    let project = ws0.projects[0]
    for c in project.targets.flatMap(\.configurations) {
        if let base = c.baseConfigurationID, let url = project.resolvedPath(of: base) {
            try write(url, "// CocoaPods\nOTHER_LDFLAGS = $(inherited) -ObjC\nPODS_ROOT = ${SRCROOT}/Pods\n")
        }
    }
    try write(root.appendingPathComponent("HelloRN/HelloRN.entitlements"), """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>aps-environment</key><string>development</string>
          <key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER).shared</string></array>
          <key>com.apple.developer.authentication-services.autofill-credential-provider</key><true/>
          <key>com.example.count</key><integer>3</integer>
        </dict></plist>
        """)
    try write(root.appendingPathComponent("HelloExtension/HelloExtension.entitlements"),
              "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict/></plist>\n")
    return (root, try XcodeWorkspace.load(root.appendingPathComponent("HelloRN.xcworkspace")))
}

private func overlay(_ extra: String = "", ids: String = "{ HelloRN: io.example.rn, HelloExtension: io.example.rn.HelloExtension }") throws -> ReactNativeOverlay {
    try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: HelloRN\nbundleIDs: \(ids)\nteamID: ABCDE12345\n\(extra)", name: "o")
}

// MARK: targets and per-target settings

@Test func findsTheAppAndTheBundlesItEmbeds() throws {
    let (_, ws) = try helloRN()
    let app = try ReactNativeProject.appTarget(ws, scheme: "HelloRN", stage: .build)
    #expect(app.target.name == "HelloRN")
    #expect(ReactNativeProject.embeddedTargets(app, in: ws).map(\.target.name) == ["HelloExtension"])
    let ext = try XcodeWorkspace.load(fixture("ExtPkg/ExtPkg.xcworkspace"))
    let extProject = try #require(ext.projects.first { $0.name == "ExtPkg" })
    let extApp = try #require(extProject.targets.first { $0.productType == "com.apple.product-type.application" })
    #expect(ReactNativeProject.embeddedTargets((extProject, extApp), in: ext).map(\.target.name) == ["Share"])
}

@Test func bundleIDsMustCoverTheAppAndItsExtensionsOnly() throws {
    let (_, ws) = try helloRN()
    #expect(try ReactNativeBuilder.bundleIDs(overlay: overlay(), app: "HelloRN", embedded: ["HelloExtension"], workspace: ws).count == 2)
    // The extension is embedded but not mapped (it would keep the project's ID and fail the embedded-binary check).
    let missing = #expect(throws: XlessError.self) {
        try ReactNativeBuilder.bundleIDs(overlay: overlay(ids: "{ HelloRN: io.example.rn }"), app: "HelloRN", embedded: ["HelloExtension"], workspace: ws)
    }
    #expect(missing?.stage == .build)
    // A target the app does not embed, or none at all (a typo).
    #expect(throws: XlessError.self) {
        try ReactNativeBuilder.bundleIDs(overlay: overlay(ids: "{ HelloRN: io.example.rn, HelloExtension: io.example.rn.H, Helo: io.example.rn.x }"),
                                         app: "HelloRN", embedded: ["HelloExtension"], workspace: ws)
    }
}

@Test func perTargetSettingsReachOnlyTheirTargetsInThePIF() throws {
    let (_, ws) = try helloRN()
    let app = ws.projects[0].target(named: "HelloRN")!, ext = ws.projects[0].target(named: "HelloExtension")!
    let p = ws.projects[0]
    let overridden = try ws.overridingTargetSettings([
        PIFWriter.targetGUID(app, in: p, workspace: ws): ReactNativeEnvironment.targetSettings(bundleID: "io.example.rn", version: "2.0", build: "2.0.2026101601"),
        PIFWriter.targetGUID(ext, in: p, workspace: ws): ReactNativeEnvironment.targetSettings(bundleID: "io.example.rn.HelloExtension", version: "2.0", build: "2.0.2026101601"),
    ])
    let objects = try PIFWriter.objects(overridden)
    func settings(_ target: String) -> [[String: JSON]] {
        objects.compactMap { o -> [[String: JSON]]? in
            guard o["type"]?.stringValue == "target", o["contents"]?["name"]?.stringValue == target else { return nil }
            return o["contents"]?["buildConfigurations"]?.arrayValue?.compactMap { c -> [String: JSON]? in
                if case .object(let d)? = c["buildSettings"] { return d } else { return nil }
            }
        }.first ?? []
    }
    for c in settings("HelloRN") {
        #expect(c["PRODUCT_BUNDLE_IDENTIFIER"] == .string("io.example.rn"))
        #expect(c["MARKETING_VERSION"] == .string("2.0") && c["CURRENT_PROJECT_VERSION"] == .string("2.0.2026101601"))
        #expect(c["CODE_SIGN_ENTITLEMENTS"] == .string("HelloRN/HelloRN.entitlements"))   // the target's other settings stay
    }
    for c in settings("HelloExtension") { #expect(c["PRODUCT_BUNDLE_IDENTIFIER"] == .string("io.example.rn.HelloExtension")) }
    #expect(settings("HelloRN").count == 2 && settings("HelloExtension").count == 2)
    // The project level is untouched (pods and other targets keep their settings).
    let projectSettings = objects.first { $0["type"]?.stringValue == "project" }?["contents"]?["buildConfigurations"]?.arrayValue ?? []
    #expect(!projectSettings.isEmpty && projectSettings.allSatisfy { $0["buildSettings"]?["PRODUCT_BUNDLE_IDENTIFIER"] == nil })
    #expect(throws: XlessError.self) { try ws.overridingTargetSettings(["P0:nope": [:]]) }
}

@Test func resolvesTheProjectFromTheWorkCopyOnceItExists() throws {
    let (root, _) = try helloRN()
    let work = root.deletingLastPathComponent()
    try write(work.appendingPathComponent("app.json"), #"{"expo": {"version": "1.4.0"}}"#)
    let pbx = root.appendingPathComponent("HelloRN.xcodeproj/project.pbxproj")   // the app target: 16.4 → 16.6
    let text = try String(contentsOf: pbx, encoding: .utf8).components(separatedBy: "\n").enumerated()
        .map { [462, 495].contains($0.offset + 1) ? $0.element.replacingOccurrences(of: "16.4", with: "16.6") : $0.element }.joined(separator: "\n")
    try write(pbx, text)
    let o = try overlay("build: dated\n")
    // Read only after a successful prepare.
    #expect(try ReactNativeProject.resolve(overlay: o, source: work, work: work).config.platforms[.ios]?.minimumOS == "16.4")
    try write(ReactNativeProject.stateFile(work: work), "f\n")
    let r = try ReactNativeProject.resolve(overlay: o, source: work, work: work)
    #expect(r.appTarget == "HelloRN" && r.config.bundleID == "io.example.rn" && r.config.version == "1.4.0" && r.versionSource == "app.json")
    #expect(r.config.platforms[.ios]?.minimumOS == "16.6" && r.config.platforms[.ios]?.product == "HelloRN")
    #expect(r.config.buildScheme == .dated)
    // Before prepare: no workspace, the overlay's guess.
    let empty = try tmp("empty")
    try write(empty.appendingPathComponent("package.json"), #"{"version": "3.0.1"}"#)
    let early = try ReactNativeProject.resolve(overlay: o, source: empty, work: empty)
    #expect(early.appTarget == "HelloRN" && early.config.version == "3.0.1" && early.versionSource == "package.json")
}

@Test func theVersionComesFromTheOverlayAppJsonOrPackageJson() throws {
    let dir = try tmp("version")
    try write(dir.appendingPathComponent("package.json"), #"{"version": "1.2.3-beta"}"#)
    // A pre-release suffix is not a CFBundleShortVersionString: the overlay must say.
    #expect(throws: XlessError.self) { try ReactNativeProject.version(overlay: overlay(), appDir: dir) }
    #expect(try ReactNativeProject.version(overlay: overlay("version: 1.2.3\n"), appDir: dir) == ("1.2.3", "overlay"))
    try write(dir.appendingPathComponent("app.json"), #"{"expo": {"version": "7.2"}}"#)
    #expect(try ReactNativeProject.version(overlay: overlay(), appDir: dir) == ("7.2", "app.json"))
}

// MARK: entitlements.json

@Test func entitlementsAreRecordedWithBuildSettingsExpanded() throws {
    let (_, ws) = try helloRN()
    let p = ws.projects[0]
    let settings = try TargetSettings(project: p, target: p.target(named: "HelloRN")!, configuration: "Release",
                                      overrides: ["PRODUCT_BUNDLE_IDENTIFIER": "io.example.rn", "DEVELOPMENT_TEAM": "ABCDE12345"])
    let e = try BuiltApp.entitlements(settings, bundleID: "io.example.rn")
    #expect(e.file == "HelloRN/HelloRN.entitlements" && e.target == "HelloRN")
    #expect(e.entitlements == .object([
        "aps-environment": .string("development"),
        // $(AppIdentifierPrefix) is the signing team's; it stays for the sign stage. The bundle ID is the overlay's.
        "keychain-access-groups": .array([.string("$(AppIdentifierPrefix)io.example.rn.shared")]),
        "com.apple.developer.authentication-services.autofill-credential-provider": .bool(true),
        "com.example.count": .int(3),
    ]))
    let ext = try BuiltApp.entitlements(TargetSettings(project: p, target: p.target(named: "HelloExtension")!, configuration: "Release", overrides: [:]),
                                        bundleID: "io.example.rn.HelloExtension")
    #expect(ext.entitlements == .object([:]) && ext.file == "HelloExtension/HelloExtension.entitlements")

    let json = String(decoding: BuiltApp.entitlementsJSON(["": e, "PlugIns/HelloExtension.appex": ext]), as: UTF8.self)
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [String: Any]]
    #expect(Set(parsed.keys) == ["", "PlugIns/HelloExtension.appex"])
    #expect(parsed[""]?["bundleID"] as? String == "io.example.rn" && parsed["PlugIns/HelloExtension.appex"]?["target"] as? String == "HelloExtension")
    #expect((parsed[""]?["entitlements"] as? [String: Any])?["aps-environment"] as? String == "development")
    #expect(json.hasSuffix("}\n"))
}

@Test func entitlementsRefuseWhatSigningCouldNotUse() throws {
    let (root, ws) = try helloRN()
    let p = ws.projects[0]
    let settings = try TargetSettings(project: p, target: p.target(named: "HelloRN")!, configuration: "Release", overrides: [:])
    try write(root.appendingPathComponent("HelloRN/HelloRN.entitlements"),
              "<plist version=\"1.0\"><dict><key>k</key><string>$(NOT_A_SETTING)</string></dict></plist>")
    #expect(throws: XlessError.self) { try BuiltApp.entitlements(settings, bundleID: "a.b") }
    try write(root.appendingPathComponent("HelloRN/HelloRN.entitlements"), "<plist version=\"1.0\"><dict><key>k</key><real>1.5</real></dict></plist>")
    #expect(throws: XlessError.self) { try BuiltApp.entitlements(settings, bundleID: "a.b") }
    try fm.removeItem(at: root.appendingPathComponent("HelloRN/HelloRN.entitlements"))
    #expect(throws: XlessError.self) { try BuiltApp.entitlements(settings, bundleID: "a.b") }
}

@Test func targetSettingsFollowXcodesLevels() throws {
    let (_, ws) = try helloRN()
    let p = ws.projects[0]
    let s = try TargetSettings(project: p, target: p.target(named: "HelloRN")!, configuration: "Release", overrides: ["X": "$(TARGET_NAME)-$(CONFIGURATION)"])
    #expect(try s.raw("PODS_ROOT") == "${SRCROOT}/Pods")                       // from the Pods xcconfig
    #expect(try s.expand("$(PODS_ROOT)", context: "t") == p.directory.path + "/Pods")
    #expect(try s.expand("$(X)", context: "t") == "HelloRN-Release")           // overrides first
    #expect(try s.expand("$(A)x", keep: ["A"], context: "t") == "$(A)x")
    #expect(throws: XlessError.self) { try s.raw("OTHER_LDFLAGS") }            // $(inherited) is not evaluated
    #expect(throws: XlessError.self) { try TargetSettings(project: p, target: p.target(named: "HelloRN")!, configuration: "Staging", overrides: [:]) }
    #expect(try TargetSettings.xcconfig(try write2("A = 1 // c\n#include \"b.xcconfig\"\nB = 3;\n", "b.xcconfig", "A = 2\n"), depth: 0) == ["A": "2", "B": "3"])
}

/// An xcconfig and the file it includes in a fresh directory; returns the first.
private func write2(_ main: String, _ name: String, _ included: String) throws -> URL {
    let d = try tmp("xcconfig")
    try write(d.appendingPathComponent(name), included)
    try write(d.appendingPathComponent("main.xcconfig"), main)
    return d.appendingPathComponent("main.xcconfig")
}

// MARK: versions in the built app

@Test func theRunsVersionIsStampedIntoEveryBundleKeepingEachPlistsFormat() throws {
    let app = try tmp("stamp").appendingPathComponent("A.app")
    let ext = app.appendingPathComponent("PlugIns/E.appex")
    try fm.createDirectory(at: ext, withIntermediateDirectories: true)
    // The app's Info.plist: literal values from the app's config (binary, as Swift Build writes it); the extension's from settings.
    try Plist.write(["CFBundleIdentifier": "io.example.rn", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "100"],
                    to: app.appendingPathComponent("Info.plist"), format: .binary, stage: .build)
    try Plist.write(["CFBundleIdentifier": "io.example.rn.E", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "1.2.3.2026101601"],
                    to: ext.appendingPathComponent("Info.plist"), format: .xml, stage: .build)
    let bundles = try BuiltApp.bundles(in: app)
    #expect(bundles == [.init(path: "", bundleID: "io.example.rn"), .init(path: "PlugIns/E.appex", bundleID: "io.example.rn.E")])
    #expect(try BuiltApp.stampVersions(app: app, bundles: bundles, version: "1.2.3", build: "1.2.3.2026101601") == [""])
    for dir in [app, ext] {
        let (p, _) = try BuiltApp.readInfoPlist(dir)
        #expect(p["CFBundleShortVersionString"] as? String == "1.2.3" && p["CFBundleVersion"] as? String == "1.2.3.2026101601")
    }
    #expect(try BuiltApp.readInfoPlist(app).1 == .binary && BuiltApp.readInfoPlist(ext).1 == .xml)
    #expect(try BuiltApp.stampVersions(app: app, bundles: bundles, version: "1.2.3", build: "1.2.3.2026101601").isEmpty)
}

@Test func aDatedOverrideMustBeADatedBuildOfTheVersion() throws {
    let (root, _) = try helloRN()
    let work = root.deletingLastPathComponent()
    var r = try ReactNativeProject.resolve(overlay: overlay("version: 1.2.3\n"), source: work, work: work)
    #expect(throws: XlessError.self) { try DatedBuildNumber.applyOverride("101", to: &r.config) }
    #expect(throws: XlessError.self) { try DatedBuildNumber.applyOverride("1.2.4.2026101601", to: &r.config) }
    try DatedBuildNumber.applyOverride("1.2.3.2026101601", to: &r.config)
    #expect(r.config.build == "1.2.3.2026101601" && r.config.buildScheme == .dated)
}

// MARK: missing commands (ruling R4)

@Test func missingCommandsAreNamedFromTheShellsWords() {
    #expect(SwiftBuildOutput.missingCommandName("Script-AB.sh: line 4: ditto: command not found") == "ditto")
    #expect(SwiftBuildOutput.missingCommandName("/x/Script-AB.sh: line 9: /usr/libexec/PlistBuddy: No such file or directory") == "/usr/libexec/PlistBuddy")
    #expect(SwiftBuildOutput.missingCommandName("env: ‘node’: No such file or directory") == "node")
    #expect(SwiftBuildOutput.missingCommandName("/usr/bin/env: 'python3': No such file or directory") == "python3")
    #expect(SwiftBuildOutput.missingCommandName("/x/Script-1.sh: line 3: ./gen.sh: /usr/bin/python: bad interpreter: No such file or directory") == "/usr/bin/python")
    #expect(SwiftBuildOutput.missingCommandName("cat: notes.txt: No such file or directory") == nil)   // a missing input, not a command
    #expect(SwiftBuildOutput.missingCommandName("warning: something") == nil)
}

private func summary(succeeded: Bool = true, missing: [String] = [], refusals: [String] = [], failed: [String] = [],
                     output: [[String]] = []) -> SwiftBuildOutput.Summary {
    var s = SwiftBuildOutput.Summary(succeeded: succeeded, errors: [], warnings: [], failedTasks: failed, tasks: 9)
    s.commandsNotFound = missing; s.shimRefusals = refusals; s.failedTaskOutput = output
    return s
}

private let log = URL(fileURLWithPath: "/dd/xless/swbuild.log")

@Test func aMissingCommandFailsTheBuildUnlessTheOverlayAllowsIt() throws {
    let lines = ["S.sh: line 4: ditto: command not found", "S.sh: line 9: /usr/libexec/PlistBuddy: No such file or directory"]
    #expect((#expect(throws: XlessError.self) { try ReactNativeBuilder.checkPhaseOutput(summary(missing: lines), allowed: [], log: log) })?.stage == .build)
    #expect(throws: XlessError.self) { try ReactNativeBuilder.checkPhaseOutput(summary(missing: lines), allowed: ["ditto"], log: log) }
    #expect(try ReactNativeBuilder.checkPhaseOutput(summary(missing: lines), allowed: ["ditto", "PlistBuddy"], log: log) == lines)            // by name
    #expect(try ReactNativeBuilder.checkPhaseOutput(summary(missing: lines), allowed: ["ditto", "/usr/libexec/PlistBuddy"], log: log) == lines) // by path
    #expect(try ReactNativeBuilder.checkPhaseOutput(summary(), allowed: [], log: log).isEmpty)
}

@Test func aShimRefusalFailsTheBuildEvenWhenItsTaskSucceededAndCannotBeAllowed() throws {
    // CocoaPods' [CP] Copy Pods Resources tests `xcrun --find actool` inside `[ … ]`: a refusal there skipped the pods'
    // asset catalogs and the phase still succeeded.
    let refusal = "xcrun shim: unsupported call: xcrun --find actool"
    for allowed in [[], ["xcrun"], ["actool", "xcrun", "ditto"]] {
        let e = #expect(throws: XlessError.self) { try ReactNativeBuilder.checkPhaseOutput(summary(refusals: [refusal]), allowed: allowed, log: log) }
        #expect(e?.stage == .build && e?.cause == "a build phase went on after an xless shim refused a call: \(refusal)", "\(allowed)")
    }
    // A refusal goes first: before a missing command that the overlay would not allow.
    let e = #expect(throws: XlessError.self) {
        try ReactNativeBuilder.checkPhaseOutput(summary(missing: ["S.sh: line 4: ditto: command not found"], refusals: [refusal]), allowed: [], log: log)
    }
    #expect(e?.cause.contains(refusal) == true)
}

@Test func aFailedBuildIsCausedByTheFirstShimRefusalInAFailedTasksOutput() throws {
    // The strip / copypng / ditto / PlistBuddy shims refuse on stderr, which only reaches the task's output.
    let early = "PlistBuddy shim: unsupported call (option -x): PlistBuddy -x -c Print x.plist"
    let mine = "copypng shim: unsupported call (ancillary chunk iCCP): copypng -compress a.png b.png"
    let s = summary(succeeded: false, refusals: [early, mine], failed: ["CopyPNGFile b.png a.png"], output: [["copying a.png", mine]])
    let e = #expect(throws: XlessError.self) { try ReactNativeBuilder.checkPhaseOutput(s, allowed: [], log: log) }
    #expect(e?.stage == .build && e?.cause == mine)
    #expect(ReactNativeBuilder.failedTasksReport(s) == "failed: CopyPNGFile b.png a.png\n  | copying a.png\n  | \(mine)\n")
    // Without a refusal, the first failed task.
    let plain = #expect(throws: XlessError.self) {
        try ReactNativeBuilder.checkPhaseOutput(summary(succeeded: false, failed: ["Ld X"], output: [["ld: error"]]), allowed: [], log: log)
    }
    #expect(plain?.cause == "Swift Build failed: Ld X")
}

// MARK: CocoaPods xcframework scripts

@Test func xcframeworkLinesAreSplitIntoWordsNotRun() throws {
    let line = #"install_xcframework "${PODS_ROOT}/OpenSSL-Universal/OpenSSL.xcframework" "OpenSSL-Universal" "framework" "ios-arm64" "ios-arm64_x86_64-simulator""#
    #expect(try XCFrameworkAliases.words(line, podsRoot: "/w/ios/Pods") ==
        ["install_xcframework", "/w/ios/Pods/OpenSSL-Universal/OpenSSL.xcframework", "OpenSSL-Universal", "framework", "ios-arm64", "ios-arm64_x86_64-simulator"])
    // Paths out of Pods (node_modules) and destinations with a slash.
    let hermes = #"install_xcframework "${PODS_ROOT}/../../node_modules/x/hermesvm.xcframework" "hermes-engine/Pre-built" "framework" "ios-arm64""#
    #expect(try XCFrameworkAliases.words(hermes, podsRoot: "/P")[1...2] == ["/P/../../node_modules/x/hermesvm.xcframework", "hermes-engine/Pre-built"])
    for bad in [#"install_xcframework "$(id)/A.xcframework" "A" "framework" "ios-arm64""#,
                #"install_xcframework "${HOME}/A.xcframework" "A" "framework" "ios-arm64""#,
                #"install_xcframework "`id`/A.xcframework" "A" "framework" "ios-arm64""#,
                #"install_xcframework "${PODS_ROOT}/A.xcframework "A" "framework""#,
                #"install_xcframework "${PODS_ROOT}/A.xcframework" "A" "framework" "ios-arm64"; rm -rf /"#,
                #"install_xcframework "${PODS_ROOT}/A\".xcframework" "A" "framework" "ios-arm64""#,
                #"install_xcframework "${PODS_ROOT}/A.xcframework""A" "framework" "ios-arm64""#] {
        #expect(throws: XlessError.self) { try XCFrameworkAliases.words(bad, podsRoot: "/P") }
    }
}

@Test func lowercaseAliasesForVendoredFrameworksOnly() throws {
    let script = """
    install_xcframework() {
      local basepath="$1"
    }
    install_xcframework "${PODS_ROOT}/OpenSSL-Universal/OpenSSL.xcframework" "OpenSSL-Universal" "framework" "ios-arm64" "ios-arm64_x86_64-simulator"
    install_xcframework "${PODS_ROOT}/YW/platforms/ios/libuniffi.xcframework" "YW" "library" "ios-arm64"
      install_xcframework "${PODS_ROOT}/hermes-engine/destroot/hermesvm.xcframework" "hermes-engine/Pre-built" "framework" "ios-arm64"
    install_xcframework "${PODS_ROOT}/Vendor/VendorKit.xcframework" "VendorKit/Core" "framework" "ios-arm64"

    """
    let installs = try XCFrameworkAliases.installs(script: script, podsRoot: "/P")
    #expect(installs.map(\.kind) == ["framework", "library", "framework", "framework"])
    let aliases = XCFrameworkAliases.aliases(installs)
    #expect(aliases.map { "\($0.dir)/\($0.link)->\($0.target)" } ==
        ["OpenSSL-Universal/openssl.framework->OpenSSL.framework", "VendorKit/Core/vendorkit.framework->VendorKit.framework"])
    #expect(throws: XlessError.self) { try XCFrameworkAliases.installs(script: "install_xcframework \"${PODS_ROOT}/A.xcframework\" \"A\" \"both\" \"x\"\n", podsRoot: "/P") }
    #expect(throws: XlessError.self) { try XCFrameworkAliases.installs(script: "install_xcframework \"${PODS_ROOT}/A.xcframework\" \"../A\" \"framework\" \"x\"\n", podsRoot: "/P") }

    let pods = try tmp("pods")
    try write(pods.appendingPathComponent("Target Support Files/OpenSSL-Universal/OpenSSL-Universal-xcframeworks.sh"), script)
    let inter = try tmp("xcfi")
    try fm.createDirectory(at: inter.appendingPathComponent("VendorKit/Core/vendorkit.framework"), withIntermediateDirectories: true)
    #expect(try XCFrameworkAliases.create(pods: pods, intermediates: inter) == 1)   // a real directory of that name is left alone
    #expect(try fm.destinationOfSymbolicLink(atPath: inter.appendingPathComponent("OpenSSL-Universal/openssl.framework").path) == "OpenSSL.framework")
    #expect(try XCFrameworkAliases.create(pods: pods, intermediates: inter) == 1)   // idempotent
    let link = inter.appendingPathComponent("OpenSSL-Universal/openssl.framework")
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "Stale.framework")
    #expect(try XCFrameworkAliases.create(pods: pods, intermediates: inter) == 1)   // a stale link is replaced
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "OpenSSL.framework")
    // An indented call is still a call: parsed (here) or refused, never skipped.
    #expect(throws: XlessError.self) { try XCFrameworkAliases.installs(script: "  install_xcframework \"$(x)/A.xcframework\" \"A\" \"framework\" \"s\"\n", podsRoot: "/P") }
}

// MARK: prepare

@Test func prebuildIsSkippedForATrackedNativeProjectAndRepeatedInputs() {
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: false, recorded: nil, fingerprint: "f", podsInstalled: false, hasWorkspace: false) == .prebuildAndPods)
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: true, recorded: nil, fingerprint: "f", podsInstalled: false, hasWorkspace: true) == .pods)
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: false, recorded: "f", fingerprint: "f", podsInstalled: true, hasWorkspace: true) == .upToDate)
    // A tracked native project always gets pod install (quick when the pods are current); never prebuild.
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: true, recorded: "f", fingerprint: "f", podsInstalled: true, hasWorkspace: true) == .pods)
    // Changed inputs, or pods out of date, regenerate.
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: false, recorded: "e", fingerprint: "f", podsInstalled: true, hasWorkspace: true) == .prebuildAndPods)
    #expect(ReactNativeBuilder.nativeSteps(iosTracked: false, recorded: "f", fingerprint: "f", podsInstalled: false, hasWorkspace: true) == .prebuildAndPods)
}

private func git(_ dir: URL, _ args: String...) throws {
    try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare)
}

@Test func trackedNativeProjectsAndTheFingerprintComeFromGit() throws {
    let src = try tmp("src")
    try git(src, "init", "-q")
    try write(src.appendingPathComponent("apps/client/package.json"), "{}")
    try write(src.appendingPathComponent("apps/client/ios/Podfile"), "x")   // present but untracked (Expo CNG: generated)
    try write(src.appendingPathComponent("apps/client/ios/README.md"), "notes")
    try write(src.appendingPathComponent("other/ios/App.xcodeproj/project.pbxproj"), "{}")
    try git(src, "add", "apps/client/package.json", "apps/client/ios/README.md", "other/ios/App.xcodeproj/project.pbxproj")
    try git(src, "commit", "-q", "-m", "i")
    let env = ProcessInfo.processInfo.environment
    #expect(try !ReactNativeBuilder.isTracked(ios: "apps/client/ios", in: src, env: env))   // a tracked README is no native project
    #expect(try ReactNativeBuilder.isTracked(ios: "other/ios", in: src, env: env))          // a tracked .xcodeproj is
    try git(src, "add", "apps/client/ios/Podfile")
    #expect(try ReactNativeBuilder.isTracked(ios: "apps/client/ios", in: src, env: env))

    let o = try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: A\nbundleIDs: { A: a.b }\nteamID: ABCDE12345\napp: { dir: apps/client }\nversion: 1.0.0\n", name: "o")
    func ctx(_ o: ReactNativeOverlay) throws -> ReactNativeBuildContext {
        let w = try tmp("w")
        return ReactNativeBuildContext(overlay: o, resolved: try ReactNativeProject.resolve(overlay: o, source: src, work: w), sourceRoot: src,
                                       workRoot: w, paths: StagePaths(project: w, platform: .ios))
    }
    let tools = ["node --version: v24.22.0"]
    let toolchain = ReactNativeBuilder.toolchainIdentity(try ctx(o), tools: tools)
    let base = try ReactNativeBuilder.fingerprint(ctx(o), toolchain: toolchain)
    #expect(try ReactNativeBuilder.fingerprint(ctx(o), toolchain: toolchain) == base)
    var withEnv = o; withEnv.env = ["FEATURE_X": "enabled"]
    #expect(try ReactNativeBuilder.fingerprint(ctx(withEnv), toolchain: toolchain) != base)
    #expect(ReactNativeBuilder.toolchainIdentity(try ctx(withEnv), tools: tools) == toolchain)    // the overlay's env is no toolchain
    var otherConfiguration = o; otherConfiguration.configuration = "Staging"   // the pods' configuration switches follow it
    #expect(try ReactNativeBuilder.fingerprint(ctx(otherConfiguration), toolchain: toolchain) != base)
    let otherTool = ReactNativeBuilder.toolchainIdentity(try ctx(o), tools: ["node --version: v24.23.0"])   // another tool version
    #expect(otherTool != toolchain)
    #expect(try ReactNativeBuilder.fingerprint(ctx(o), toolchain: otherTool) != base)
    var image = try ctx(o); image.env["XLESS_IMAGE_ID"] = "abc-123"
    #expect(ReactNativeBuilder.toolchainIdentity(image, tools: tools) != toolchain)                 // another image
    // Another SDK (an image made from another Xcode, the same commit): another toolchain (Ruling R8).
    let metaFile = try tmp("meta").appendingPathComponent("toolchain-meta.json")
    try write(metaFile, "{\"xcodeVersion\": \"2620\"}")
    var sdk262 = try ctx(o); sdk262.env["XLESS_TOOLCHAIN_META"] = metaFile.path
    let with262 = ReactNativeBuilder.toolchainIdentity(sdk262, tools: tools)
    try write(metaFile, "{\"xcodeVersion\": \"2700\"}")
    #expect(with262 != toolchain && ReactNativeBuilder.toolchainIdentity(sdk262, tools: tools) != with262)
    #expect(ReactNativeBuilder.executableDigest().count == 64)
    try write(src.appendingPathComponent("apps/client/package.json"), "{\"a\": 1}")   // an uncommitted edit, which the work copy carries
    #expect(try ReactNativeBuilder.fingerprint(ctx(o), toolchain: toolchain) != base)
}

/// A monorepo source (root package.json + lockfile, two workspace packages) synced into a work copy whose install has
/// run: `node_modules` at the root and in both packages, plus a package's cached build output inside one of them.
private func jsWorkCopy() throws -> (ctx: ReactNativeBuildContext, outside: URL) {
    let src = try tmp("jssrc")
    try git(src, "init", "-q")
    for f in ["package.json", "pnpm-lock.yaml", "apps/client/package.json", "packages/lib/package.json"] { try write(src.appendingPathComponent(f), "{}") }
    try write(src.appendingPathComponent("tools/node_modules/vendored/package.json"), "{}")   // tracked under node_modules: never a package dir
    try git(src, "add", "-A"); try git(src, "commit", "-q", "-m", "i")
    try write(src.appendingPathComponent("node_modules/.keep"), "the source's own install")   // never touched
    let o = try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: A\nbundleIDs: { A: a.b }\nteamID: ABCDE12345\napp: { dir: apps/client }\nversion: 1.0.0\n", name: "o")
    let w = try tmp("jswork")
    _ = try WorkCopy.sync(source: src, to: w)
    for d in ["node_modules/.pnpm/expo@1/node_modules/expo/apple/Products", "apps/client/node_modules/.bin", "packages/lib/node_modules/x"] {
        try write(w.appendingPathComponent(d).appendingPathComponent("cached"), "made by the old toolchain")
    }
    let outside = try tmp("outside")
    try write(outside.appendingPathComponent("keep"), "outside the work copy")
    // A symlink inside a tree to a directory outside the work copy: deleting the tree unlinks it, never follows it.
    try fm.createSymbolicLink(at: w.appendingPathComponent("packages/lib/node_modules/escape"), withDestinationURL: outside)
    let ctx = ReactNativeBuildContext(overlay: o, resolved: try ReactNativeProject.resolve(overlay: o, source: src, work: w), sourceRoot: src,
                                      workRoot: w, paths: StagePaths(project: w, platform: .ios))
    return (ctx, outside)
}

@Test func aToolchainChangeDeletesSwiftBuildsDerivedData() throws {
    let (ctx, _) = try jsWorkCopy()
    let w = ctx.workRoot
    for d in [".xless/derived-data/ModuleCache.noindex/x.pcm", ".xless/derived-data-simulator/Build/x.o"] {
        try write(w.appendingPathComponent(d), "made by the old image")
    }
    try Data("same\n".utf8).write(to: ctx.toolchainFile)
    #expect(try ReactNativeBuilder.resetDerivedData(ctx, toolchain: "same\n", clean: false).isEmpty)
    #expect(try ReactNativeBuilder.resetDerivedData(ctx, toolchain: "new\n", clean: false) == [".xless/derived-data", ".xless/derived-data-simulator"])
    #expect(!fm.fileExists(atPath: w.appendingPathComponent(".xless/derived-data").path))
    #expect(!fm.fileExists(atPath: w.appendingPathComponent(".xless/derived-data-simulator").path))
    #expect(try ReactNativeBuilder.resetDerivedData(ctx, toolchain: "new\n", clean: false).isEmpty)   // nothing left
}

@Test func aToolchainChangeDeletesTheWorkCopysJSDependencyTrees() throws {
    let (ctx, outside) = try jsWorkCopy()
    let w = ctx.workRoot
    try Data("old\n".utf8).write(to: ctx.toolchainFile)
    let deleted = try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: w, toolchain: "new\n", clean: false)
    #expect(deleted.sorted() == ["apps/client/node_modules", "node_modules", "packages/lib/node_modules"])
    for d in deleted { #expect(!fm.fileExists(atPath: w.appendingPathComponent(d).path)) }
    #expect(fm.fileExists(atPath: w.appendingPathComponent("tools/node_modules/vendored/package.json").path))   // a tracked file
    #expect(fm.fileExists(atPath: outside.appendingPathComponent("keep").path))
    #expect(fm.fileExists(atPath: ctx.sourceRoot.appendingPathComponent("node_modules/.keep").path))
    // No record (a work copy from before R6, or a fresh one) counts as another toolchain; a fresh one has nothing to delete.
    try fm.removeItem(at: ctx.toolchainFile)
    #expect(try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: w, toolchain: "new\n", clean: false).isEmpty)
    // Only trees at or below the install's root (here the app's own install).
    let (ctx2, _) = try jsWorkCopy()
    #expect(try ReactNativeBuilder.resetJSDependencies(ctx2, jsRoot: ctx2.appDir, toolchain: "new\n", clean: false) == ["apps/client/node_modules"])
    #expect(fm.fileExists(atPath: ctx2.workRoot.appendingPathComponent("node_modules/.pnpm").path))
}

@Test func anUnchangedToolchainKeepsTheJSDependencyTreesWhateverTheOverlaysEnv() throws {
    var (ctx, _) = try jsWorkCopy()
    let tools = ["node --version: v24.22.0"]
    let toolchain = ReactNativeBuilder.toolchainIdentity(ctx, tools: tools)
    try Data(toolchain.utf8).write(to: ctx.toolchainFile)
    let before = try ReactNativeBuilder.fingerprint(ctx, toolchain: toolchain)
    ctx.overlay.env = ["FEATURE_X": "enabled"]   // regenerates ios/ (another fingerprint), but the same toolchain
    let again = ReactNativeBuilder.toolchainIdentity(ctx, tools: tools)
    #expect(try ReactNativeBuilder.fingerprint(ctx, toolchain: again) != before)
    #expect(try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: ctx.workRoot, toolchain: again, clean: false).isEmpty)
    #expect(fm.fileExists(atPath: ctx.workRoot.appendingPathComponent("node_modules/.pnpm/expo@1/node_modules/expo/apple/Products/cached").path))
}

@Test func xlessRNCleanDeletesTheJSDependencyTrees() throws {
    let (ctx, _) = try jsWorkCopy()
    try Data("same\n".utf8).write(to: ctx.toolchainFile)
    #expect(try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: ctx.workRoot, toolchain: "same\n", clean: true).count == 3)
    #expect(!fm.fileExists(atPath: ctx.workRoot.appendingPathComponent("node_modules").path))
}

@Test func theJSReinstallNeverLeavesTheWorkCopy() throws {
    let (ctx, outside) = try jsWorkCopy()
    let w = ctx.workRoot
    // The root node_modules is a symlink to a directory outside: unlinked, its target untouched.
    try fm.removeItem(at: w.appendingPathComponent("node_modules"))
    try write(outside.appendingPathComponent("node_modules/cached"), "outside")
    try fm.createSymbolicLink(at: w.appendingPathComponent("node_modules"), withDestinationURL: outside.appendingPathComponent("node_modules"))
    // A package directory that is a symlink out of the work copy is skipped (git tracks no path through a symlink, but
    // the work copy may have been changed by hand or by a build).
    let lib = w.appendingPathComponent("packages/lib")
    try fm.moveItem(at: lib, to: outside.appendingPathComponent("lib"))
    try fm.createSymbolicLink(at: lib, withDestinationURL: outside.appendingPathComponent("lib"))
    let trees = ReactNativeBuilder.jsDependencyTrees(work: w, jsRoot: w, packageJSONs: [
        "package.json", "apps/client/package.json", "packages/lib/package.json", "../x/package.json", "/abs/package.json",
        "tools/node_modules/vendored/package.json", "package.json"])
    #expect(trees.map { ReactNativeBuilder.relative($0, to: w) } == ["node_modules", "apps/client/node_modules"])
    try Data("old\n".utf8).write(to: ctx.toolchainFile)
    #expect(try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: w, toolchain: "new\n", clean: false).sorted() == ["apps/client/node_modules", "node_modules"])
    #expect((try? fm.attributesOfItem(atPath: w.appendingPathComponent("node_modules").path)) == nil)   // the link is gone
    #expect(fm.fileExists(atPath: outside.appendingPathComponent("node_modules/cached").path))
    #expect(fm.fileExists(atPath: outside.appendingPathComponent("lib/node_modules/x/cached").path))
    #expect(fm.fileExists(atPath: outside.appendingPathComponent("keep").path))
}

@Test func aJSDependencyTreeThatCannotBeDeletedIsAPrepareError() throws {
    guard getuid() != 0 else { return }   // root deletes regardless of permissions
    let (ctx, _) = try jsWorkCopy()
    let parent = ctx.workRoot.appendingPathComponent("apps/client")
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
    let e = #expect(throws: XlessError.self) {
        try ReactNativeBuilder.resetJSDependencies(ctx, jsRoot: ctx.workRoot, toolchain: "new\n", clean: false)
    }
    #expect(e?.stage == .prepare)
    #expect(e?.cause.contains("apps/client/node_modules") == true)
}

@Test func theJSInstallRunsAtTheMonorepoRoot() throws {
    let w = try tmp("mono")
    try write(w.appendingPathComponent("package.json"), "{}")
    try write(w.appendingPathComponent("pnpm-lock.yaml"), "")
    try write(w.appendingPathComponent("apps/client/package.json"), "{}")
    #expect(ReactNativeBuilder.jsRoot(app: w.appendingPathComponent("apps/client"), work: w)?.path == w.standardizedFileURL.path)
    try write(w.appendingPathComponent("apps/client/yarn.lock"), "")
    #expect(ReactNativeBuilder.jsRoot(app: w.appendingPathComponent("apps/client"), work: w)?.lastPathComponent == "client")
    #expect(ReactNativeBuilder.jsRoot(app: try tmp("none"), work: try tmp("other")) == nil)
    try write(w.appendingPathComponent("node_modules/.bin/expo"), "#!/bin/sh\n")
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.appendingPathComponent("node_modules/.bin/expo").path)
    #expect(ReactNativeBuilder.binary("expo", from: w.appendingPathComponent("apps/client"), work: w)?.path.hasSuffix("node_modules/.bin/expo") == true)
    let ios = try tmp("ios")
    try write(ios.appendingPathComponent("Podfile.lock"), "PODFILE CHECKSUM: a\n")
    #expect(!ReactNativeBuilder.podsInstalled(ios: ios))
    try write(ios.appendingPathComponent("Pods/Manifest.lock"), "PODFILE CHECKSUM: a\n")
    #expect(ReactNativeBuilder.podsInstalled(ios: ios))
}

@Test func theStubCompileIsRetargetedAndNothingElse() throws {
    let bundle = try tmp("sdk")
    try fm.createDirectory(at: bundle.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk"), withIntermediateDirectories: true)
    let sdk = DarwinSDK(bundle: bundle)
    let stub = ["-x", "c", "-", "-dynamiclib", "-o", "S/.stub-binary", "-install_name", "@rpath/S.framework/S"]
    let mapped = try PrepareClangShim.arguments(stub, sdk: sdk)
    #expect(mapped.prefix(2) == ["-target", "arm64-apple-ios16.4"] && mapped.suffix(stub.count) == stub[...])
    #expect(mapped.contains("-fuse-ld=\(bundle.path)/toolset/bin/ld64.lld"))
    #expect(try PrepareClangShim.arguments(["-c", "x.c", "-o", "x.o"], sdk: sdk) == ["-c", "x.c", "-o", "x.o"])   // host builds
    #expect(try PrepareClangShim.arguments(["-target", "arm64-apple-ios17", "-dynamiclib"], sdk: sdk) == ["-target", "arm64-apple-ios17", "-dynamiclib"])
    // Ruling R10: the Darwin compile uses the app Swift toolchain's clang; host builds the image's own.
    let swift = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
    #expect(PrepareClangShim.executable(stub, swift: swift) == "/opt/xless/toolchains/swift-6.2.3/usr/bin/clang")
    #expect(PrepareClangShim.executable(["-c", "x.c", "-o", "x.o"], swift: swift) == "/usr/bin/clang")
    #expect(PrepareClangShim.executable(stub, swift: nil) == "/usr/bin/clang")
}

// MARK: Swift packages

@Test func packageRootsAndPins() throws {
    let manifest = SwiftPackageCheckouts.rootManifest(checkout: URL(fileURLWithPath: "/dd/packages/kit"))
    #expect(manifest.contains(#".package(path: "/dd/packages/kit")"#) && manifest.hasPrefix("// swift-tools-version: 5.9"))
    let resolved = #"{"pins":[{"identity":"swift-crypto","kind":"remoteSourceControl","location":"https://github.com/apple/swift-crypto.git","state":{"revision":"abc","version":"2.6.0"}},{"identity":"a","kind":"remoteSourceControl","location":"https://x/a","state":{"branch":"main","revision":"def"}}],"version":3}"#
    let pins = try SwiftPackageCheckouts.pins(resolvedFile: Data(resolved.utf8))
    #expect(pins.map(\.identity) == ["a", "swift-crypto"] && pins[1].version == "2.6.0" && pins[0].branch == "main" && pins[0].revision == "def")
    let (_, ws) = try helloRN()
    #expect(try SwiftPackageCheckouts.references(ws).isEmpty)
    let ext = try SwiftPackageCheckouts.references(XcodeWorkspace.load(fixture("ExtPkg/ExtPkg.xcworkspace")))
    #expect(ext.count == 1 && ext[0].revision != nil && ext[0].location.hasPrefix("https://"))

    // A requirement other than a full revision is refused for the build, before anything is cloned.
    for (from, to) in [("kind = revision;", "kind = upToNextMajorVersion; minimumVersion = 1.0.0;"),
                       ("revision = 83cca1bb83e4f45fe6dc0d8d6c52c5f656c51051;", "revision = main;")] {
        let dir = try tmp("extpkg").appendingPathComponent("ExtPkg")
        try fm.copyItem(at: fixture("ExtPkg"), to: dir)
        let pbx = dir.appendingPathComponent("ExtPkg.xcodeproj/project.pbxproj")
        try write(pbx, try String(contentsOf: pbx, encoding: .utf8).replacingOccurrences(of: from, with: to))
        let e = #expect(throws: XlessError.self) { try SwiftPackageCheckouts.references(XcodeWorkspace.load(dir.appendingPathComponent("ExtPkg.xcworkspace"))) }
        #expect(e?.stage == .build)
    }
}

@Test func packageIdentitiesThatCannotNameADirectoryAreRefused() throws {
    // The identity is the URL's last component: it becomes <packages>/<identity> and a git argument.
    for url in ["https://example.com/swift/..", "https://example.com/swift/-upload-pack=x.git", "https://example.com/swift/.git"] {
        let dir = try tmp("extpkg-id").appendingPathComponent("ExtPkg")
        try fm.copyItem(at: fixture("ExtPkg"), to: dir)
        let pbx = dir.appendingPathComponent("ExtPkg.xcodeproj/project.pbxproj")
        try write(pbx, try String(contentsOf: pbx, encoding: .utf8)
            .replacingOccurrences(of: #"repositoryURL = "https://example.com/swift/GreetingKit.git";"#, with: #"repositoryURL = "\#(url)";"#))
        let e = #expect(throws: XlessError.self, "\(url)") { try SwiftPackageCheckouts.references(XcodeWorkspace.load(dir.appendingPathComponent("ExtPkg.xcworkspace"))) }
        #expect(e?.stage == .build && e?.cause.contains("cannot name a checkout directory") == true, "\(url): \(e?.cause ?? "")")
    }
}

@Test func aCloneOfAnotherURLWithTheSameIdentityIsReplaced() throws {
    let root = try tmp("clone"), env = ProcessInfo.processInfo.environment
    func git(_ args: [String], in dir: URL) throws -> String {
        try Shell.run("git", ["-C", dir.path, "-c", "user.name=x", "-c", "user.email=x@example.com", "-c", "commit.gpgsign=false"] + args,
                      baseEnvironment: env, stage: .build).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func repo(_ name: String, file: String) throws -> (url: String, head: String) {
        let dir = root.appendingPathComponent(name).appendingPathComponent("kit")   // both identities: kit
        try write(dir.appendingPathComponent(file), "x\n")
        _ = try git(["init", "-q"], in: dir); _ = try git(["add", "."], in: dir); _ = try git(["commit", "-q", "-m", name], in: dir)
        return (dir.path, try git(["rev-parse", "HEAD"], in: dir))
    }
    let a = try repo("a", file: "A.txt"), b = try repo("b", file: "B.txt")
    let packages = root.appendingPathComponent("packages")
    let first = try SwiftPackageCheckouts.clone(.init(identity: "kit", location: a.url, revision: a.head), revision: a.head, in: packages, env: env)
    #expect(fm.fileExists(atPath: first.appendingPathComponent("A.txt").path))
    // The project now names another repository whose identity is also kit: a fresh clone of it, not a checkout in A's.
    let second = try SwiftPackageCheckouts.clone(.init(identity: "kit", location: b.url, revision: b.head), revision: b.head, in: packages, env: env)
    #expect(second.standardizedFileURL.path == first.standardizedFileURL.path)
    #expect(try git(["config", "--get", "remote.origin.url"], in: second) == b.url && (try git(["rev-parse", "HEAD"], in: second)) == b.head)
    #expect(fm.fileExists(atPath: second.appendingPathComponent("B.txt").path) && !fm.fileExists(atPath: second.appendingPathComponent("A.txt").path))
    // The same URL at a revision the clone lacks: reused and fetched.
    let bDir = URL(fileURLWithPath: b.url)
    try write(bDir.appendingPathComponent("C.txt"), "y\n"); _ = try git(["add", "."], in: bDir); _ = try git(["commit", "-q", "-m", "c"], in: bDir)
    let c = try git(["rev-parse", "HEAD"], in: bDir)
    try write(second.appendingPathComponent(".git/xless-marker"), "kept\n")
    let third = try SwiftPackageCheckouts.clone(.init(identity: "kit", location: b.url, revision: c), revision: c, in: packages, env: env)
    #expect(try git(["rev-parse", "HEAD"], in: third) == c && fm.fileExists(atPath: third.appendingPathComponent(".git/xless-marker").path))
}

// MARK: stages and a stale native project

@Test func prepareRefusalsArePrepareErrors() throws {
    let empty = try tmp("stage")
    #expect((#expect(throws: XlessError.self) { try ReactNativeContract.checkRuby(appDir: empty, root: empty) })?.stage == .prepare)
    #expect((#expect(throws: XlessError.self) { try ReactNativeContract.checkJavaScript(appDir: empty, root: empty) })?.stage == .prepare)
    #expect((#expect(throws: XlessError.self) { try ReactNativeProject.workspaceURL(ios: empty, scheme: "A", stage: .prepare) })?.stage == .prepare)
}

@Test func aStaleNativeProjectDoesNotStopResolution() throws {
    let (root, _) = try helloRN()
    let work = root.deletingLastPathComponent()
    try write(ReactNativeProject.stateFile(work: work), "f\n")
    // The overlay's scheme is not in the workspace (e.g. the variant changed): the overlay's values are used until prepare.
    let other = try ReactNativeOverlay.parse(yaml: "type: react-native\nscheme: Other\nbundleIDs: { Other: io.example.o }\nteamID: ABCDE12345\nversion: 1.0.0\n", name: "o")
    let r = try ReactNativeProject.resolve(overlay: other, source: work, work: work)
    #expect(r.appTarget == "Other" && r.config.platforms[.ios]?.minimumOS == "16.4" && r.config.platforms[.ios]?.product == "Other")
    // A half-written project (the Pods xcconfig gone): still resolves.
    try fm.removeItem(at: root.appendingPathComponent("HelloRN.xcworkspace"))
    #expect(try ReactNativeProject.resolve(overlay: overlay("version: 1.0.0\n"), source: work, work: work).appTarget == "HelloRN")
    #expect(ReactNativeInspectReport.native(overlay: other, work: work) == nil)
}

// MARK: finishing the built app

/// A built app with an extension, as Swift Build leaves it, and the context `finish` reads.
private func builtApp(appID: String = "io.example.rn", extID: String = "io.example.rn.HelloExtension", privacy: String? = nil) throws -> (URL, ReactNativeBuildContext) {
    let app = try tmp("finish").appendingPathComponent("HelloRN.app")
    try fm.createDirectory(at: app.appendingPathComponent("PlugIns/HelloExtension.appex"), withIntermediateDirectories: true)
    try Plist.write(["CFBundleIdentifier": appID, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"],
                    to: app.appendingPathComponent("Info.plist"), stage: .build)
    try Plist.write(["CFBundleIdentifier": extID, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"],
                    to: app.appendingPathComponent("PlugIns/HelloExtension.appex/Info.plist"), stage: .build)
    try write(app.appendingPathComponent("PrivacyInfo.xcprivacy"), "app's own")
    var o = try overlay("version: 1.0.0\nbuild: 7\n")
    o.privacyManifest = privacy
    let w = app.deletingLastPathComponent()
    let ctx = ReactNativeBuildContext(overlay: o, resolved: try ReactNativeProject.resolve(overlay: o, source: w, work: w),
                                      sourceRoot: w, workRoot: w, paths: StagePaths(project: w, platform: .ios))
    return (app, ctx)
}

private let ids = ["HelloRN": "io.example.rn", "HelloExtension": "io.example.rn.HelloExtension"]
private let ents = ["HelloRN": BuiltApp.Entitlements(target: "HelloRN", bundleID: "io.example.rn", file: nil, entitlements: .object([:])),
                    "HelloExtension": BuiltApp.Entitlements(target: "HelloExtension", bundleID: "io.example.rn.HelloExtension", file: nil, entitlements: .object([:]))]

@Test func finishKeysEntitlementsByBundlePathAndCopiesThePrivacyManifest() throws {
    let privacy = try tmp("privacy").appendingPathComponent("PrivacyInfo.xcprivacy")
    try write(privacy, "overlay's")
    let (app, ctx) = try builtApp(privacy: privacy.path)
    let byPath = try ReactNativeBuilder.finish(app, appTarget: "HelloRN", ids: ids, entitlements: ents, ctx: ctx)
    #expect(byPath.keys.sorted() == ["", "PlugIns/HelloExtension.appex"] && byPath[""]?.target == "HelloRN")
    #expect(try String(contentsOf: app.appendingPathComponent("PrivacyInfo.xcprivacy"), encoding: .utf8) == "overlay's")
    #expect(try BuiltApp.readInfoPlist(app.appendingPathComponent("PlugIns/HelloExtension.appex")).0["CFBundleVersion"] as? String == "7")
    // Without the overlay's, the app's own stays.
    let (own, ownCtx) = try builtApp()
    _ = try ReactNativeBuilder.finish(own, appTarget: "HelloRN", ids: ids, entitlements: ents, ctx: ownCtx)
    #expect(try String(contentsOf: own.appendingPathComponent("PrivacyInfo.xcprivacy"), encoding: .utf8) == "app's own")
}

@Test func finishRefusesWrongBundleIDsAndMissingBundles() throws {
    // The app's Info.plist does not take PRODUCT_BUNDLE_IDENTIFIER.
    let (wrong, ctx) = try builtApp(appID: "com.literal.id")
    #expect((#expect(throws: XlessError.self) { try ReactNativeBuilder.finish(wrong, appTarget: "HelloRN", ids: ids, entitlements: ents, ctx: ctx) })?.stage == .build)
    // A nested bundle no bundleIDs target builds.
    let (stray, ctx2) = try builtApp(extID: "io.example.rn.Unknown")
    #expect(throws: XlessError.self) { try ReactNativeBuilder.finish(stray, appTarget: "HelloRN", ids: ids, entitlements: ents, ctx: ctx2) }
    // A target whose bundle the app does not contain.
    let (app, ctx3) = try builtApp()
    try fm.removeItem(at: app.appendingPathComponent("PlugIns"))
    #expect(throws: XlessError.self) { try ReactNativeBuilder.finish(app, appTarget: "HelloRN", ids: ids, entitlements: ents, ctx: ctx3) }
}

@Test func dSYMsAreCopiedAtTheirPathsUnderProducts() throws {
    let root = try tmp("dsym"); defer { try? fm.removeItem(at: root) }
    let products = root.appendingPathComponent("Products/Release-iphoneos")
    for rel in ["HelloRN.app.dSYM/Contents/Resources/DWARF/HelloRN", "HelloExtension.appex.dSYM/Contents/Resources/DWARF/HelloExtension",
                "Pod/Pod.framework.dSYM/Contents/Info.plist", "HelloRN.app/HelloRN", "Pod/Pod.framework/Pod"] {
        try write(products.appendingPathComponent(rel), "x")
    }
    let out = root.appendingPathComponent("build/dSYMs")
    try write(out.appendingPathComponent("Stale.app.dSYM/x"), "old")
    let copied = try BuiltApp.copyDSYMs(from: products, to: out)
    #expect(copied == ["HelloExtension.appex.dSYM", "HelloRN.app.dSYM", "Pod/Pod.framework.dSYM"])
    #expect(fm.fileExists(atPath: out.appendingPathComponent("HelloRN.app.dSYM/Contents/Resources/DWARF/HelloRN").path))
    #expect(fm.fileExists(atPath: out.appendingPathComponent("Pod/Pod.framework.dSYM/Contents/Info.plist").path))
    #expect(!fm.fileExists(atPath: out.appendingPathComponent("Stale.app.dSYM").path))

    try fm.removeItem(at: products)
    try fm.createDirectory(at: products, withIntermediateDirectories: true)
    #expect(try BuiltApp.copyDSYMs(from: products, to: out).isEmpty)
    #expect(!fm.fileExists(atPath: out.path))
}

/// A thin arm64 Mach-O of `filetype` (MH_EXECUTE 2, MH_DYLIB 6, MH_DSYM 0xa) whose LC_UUID is 16 bytes of `uuid`.
private func machO(uuid: UInt8, filetype: UInt32) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(filetype); u32(1); u32(24); u32(0); u32(0)
    u32(0x1b); u32(24); d.append(Data(repeating: uuid, count: 16))
    return d
}

@Test func dSYMsOfBinariesTheAppNoLongerShipsAreLeftOut() throws {
    let root = try tmp("dsym-app"); defer { try? fm.removeItem(at: root) }
    let products = root.appendingPathComponent("Products/Release-iphoneos")
    let app = root.appendingPathComponent("app/HelloRN.app")
    try fm.createDirectory(at: app.appendingPathComponent("Frameworks/Pod.framework"), withIntermediateDirectories: true)
    try machO(uuid: 0x11, filetype: 2).write(to: app.appendingPathComponent("HelloRN"))
    try machO(uuid: 0x22, filetype: 6).write(to: app.appendingPathComponent("Frameworks/Pod.framework/Pod"))
    for (rel, byte) in [("HelloRN.app.dSYM/Contents/Resources/DWARF/HelloRN", UInt8(0x11)),
                        ("XCFrameworkIntermediates/Pod/Pod.framework.dSYM/Contents/Resources/DWARF/Pod", 0x22),
                        // A pod removed since the derived data was last cleared: its dSYM is still under Products.
                        ("XCFrameworkIntermediates/Gone/Gone.framework.dSYM/Contents/Resources/DWARF/Gone", 0x33)] {
        let f = products.appendingPathComponent(rel)
        try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try machO(uuid: byte, filetype: 0xa).write(to: f)
    }
    let out = root.appendingPathComponent("build/dSYMs")
    let copied = try BuiltApp.copyDSYMs(from: products, to: out, keepingImagesOf: app)
    #expect(copied == ["HelloRN.app.dSYM", "XCFrameworkIntermediates/Pod/Pod.framework.dSYM"])
    #expect(!fm.fileExists(atPath: out.appendingPathComponent("XCFrameworkIntermediates/Gone").path))
}
