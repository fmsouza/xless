import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

private let appID = "com.example.app", extID = "com.example.app.Ext", extPath = "PlugIns/Ext.appex"
private let autofill = "com.apple.developer.authentication-services.autofill-credential-provider"
private let appGroups = "com.apple.security.application-groups"
private let domains = "com.apple.developer.associated-domains"
private let keychain = "keychain-access-groups"

/// What the sign stage handed rcodesign: its arguments and every entitlements file they name (read while they exist).
final class SignCapture: @unchecked Sendable {
    var arguments: [String] = []
    /// "" for the main bundle, else the scope (`PlugIns/Ext.appex`) → entitlements.
    var entitlements: [String: [String: Any]] = [:]
    func record(_ args: [String]) throws {
        arguments = args
        for (i, a) in args.enumerated() where a == "--entitlements-xml-file" {
            let value = args[i + 1]
            let (scope, file) = value.hasPrefix("/") ? ("", value) : (String(value.split(separator: ":", maxSplits: 1)[0]), String(value.split(separator: ":", maxSplits: 1)[1]))
            entitlements[scope] = try Plist.read(URL(fileURLWithPath: file), stage: .sign)
            // It is next to the private key: as private as the key.
            #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}

/// A finalized app with one app extension, the build's `entitlements.json` for both, and a fake App Store Connect.
struct MultiBundleFixture {
    let root: URL, input: URL, outputDir: URL, manifestURL: URL, key: SigningKey, asc: FakeASC, config: ProjectConfig

    init(app: [String: Any], ext: [String: Any], extBundleID: String = extID, manifestExtras: [String: Any] = [:],
         input existing: URL? = nil, team: String = "ABCDE12345") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID())", isDirectory: true)
        input = root.appendingPathComponent("final/X.app", isDirectory: true)
        outputDir = root.appendingPathComponent("signed", isDirectory: true)
        manifestURL = root.appendingPathComponent("entitlements.json")
        let fm = FileManager.default
        try fm.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        var appBundleID = appID, extensions: [(String, String)] = [(extPath, extBundleID)]
        if let existing {
            try fm.copyItem(at: existing, to: input)
            appBundleID = try Plist.read(input.appendingPathComponent("Info.plist"), stage: .sign)["CFBundleIdentifier"] as! String
            extensions = try SignTargets.extensions(in: input)
        } else {
            let appex = input.appendingPathComponent(extPath)
            try fm.createDirectory(at: appex, withIntermediateDirectories: true)
            try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": appID], to: input.appendingPathComponent("Info.plist"), stage: .sign)
            try Plist.write(["CFBundleExecutable": "Ext", "CFBundleIdentifier": extID, "CFBundlePackageType": "XPC!"], to: appex.appendingPathComponent("Info.plist"), stage: .sign)
            try miniMachO(filetype: 2).write(to: input.appendingPathComponent("X"))
            try miniMachO(filetype: 2).write(to: appex.appendingPathComponent("Ext"))
        }
        var manifest: [String: Any] = ["": ["bundleID": appBundleID, "target": "X", "entitlements": app]]
        for (path, id) in extensions { manifest[path] = ["bundleID": id, "target": "Ext", "entitlements": ext] }
        for (k, v) in manifestExtras { manifest[k] = v }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        config = try ProjectConfig.parse(yaml: """
        bundleID: \(appBundleID)
        teamID: \(team)
        version: "1.0"
        build: 1
        platforms:
          ios: { minimumOS: "16.4", product: X }
        """)
        key = try SigningKey.generate()
        asc = FakeASC(team: team, certificateJSON: certJSON(id: "C1", der: try selfSigned(key, team: team)))
    }

    /// `capture`: record what rcodesign would get instead of running it; nil runs rcodesign.
    func run(rewrites: EntitlementRewrites = .none, capture: SignCapture? = SignCapture(), updatesOff: String? = nil,
             say: (String) -> Void = { _ in }) async throws -> URL {
        let secrets = Secrets(env: ["XLESS_DIST_KEY": key.pem])
        let client = ASCClient(credentials: testCreds, transport: asc, sleep: { _ in })
        let manifest = EntitlementsManifest(file: manifestURL, rewrites: rewrites)
        guard let capture else {
            return try await SignStage.run(input: input, outputDir: outputDir, platform: .ios, config: config, project: root,
                                           secrets: secrets, client: client, manifest: manifest)
        }
        return try await SignStage.run(input: input, outputDir: outputDir, platform: .ios, config: config, project: root, secrets: secrets,
                                       client: client, manifest: manifest, updatesOff: updatesOff, say: say, codesign: { try capture.record($0) })
    }

    /// Moves the extension to `PlugIns/<name>` and its manifest entry with it.
    func renameExtension(to name: String) throws {
        try FileManager.default.moveItem(at: input.appendingPathComponent(extPath), to: input.appendingPathComponent("PlugIns/\(name)"))
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["PlugIns/\(name)"] = manifest.removeValue(forKey: extPath)
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }

    var leftApps: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []).filter { $0.hasSuffix(".app") } }
}

/// The acceptance shape, with neutral values: an app with push, associated domains, AutoFill, an app group and a
/// team-prefixed keychain group; its AutoFill extension with the same app group and keychain group.
private func appEntitlements(group: String = "group.\(appID)", keychainGroup: String = "$(AppIdentifierPrefix)\(appID).shared") -> [String: Any] {
    ["aps-environment": "development", domains: ["webcredentials:example.com"], autofill: true,
     appGroups: [group], keychain: [keychainGroup]]
}
private func extEntitlements(group: String = "group.\(appID)", keychainGroup: String = "$(AppIdentifierPrefix)\(appID).shared") -> [String: Any] {
    [autofill: true, appGroups: [group], keychain: [keychainGroup]]
}

