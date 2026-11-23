import Foundation
import Yams

public struct PlatformConfig: Sendable, Equatable, Decodable {
    public var minimumOS: String
    public var product: String
    public var entitlements: String?
    public var distribution: Distribution?
    /// Optional per-platform bundle identifier override.
    public var bundleID: String?

    public init(minimumOS: String, product: String, entitlements: String? = nil, distribution: Distribution? = nil, bundleID: String? = nil) {
        self.minimumOS = minimumOS; self.product = product; self.entitlements = entitlements
        self.distribution = distribution; self.bundleID = bundleID
    }
}

/// Optional `testflight:` block: deliver each uploaded build to TestFlight groups, add testers to them, and run external
/// testing (beta app review).
public struct TestFlightConfig: Sendable, Equatable, Decodable {
    /// Internal groups (created as internal with automatic distribution when missing).
    public var groups: [String]
    public var whatToTest: String?
    /// Locale of the "What to Test" text (and of `external.info`).
    public var locale: String
    /// Added to every internal group of `groups`: App Store Connect users of the team.
    public var testers: [TestFlightTester]
    public var external: ExternalTestFlight?

    public init(groups: [String], whatToTest: String? = nil, locale: String = "en-US", testers: [TestFlightTester] = [],
                external: ExternalTestFlight? = nil) {
        self.groups = groups; self.whatToTest = whatToTest; self.locale = locale; self.testers = testers; self.external = external
    }

    enum CodingKeys: String, CodingKey { case groups, whatToTest, locale, testers, external }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        whatToTest = try c.decodeIfPresent(String.self, forKey: .whatToTest)
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
        testers = try c.decodeIfPresent([TestFlightTester].self, forKey: .testers) ?? []
        external = try c.decodeIfPresent(ExternalTestFlight.self, forKey: .external)
    }

    /// The secret the demo account's password is in when `external.review.demoAccount` names none.
    public static let defaultDemoPasswordSecret = "XLESS_DEMO_PASSWORD"

    /// The secret a run's TestFlight publishing may read: the external beta review's demo account password
    /// (`passwordSecret`, else `XLESS_DEMO_PASSWORD`). Apple never gives the password back, so it is sent only when the
    /// account is required (`required: true`, or unset and the account named, when Apple may still require it); nil
    /// when it never is. scripts/testflight.sh gives it to the container that uploads (`xless secrets named-by`).
    public var demoPasswordSecret: String? {
        guard let demo = external?.review?.demoAccount, demo.required == true || (demo.required == nil && demo.name != nil) else { return nil }
        return demo.passwordSecret ?? Self.defaultDemoPasswordSecret
    }

    /// The secret names this block gives of the user's own (the demo account's `passwordSecret`), for
    /// `SecretEnvironment.scrub`: registered whenever the block is read, so no tool started after sees them. A name
    /// validation refuses (`SecretEnvironment.passwordNameProblem`: `PATH`, `HOME`, …) is left out, so the tools a
    /// loader starts before that error (a cargo overlay's `git ls-files`) keep the variable.
    public var secretNames: [String] {
        [external?.review?.demoAccount?.passwordSecret].compactMap { $0 }.filter { SecretEnvironment.passwordNameProblem($0) == nil }
    }

    /// Registers `secretNames` with `SecretEnvironment.scrub`. The configuration loaders call it as soon as they have
    /// parsed, before anything that may start a tool (a cargo overlay's `git ls-files` of its manifests).
    public func registerSecretNames() {
        for name in secretNames { SecretEnvironment.scrub(name) }
    }
}

/// A tester in xless.yml: an email address, or `{email, firstName, lastName}`.
public struct TestFlightTester: Sendable, Equatable, Decodable {
    public var email: String
    public var firstName: String?
    public var lastName: String?

    public init(email: String, firstName: String? = nil, lastName: String? = nil) {
        self.email = email; self.firstName = firstName; self.lastName = lastName
    }

    enum CodingKeys: String, CodingKey { case email, firstName, lastName }
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) { self.init(email: text); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(email: try c.decode(String.self, forKey: .email), firstName: try c.decodeIfPresent(String.self, forKey: .firstName),
                  lastName: try c.decodeIfPresent(String.self, forKey: .lastName))
    }
}

