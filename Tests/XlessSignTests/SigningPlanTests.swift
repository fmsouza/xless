import Testing
import Foundation
@testable import XlessSign
@testable import XlessASC
@testable import XlessCore

let future = "2099-01-01T00:00:00.000+0000"

private let bundle = "com.example.app"
private let name = "xless com.example.app IOS_APP_STORE"
private let push = ["aps-environment": "production"]

/// One iOS App Store app on a fake account, planned and applied as `sign` does.
private struct Signing {
    let asc = FakeASC(certificateJSON: "{}")
    var entitlements: [String: Any] = [:]
    var now = ISO8601DateFormatter().date(from: "2026-11-25T00:00:00Z")!
    var platform = Platform.ios, distribution = Distribution.appStore

    var account: APISigningAccount {
        APISigningAccount(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: asc, sleep: { _ in })), stage: .sign)
    }
    var target: SigningTarget { SigningTarget(platform: platform, distribution: distribution, bundleID: bundle, entitlements: entitlements) }
    func plan() async throws -> SigningPlan { try await SigningPlanner(account: account, now: now).plan([target], certificate: "C1") }
    func apply(_ plan: SigningPlan) async throws -> [Data] { try await SigningApplier(account: account).apply(plan) }

    /// The identifier registered, with its profile.
    func registered(capabilities: [String] = [], profile: Bool = true, _ change: (inout FakeASC.Profile) -> Void = { _ in }) throws {
        asc.bundleIDs[bundle] = "B0"
        asc.capabilities["B0"] = capabilities
        guard profile else { return }
        var p = FakeASC.Profile(id: "P0", name: name, bundleResource: "B0", content: try fakeProfile(asc.entitlements(of: bundle)))
        change(&p)
        asc.profiles = [p]
    }
    var writes: [String] { asc.log.filter { !$0.hasPrefix("GET ") } }
}

@Test func nothingIsPlannedWhenTheAccountHasWhatSigningNeeds() async throws {
    var s = Signing()
    s.entitlements = push
    try s.registered(capabilities: ["PUSH_NOTIFICATIONS", "IN_APP_PURCHASE"])
    let plan = try await s.plan()
    #expect(plan.changes.isEmpty)
    #expect(plan.text == "xless: sign: the account has what signing needs; nothing is changed there")
    #expect(try await s.apply(plan) == [s.asc.profiles[0].content])
    #expect(s.writes.isEmpty)
}

@Test func aNewIdentifierIsPlannedThenRegisteredEnabledAndGivenAProfile() async throws {
    var s = Signing()
    s.entitlements = push
    let plan = try await s.plan()
    #expect(s.writes.isEmpty)   // planning only reads
    #expect(plan.changes == [
        "register bundle ID com.example.app as universal (iOS and macOS), named \"xless com example app\"",
        "enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app",
        "create profile \(name) (iOS App Store Connect for the iOS app, with certificate C1)",
    ])
    #expect(plan.text.hasPrefix("xless: sign: 3 changes on the account:\n  register bundle ID "))
    let profiles = try await s.apply(plan)
    #expect(s.writes == ["POST /v1/bundleIds", "POST /v1/bundleIdCapabilities", "POST /v1/profiles"])
    #expect(try Entitlements.extract(fromProfile: profiles[0])["aps-environment"] as? String == "production")
    #expect(try await s.plan().changes.isEmpty)   // a second run changes nothing
}

/// One identifier serves both the iOS and the macOS build, and App Store Connect takes ASCII letters, digits and spaces
/// only in a bundle ID's name.
@Test(arguments: Platform.allCases)
func newIdentifiersAreUniversalWithANameAppleTakes(platform: Platform) async throws {
    let t = MockTransport([(200, #"{"data":[]}"#), (201, #"{"data":{"type":"bundleIds","id":"NEW","attributes":{"identifier":"com.example.helloship"}}}"#)])
    let account = APISigningAccount(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })), stage: .sign)
    #expect(try await account.register(bundleID: "com.example.helloship") == "NEW")
    let json = try JSONSerialization.jsonObject(with: t.requests[1].httpBody!) as! [String: Any]
    #expect((json["data"] as! [String: Any])["attributes"] as? [String: String]
        == ["identifier": "com.example.helloship", "name": "xless com example helloship", "platform": "UNIVERSAL"])
}

@Test func bundleIDNamesAreCollapsedAndBounded() {
    #expect(PortalName.bundleID(for: "a..b-_c") == "xless a b c")
    #expect(PortalName.bundleID(for: "é.ü").allSatisfy { $0.isASCII })
    #expect(PortalName.bundleID(for: String(repeating: "a.", count: 400)).count <= 255)
}