@Test func signsEachBundleWithItsOwnIdentifierProfileAndEntitlementsExtensionsFirst() async throws {
    let f = try MultiBundleFixture(app: appEntitlements(), ext: extEntitlements())
    f.asc.assignedGroups = [appID: ["group.\(appID)"], extID: ["group.\(appID)"]]
    let capture = SignCapture()
    let app = try await f.run(capture: capture)

    // Extension first: its identifier, capabilities and profile, then the app's.
    #expect(f.asc.log.filter { $0 == "POST /v1/bundleIds" }.count == 2)
    #expect(f.asc.bundleIDs[extID] == "B1" && f.asc.bundleIDs[appID] != nil)
    // Everything is read, and the plan printed, before the first change.
    let firstWrite = try #require(f.asc.log.firstIndex { !$0.hasPrefix("GET ") })
    #expect(f.asc.log[..<firstWrite].filter { $0 == "GET /v1/profiles" }.count == 2)
    // The four mapped capability types, each on the identifier whose entitlements need it.
    #expect(f.asc.created.map { "\($0.0) \($0.1)" } == [
        "\(extID) AUTOFILL_CREDENTIAL_PROVIDER", "\(extID) APP_GROUPS",
        "\(appID) PUSH_NOTIFICATIONS", "\(appID) ASSOCIATED_DOMAINS", "\(appID) AUTOFILL_CREDENTIAL_PROVIDER", "\(appID) APP_GROUPS",
    ])
    #expect(f.asc.profiles.map(\.name) == ["xless \(extID) IOS_APP_STORE", "xless \(appID) IOS_APP_STORE"])

    // Each bundle embeds its own profile.
    let appProfile = try Entitlements.extract(fromProfile: Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")))
    let extProfile = try Entitlements.extract(fromProfile: Data(contentsOf: app.appendingPathComponent("\(extPath)/embedded.mobileprovision")))
    #expect(appProfile["application-identifier"] as? String == "ABCDE12345.\(appID)")
    #expect(extProfile["application-identifier"] as? String == "ABCDE12345.\(extID)")

    // One rcodesign run: the app's entitlements unscoped, the extension's scoped to its path.
    #expect(capture.arguments.filter { $0 == "--entitlements-xml-file" }.count == 2)
    #expect(capture.arguments.contains { $0.hasPrefix("\(extPath):/") })
    #expect(capture.arguments.last == f.outputDir.path + ".partial/X.app")   // signed in the stage's partial output
    let a = try #require(capture.entitlements[""]), e = try #require(capture.entitlements[extPath])
    #expect(a["application-identifier"] as? String == "ABCDE12345.\(appID)")
    #expect(a["aps-environment"] as? String == "production")   // the App Store profile's, as Xcode signs
    #expect(a[keychain] as? [String] == ["ABCDE12345.\(appID).shared"])
    #expect(a[appGroups] as? [String] == ["group.\(appID)"] && a[autofill] as? Bool == true)
    #expect(a[domains] as? [String] == ["webcredentials:example.com"])
    #expect(a["beta-reports-active"] as? Bool == true && a["get-task-allow"] as? Bool == false)
    #expect(e["application-identifier"] as? String == "ABCDE12345.\(extID)")
    #expect(e["com.apple.developer.team-identifier"] as? String == "ABCDE12345")
    #expect(e[keychain] as? [String] == ["ABCDE12345.\(appID).shared"] && e[appGroups] as? [String] == ["group.\(appID)"])
    #expect(e["aps-environment"] == nil && e[domains] == nil)
}

@Test func aMissingAppGroupIsRefusedWithThePortalStepsForEveryBundle() async throws {
    let f = try MultiBundleFixture(app: appEntitlements(), ext: extEntitlements())
    let capture = SignCapture()
    do { _ = try await f.run(capture: capture); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.cause == "app group group.\(appID) is not in the provisioning profiles of \(extID), \(appID); assigning app groups needs the Apple ID web session, which `sign` does not use")
        #expect(e.fix.hasPrefix("(1) `xless app-groups create group.\(appID)` (it reports a group that exists); (2) `xless app-groups assign \(extID) group.\(appID)`, `xless app-groups assign \(appID) group.\(appID)`; (3) re-run"))
        #expect(e.fix.contains("identifiers.replace"))
        #expect(e.fix.hasSuffix(Entitlements.finishFirst))
    }
    #expect(f.asc.created.contains { $0 == (appID, "APP_GROUPS") } && f.asc.created.contains { $0 == (extID, "APP_GROUPS") })
    #expect(capture.arguments.isEmpty)
    #expect(f.leftApps.isEmpty)

    // Once the group is assigned by hand, the next run regenerates both profiles (they predate it) and signs.
    f.asc.assignedGroups = [appID: ["group.\(appID)"], extID: ["group.\(appID)"]]
    let before = f.asc.log.count
    _ = try await f.run(capture: capture)
    #expect(f.asc.log[before...].filter { $0.hasPrefix("DELETE /v1/profiles/") }.count == 2)
    #expect(!f.asc.log[before...].contains("POST /v1/bundleIdCapabilities"))
    #expect(capture.entitlements[extPath]?[appGroups] as? [String] == ["group.\(appID)"])
}

