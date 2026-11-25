import Foundation
import Testing
@testable import XlessCore

private func settings(_ yaml: String?) throws -> UnlockSettings {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unlock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("xless"), withIntermediateDirectories: true)
    if let yaml { try Data(yaml.utf8).write(to: dir.appendingPathComponent("xless/config.yml")) }
    return try UserConfig.unlockSettings(env: ["XDG_CONFIG_HOME": dir.path])
}

private let hour = 3600, day = 86400

@Test func durationsAreSecondsMinutesHoursOrDays() {
    for (text, seconds) in [("30m", 1800), ("1h", 3600), ("90", 90), ("90s", 90), ("8h", 28800), ("7d", 604_800), (" 2D ", 172_800)] {
        #expect(HoldDuration.seconds(text) == seconds, "\(text)")
    }
    for bad in ["0", "0h", "", "m", "-5s", "1.5h", "٣m", "8d", "169h", "604801", "99999999999999999999d", "1w", "h8", "8 h x"] {
        #expect(HoldDuration.seconds(bad) == nil, "\(bad)")
    }
}

@Test func durationsArePrintedShort() {
    for (seconds, text) in [(45, "45 s"), (1800, "30 min"), (3600, "1 h"), (5400, "1 h 30 min"), (28800, "8 h"), (604_800, "7 days"), (90_000, "1 day 1 h")] {
        #expect(HoldDuration.text(seconds) == text)
    }
}

@Test func anUnlockIsHeldEightHoursAndIdleTwoByDefault() throws {
    for yaml in [nil, "", "team: ABCDE12345", "unlock: {}"] {
        #expect(try settings(yaml) == UnlockSettings(duration: 8 * hour, idle: 2 * hour, maximum: 7 * day, lockOnSleep: true, lockOnScreenLock: true))
    }
}

@Test func theSettingsComeFromConfigYml() throws {
    let s = try settings("unlock: { duration: 4h, idle: 30m, maximum: 1d, lockOnSleep: false, lockOnScreenLock: false }")
    #expect(s == UnlockSettings(duration: 4 * hour, idle: 1800, maximum: day, lockOnSleep: false, lockOnScreenLock: false))
    #expect(try settings("unlock: { maximum: 1h }").duration == hour) // the defaults stay within the maximum
    #expect(try settings("unlock: { maximum: 1h }").idle == hour)
    #expect(try settings("unlock: { duration: 30m }").idle == 1800)
    #expect(try settings("unlock: { duration: 600 }").duration == 600) // seconds
}

@Test(arguments: ["unlock: 8h", "unlock: { durations: 8h }", "unlock: { duration: 8d }", "unlock: { maximum: 30d }", "unlock: { duration: soon }",
                  "unlock: { duration: 2h, maximum: 1h }", "unlock: { idle: 0 }", "unlock: { lockOnSleep: maybe }", "unlock: { duration: [1h] }",
                  "unlock: { idle: 9h, maximum: 8h }"])
func aMalformedSettingIsAnErrorNeverADefault(yaml: String) {
    let error = #expect(throws: XlessError.self) { try settings(yaml) }
    #expect(error?.stage == .config)
    #expect(error?.cause.contains("unlock") == true)
}

@Test func aHoldIsWhatIsAskedWithinTheMaximum() throws {
    let s = UnlockSettings(duration: 8 * hour, idle: 2 * hour, maximum: day)
    #expect(try s.hold(nil, option: "--for", stage: .config) == SecretHold(seconds: 8 * hour, idle: 2 * hour, maximum: day))
    #expect(try s.hold("default", option: "--keep", stage: .config).seconds == 8 * hour)
    #expect(try s.hold("30m", option: "--for", stage: .config) == SecretHold(seconds: 1800, idle: 1800, maximum: day)) // never idle past its end
    #expect(try s.hold("1d", idle: "1d", option: "--for", stage: .config).idle == day)
    for (text, idle) in [("25h", nil), ("8d", nil), ("x", nil), ("", nil), ("1h", "x"), ("1h", "25h")] as [(String, String?)] {
        let error = #expect(throws: XlessError.self) { try s.hold(text, idle: idle, option: "--keep", stage: .account) }
        #expect(error?.stage == .account)
        #expect(error?.cause.contains(idle == nil ? "--keep" : "--idle") == true)
    }
    // The lowered maximum is named, with where it comes from.
    let error = #expect(throws: XlessError.self) { try s.hold("25h", option: "--keep", stage: .account) }
    #expect(error?.fix.contains("24 h") == true || error?.fix.contains("1 day") == true)
    #expect(error?.fix.contains("config.yml") == true)
}

@Test func anOptionWithoutADurationTakesTheDefault() {
    func f(_ a: [String]) -> [String] { HoldArguments.withDefaults(["xless"] + a).dropFirst().map { $0 } }
    #expect(f(["auth", "login", "--keep"]) == ["auth", "login", "--keep", "default"])
    #expect(f(["auth", "login", "--keep", "--verbose"]) == ["auth", "login", "--keep", "default", "--verbose"])
    #expect(f(["auth", "login", "--keep", "30m"]) == ["auth", "login", "--keep", "30m"])
    #expect(f(["auth", "login", "--keep=30m"]) == ["auth", "login", "--keep=30m"])
    #expect(f(["secrets", "unlock", "--remember"]) == ["secrets", "unlock", "--remember", "default"])
    #expect(f(["secrets", "import", "A", "--remember", "--file", "x"]) == ["secrets", "import", "A", "--remember", "default", "--file", "x"])
    #expect(f(["secrets", "rm", "--", "--remember"]) == ["secrets", "rm", "--", "--remember"])
    #expect(f(["api", "GET", "--keep"]) == ["api", "GET", "--keep"])
    #expect(f([]) == [])
}

@Test func whetherToOfferToKeepIsASettingAndAskingIsTheDefault() throws {
    #expect(try settings(nil).keep == .ask)
    #expect(try settings("unlock: { duration: 1h }").keep == .ask)
    for (text, keep) in [("ask", KeepAnswer.ask), ("always", .always), ("never", .never)] {
        #expect(try settings("unlock: { keep: \(text) }").keep == keep)
    }
    for bad in ["yes", "sometimes", "1", "[always]"] {
        let error = #expect(throws: XlessError.self) { try settings("unlock: { keep: \(bad) }") }
        #expect(error?.cause.contains("unlock.keep") == true)
        #expect(error?.fix.contains("keep") == true)
    }
}