@Test func anIdentifierTheFilterMatchesLooselyIsNotTaken() async throws {
    let t = MockTransport([(200, #"{"data":[{"type":"bundleIds","id":"B2","attributes":{"identifier":"a.b.c"}},{"type":"bundleIds","id":"B1","attributes":{"identifier":"a.b"}}]}"#)])
    let account = APISigningAccount(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })), stage: .sign)
    #expect(try await account.bundleID("a.b") == "B1")
}

/// Each reason the profile cannot be signed with, as the plan says it; the profile is then replaced.
@Test func aProfileThatCannotBeUsedIsReplacedAndThePlanSaysWhy() async throws {
    func check(_ why: String, _ change: (inout FakeASC.Profile) -> Void) async throws {
        let s = Signing()
        try s.registered(change)
        let plan = try await s.plan()
        #expect(plan.changes == ["replace profile \(name) (P0, which xless made): \(why)"])
        let profiles = try await s.apply(plan)
        #expect(s.writes == ["DELETE /v1/profiles/P0", "POST /v1/profiles"], "\(why)")
        #expect(s.asc.profiles.count == 1 && s.asc.profiles[0].id != "P0" && profiles == [s.asc.profiles[0].content])
    }
    try await check("it is INVALID") { $0.state = "INVALID" }
    try await check("it expires on 2026-11-29") { $0.expires = "2026-11-29T00:00:00.000+0000" }
    try await check("it expires on 2026-10-01") { $0.expires = "2026-10-01T00:00:00.000+0000" }
    try await check("App Store Connect gives no expiry date for it") { $0.expires = "soon" }
    try await check("it does not hold the Apple Distribution certificate C1") { $0.certificates = ["OLD"] }
    try await check("it is for another bundle ID") { $0.bundleResource = "OTHER" }
    try await check("App Store Connect gives no content for it") { $0.content = Data() }
}

/// What App Store Connect does not say is not taken for good: neither the day it expires nor whose profile it is.
@Test func aProfileThatDoesNotSayWhenItExpiresOrWhoseItIsIsNotUsable() throws {
    let target = SigningTarget(platform: .ios, distribution: .appStore, bundleID: bundle, entitlements: [:])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func problems(expires: Date?, bundleID: String?) -> [String] {
        target.problems(of: SigningProfile(id: "P", name: name, type: "IOS_APP_STORE", state: "ACTIVE", expires: expires, bundleID: bundleID,
                                           certificateIDs: ["C1"]), bundle: "B0", certificate: "C1", now: now)
    }
    let later = now.addingTimeInterval(300 * 86_400)
    #expect(problems(expires: later, bundleID: "B0") == [])
    #expect(problems(expires: nil, bundleID: "B0") == ["App Store Connect gives no expiry date for it"])
    #expect(problems(expires: later, bundleID: nil) == ["App Store Connect gives no bundle ID for it"])
    #expect(problems(expires: nil, bundleID: nil).count == 2)
}

/// What a terminal or a reader could be misled by, in a value that the project, the built app or Apple chose.
private let hostile = "\u{1B}[2J\u{1B}[H\r\n  nothing is changed\u{9B}K\u{7F}\u{202E}\u{200B}\u{2028}"

private func isPlain(_ text: String) -> Bool { TerminalText.escaped(text) == text }