/// `testflight.external`: external groups, their testers, the beta information App Review reads, and the submission.
public struct ExternalTestFlight: Sendable, Equatable, Decodable {
    /// External groups (created as external when missing).
    public var groups: [String]
    /// Added to every group of `groups`.
    public var testers: [TestFlightTester]
    /// Submit the build for beta app review (default true): external testers get a build only once Apple approves it.
    public var submit: Bool
    public var info: Info?
    public var review: Review?

    public struct Info: Sendable, Equatable, Decodable {
        public var description: String?
        public var feedbackEmail: String?
        public var marketingUrl: String?
        public var privacyPolicyUrl: String?
        public init(description: String? = nil, feedbackEmail: String? = nil, marketingUrl: String? = nil, privacyPolicyUrl: String? = nil) {
            self.description = description; self.feedbackEmail = feedbackEmail; self.marketingUrl = marketingUrl; self.privacyPolicyUrl = privacyPolicyUrl
        }
    }

    public struct Review: Sendable, Equatable, Decodable {
        public struct Contact: Sendable, Equatable, Decodable {
            public var firstName: String?
            public var lastName: String?
            public var phone: String?
            public var email: String?
            public init(firstName: String? = nil, lastName: String? = nil, phone: String? = nil, email: String? = nil) {
                self.firstName = firstName; self.lastName = lastName; self.phone = phone; self.email = email
            }
        }
        public struct DemoAccount: Sendable, Equatable, Decodable {
            public var name: String?
            /// The secret holding the password (never the password itself); default XLESS_DEMO_PASSWORD.
            public var passwordSecret: String?
            public var required: Bool?
            public init(name: String? = nil, passwordSecret: String? = nil, required: Bool? = nil) {
                self.name = name; self.passwordSecret = passwordSecret; self.required = required
            }
        }
        public var contact: Contact?
        public var notes: String?
        public var demoAccount: DemoAccount?
        public init(contact: Contact? = nil, notes: String? = nil, demoAccount: DemoAccount? = nil) {
            self.contact = contact; self.notes = notes; self.demoAccount = demoAccount
        }
    }

    public init(groups: [String], testers: [TestFlightTester] = [], submit: Bool = true, info: Info? = nil, review: Review? = nil) {
        self.groups = groups; self.testers = testers; self.submit = submit; self.info = info; self.review = review
    }

    enum CodingKeys: String, CodingKey { case groups, testers, submit, info, review }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        testers = try c.decodeIfPresent([TestFlightTester].self, forKey: .testers) ?? []
        submit = try c.decodeIfPresent(Bool.self, forKey: .submit) ?? true
        info = try c.decodeIfPresent(Info.self, forKey: .info)
        review = try c.decodeIfPresent(Review.self, forKey: .review)
    }
}

/// How `build` is validated: `.fixed` is 1–3 dot-separated integers; `.dated` is `<version>.<YYYYMMDDNN>` (Tauri overlays).
public enum BuildScheme: Sendable, Equatable { case fixed, dated }

public struct ProjectConfig: Sendable, Equatable {
    public var bundleID: String
    public var teamID: String
    public var version: String
    public var build: String
    public var platforms: [Platform: PlatformConfig]
    public var assets: String?
    public var privacyManifest: String?
    public var infoPlist: String?
    /// iOS launch-screen storyboard (`.storyboard`), relative to the project; compiled in the `assets` stage.
    public var launchStoryboard: String? = nil
    public var testflight: TestFlightConfig? = nil
    /// Value stamped as `ITSAppUsesNonExemptEncryption` (export compliance) when set.
    public var usesNonExemptEncryption: Bool? = nil
    public var buildScheme: BuildScheme = .fixed
    /// `xcode:` (xless.yml or an overlay): the Xcode whose SDK must build the app (`XcodePin`); nil: the image's SDK.
    public var xcode: String? = nil