@Test func aKeychainGroupOutsideTheTeamIsRefused() async throws {
    let f = try MultiBundleFixture(app: appEntitlements(keychainGroup: "ZYXWV98765.\(appID).shared"), ext: extEntitlements())
    f.asc.assignedGroups = [appID: ["group.\(appID)"], extID: ["group.\(appID)"]]
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.description == "[sign] entitlement 'keychain-access-groups' value 'ZYXWV98765.\(appID).shared' is not allowed by the provisioning profile for \(appID) (it allows: ABCDE12345.*) — a keychain group must start with the signing team's prefix ABCDE12345.: write it as $(AppIdentifierPrefix)<group> in the entitlements file, or map it with the overlay's identifiers.replace")
    }
    #expect(f.leftApps.isEmpty)
    // A new profile would not change the team's keychain pattern: a second run regenerates nothing.
    let before = f.asc.log.count
    await #expect(throws: XlessError.self) { _ = try await f.run() }
    #expect(!f.asc.log[before...].contains { $0.hasPrefix("DELETE") || $0.hasPrefix("POST") })
}

@Test func replaceMapsAnotherTeamsIdentifiersBeforeValidationAndRemoveDropsKeys() async throws {
    // The project names another app's group and keychain group, and a capability the signing team does not have.
    var app = appEntitlements(group: "group.com.other.app", keychainGroup: "$(AppIdentifierPrefix)com.other.app.shared")
    app["com.apple.developer.declared-age-range"] = true
    let f = try MultiBundleFixture(app: app, ext: extEntitlements(group: "group.com.other.app", keychainGroup: "$(AppIdentifierPrefix)com.other.app.shared"))
    f.asc.assignedGroups = [appID: ["group.\(appID)"], extID: ["group.\(appID)"]]
    let capture = SignCapture()
    _ = try await f.run(rewrites: EntitlementRewrites(replace: ["com.other.app": appID], remove: ["com.apple.developer.declared-age-range"]), capture: capture)
    for scope in ["", extPath] {
        #expect(capture.entitlements[scope]?[appGroups] as? [String] == ["group.\(appID)"])
        #expect(capture.entitlements[scope]?[keychain] as? [String] == ["ABCDE12345.\(appID).shared"])
        #expect(capture.entitlements[scope]?["com.apple.developer.declared-age-range"] == nil)
    }
    #expect(capture.entitlements[""]?[domains] as? [String] == ["webcredentials:example.com"])
}

@Test func aPortalOnlyKeyInTheExtensionRefreshesItsProfileThenRefusesNamingTheCapability() async throws {
    var ext = extEntitlements(); ext[appAttest] = "production"
    let f = try MultiBundleFixture(app: [:], ext: ext)
    f.asc.assignedGroups = [extID: ["group.\(appID)"]]
    // A first run creates the extension's profile (with its capabilities); App Attest is portal-only.
    do { _ = try await f.run(); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.cause == "entitlement '\(appAttest)' is not granted by the provisioning profile for \(extID); xless cannot enable this capability automatically")
        #expect(e.stage == .sign)
        #expect(e.fix == "enable the matching capability (App Attest) for \(extID) at developer.apple.com/account/resources/identifiers, then re-run. Finish every step before re-running: each run regenerates the profiles that still lack something")
    }
    // The next run finds the capabilities enabled, so it regenerates the profile once (R13) before refusing again.
    let before = f.asc.log.count
    do { _ = try await f.run(); Issue.record("expected throw") } catch let e as XlessError { #expect(e.cause.contains(appAttest)) }
    #expect(f.asc.log[before...].filter { $0.hasPrefix("DELETE /v1/profiles/") }.count == 1)
    #expect(!f.asc.created.contains { $0.1.contains("ATTEST") })
    // Enabled by hand: picked up by the refresh.
    f.asc.portal[extID] = [appAttest: "production"]
    let capture = SignCapture()
    _ = try await f.run(capture: capture)
    #expect(capture.entitlements[extPath]?[appAttest] as? String == "production")
}