/// The plan is what the person reads before the account is changed: nothing in it can clear, hide or forge a line.
@Test func nothingInThePlanOrItsRefusalDrivesTheTerminal() throws {
    let request = CapabilityRequest(.pushNotifications)
    func target(_ ents: [String: Any] = [:]) -> SigningTarget {
        SigningTarget(platform: .ios, distribution: .appStore, bundleID: "com.example.app.\(hostile)", entitlements: ents,
                      extensionPath: "PlugIns/W\(hostile).appex")
    }
    let old = SigningProfile(id: "P\(hostile)", name: "n", type: "IOS_APP_STORE", state: hostile, expires: nil, bundleID: "B0", certificateIDs: [],
                             content: try fakeProfile([:]))
    let lacking = target(["com.example.\(hostile)": true])
    let reasons = lacking.problems(of: old, bundle: "B0", certificate: "C\(hostile)", now: Date())
    #expect(reasons.contains { $0.hasPrefix("it is ") } && reasons.contains { $0.hasPrefix("it lacks ") } && reasons.contains { $0.contains("certificate C") })
    let plan = SigningPlan(items: [.init(target: target(), bundle: nil, enable: [request], profile: .create),
                                   .init(target: lacking, bundle: "B0", enable: [], profile: .replace([old], reasons: reasons))], certificate: "C\(hostile)")
    #expect(plan.changes.count == 4)
    for change in plan.changes { #expect(isPlain(change), "\(change)") }
    #expect(plan.text.split(separator: "\n", omittingEmptySubsequences: false).count == 5)
    #expect(isPlain(plan.text.replacingOccurrences(of: "\n", with: " ")))
    #expect(plan.text.contains(#"for PlugIns/W\u{1B}[2J\u{1B}[H\u{D}\u{A}  nothing is changed\u{9B}K\u{7F}\u{202E}\u{200B}\u{2028}.appex, with certificate C\u{1B}"#))
    do { try plan.requireNothing(off: "--no-provisioning-updates"); Issue.record("expected throw") }
    catch let e as XlessError { #expect(isPlain(e.cause) && isPlain(e.fix) && e.exitCode == 24) }
}

@Test func aProfileWithMoreThanAWeekLeftIsKept() async throws {
    let s = Signing()
    try s.registered { $0.expires = "2026-12-03T00:00:00.000+0000" }
    #expect(try await s.plan().changes.isEmpty)
}

@Test func aProfileFromBeforeACapabilityIsReplaced() async throws {
    var s = Signing()
    s.entitlements = push
    try s.registered()
    let plan = try await s.plan()
    #expect(plan.changes == ["enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app",
                             "replace profile \(name) (P0, which xless made): it does not carry PUSH_NOTIFICATIONS, enabled above"])
    _ = try await s.apply(plan)
    #expect(s.writes == ["POST /v1/bundleIdCapabilities", "DELETE /v1/profiles/P0", "POST /v1/profiles"])
}

@Test func aProfileFromBeforeACapabilityEnabledByHandIsReplaced() async throws {
    var s = Signing()
    s.entitlements = [appAttest: "production"]
    try s.registered()
    s.asc.portal[bundle] = [appAttest: "production"]
    let plan = try await s.plan()
    #expect(plan.changes == ["replace profile \(name) (P0, which xless made): it lacks \(appAttest)"])
    #expect(try Entitlements.extract(fromProfile: try await s.apply(plan)[0])[appAttest] as? String == "production")
}

/// A keychain group outside the team's pattern is not something a new profile changes.
@Test func aKeychainGroupIsNoReasonToReplaceAProfile() async throws {
    var s = Signing()
    s.entitlements = ["keychain-access-groups": ["OTHERTEAM1.group"]]
    try s.registered()
    #expect(try await s.plan().changes.isEmpty)
}

/// The settings of a capability that is enabled are never changed by `sign` (`provision` manages the Data Protection level).
@Test func anEnabledCapabilityIsLeftAsItIs() async throws {
    var s = Signing()
    s.entitlements = ["com.apple.developer.default-data-protection": "NSFileProtectionNone"]
    try s.registered(capabilities: ["DATA_PROTECTION"], profile: false)
    let plan = try await s.plan()
    #expect(plan.changes.map { $0.prefix(14) } == ["create profile"])
    _ = try await s.apply(plan)
    #expect(s.writes == ["POST /v1/profiles"])
}

/// App Store Connect enables some capabilities itself on a new identifier: they are not enabled again.
@Test func aCapabilityAppleEnabledOnANewIdentifierIsNotSentAgain() async throws {
    var s = Signing()
    s.entitlements = push
    let plan = try await s.plan()
    s.asc.enabledByApple = ["PUSH_NOTIFICATIONS"]
    _ = try await s.apply(plan)
    #expect(s.writes == ["POST /v1/bundleIds", "POST /v1/profiles"])
}

@Test func onlyProfilesNamedAsXlessNamesItsOwnAreDeleted() async throws {
    let s = Signing()
    try s.registered { $0.certificates = ["OLD"] }
    s.asc.profiles.append(FakeASC.Profile(id: "MINE", name: "my profile", bundleResource: "B0", content: Data()))
    _ = try await s.apply(try await s.plan())
    #expect(s.writes == ["DELETE /v1/profiles/P0", "POST /v1/profiles"])
    #expect(s.asc.profiles.contains { $0.id == "MINE" })
}

/// Several profiles of the name: one that can be used is used, and nothing is deleted.
@Test func aUsableProfileNextToAnUnusableOneIsUsed() async throws {
    let s = Signing()
    try s.registered { $0.certificates = ["OLD"] }
    s.asc.profiles.append(FakeASC.Profile(id: "P9", name: name, bundleResource: "B0", content: try fakeProfile(["x": true])))
    let plan = try await s.plan()
    #expect(plan.changes.isEmpty)
    #expect(try await s.apply(plan) == [try fakeProfile(["x": true])])
}

// MARK: - A create whose answer is lost