    public init(bundleID: String, teamID: String, version: String, build: String, platforms: [Platform: PlatformConfig],
                assets: String? = nil, privacyManifest: String? = nil, infoPlist: String? = nil, launchStoryboard: String? = nil,
                testflight: TestFlightConfig? = nil, usesNonExemptEncryption: Bool? = nil, buildScheme: BuildScheme = .fixed,
                xcode: String? = nil) {
        self.bundleID = bundleID; self.teamID = teamID; self.version = version; self.build = build; self.platforms = platforms
        self.assets = assets; self.privacyManifest = privacyManifest; self.infoPlist = infoPlist
        self.launchStoryboard = launchStoryboard; self.testflight = testflight
        self.usesNonExemptEncryption = usesNonExemptEncryption; self.buildScheme = buildScheme; self.xcode = xcode
    }

    /// The secrets this configuration names under names of the user's own (the external TestFlight review's demo
    /// account password): a run registers them with `SecretEnvironment.scrub` before its first tool starts, so the
    /// build tools never see them even though they are read only at upload.
    public var secretNames: [String] {
        testflight?.secretNames ?? []
    }

    public func platform(_ p: Platform) throws -> PlatformConfig {
        guard let c = platforms[p] else {
            throw XlessError(.config, "platform '\(p.rawValue)' is not configured in xless.yml", fix: "add a platforms.\(p.rawValue) entry")
        }
        return c
    }

    public func distribution(for p: Platform) -> Distribution {
        platforms[p]?.distribution ?? (p == .ios ? .appStore : .developerID)
    }

    public func bundleID(for p: Platform) -> String {
        platforms[p]?.bundleID ?? bundleID
    }
}

private struct BuildNumber: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) } else { value = try c.decode(String.self) }
    }
}

private struct RawConfig: Decodable {
    var bundleID: String
    var teamID: String
    var version: String
    var build: BuildNumber
    var platforms: [String: PlatformConfig]
    var assets: String?
    var privacyManifest: String?
    var infoPlist: String?
    var launchStoryboard: String?
    var testflight: TestFlightConfig?
    var usesNonExemptEncryption: Bool?
    var xcode: String?
}

extension ProjectConfig {
    public static func parse(yaml: String, buildOverride: String? = nil, buildScheme: BuildScheme = .fixed) throws -> ProjectConfig {
        let raw: RawConfig
        do {
            raw = try YAMLDecoder().decode(RawConfig.self, from: yaml)
        } catch {
            throw XlessError(.config, "xless.yml is invalid: \(error)", fix: "see docs/xless-yml.md for the schema")
        }
        var platforms: [Platform: PlatformConfig] = [:]
        for (key, value) in raw.platforms {
            guard let p = Platform(rawValue: key) else {
                throw XlessError(.config, "unknown platform '\(key)'", fix: "use 'ios' or 'macos'")
            }
            platforms[p] = value
        }
        let config = ProjectConfig(
            bundleID: raw.bundleID, teamID: raw.teamID, version: raw.version,
            build: buildOverride ?? raw.build.value, platforms: platforms,
            assets: raw.assets, privacyManifest: raw.privacyManifest, infoPlist: raw.infoPlist,
            launchStoryboard: raw.launchStoryboard, testflight: raw.testflight,
            usesNonExemptEncryption: raw.usesNonExemptEncryption, buildScheme: buildScheme, xcode: raw.xcode)
        if let pin = raw.xcode { try XcodePin.validate(pin, file: "xless.yml") }
        try config.validate()
        return config
    }