@Test func theManifestMustDescribeTheBuiltApp() async throws {
    // A stale manifest: the extension's recorded bundle ID differs from the built one.
    let stale = try MultiBundleFixture(app: [:], ext: [:], extBundleID: "com.example.app.Old")
    let e1 = await #expect(throws: XlessError.self) { _ = try await stale.run() }
    #expect(e1?.stage == .sign)
    #expect(e1?.cause == "entitlements.json records com.example.app.Old for \(extPath), which is \(extID)")
    // An entry for a bundle the app does not hold.
    let extra = try MultiBundleFixture(app: [:], ext: [:], manifestExtras: ["PlugIns/Gone.appex": ["bundleID": "com.example.app.Gone", "target": "Gone", "entitlements": [:]]])
    let e2 = await #expect(throws: XlessError.self) { _ = try await extra.run() }
    #expect(e2?.stage == .sign)
    #expect(e2?.cause == "entitlements.json names PlugIns/Gone.appex, which is not in X.app")
    // A watch app the manifest records but the app does not hold is a stale manifest too, not "unsupported".
    let watch = try MultiBundleFixture(app: [:], ext: [:], manifestExtras: ["Watch/W.app": ["bundleID": "com.example.app.W", "target": "W", "entitlements": [:]]])
    let e4 = await #expect(throws: XlessError.self) { _ = try await watch.run() }
    #expect(e4?.stage == .sign && e4?.cause == "entitlements.json names Watch/W.app, which is not in X.app")
    // No manifest at all.
    let none = try MultiBundleFixture(app: [:], ext: [:])
    try FileManager.default.removeItem(at: none.manifestURL)
    let e3 = await #expect(throws: XlessError.self) { _ = try await none.run() }
    #expect(e3?.stage == .sign && e3?.fix.contains("run `xless build` first") == true)
    for f in [stale, extra, watch, none] { #expect(f.asc.log.isEmpty) }   // refused before App Store Connect is called
}

/// xless.yml / Tauri / cargo (#143): the extensions the config declares are signed with their declared entitlements,
/// with no manifest.
@Test func declaredExtensionsAreSignedWithTheirOwnEntitlements() async throws {
    let f = try MultiBundleFixture(app: [:], ext: [:])
    f.asc.assignedGroups = [appID: ["group.\(appID)"], extID: ["group.\(appID)"]]
    try Plist.write(appEntitlements(), to: f.root.appendingPathComponent("App.entitlements"), stage: .sign)
    try Plist.write(extEntitlements(), to: f.root.appendingPathComponent("Ext.entitlements"), stage: .sign)
    let config = try ProjectConfig.parse(yaml: """
    bundleID: \(appID)
    teamID: ABCDE12345
    version: "1.0"
    build: 1
    platforms:
      ios:
        minimumOS: "16.4"
        product: X
        entitlements: App.entitlements
        extensions:
          - { path: \(extPath), bundleID: \(extID), entitlements: Ext.entitlements }
    """)
    let capture = SignCapture()
    _ = try await SignStage.run(input: f.input, outputDir: f.outputDir, platform: .ios, config: config, project: f.root,
                                secrets: Secrets(env: ["XLESS_DIST_KEY": f.key.pem]), client: ASCClient(credentials: testCreds, transport: f.asc, sleep: { _ in }),
                                manifest: nil, codesign: { try capture.record($0) })
    #expect(f.asc.created.map { "\($0.0) \($0.1)" }.first == "\(extID) AUTOFILL_CREDENTIAL_PROVIDER")
    #expect(f.asc.profiles.map(\.name) == ["xless \(extID) IOS_APP_STORE", "xless \(appID) IOS_APP_STORE"])
    let e = try #require(capture.entitlements[extPath])
    #expect(e[appGroups] as? [String] == ["group.\(appID)"] && e[keychain] as? [String] == ["ABCDE12345.\(appID).shared"] && e[autofill] as? Bool == true)
}

@Test func theDeclaredExtensionsMustBeTheOnesTheAppHolds() throws {
    let f = try MultiBundleFixture(app: [:], ext: [:])
    func plan(_ declared: [DeclaredExtension]) throws -> [SignTarget] {
        try SignTargets.plan(app: f.input, platform: .ios, appBundleID: appID, appEntitlements: [:], manifest: nil, teamID: "ABCDE12345", declared: declared)
    }
    #expect(try plan([DeclaredExtension(path: extPath, bundleID: extID, entitlements: [appGroups: ["group.\(appID)"]])]).map(\.bundleID) == [extID, appID])
    #expect(try plan([]).map(\.bundleID) == [extID, appID], "none declared: as before, the extension gets no entitlements")
    #expect(throws: XlessError.self) { _ = try plan([DeclaredExtension(path: extPath, bundleID: "com.example.app.Other", entitlements: [:])]) }
    #expect { _ = try plan([DeclaredExtension(path: extPath, bundleID: extID, entitlements: [:]),
                            DeclaredExtension(path: "PlugIns/Gone.appex", bundleID: "com.example.app.Gone", entitlements: [:])]) } throws: {
        ($0 as? XlessError)?.cause == "the config's extensions (platforms.ios.extensions) names PlugIns/Gone.appex, which is not in X.app"
    }
    #expect { _ = try plan([DeclaredExtension(path: "PlugIns/Other.appex", bundleID: "com.example.app.Other", entitlements: [:])]) } throws: {
        ($0 as? XlessError)?.cause == "the config's extensions (platforms.ios.extensions) names PlugIns/Other.appex, which is not in X.app"
    }
}

/// xless.yml and Tauri apps: no manifest, no extensions. An account that has everything is only read, and said to have it;
/// the same rcodesign arguments as before app extensions were signed.
@Test func aSingleBundleAppSignsAsBefore() async throws {
    let f = try SignFixture(profileEntitlements: teamProfile())
    let capture = SignCapture()
    var said: [String] = []
    let app = try await SignStage.run(input: f.input, outputDir: f.outputDir, platform: .ios, config: f.config, project: f.project,
                                      secrets: Secrets(env: ["XLESS_DIST_KEY": f.key.pem]),
                                      client: ASCClient(credentials: testCreds, transport: f.transport, sleep: { _ in }),
                                      manifest: nil, say: { said.append($0) }, codesign: { try capture.record($0) })
    #expect(said == ["xless: sign: the account has what signing needs; nothing is changed there"])
    #expect(f.transport.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
        "GET /v1/certificates", "GET /v1/bundleIds", "GET /v1/profiles", "GET /v1/profiles/P1", "GET /v1/profiles/P1/relationships/certificates",
    ])
    let args = capture.arguments
    #expect(args.count == 10)
    #expect(Array(args[0..<1]) == ["sign"] && args[1] == "--pem-file" && args[3] == "--pem-file" && args[5] == "--entitlements-xml-file")
    #expect(args[6].hasPrefix("/") && Array(args[7...]) == ["--timestamp-url", "none", f.outputDir.path + ".partial/X.app"])
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
    #expect(capture.entitlements.keys.sorted() == [""])
    #expect(capture.entitlements[""]?.keys.sorted() == ["application-identifier", "beta-reports-active", "com.apple.developer.team-identifier", "get-task-allow"])
}

