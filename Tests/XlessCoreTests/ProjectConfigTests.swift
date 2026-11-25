import Testing
import Foundation
@testable import XlessCore

let validYAML = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 7
platforms:
  ios:   { minimumOS: "17.0", product: HelloShip, entitlements: ios.entitlements }
  macos: { minimumOS: "14.0", product: HelloShip, distribution: developer-id }
assets: Resources/Assets.xcassets
privacyManifest: Resources/PrivacyInfo.xcprivacy
"""

@Test func parsesValidConfig() throws {
    let c = try ProjectConfig.parse(yaml: validYAML)
    #expect(c.bundleID == "app.example.helloship")
    #expect(c.build == "7")
    #expect(try c.platform(.ios).minimumOS == "17.0")
    #expect(c.distribution(for: .ios) == .appStore)
    #expect(c.distribution(for: .macos) == .developerID)
    #expect(c.bundleID(for: .macos) == "app.example.helloship")
}

@Test func buildOverrideWins() throws {
    let c = try ProjectConfig.parse(yaml: validYAML, buildOverride: "42")
    #expect(c.build == "42")
}

@Test(arguments: [
    ("teamID: ABCDE12345", "teamID: abc", "teamID"),
    ("version: 1.0.0", "version: one", "version"),
    ("ios:   {", "tvos:   {", "unknown platform"),
    ("bundleID: app.example.helloship", "bundleID: nodots", "bundleID"),
])
func rejectsInvalid(from: String, to: String, expectedFragment: String) {
    let yaml = validYAML.replacingOccurrences(of: from, with: to)
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: yaml) }
    do { _ = try ProjectConfig.parse(yaml: yaml) } catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.description.contains(expectedFragment))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func iosMustBeAppStore() {
    let yaml = validYAML.replacingOccurrences(of: "entitlements: ios.entitlements }", with: "distribution: developer-id }")
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: yaml) }
}

@Test func macosMayBeAppStore() throws {
    let yaml = validYAML.replacingOccurrences(of: "product: HelloShip, distribution: developer-id }",
                                             with: "product: HelloShip, distribution: app-store }")
    let c = try ProjectConfig.parse(yaml: yaml)
    #expect(c.distribution(for: .macos) == .appStore)
}

// MARK: --distribution override (xless ship)

@Test func distributionOverrideReplacesThePlatformForTheRun() throws {
    let c = try ProjectConfig.parse(yaml: validYAML)
    let overridden = try c.overridingDistribution(.appStore, for: .macos)
    #expect(overridden.distribution(for: .macos) == .appStore)
    // Everything else carries over, and nothing else changes.
    #expect(overridden.distribution(for: .ios) == .appStore)
    #expect(try overridden.platform(.macos).product == "HelloShip")
    #expect(try overridden.platform(.macos).minimumOS == "14.0")
    // The config file's own value (the parsed config) is untouched.
    #expect(c.distribution(for: .macos) == .developerID)
}

@Test func macosDeveloperIDOverrideIsAccepted() throws {
    let yaml = validYAML.replacingOccurrences(of: "product: HelloShip, distribution: developer-id }",
                                             with: "product: HelloShip, distribution: app-store }")
    let c = try ProjectConfig.parse(yaml: yaml)
    #expect(try c.overridingDistribution(.developerID, for: .macos).distribution(for: .macos) == .developerID)
}

@Test func iosAppStoreOverrideIsANoOp() throws {
    let c = try ProjectConfig.parse(yaml: validYAML)
    #expect(try c.overridingDistribution(.appStore, for: .ios).distribution(for: .ios) == .appStore)
}

@Test func iosDeveloperIDOverrideIsRefused() throws {
    let c = try ProjectConfig.parse(yaml: validYAML)
    do { _ = try c.overridingDistribution(.developerID, for: .ios); Issue.record("--distribution developer-id must be refused for iOS") }
    catch let e as XlessError {
        #expect(e.stage == .config)
        #expect(e.description.contains("app-store"))
        #expect(e.fix.contains("--distribution"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func distributionOverrideOnAnUnconfiguredPlatformThrows() throws {
    let yaml = validYAML.replacingOccurrences(of: "  macos: { minimumOS: \"14.0\", product: HelloShip, distribution: developer-id }\n", with: "")
    let c = try ProjectConfig.parse(yaml: yaml)
    #expect(throws: XlessError.self) { try c.overridingDistribution(.appStore, for: .macos) }
}

@Test func missingPlatformThrowsOnLookup() throws {
    let yaml = validYAML.replacingOccurrences(of: "  macos: { minimumOS: \"14.0\", product: HelloShip, distribution: developer-id }\n", with: "")
    let c = try ProjectConfig.parse(yaml: yaml)
    #expect(throws: XlessError.self) { try c.platform(.macos) }
}

// MARK: testflight / export compliance

@Test func testflightAbsentByDefault() throws {
    let c = try ProjectConfig.parse(yaml: validYAML)
    #expect(c.testflight == nil)
    #expect(c.usesNonExemptEncryption == nil)
}

@Test func parsesTestflightBlockAndEncryption() throws {
    let c = try ProjectConfig.parse(yaml: validYAML + """

    testflight:
      groups: ["Internal", "QA"]
      whatToTest: "Launch screen built on Linux"
    usesNonExemptEncryption: false
    """)
    #expect(c.testflight == TestFlightConfig(groups: ["Internal", "QA"], whatToTest: "Launch screen built on Linux", locale: "en-US"))
    #expect(c.usesNonExemptEncryption == false)
}

@Test func testflightLocaleIsConfigurable() throws {
    let c = try ProjectConfig.parse(yaml: validYAML + "\ntestflight: { groups: [Internal], whatToTest: Hola, locale: es-ES }\n")
    #expect(c.testflight?.locale == "es-ES")
}

@Test(arguments: [
    "testflight: { groups: [] }",
    "testflight: { groups: [\"\"] }",
    "testflight: { groups: [A, A] }",
    "testflight: { groups: [A], whatToTest: \"  \" }",
    "testflight: { groups: [A], locale: \"not a locale\" }",
    "testflight: { groups: [A], locale: en_US }",
    "testflight: { whatToTest: x }",
    "usesNonExemptEncryption: maybe",
])
func rejectsInvalidTestflight(extra: String) {
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: validYAML + "\n" + extra + "\n") }
}

@Test func parsesTestersAndExternalTesting() throws {
    let c = try ProjectConfig.parse(yaml: validYAML + """

    testflight:
      groups: [Internal]
      whatToTest: Try the editor
      testers: [ada@example.com, {email: grace@example.com, firstName: Grace, lastName: Hopper}]
      external:
        groups: ["Public Beta"]
        testers: [ext@example.com]
        info: {description: A beta, feedbackEmail: beta@example.com, privacyPolicyUrl: "https://example.com/privacy"}
        review:
          contact: {firstName: Ada, lastName: Lovelace, phone: "+1 555 0100", email: review@example.com}
          notes: Sign in with the demo account
          demoAccount: {name: demo, required: true}
    """)
    let tf = try #require(c.testflight)
    #expect(tf.testers == [TestFlightTester(email: "ada@example.com"), TestFlightTester(email: "grace@example.com", firstName: "Grace", lastName: "Hopper")])
    let ext = try #require(tf.external)
    #expect(ext.groups == ["Public Beta"] && ext.testers == [TestFlightTester(email: "ext@example.com")] && ext.submit)
    #expect(ext.info?.privacyPolicyUrl == "https://example.com/privacy")
    #expect(ext.review?.demoAccount == .init(name: "demo", passwordSecret: nil, required: true))
}

@Test func anEmptyExternalBlockNamesItsOwnKey() {
    do { _ = try ProjectConfig.parse(yaml: validYAML + "\ntestflight: { external: { groups: [] } }\n"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause == "testflight.external.groups is empty") }
    catch { Issue.record("\(error)") }
}

@Test func externalGroupsAloneAreEnough() throws {
    let c = try ProjectConfig.parse(yaml: validYAML + "\ntestflight: { external: { groups: [Beta], submit: false } }\n")
    #expect(c.testflight?.groups == [] && c.testflight?.external?.submit == false)
}

@Test(arguments: [
    "testflight: { external: { groups: [] } }",
    "testflight: { groups: [A], external: { groups: [A], submit: false } }",
    "testflight: { groups: [A], testers: [nope] }",
    "testflight: { groups: [A], testers: [a@example.com, A@example.com] }",
    "testflight: { external: { groups: [B], submit: false }, testers: [a@example.com] }",
    "testflight: { external: { groups: [B] } }",
    "testflight: { whatToTest: x, external: { groups: [B], info: { feedbackEmail: nope } } }",
    "testflight: { whatToTest: x, external: { groups: [B], info: { privacyPolicyUrl: example.com } } }",
    "testflight: { whatToTest: x, external: { groups: [B], review: { demoAccount: { required: true } } } }",
    "testflight: { whatToTest: x, external: { groups: [B], review: { demoAccount: { name: d, passwordSecret: ASC_KEY_P8 } } } }",
])
func rejectsInvalidTestersAndExternalTesting(extra: String) {
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: validYAML + "\n" + extra + "\n") }
}

@Test func rejectsOverlongWhatToTest() {
    let long = String(repeating: "x", count: 4001)
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: validYAML + "\ntestflight: { groups: [A], whatToTest: \(long) }\n") }
}

@Test func datedBuildSchemeAcceptsFourComponentDatedBuild() throws {
    let c = try ProjectConfig.parse(yaml: validYAML, buildOverride: "1.0.0.2026101501", buildScheme: .dated)
    #expect(c.build == "1.0.0.2026101501")
    #expect(c.buildScheme == .dated)
}

@Test(arguments: ["1.0.0.2026101500", "1.0.0.1999101501", "1.0.0", "1.0.0.202610150", "2026101501", "1.0.1.2026101501", "1.0.2026101501"])
func datedBuildSchemeRejectsBadBuild(build: String) {
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: validYAML, buildOverride: build, buildScheme: .dated) }
}

@Test func fixedBuildSchemeRejectsDatedBuild() {
    #expect(throws: XlessError.self) { try ProjectConfig.parse(yaml: validYAML, buildOverride: "1.0.0.2026101501") }
}

// MARK: - App extensions (#143)

private func withExtensions(_ list: String, platform: String = "ios") -> String {
    """
    bundleID: com.example.app
    teamID: ABCDE12345
    version: 1.0.0
    build: 1
    platforms:
      \(platform):
        minimumOS: "17.0"
        product: App
        extensions:
    \(list)
    """
}

@Test func iosExtensionsAreDeclaredWithTheirBundleIDsAndEntitlements() throws {
    let c = try ProjectConfig.parse(yaml: withExtensions("""
          - { path: PlugIns/Widget.appex, bundleID: com.example.app.widget, entitlements: Widget.entitlements }
          - { path: Extensions/Share.appex, bundleID: com.example.app.share }
    """))
    #expect(try c.platform(.ios).extensions == [ExtensionConfig(path: "PlugIns/Widget.appex", bundleID: "com.example.app.widget", entitlements: "Widget.entitlements"),
                                                ExtensionConfig(path: "Extensions/Share.appex", bundleID: "com.example.app.share")])
    #expect(try ProjectConfig.parse(yaml: validYAML).platform(.ios).extensions.isEmpty)
}

@Test(arguments: [
    ("      - { path: Widget.appex, bundleID: com.example.app.widget }", "ios", "is not an app extension in the app"),
    ("      - { path: PlugIns/Wid:get.appex, bundleID: com.example.app.widget }", "ios", "is not an app extension in the app"),
    ("      - { path: PlugIns/Widget.appex, bundleID: com.other.widget }", "ios", "is not under the app's com.example.app"),
    ("      - { path: PlugIns/A.appex, bundleID: com.example.app.a }\n      - { path: PlugIns/A.appex, bundleID: com.example.app.b }", "ios", "lists PlugIns/A.appex twice"),
    ("      - { path: PlugIns/A.appex, bundleID: com.example.app.a }\n      - { path: PlugIns/B.appex, bundleID: com.example.app.a }", "ios", "gives com.example.app.a to two extensions"),
    ("      - { path: PlugIns/A.appex, bundleID: com.example.app.a }", "macos", "only an iOS app's extensions"),
])
func badExtensionsAreConfigErrors(list: String, platform: String, needle: String) {
    #expect { _ = try ProjectConfig.parse(yaml: withExtensions(list, platform: platform)) } throws: {
        guard let e = $0 as? XlessError else { return false }
        return e.stage == .config && e.cause.contains(needle) && e.cause.contains("platforms.\(platform).extensions")
    }
}

private func yaml(_ extra: String) -> String {
    "bundleID: com.example.app\nteamID: ABCDE12345\nversion: \"1.0\"\nbuild: 1\nplatforms:\n  ios: { minimumOS: \"17.0\", product: X }\n\(extra)\n"
}

@Test func provisioningUpdatesAreOnUnlessTheConfigSaysNot() throws {
    #expect(try ProjectConfig.parse(yaml: yaml("")).provisioningUpdates)
    #expect(try ProjectConfig.parse(yaml: yaml("provisioningUpdates: true")).provisioningUpdates)
    #expect(try !ProjectConfig.parse(yaml: yaml("provisioningUpdates: false")).provisioningUpdates)
    #expect(throws: XlessError.self) { _ = try ProjectConfig.parse(yaml: yaml("provisioningUpdates: \"no\"")) }
}

/// A restriction that is misspelt would be dropped silently (xless.yml ignores keys it does not know): refused.
@Test(arguments: ["provisioningUpdate: false", "provisioning_updates: false", "ProvisioningUpdates: false", "noProvisioningUpdates: true", "provisioning: false",
                  "provisionUpdates: false", "provisionning-updates: false", "provisoningUpdates: false", "povisioningUpdates: false", "prvsioningUpdates: false",
                  "provUpdates: false", "noProvisionUpdates: true", "allowProvisioningUpdates: false", "\"provisioningUpdates \": false", "7: a\nprovisionUpdates: false"])
func aMisspeltProvisioningUpdatesIsRefused(line: String) {
    #expect { _ = try ProjectConfig.parse(yaml: yaml(line)) } throws: {
        ($0 as? XlessError)?.stage == .config && ($0 as? XlessError)?.fix == "write it as provisioningUpdates: false"
    }
}

/// A restriction without a value is not "unset": whoever wrote the key meant something by it.
@Test(arguments: ["provisioningUpdates:", "provisioningUpdates: null", "provisioningUpdates: ~", "provisioningUpdates: # false",
                  "x: &x ~\nprovisioningUpdates: *x"])
func aProvisioningUpdatesWithoutAValueIsRefused(line: String) {
    #expect { _ = try ProjectConfig.parse(yaml: yaml(line)) } throws: {
        ($0 as? XlessError)?.stage == .config && ($0 as? XlessError)?.cause == "xless.yml: provisioningUpdates has no value"
            && ($0 as? XlessError)?.fix == "write it as provisioningUpdates: false"
    }
}

/// Only the top level is read: anywhere else the restriction would be dropped silently.
@Test func aMisplacedProvisioningUpdatesIsRefused() {
    func refused(_ yaml: String, _ cause: String, _ fix: String = "write it at the top level, as provisioningUpdates: false") {
        #expect { _ = try ProjectConfig.parse(yaml: yaml) } throws: {
            ($0 as? XlessError)?.stage == .config && ($0 as? XlessError)?.cause == cause && ($0 as? XlessError)?.fix == fix
        }
    }
    let base = "bundleID: com.example.app\nteamID: ABCDE12345\nversion: \"1.0\"\nbuild: 1\n"
    refused(base + "platforms:\n  ios: { minimumOS: \"17.0\", product: X, provisioningUpdates: false }\n", "xless.yml: platforms.ios.provisioningUpdates is not read")
    refused(yaml("testflight: { provisioningUpdates: false }"), "xless.yml: testflight.provisioningUpdates is not read")
    refused(yaml("x: [1, { y: { provisioningUpdates: ~ } }]"), "xless.yml: x[1].y.provisioningUpdates is not read")
    refused(yaml("x: &x { provisioningUpdates: false }\n<<: *x"), "xless.yml: x.provisioningUpdates is not read")
    refused(yaml("testflight: { provisionUpdates: false }"), "xless.yml: unknown key 'testflight.provisionUpdates'", "write it as provisioningUpdates: false")
    // Twice is not a choice between the two.
    #expect(throws: XlessError.self) { _ = try ProjectConfig.parse(yaml: yaml("provisioningUpdates: false\nprovisioningUpdates: true")) }
}

@Test func onlyWhatReadsLikeProvisioningUpdatesIsRefused() throws {
    // A key of one's own, and the names a map leaves to the person.
    #expect(try ProjectConfig.parse(yaml: yaml("x-note: provisioning\nupdates: weekly\nprofile: a")).provisioningUpdates)
    let names = "a:\n  env: { PROVISIONING_UPDATES: \"1\", provisioning: a }\n  plistVars: { PROVISIONING: a }\n  scripts: { provision: run }\n  bundleIDs: { Provisioning: a.b }\n  replace: { provisioning.x: y }\n"
    try ProvisioningUpdates.check(yaml: names, file: "overlay a")
    #expect { try ProvisioningUpdates.check(yaml: "env: { provisioningUpdates: \"false\" }\n", file: "overlay a") } throws: {
        ($0 as? XlessError)?.cause == "overlay a: env.provisioningUpdates is not read"
    }
}

@Test func anErrorsExitCodeIsItsStagesUnlessItHasItsOwn() {
    #expect(XlessError(.sign, "a", fix: "b").exitCode == 15)
    let e = XlessError(.sign, "a", fix: "b", code: XlessError.provisioningNeeded)
    #expect(e.exitCode == 24 && e.description == "[sign] a — b" && XlessError.wrapping(e, stage: .sign) == e)
    #expect(Stage.allCases.allSatisfy { $0.exitCode != XlessError.provisioningNeeded })
}