    public static func load(from url: URL, buildOverride: String? = nil) throws -> ProjectConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read \(url.path)", fix: "run xless in the directory containing xless.yml or pass --project")
        }
        let config = try parse(yaml: text, buildOverride: buildOverride)
        config.testflight?.registerSecretNames()
        return config
    }

    public func validate() throws {
        if platforms.isEmpty {
            throw XlessError(.config, "no platforms configured", fix: "add platforms.ios and/or platforms.macos")
        }
        if teamID.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            throw XlessError(.config, "teamID '\(teamID)' is not a 10-character Apple team ID", fix: "copy it from developer.apple.com → Membership")
        }
        for id in [bundleID] + platforms.values.compactMap(\.bundleID) where id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
            throw XlessError(.config, "bundleID '\(id)' is invalid", fix: "use reverse-DNS form, e.g. com.example.app")
        }
        if version.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
            throw XlessError(.config, "version '\(version)' is invalid", fix: "use 1–3 dot-separated integers, e.g. 1.0.0")
        }
        switch buildScheme {
        case .fixed:
            if build.wholeMatch(of: /\d+(\.\d+){0,2}/) == nil {
                throw XlessError(.config, "build '\(build)' is invalid", fix: "use 1–3 dot-separated integers")
            }
        case .dated:
            // `<version>.<YYYYMMDDNN>` of this very version: anything else could sort above the dated builds of the version.
            // A macOS-only config (Developer ID, no App Store Connect) uses the minute-resolution form `<version>.<YYYYMMDDHHmm>`.
            let prefix = version + "."
            let tail = build.dropFirst(prefix.count)
            if Self.isMacOnly(platforms) {
                if !build.hasPrefix(prefix) || tail.wholeMatch(of: /20\d{6}([01]\d|2[0-3])[0-5]\d/) == nil {
                    throw XlessError(.config, "build '\(build)' is invalid for a dated macOS build of version \(version)",
                                     fix: "use <version>.<YYYYMMDDHHmm>, e.g. \(version).202610151530 (UTC), also for --build-number/XLESS_BUILD_NUMBER")
                }
            } else if !build.hasPrefix(prefix) || tail.wholeMatch(of: /20\d{6}(0[1-9]|[1-9]\d)/) == nil {
                throw XlessError(.config, "build '\(build)' is invalid for a dated build of version \(version)",
                                 fix: "use <version>.<YYYYMMDDNN>, e.g. \(version).2026101501 (NN is 01–99), also for --build-number/XLESS_BUILD_NUMBER")
            }
        }
        for (p, pc) in platforms {
            if DottedVersion(pc.minimumOS) == nil {
                throw XlessError(.config, "platforms.\(p.rawValue).minimumOS '\(pc.minimumOS)' is invalid", fix: "use e.g. \"17.0\"")
            }
        }
        if let sb = launchStoryboard, !sb.hasSuffix(".storyboard") || sb == ".storyboard" || sb.hasSuffix("/.storyboard") {
            throw XlessError(.config, "launchStoryboard '\(sb)' is not a .storyboard file", fix: "point launchStoryboard at the launch screen's .storyboard, e.g. Resources/LaunchScreen.storyboard")
        }
        if let tf = testflight { try Self.validate(tf) }
        if distribution(for: .ios) != .appStore, platforms[.ios] != nil {
            throw XlessError(.config, "iOS distribution must be app-store in milestone 1", fix: "remove platforms.ios.distribution")
        }
    }

    /// `xless ship --distribution`: the CLI value replaces the platform's configured distribution for this run
    /// (sign/package/upload all see it); the parsed config the value came from is untouched. Absent, the config's
    /// own value stands — `distribution(for:)` defaults macOS to developer-id. iOS is app-store only, so a
    /// developer-id override is refused there.
    public func overridingDistribution(_ override: Distribution?, for p: Platform) throws -> ProjectConfig {
        guard let d = override else { return self }
        if p == .ios, d != .appStore {
            throw XlessError(.config, "--distribution \(d.rawValue) is not supported: iOS must be app-store in milestone 1",
                             fix: "drop --distribution (iOS builds ship to the App Store)")
        }
        var c = self
        var pc = try c.platform(p)
        pc.distribution = d
        c.platforms[p] = pc
        return c
    }

    /// Whether the config builds only for macOS (no iOS platform).
    public static func isMacOnly(_ platforms: [Platform: PlatformConfig]) -> Bool {
        platforms[.macos] != nil && platforms[.ios] == nil
    }

    private static func validate(_ tf: TestFlightConfig) throws {
        let external = tf.external?.groups ?? []
        if tf.external != nil, external.isEmpty {
            throw XlessError(.config, "testflight.external.groups is empty", fix: "list at least one external TestFlight group, e.g. groups: [\"Beta\"], or remove testflight.external")
        }
        if tf.groups.isEmpty, external.isEmpty {
            throw XlessError(.config, "testflight.groups is empty", fix: "list at least one internal TestFlight group, e.g. groups: [\"Internal\"] (or external groups in testflight.external.groups), or remove the testflight block")
        }
        try validateNames(tf.groups, key: "testflight.groups")
        try validateNames(external, key: "testflight.external.groups")
        if let both = tf.groups.first(where: external.contains) {
            throw XlessError(.config, "'\(both)' is in both testflight.groups and testflight.external.groups", fix: "a group is either internal or external: keep it in one list")
        }
        if let w = tf.whatToTest {
            if w.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw XlessError(.config, "testflight.whatToTest is empty", fix: "write the text testers should see, or remove the key")
            }
            if w.count > 4000 {
                throw XlessError(.config, "testflight.whatToTest is \(w.count) characters; App Store Connect allows at most 4000", fix: "shorten the text")
            }
        }
        if tf.locale.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil {
            throw XlessError(.config, "testflight.locale '\(tf.locale)' is not a locale code", fix: "use e.g. en-US")
        }
        if !tf.testers.isEmpty, tf.groups.isEmpty {
            throw XlessError(.config, "testflight.testers has no internal group to go to", fix: "list the internal groups in testflight.groups, or move the testers to testflight.external.testers")
        }
        try validateTesters(tf.testers, key: "testflight.testers")
        guard let ext = tf.external else { return }
        try validateTesters(ext.testers, key: "testflight.external.testers")
        if ext.submit, tf.whatToTest == nil {
            throw XlessError(.config, "testflight.external submits builds for beta app review, which needs the build's What to Test",
                             fix: "add testflight.whatToTest, or set testflight.external.submit: false")
        }
        if let info = ext.info {
            if let d = info.description, d.count > 4000 {
                throw XlessError(.config, "testflight.external.info.description is \(d.count) characters; App Store Connect allows at most 4000", fix: "shorten the text")
            }
            if let e = info.feedbackEmail, !looksLikeEmail(e) {
                throw XlessError(.config, "testflight.external.info.feedbackEmail '\(e)' is not an email address", fix: "use e.g. beta@example.com")
            }
            for (key, url) in [("marketingUrl", info.marketingUrl), ("privacyPolicyUrl", info.privacyPolicyUrl)] {
                if let url, !url.isEmpty, !(url.hasPrefix("https://") || url.hasPrefix("http://")) {
                    throw XlessError(.config, "testflight.external.info.\(key) '\(url)' is not an http(s) URL", fix: "use e.g. https://example.com")
                }
            }
        }
        if let review = ext.review {
            if let e = review.contact?.email, !looksLikeEmail(e) {
                throw XlessError(.config, "testflight.external.review.contact.email '\(e)' is not an email address", fix: "use e.g. review@example.com")
            }
            if let demo = review.demoAccount {
                if demo.required == true, (demo.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    throw XlessError(.config, "testflight.external.review.demoAccount is required but has no name", fix: "add demoAccount.name: the account App Review signs in with")
                }
                if let secret = demo.passwordSecret, let problem = SecretEnvironment.passwordNameProblem(secret) {
                    throw XlessError(.config, "testflight.external.review.demoAccount.passwordSecret \(secret) \(problem)",
                                     fix: "keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD (`xless secrets import XLESS_DEMO_PASSWORD --file <file> --kind password`)")
                }
            }
        }
    }

    private static func validateNames(_ names: [String], key: String) throws {
        var seen = Set<String>()
        for g in names {
            if g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw XlessError(.config, "\(key) contains an empty name", fix: "give every group a name")
            }
            if !seen.insert(g).inserted {
                throw XlessError(.config, "\(key) lists '\(g)' twice", fix: "remove the duplicate")
            }
        }
    }

    private static func validateTesters(_ testers: [TestFlightTester], key: String) throws {
        var seen = Set<String>()
        for t in testers {
            guard looksLikeEmail(t.email), !t.email.contains(",") else {
                throw XlessError(.config, "\(key) has '\(t.email)', which is not an email address", fix: "use e.g. grace@example.com")
            }
            if !seen.insert(t.email.lowercased()).inserted {
                throw XlessError(.config, "\(key) lists \(t.email) twice", fix: "remove the duplicate")
            }
        }
    }

    private static func looksLikeEmail(_ text: String) -> Bool {
        text.wholeMatch(of: /[^@\s\/]+@[^@\s\/.]+(\.[^@\s\/.]+)+/) != nil
    }
}