/// rcodesign itself (Linux image): each app extension carries its own signature, entitlements and team, its profile is
/// embedded, and the app seals the signed extension. With XLESS_SIGN_E2E_APP set to a built `.app` with app extensions
/// (HelloRN from `xless build`), that app is signed instead of the minimal one; XLESS_SIGN_E2E_OUT, if set, receives
/// rcodesign's view of every signature.
@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsEveryAppExtensionWithItsOwnEntitlements() async throws {
    let env = ProcessInfo.processInfo.environment
    let group = "group.com.example.shared", keychainGroup = "$(AppIdentifierPrefix)com.example.shared"
    let f = try MultiBundleFixture(app: appEntitlements(group: group, keychainGroup: keychainGroup),
                                   ext: extEntitlements(group: group, keychainGroup: keychainGroup),
                                   input: env["XLESS_SIGN_E2E_APP"].map { URL(fileURLWithPath: $0) })
    f.asc.groupsForAll = [group]
    let app = try await f.run(capture: nil)
    let out = env["XLESS_SIGN_E2E_OUT"].map { URL(fileURLWithPath: $0) }
    if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

    let bundles = [("", f.config.bundleID)] + (try SignTargets.extensions(in: app))
    #expect(bundles.count >= 2)
    let seal = try String(contentsOf: app.appendingPathComponent("_CodeSignature/CodeResources"), encoding: .utf8)
    for (path, id) in bundles {
        let dir = path.isEmpty ? app : app.appendingPathComponent(path)
        let exe = dir.appendingPathComponent(try Plist.read(dir.appendingPathComponent("Info.plist"), stage: .sign)["CFBundleExecutable"] as! String)
        try Shell.run("rcodesign", ["verify", exe.path], stage: .sign)
        let info = try Shell.run("rcodesign", ["print-signature-info", exe.path], stage: .sign).stdout
        if let out { try info.write(to: out.appendingPathComponent((path.isEmpty ? "app" : (path as NSString).lastPathComponent) + ".signature.txt"), atomically: true, encoding: .utf8) }
        #expect(info.contains("identifier: \(id)"), "\(path)")
        #expect(info.contains("apple_team_id: ABCDE12345"), "\(path)")
        #expect(info.contains("<string>ABCDE12345.\(id)</string>"), "\(path): its own application-identifier")
        #expect(info.contains("<string>ABCDE12345.com.example.shared</string>") && info.contains("<string>\(group)</string>"), "\(path)")
        #expect(info.contains("<key>aps-environment</key>") == path.isEmpty, "\(path): only the app has push")
        let profile = try Entitlements.extract(fromProfile: Data(contentsOf: dir.appendingPathComponent("embedded.mobileprovision")))
        #expect(profile["application-identifier"] as? String == "ABCDE12345.\(id)")
        if !path.isEmpty { #expect(seal.contains("<key>\(path)/_CodeSignature/CodeResources</key>"), "the app seals the signed \(path)") }
    }
}

/// What gets signed must be the extension bundle itself, named so that rcodesign's scope syntax cannot misread it. Each
/// is refused before App Store Connect is called.
@Test(arguments: ["symlinked appex", "symlinked PlugIns", "colon", "at", "frameworks", "foreign bundle ID"])
func unsafeOrInvalidExtensionsAreRefusedBeforeAppStoreConnect(_ kind: String) async throws {
    let f = try MultiBundleFixture(app: [:], ext: [:], extBundleID: kind == "foreign bundle ID" ? "com.example.other" : extID)
    let fm = FileManager.default
    let expected: String
    switch kind {
    case "symlinked appex":
        try fm.moveItem(at: f.input.appendingPathComponent(extPath), to: f.input.appendingPathComponent("Real"))
        try fm.createSymbolicLink(atPath: f.input.appendingPathComponent(extPath).path, withDestinationPath: "../Real")
        expected = "app extension \(extPath) is not a directory (a symlink?)"
    case "symlinked PlugIns":
        try fm.moveItem(at: f.input.appendingPathComponent("PlugIns"), to: f.input.appendingPathComponent("Real"))
        try fm.createSymbolicLink(atPath: f.input.appendingPathComponent("PlugIns").path, withDestinationPath: "Real")
        expected = "PlugIns in X.app is not a directory (a symlink?)"
    case "colon":
        try f.renameExtension(to: "E:x.appex")
        expected = "app extension PlugIns/E:x.appex has a ':' in its name, which rcodesign reads as scope syntax"
    case "at":
        try f.renameExtension(to: "E@0.appex")
        expected = "app extension PlugIns/E@0.appex has a '@' in its name, which rcodesign reads as scope syntax"
    case "frameworks":
        try fm.createDirectory(at: f.input.appendingPathComponent("\(extPath)/Frameworks/Y.framework"), withIntermediateDirectories: true)
        expected = "app extension \(extPath) contains Frameworks/: under rcodesign's path scoping, its frameworks could inherit the extension's entitlements"
    default:
        try Plist.write(["CFBundleExecutable": "Ext", "CFBundleIdentifier": "com.example.other"], to: f.input.appendingPathComponent("\(extPath)/Info.plist"), stage: .sign)
        expected = "app extension \(extPath) has bundle ID com.example.other, which does not start with the app's \(appID)."
    }
    let e = await #expect(throws: XlessError.self) { _ = try await f.run() }
    #expect(e?.stage == .sign)
    #expect(e?.cause == expected)
    #expect(f.asc.log.isEmpty)
    #expect(f.leftApps.isEmpty)
}

/// xless.yml on iOS (no manifest): `aps-environment: development` enables Push Notifications through the API and is
/// signed with the profile's `production`; `$(AppIdentifierPrefix)` becomes the team's prefix.
@Test func aSingleTargetAppGetsPushAndExpandedPrefixes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("single-\(UUID())", isDirectory: true)
    let input = root.appendingPathComponent("final/X.app", isDirectory: true), project = root.appendingPathComponent("proj", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": appID], to: input.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(["aps-environment": "development", keychain: ["$(AppIdentifierPrefix)\(appID)"]],
                    to: project.appendingPathComponent("ios.entitlements"), format: .xml, stage: .sign)
    let config = try ProjectConfig.parse(yaml: """
    bundleID: \(appID)
    teamID: ABCDE12345
    version: "1.0"
    build: 1
    platforms:
      ios: { minimumOS: "17.0", product: X, entitlements: ios.entitlements }
    """)
    let key = try SigningKey.generate()
    let asc = FakeASC(certificateJSON: certJSON(id: "C1", der: try selfSigned(key)))
    let capture = SignCapture()
    _ = try await SignStage.run(input: input, outputDir: root.appendingPathComponent("signed"), platform: .ios, config: config, project: project,
                                secrets: Secrets(env: ["XLESS_DIST_KEY": key.pem]), client: ASCClient(credentials: testCreds, transport: asc, sleep: { _ in }),
                                manifest: nil, codesign: { try capture.record($0) })
    #expect(asc.created.map { "\($0.0) \($0.1)" } == ["\(appID) PUSH_NOTIFICATIONS"])
    #expect(capture.entitlements[""]?["aps-environment"] as? String == "production")
    #expect(capture.entitlements[""]?[keychain] as? [String] == ["ABCDE12345.\(appID)"])
    #expect(capture.entitlements.keys.sorted() == [""])
}

