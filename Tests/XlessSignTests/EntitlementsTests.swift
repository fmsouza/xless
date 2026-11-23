import Testing
import Foundation
@testable import XlessSign
@testable import XlessCore

func fakeProfile(_ ents: [String: Any]) throws -> Data {
    let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ents, "Name": "p"], format: .xml, options: 0)
    return Data([0x30, 0x82, 0x01, 0x00]) + plist + Data([0x00, 0xa0])   // CMS wrapper bytes around the XML
}

@Test func extractsEntitlementsFromCMS() throws {
    let e = try Entitlements.extract(fromProfile: fakeProfile(["beta-reports-active": true, "application-identifier": "T.a.b"]))
    #expect(e["beta-reports-active"] as? Bool == true)
}

@Test func mergeIOSAppStore() throws {
    let profile: [String: Any] = ["application-identifier": "ABCDE12345.a.b", "beta-reports-active": true,
                                  "com.apple.developer.team-identifier": "ABCDE12345", "get-task-allow": false,
                                  "keychain-access-groups": ["ABCDE12345.*"]]
    let m = try Entitlements.merge(user: [:], profile: profile, platform: .ios, teamID: "ABCDE12345", bundleID: "a.b")
    #expect(m["application-identifier"] as? String == "ABCDE12345.a.b")
    #expect(m["com.apple.developer.team-identifier"] as? String == "ABCDE12345")
    #expect(m["get-task-allow"] as? Bool == false)
    #expect(m["beta-reports-active"] as? Bool == true)
    #expect(m["keychain-access-groups"] == nil)
}

@Test func userEntitlementNotInProfileFails() throws {
    do {
        _ = try Entitlements.merge(user: ["aps-environment": "production"], profile: ["application-identifier": "ABCDE12345.a.b"],
                                   platform: .ios, teamID: "ABCDE12345", bundleID: "a.b")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .sign)
        #expect(e.description.contains("aps-environment"))
    }
}

@Test func userEntitlementGrantedByProfilePasses() throws {
    let m = try Entitlements.merge(user: ["aps-environment": "production"],
                                   profile: ["application-identifier": "ABCDE12345.a.b", "aps-environment": "production"],
                                   platform: .ios, teamID: "ABCDE12345", bundleID: "a.b")
    #expect(m["aps-environment"] as? String == "production")
}

@Test func mergeMacDeveloperID() throws {
    let m = try Entitlements.merge(user: [:], profile: ["com.apple.application-identifier": "ABCDE12345.a.b"],
                                   platform: .macos, teamID: "ABCDE12345", bundleID: "a.b")
    #expect(m["com.apple.application-identifier"] as? String == "ABCDE12345.a.b")
    #expect(m["com.apple.developer.team-identifier"] as? String == "ABCDE12345")
    #expect(m["get-task-allow"] == nil)
}

@Test func userBetaReportsIgnoredWhenProfileLacksIt() throws {
    let m = try Entitlements.merge(user: ["beta-reports-active": true], profile: ["application-identifier": "T.a.b"],
                                   platform: .ios, teamID: "T", bundleID: "a.b")
    #expect(m["beta-reports-active"] == nil)
}

@Test func userGetTaskAllowForcedFalseOnIOS() throws {
    let m = try Entitlements.merge(user: ["get-task-allow": true], profile: [:], platform: .ios, teamID: "T", bundleID: "a.b")
    #expect(m["get-task-allow"] as? Bool == false)
}

@Test func userGetTaskAllowDroppedOnMac() throws {
    let m = try Entitlements.merge(user: ["get-task-allow": true, "beta-reports-active": true], profile: [:],
                                   platform: .macos, teamID: "T", bundleID: "a.b")
    #expect(m["get-task-allow"] == nil && m["beta-reports-active"] == nil)
}

@Test func applicationGroupsRequireProfile() throws {
    do {
        _ = try Entitlements.merge(user: ["com.apple.security.application-groups": ["group.x"]], profile: [:],
                                   platform: .macos, teamID: "T", bundleID: "a.b")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.description.contains("application-groups"))
    }
}

@Test func ungatedSecurityKeysPass() throws {
    let m = try Entitlements.merge(user: ["com.apple.security.cs.allow-jit": true, "com.apple.security.app-sandbox": true,
                                          "com.apple.security.network.client": true], profile: [:],
                                   platform: .macos, teamID: "T", bundleID: "a.b")
    #expect(m["com.apple.security.cs.allow-jit"] as? Bool == true)
}

@Test func profileTeamFallsBackToApplicationIdentifierPrefix() throws {
    #expect(Entitlements.team(ofProfile: ["application-identifier": "QWERT12345.a.b"]) == "QWERT12345")
    #expect(Entitlements.team(ofProfile: ["com.apple.application-identifier": "QWERT12345.a.b"]) == "QWERT12345")
    #expect(Entitlements.team(ofProfile: ["com.apple.developer.team-identifier": "TEAM000001", "application-identifier": "X.a.b"]) == "TEAM000001")
    #expect(throws: XlessError.self) { try Entitlements.checkTeam(profile: ["application-identifier": "QWERT12345.a.b"], teamID: "ABCDE12345") }
    #expect(throws: Never.self) { try Entitlements.checkTeam(profile: ["application-identifier": "ABCDE12345.a.b"], teamID: "ABCDE12345") }
}

@Test func macPushTakesTheProfilesEnvironment() throws {
    let m = try Entitlements.merge(user: ["com.apple.developer.aps-environment": "development"],
                                   profile: ["com.apple.application-identifier": "T.a.b", "com.apple.developer.aps-environment": "production"],
                                   platform: .macos, teamID: "T", bundleID: "a.b")
    #expect(m["com.apple.developer.aps-environment"] as? String == "production")
}

@Test func merchantIDsAndICloudContainersMustBeInTheProfile() throws {
    let profile: [String: Any] = ["com.apple.developer.in-app-payments": ["merchant.com.a"], "com.apple.developer.icloud-container-identifiers": ["iCloud.a.b"]]
    for platform in Platform.allCases {
        #expect(Entitlements.problems(user: ["com.apple.developer.in-app-payments": ["merchant.com.a"], "com.apple.developer.icloud-container-identifiers": ["iCloud.a.b"]],
                                      profile: profile, platform: platform).isEmpty)
        #expect(Entitlements.problems(user: ["com.apple.developer.in-app-payments": ["merchant.com.b"]], profile: profile, platform: platform)
                == [.notAllowed(key: "com.apple.developer.in-app-payments", values: ["merchant.com.b"], allowed: ["merchant.com.a"])])
    }
    do {
        _ = try Entitlements.merge(user: ["com.apple.developer.in-app-payments": ["merchant.com.b"]], profile: profile, platform: .macos, teamID: "T", bundleID: "a.b")
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.fix.hasPrefix("(1) register the merchant ID with `xless merchant-ids create <identifier> --name <name>` (merchant.com.b; skip one that exists)"))
        #expect(e.fix.contains("a.b → Apple Pay Payment Processing → Edit → select merchant.com.b → Save"))
    }
}