@Test func aLostAnswerToACreateIsLookedUpNotSentAgain() async throws {
    var s = Signing()
    s.entitlements = push
    s.asc.failures = ["POST /v1/bundleIds": [(500, true)], "POST /v1/profiles": [(500, true)]]
    _ = try await s.apply(try await s.plan())
    #expect(s.writes == ["POST /v1/bundleIds", "POST /v1/bundleIdCapabilities", "POST /v1/profiles"])
    #expect(s.asc.profiles.count == 1)
}

@Test func aFailedCreateIsSentAgainAfterReadingShowsNothingWasMade() async throws {
    let s = Signing()
    try s.registered { $0.certificates = ["OLD"] }
    s.asc.failures = ["POST /v1/profiles": [(500, false), (503, false)]]
    _ = try await s.apply(try await s.plan())
    #expect(s.writes == ["DELETE /v1/profiles/P0", "POST /v1/profiles", "POST /v1/profiles", "POST /v1/profiles"])
    #expect(s.asc.log.suffix(5) == ["POST /v1/profiles", "GET /v1/profiles", "POST /v1/profiles", "GET /v1/profiles", "POST /v1/profiles"])
}

/// A listing may show a deleted profile a little longer: it is never taken for the new one.
@Test func aDeletedProfileStillListedIsNotTakenForTheNewOne() async throws {
    let s = Signing()
    try s.registered { $0.state = "INVALID" }
    s.asc.keepsDeleted = true
    s.asc.failures = ["POST /v1/profiles": [(409, false)]]
    do { _ = try await s.apply(try await s.plan()); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign && e.cause.hasPrefix("cannot create IOS_APP_STORE profile for com.example.app: App Store Connect HTTP 409"))
        #expect(e.fix == "check the bundle ID and certificate in App Store Connect")
    }
}

@Test func aRefusedMacProfilePointsAtTheIdentifiersPlatform() async throws {
    var s = Signing()
    (s.platform, s.distribution) = (.macos, .developerID)
    try s.registered(profile: false)
    s.asc.failures = ["POST /v1/profiles": [(409, false)]]
    do { _ = try await s.apply(try await s.plan()); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix.contains("registered for iOS only")) }
}

@Test func aRefusedCapabilityIsExplained() async throws {
    var s = Signing()
    s.entitlements = push
    try s.registered()
    s.asc.refuse = ["PUSH_NOTIFICATIONS"]
    do { _ = try await s.apply(try await s.plan()); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .sign && e.cause.hasPrefix("App Store Connect refused to enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app: "))
        #expect(e.fix.contains("Apple's approval"))
    }
    #expect(!s.writes.contains("DELETE /v1/profiles/P0"))   // nothing is replaced for a capability that could not be enabled
}

@Test func aProfileWithoutContentIsRefused() async throws {
    let t = MockTransport([(201, #"{"data":{"type":"profiles","id":"P2","attributes":{"name":"n"}}}"#)])
    let account = APISigningAccount(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })), stage: .sign)
    let plan = SigningPlan(items: [.init(target: Signing().target, bundle: "B1", enable: [], profile: .create)], certificate: "C1")
    do { _ = try await SigningApplier(account: account).apply(plan); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause == "App Store Connect returned a profile without content") }
}

/// A response without the bundle ID's linkage is not taken for a match: the relationship is read.
@Test func aProfilesBundleIDIsReadWhenTheAnswerDoesNotSayIt() async throws {
    let p = #""attributes":{"name":"n","profileType":"IOS_APP_STORE"}"#
    let t = MockTransport([(200, #"{"data":[{"type":"profiles","id":"P1",\#(p)}]}"#), (200, #"{"data":{"type":"profiles","id":"P1",\#(p)}}"#),
                           (200, #"{"data":{"type":"bundleIds","id":"B7"}}"#), (200, #"{"data":[]}"#)])
    let account = APISigningAccount(resources: ASCResources(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in })), stage: .sign)
    #expect(try await account.profiles(named: "n", type: .iosAppStore).map(\.bundleID) == ["B7"])
    #expect(t.requests[0].url!.absoluteString.contains("filter%5BprofileType%5D=IOS_APP_STORE"))
}

@Test func profileTypeFollowsPlatformAndDistribution() {
    #expect(ProfileType.for(platform: .ios, distribution: .appStore) == .iosAppStore)
    #expect(ProfileType.for(platform: .macos, distribution: .developerID) == .macAppDirect)
    #expect(ProfileType.for(platform: .macos, distribution: .appStore) == .macAppStore)
    #expect(ProfileType.macAppStore.rawValue == "MAC_APP_STORE")
    #expect(SigningProfile.name(bundleID: "a.b", type: .iosAppAdHoc) == "xless a.b IOS_APP_ADHOC")
}