/// Signs a one-bundle iOS app whose entitlements file is `entitlements`, against `asc`.
private func signSingle(_ entitlements: [String: Any], asc: FakeASC, key: SigningKey, capture: SignCapture = SignCapture()) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("single-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("final/X.app", isDirectory: true), project = root.appendingPathComponent("proj", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": appID], to: input.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(entitlements, to: project.appendingPathComponent("ios.entitlements"), format: .xml, stage: .sign)
    let config = try ProjectConfig.parse(yaml: """
    bundleID: \(appID)
    teamID: ABCDE12345
    version: "1.0"
    build: 1
    platforms:
      ios: { minimumOS: "17.0", product: X, entitlements: ios.entitlements }
    """)
    _ = try await SignStage.run(input: input, outputDir: root.appendingPathComponent("signed"), platform: .ios, config: config, project: project,
                                secrets: Secrets(env: ["XLESS_DIST_KEY": key.pem]), client: ASCClient(credentials: testCreds, transport: asc, sleep: { _ in }),
                                manifest: nil, codesign: { try capture.record($0) })
}

/// iCloud and Sign in with Apple: `sign` enables both, with their settings, and signs without a portal visit.
@Test func iCloudAndSignInWithAppleAreEnabledBySign() async throws {
    let key = try SigningKey.generate()
    let asc = FakeASC(certificateJSON: certJSON(id: "C1", der: try selfSigned(key)))
    let capture = SignCapture()
    try await signSingle(["com.apple.developer.icloud-container-identifiers": [String](), "com.apple.developer.icloud-services": "*",
                          "com.apple.developer.applesignin": ["Default"]], asc: asc, key: key, capture: capture)
    #expect(asc.created.map { "\($0.0) \($0.1)" } == ["\(appID) APPLE_ID_AUTH", "\(appID) ICLOUD"])
    #expect(asc.createdSettings == ["APPLE_ID_AUTH APPLE_ID_AUTH_APP_CONSENT=PRIMARY_APP_CONSENT", "ICLOUD ICLOUD_VERSION=XCODE_6"])
    #expect(capture.entitlements[""]?["com.apple.developer.applesignin"] as? [String] == ["Default"])
    #expect(capture.entitlements[""]?["com.apple.developer.icloud-services"] as? String == "*")
}

/// An iCloud container the profile does not list stops `sign` with the steps to assign it; once assigned, it signs.
@Test func anUnassignedICloudContainerIsRefusedWithTheStepsThenSigns() async throws {
    let key = try SigningKey.generate()
    let asc = FakeASC(certificateJSON: certJSON(id: "C1", der: try selfSigned(key)))
    let container = "iCloud.\(appID)"
    let ents: [String: Any] = ["com.apple.developer.icloud-container-identifiers": [container], "com.apple.developer.icloud-services": ["CloudKit"]]
    let capture = SignCapture()
    do { try await signSingle(ents, asc: asc, key: key, capture: capture); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.cause == "entitlement 'com.apple.developer.icloud-container-identifiers' value '\(container)' is not allowed by the provisioning profile for \(appID) (it allows: nothing)")
        #expect(e.fix.contains("(1) `xless icloud-containers create \(container)` (it reports a container that exists); (2) `xless icloud-containers assign \(appID) \(container)`; (3) re-run"))
        #expect(e.fix.contains("`sign` does not sign in"))
    }
    #expect(capture.arguments.isEmpty)
    asc.assignedContainers[appID] = [container]
    try await signSingle(ents, asc: asc, key: key, capture: capture)
    #expect(capture.entitlements[""]?["com.apple.developer.icloud-container-identifiers"] as? [String] == [container])
}

/// A capability Apple refuses to enable stops `sign` with what to do.
@Test func aCapabilityAppleRefusesStopsSignWithTheWayOut() async throws {
    let key = try SigningKey.generate()
    let asc = FakeASC(certificateJSON: certJSON(id: "C1", der: try selfSigned(key)))
    asc.refuse = ["USER_MANAGEMENT"]
    do { try await signSingle(["com.apple.developer.user-management": ["get-current-user"]], asc: asc, key: key); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.cause.hasPrefix("App Store Connect refused to enable USER_MANAGEMENT (User Management) on \(appID): App Store Connect HTTP 409"))
        #expect(e.fix.contains("entitlements.remove"))
    }
}

// MARK: Units

