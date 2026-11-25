import Foundation

/// How long a secret is held for later commands (`xless unlock`, `--remember`, `--keep`).
public struct SecretHold: Sendable, Equatable {
    /// From now.
    public var seconds: Int
    /// Dropped after this long without being used.
    public var idle: Int
    /// The longest it may be held, renewals included, since the secret was last typed.
    public var maximum: Int
    /// `idle` was asked for on the command line: where it cannot be kept, nothing is held instead of that.
    public var idleAsked = false

    public init(seconds: Int, idle: Int, maximum: Int) {
        self.seconds = seconds; self.idle = idle; self.maximum = maximum
    }
}

/// `90s`, `30m`, `8h`, `2d` or bare seconds; 1 s … 7 days.
public enum HoldDuration {
    /// The longest anything is held.
    public static let maximum = 7 * 86400

    public static func seconds(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        var digits = Substring(t)
        var unit = 1
        if let last = t.last, let u = units[last] { digits = t.dropLast(); unit = u }
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(digits), n > 0, n <= maximum / unit else { return nil }
        return n * unit
    }

    /// "45 s", "30 min", "8 h", "1 h 30 min", "7 days".
    public static func text(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return s % 3600 < 60 ? "\(s / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min" }
        let days = s / 86400, text = days == 1 ? "1 day" : "\(days) days"
        return s % 86400 < 3600 ? text : "\(text) \(s % 86400 / 3600) h"
    }
}

/// `unlock:` in config.yml: how long an unlock and an Apple ID session are held when one is asked for, and the most that
/// may be asked for. It holds nothing by itself.
public struct UnlockSettings: Sendable, Equatable {
    public var duration: Int
    public var idle: Int
    public var maximum: Int
    /// The agent drops everything when the system sleeps, and when the screen is locked (where it can tell).
    public var lockOnSleep: Bool
    public var lockOnScreenLock: Bool

    public init(duration: Int = 8 * 3600, idle: Int = 2 * 3600, maximum: Int = HoldDuration.maximum, lockOnSleep: Bool = true, lockOnScreenLock: Bool = true) {
        self.duration = duration; self.idle = idle; self.maximum = maximum
        self.lockOnSleep = lockOnSleep; self.lockOnScreenLock = lockOnScreenLock
    }

    static let example = "unlock: { duration: 8h, idle: 2h, maximum: 7d, lockOnSleep: true, lockOnScreenLock: true }"

    /// The `unlock` value of config.yml (nil: not set).
    static func parse(_ value: Any?, file: String) throws -> UnlockSettings {
        func bad(_ why: String) -> XlessError { XlessError(.config, "\(file): \(why)", fix: "write it as \(example) (at most 7d)") }
        guard let value else { return UnlockSettings() }
        guard let map = value as? [String: Any] else { throw bad("`unlock` is not a mapping") }
        let keys = ["duration", "idle", "maximum", "lockOnSleep", "lockOnScreenLock"]
        if let extra = map.keys.sorted().first(where: { !keys.contains($0) }) { throw bad("`unlock` has an unknown key `\(extra)`") }
        func duration(_ key: String) throws -> Int? {
            guard let raw = map[key] else { return nil }
            guard raw is String || raw is Int, let seconds = HoldDuration.seconds("\(raw)") else {
                throw bad("`unlock.\(key)` is not a duration between 1s and 7d")
            }
            return seconds
        }
        func flag(_ key: String) throws -> Bool {
            guard let raw = map[key] else { return true }
            guard let on = raw as? Bool else { throw bad("`unlock.\(key)` is neither true nor false") }
            return on
        }
        let standard = UnlockSettings()
        let maximum = try duration("maximum") ?? standard.maximum
        let longest = try duration("duration") ?? min(standard.duration, maximum)
        let idle = try duration("idle") ?? min(standard.idle, longest)
        guard longest <= maximum else { throw bad("`unlock.duration` is longer than `unlock.maximum`") }
        guard idle <= maximum else { throw bad("`unlock.idle` is longer than `unlock.maximum`") }
        return UnlockSettings(duration: longest, idle: idle, maximum: maximum, lockOnSleep: try flag("lockOnSleep"), lockOnScreenLock: try flag("lockOnScreenLock"))
    }

    /// What an option that says `default` stands for.
    public static let standardValue = "default"

    /// The hold an option asks for: a duration, or (nil, `default`) the configured one.
    /// - Parameter option: `--keep`, for the error.
    public func hold(_ text: String?, idle idleText: String? = nil, option: String, stage: Stage) throws -> SecretHold {
        func seconds(_ text: String, _ option: String) throws -> Int {
            guard let n = HoldDuration.seconds(text) else {
                throw XlessError(stage, "\(option) \(text) is not a duration between 1s and 7d", fix: "e.g. \(option) 30m, \(option) 8h (at most \(HoldDuration.text(maximum)))")
            }
            guard n <= maximum else {
                throw XlessError(stage, "\(option) \(text) is longer than the maximum",
                                 fix: "ask for at most \(HoldDuration.text(maximum)) (unlock.maximum in config.yml; never more than 7 days)")
            }
            return n
        }
        let n = try text.flatMap { $0 == Self.standardValue ? nil : $0 }.map { try seconds($0, option) } ?? duration
        let quiet = try idleText.map { try seconds($0, "--idle") } ?? idle
        var hold = SecretHold(seconds: n, idle: min(quiet, n), maximum: maximum)
        hold.idleAsked = idleText != nil
        return hold
    }
}

extension UserConfig {
    /// `unlock:`; the defaults when the file or the key is absent. A malformed value is an error, never a default.
    public static func unlockSettings(env: [String: String] = ProcessInfo.processInfo.environment) throws -> UnlockSettings {
        let url = file(env: env)
        return try UnlockSettings.parse(try read(url)["unlock"], file: url.path)
    }
}

/// `--keep` and `--remember` with no duration take the configured one: the command line parser wants a value, so it is
/// given one.
public enum HoldArguments {
    private static let options = ["--keep", "--remember"]

    public static func withDefaults(_ arguments: [String]) -> [String] {
        guard arguments.count > 1, ["auth", "secrets"].contains(arguments[1]) else { return arguments }
        var out: [String] = []
        for (i, argument) in arguments.enumerated() {
            out.append(argument)
            if argument == "--" { return out + arguments[(i + 1)...] }
            if options.contains(argument), i + 1 == arguments.count || arguments[i + 1].hasPrefix("-") { out.append(UnlockSettings.standardValue) }
        }
        return out
    }
}