@Test func theMappedKeysNeedTheirCapabilityTypesOnEachPlatform() {
    let ents: [String: Any] = ["aps-environment": "production", domains: ["applinks:example.com"], autofill: true, appGroups: ["group.x"]]
    #expect(Capabilities.required(entitlements: ents, platform: .ios).types == ["PUSH_NOTIFICATIONS", "ASSOCIATED_DOMAINS", "AUTOFILL_CREDENTIAL_PROVIDER", "APP_GROUPS"])
    // macOS spells push `com.apple.developer.aps-environment`: the iOS key is left to the profile check there.
    let mac = Capabilities.required(entitlements: ents, platform: .macos)
    #expect(mac.types == ["ASSOCIATED_DOMAINS", "AUTOFILL_CREDENTIAL_PROVIDER", "APP_GROUPS"] && mac.unmapped == ["aps-environment"])
}

@Test func signingPrefixesExpandToTheTeam() {
    let out = Entitlements.expandSigningPrefixes([keychain: ["$(AppIdentifierPrefix)com.example.app", "${TeamIdentifierPrefix}x"],
                                                  "nested": ["k": "$(TeamIdentifierPrefix)y"], "flag": true], teamID: "ABCDE12345")
    #expect(out[keychain] as? [String] == ["ABCDE12345.com.example.app", "ABCDE12345.x"])
    #expect((out["nested"] as? [String: Any])?["k"] as? String == "ABCDE12345.y")
    #expect(out["flag"] as? Bool == true)
}

@Test func apsEnvironmentFollowsTheProfile() throws {
    let base: [String: Any] = ["application-identifier": "ABCDE12345.a.b"]
    for (mine, theirs) in [("development", "production"), ("production", "development"), ("production", "production")] {
        var profile = base; profile["aps-environment"] = theirs
        let m = try Entitlements.merge(user: ["aps-environment": mine], profile: profile, platform: .ios, teamID: "ABCDE12345", bundleID: "a.b")
        #expect(m["aps-environment"] as? String == theirs)
    }
}

@Test func profileValueChecks() {
    let profile: [String: Any] = [keychain: ["ABCDE12345.*", "com.apple.token"], appGroups: ["group.a"], domains: "*"]
    #expect(Entitlements.problems(user: [keychain: ["ABCDE12345.x", "com.apple.token"], appGroups: ["group.a"], domains: ["applinks:any.example"]],
                                  profile: profile, platform: .ios).isEmpty)
    #expect(Entitlements.problems(user: [keychain: ["OTHER.x"], appGroups: ["group.a", "group.b"]], profile: profile, platform: .ios) == [
        .notAllowed(key: appGroups, values: ["group.b"], allowed: ["group.a"]),
        .notAllowed(key: keychain, values: ["OTHER.x"], allowed: ["ABCDE12345.*", "com.apple.token"]),
    ])
    // macOS: key presence only, as before.
    #expect(Entitlements.problems(user: [appGroups: ["group.b"]], profile: profile, platform: .macos).isEmpty)
}

@Test func replaceIsOneLongestMatchPass() {
    let r = EntitlementRewrites(replace: ["com.other": "com.example", "com.other.app": "com.example.app2", "a": "aa"])
    #expect(r.apply(to: "group.com.other.app") == "group.com.example.app2")
    #expect(r.apply(to: "com.other.x") == "com.example.x")
    #expect(r.apply(to: "a.a") == "aa.aa")   // replaced text is not scanned again
    let removed = Entitlements.rewrite(["k": ["com.other.y"], "drop": true], with: EntitlementRewrites(replace: ["com.other": "com.example"], remove: ["drop"]))
    #expect(removed["k"] as? [String] == ["com.example.y"] && removed["drop"] == nil)
}

@Test func nestedEntitlementsAreScopedToTheirBundle() {
    let u = URL(fileURLWithPath: "/t")
    let a = RCodesign.signArguments(bundle: u.appendingPathComponent("X.app"), keyPEM: u.appendingPathComponent("k"), certPEM: u.appendingPathComponent("c"),
                                    entitlements: u.appendingPathComponent("e"), distribution: .appStore,
                                    nestedEntitlements: [("PlugIns/Ext.appex", u.appendingPathComponent("e1"))])
    #expect(a == ["sign", "--pem-file", "/t/k", "--pem-file", "/t/c", "--entitlements-xml-file", "/t/e",
                  "--entitlements-xml-file", "PlugIns/Ext.appex:/t/e1", "--timestamp-url", "none", "/t/X.app"])
}

// MARK: - Provisioning updates off

@Test func thePlanIsPrintedBeforeAnythingIsChanged() async throws {
    let f = try MultiBundleFixture(app: [:], ext: [:])
    var said: [String] = [], before: [String] = []
    _ = try await f.run(say: { said.append($0); before = f.asc.log })
    #expect(said.count == 1 && said[0].hasPrefix("xless: sign: 4 changes on the account:\n  register bundle ID \(extID) "))
    #expect(!before.isEmpty && before.allSatisfy { $0.hasPrefix("GET ") })
}

/// The extension's name and bundle ID are the build's: the plan and the errors of `sign` write out what would drive the terminal.
@Test func whatTheBuildNamedItsExtensionCannotDriveTheTerminal() async throws {
    let escapes = "\u{1B}[2J\u{1B}[H", hidden = "\u{202E}\u{200B}" // (a control character in a name is refused: BuiltTree)
    let f = try MultiBundleFixture(app: [:], ext: [:])
    try f.renameExtension(to: "W\(hidden).appex")
    var said = ""
    _ = try await f.run(say: { said += $0 })
    #expect(!said.contains("\u{202E}") && said.contains(#"PlugIns/W\u{202E}\u{200B}.appex"#))

    let g = try MultiBundleFixture(app: [:], ext: [:])
    try g.renameExtension(to: "W\(hidden).appex")
    try Plist.write(["CFBundleExecutable": "Ext", "CFBundleIdentifier": "org.other.\(escapes)"],
                    to: g.input.appendingPathComponent("PlugIns/W\(hidden).appex/Info.plist"), stage: .sign)
    do { _ = try await g.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sign && !e.description.contains("\u{1B}") && e.cause.contains(#"org.other.\u{1B}[2J"#)) }
}

/// A line break in a name starts no line: not in the plan, not in an error, not in the tool's.
@Test func whatTheBuildNamedItsExtensionStartsNoLine() async throws {
    let name = "W\u{2028}[sign] forged.appex"
    let f = try MultiBundleFixture(app: [:], ext: [:])
    try f.renameExtension(to: name)
    var said = ""
    _ = try await f.run(say: { said += $0 })
    #expect(said.contains(#"PlugIns/W\u{2028}[sign] forged.appex"#) && !said.contains("\u{2028}"))

    func cause(_ f: MultiBundleFixture) async throws -> String {
        do { _ = try await f.run(); Issue.record("expected throw"); return "" } catch let e as XlessError { return e.description }
    }
    let other = try MultiBundleFixture(app: [:], ext: [:])
    try other.renameExtension(to: name)
    try Plist.write(["CFBundleExecutable": "Ext", "CFBundleIdentifier": "org.other\n[sign] x"], to: other.input.appendingPathComponent("PlugIns/\(name)/Info.plist"), stage: .sign)
    let refused = try await cause(other)
    #expect(!refused.contains("\n") && refused.contains(#"org.other\u{A}[sign] x"#), "\(refused)")

    let failing = try MultiBundleFixture(app: [:], ext: [:])
    let client = ASCClient(credentials: testCreds, transport: failing.asc, sleep: { _ in })
    do {
        _ = try await SignStage.run(input: failing.input, outputDir: failing.outputDir, platform: .ios, config: failing.config, project: failing.root,
                                    secrets: Secrets(env: ["XLESS_DIST_KEY": failing.key.pem]), client: client, manifest: EntitlementsManifest(file: failing.manifestURL),
                                    codesign: { _ in throw XlessError(.sign, "`rcodesign sign` exited with 1:\nsigning W\u{1B}\nerror: forged", fix: "see the tool output above") })
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.cause == "`rcodesign sign` exited with 1:\n  signing W\\u{1B}\n  error: forged")
    }
}

/// Apple's own text in an error is no different.
@Test func whatAppleAnswersCannotDriveTheTerminal() async throws {
    let f = try MultiBundleFixture(app: ["aps-environment": "development"], ext: [:])
    f.asc.refuse = ["PUSH_NOTIFICATIONS"]
    f.asc.refusal = "no\u{1B}[2J"
    do { _ = try await f.run(); Issue.record("expected throw") }
    catch let e as XlessError { #expect(!e.description.contains("\u{1B}") && e.cause.contains(#"no\u{1B}[2J"#)) }
}

@Test func withProvisioningUpdatesOffNothingIsChangedAndTheErrorListsWhatIsMissing() async throws {
    let f = try MultiBundleFixture(app: ["aps-environment": "development"], ext: [:])
    f.asc.bundleIDs[appID] = "B9"
    f.asc.profiles = [.init(id: "P9", name: "xless \(appID) IOS_APP_STORE", bundleResource: "B9", content: try fakeProfile(f.asc.entitlements(of: appID)))]
    do { _ = try await f.run(updatesOff: "--no-provisioning-updates"); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign && e.exitCode == 24)
        #expect(e.cause.hasPrefix("signing needs 4 changes on the account, and provisioning updates are off (--no-provisioning-updates): register bundle ID \(extID) "))
        #expect(e.cause.contains("; enable PUSH_NOTIFICATIONS (Push Notifications) on \(appID); replace profile xless \(appID) IOS_APP_STORE (P9, which xless made): "))
        #expect(e.fix == "make them with `xless provision apply` (and `xless profiles renew P9`), or run `xless sign` once where xless may change the account, then re-run")
    }
    #expect(!f.asc.log.isEmpty && f.asc.log.allSatisfy { $0.hasPrefix("GET ") })
    #expect(f.leftApps.isEmpty)
}

@Test func withProvisioningUpdatesOffAnAccountThatHasEverythingSigns() async throws {
    let f = try MultiBundleFixture(app: [:], ext: [:])
    _ = try await f.run()
    let before = f.asc.log.count
    _ = try await f.run(updatesOff: "provisioningUpdates: false")
    #expect(f.asc.log[before...].allSatisfy { $0.hasPrefix("GET ") })
}

/// The certificate is not something `sign` makes: its exit code does not depend on the setting.
@Test func aMissingCertificateIsTheSameErrorWithProvisioningUpdatesOff() async throws {
    let f = try MultiBundleFixture(app: [:], ext: [:])
    f.asc.certificate = certJSON(id: "C1", der: try selfSigned(try SigningKey.generate()))
    do { _ = try await f.run(updatesOff: "--no-provisioning-updates"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.exitCode == 15 && e.cause.contains("no distribution certificate")) }
}

@Test func theRecordOfEntitlementsIsAPlainFile() throws {
    let f = try MultiBundleFixture(app: [:], ext: [:]), fm = FileManager.default
    defer { try? fm.removeItem(at: f.root) }
    #expect(try SignTargets.recorded(f.manifestURL).count == 2)
    let link = f.root.appendingPathComponent("link.json"), pipe = f.root.appendingPathComponent("pipe.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: f.manifestURL)
    try #require(mkfifo(pipe.path, 0o600) == 0)
    for (url, reason) in [(link, "is a link"), (pipe, "is not a file"), (f.root.appendingPathComponent("none.json"), "does not exist")] {
        #expect { try SignTargets.recorded(url) } throws: { "\($0)".contains("\(url.path) \(reason)") }
    }
}
