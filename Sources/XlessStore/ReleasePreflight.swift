import Foundation
import XlessASC
import XlessCore

// `xless release submit`'s pre-flight: everything App Review needs, checked before anything is sent, every missing
// item reported at once. The appstore/ manifest (when there is one) must be valid and pushed (`store push` would
// send nothing); the rest is read from App Store Connect, so it holds for a listing kept without a manifest too.

/// One item of the pre-flight.
public struct PreflightCheck: Encodable, Sendable, Equatable {
    public enum Status: String, Encodable, Sendable {
        case ok, failed, warning, skipped
    }

    /// manifest, metadata, listing, screenshots, privacy, pricing, availability, build, encryption, review contact.
    public var name: String
    public var status: Status
    public var message: String
    public var fix: String?

    public init(_ name: String, _ status: Status, _ message: String, fix: String? = nil) {
        self.name = name; self.status = status; self.message = message; self.fix = fix
    }

    /// `  FAIL  build           build 1.2+42 is still processing — xless builds wait …`
    public var line: String {
        let mark = switch status { case .ok: "ok  "; case .failed: "FAIL"; case .warning: "warn"; case .skipped: "skip" }
        return "  \(mark)  \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(message)\(fix.map { " — \($0)" } ?? "")"
    }
}

public struct PreflightReport: Encodable, Sendable, Equatable {
    public var checks: [PreflightCheck]

    public init(checks: [PreflightCheck]) { self.checks = checks }

    public var failures: [PreflightCheck] { checks.filter { $0.status == .failed } }
    public var passed: Bool { failures.isEmpty }

    /// One line per check, failures first.
    public var text: String {
        let ordered = checks.filter { $0.status == .failed } + checks.filter { $0.status != .failed }
        return ordered.map { $0.line + "\n" }.joined()
    }

    enum CodingKeys: String, CodingKey { case checks, passed }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(checks, forKey: .checks)
        try c.encode(passed, forKey: .passed)
    }
}

/// Reads only: runs every check and reports them all.
public struct ReleasePreflight: Sendable {
    public struct Input: Sendable {
        public var app: ASCApp
        /// IOS, MAC_OS, TV_OS or VISION_OS.
        public var platform: String
        public var version: ASCAppStoreVersion
        /// The build the submission will carry (given, else attached); nil when there is none.
        public var build: ASCBuildDetail?
        /// The manifest directory; nil or missing: no manifest checks.
        public var manifestDir: URL?
        /// xless.yml's bundle ID next to the manifest, when app.yml has none.
        public var inheritedBundleID: String?
        /// The submission sets the release type (`--release`) / the phased release (`--phased`): app.yml's values of
        /// those are not compared.
        public var overridesReleaseType: Bool
        public var overridesPhased: Bool
        public var today: Date

        public init(app: ASCApp, platform: String, version: ASCAppStoreVersion, build: ASCBuildDetail?, manifestDir: URL?,
                    inheritedBundleID: String? = nil, overridesReleaseType: Bool = false, overridesPhased: Bool = false, today: Date = Date()) {
            self.app = app; self.platform = platform; self.version = version; self.build = build; self.manifestDir = manifestDir
            self.inheritedBundleID = inheritedBundleID; self.overridesReleaseType = overridesReleaseType; self.overridesPhased = overridesPhased
            self.today = today
        }
    }

    public let resources: ASCResources
    /// App Privacy through a kept Apple ID web session; nil: the privacy check is a warning (not checked).
    public let privacy: (any PrivacyRemote)?
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, privacy: (any PrivacyRemote)? = nil, say: @escaping @Sendable (String) -> Void = { _ in }) {
        self.resources = resources; self.privacy = privacy; self.say = say
    }

    var asc: StoreASC { StoreASC(resources: resources, say: say) }

    public func run(_ input: Input) async throws -> PreflightReport {
        var checks = try await manifest(input)
        checks += try await listing(input)
        checks += try await screenshots(input)
        checks.append(try await privacyCheck(input))
        checks += try await pricing(input)
        checks += build(input)
        checks.append(try await reviewContact(input))
        return PreflightReport(checks: checks)
    }

    // MARK: The manifest

    func manifest(_ input: Input) async throws -> [PreflightCheck] {
        guard let dir = input.manifestDir, FileManager.default.fileExists(atPath: dir.path) else {
            let name = input.manifestDir?.lastPathComponent ?? "appstore"
            return [PreflightCheck("manifest", .skipped, "no \(name)/ directory: the listing is checked on App Store Connect only")]
        }
        let name = dir.lastPathComponent
        let read = ManifestReader.read(dir)
        var manifest = read.manifest
        var checks: [PreflightCheck] = []
        let issues = read.issues + ManifestValidator.validate(manifest, at: dir, draft: false, inheritedBundleID: input.inheritedBundleID, checkApp: read.appReadable)
        for issue in issues where issue.severity == .error {
            checks.append(PreflightCheck("manifest", .failed, "\(issue.path): \(issue.message)", fix: issue.fix))
        }
        let app = manifest.app
        if let bundleID = app.bundleID ?? input.inheritedBundleID, bundleID != input.app.bundleID {
            checks.append(PreflightCheck("manifest", .failed, "\(name)/ describes \(bundleID), not \(input.app.bundleID)",
                                         fix: "pass --dir with \(input.app.bundleID)'s manifest, or --app \(bundleID)"))
        }
        if (app.platform ?? "IOS") != input.platform {
            checks.append(PreflightCheck("manifest", .failed, "\(name)/app.yml describes the \(app.platform ?? "IOS") listing, not \(input.platform)",
                                         fix: "pass --dir with the \(input.platform) manifest, or --platform"))
        }
        if let wanted = app.version, wanted != input.version.versionString {
            checks.append(PreflightCheck("manifest", .failed, "\(name)/app.yml describes version \(wanted), not \(input.version.versionString)",
                                         fix: "set app.yml's version to \"\(input.version.versionString)\" and `xless store push`, or pass --app-version \(wanted)"))
        }
        guard checks.isEmpty else {
            checks.append(PreflightCheck("metadata", .skipped, "not compared with App Store Connect until \(name)/ is fixed"))
            return checks
        }
        checks.append(PreflightCheck("manifest", .ok, "\(name)/ is valid"))
        // What the submission sets itself is not app.yml's to compare.
        if input.overridesReleaseType { manifest.app.release?.type = nil; manifest.app.release?.earliestDate = nil }
        if input.overridesPhased { manifest.app.release?.phased = nil }
        if manifest.app.version == nil { manifest.app.version = input.version.versionString }
        let push = StorePush(resources: resources, privacy: privacy, say: say)
        do {
            let (plan, _) = try await push.plan(app: input.app, manifest: manifest, dir: dir, options: StorePush.Options(today: input.today))
            if plan.changes.isEmpty {
                checks.append(PreflightCheck("metadata", .ok, "App Store Connect matches \(name)/"))
            } else {
                let n = plan.changes.count
                let subjects = plan.changes.map(\.subject)
                let shown = subjects.prefix(5).joined(separator: ", ") + (subjects.count > 5 ? ", …" : "")
                checks.append(PreflightCheck("metadata", .failed, "\(n) change\(n == 1 ? "" : "s") in \(name)/ \(n == 1 ? "is" : "are") not on App Store Connect (\(shown))",
                                             fix: "`xless store push` sends \(n == 1 ? "it" : "them") (`--dry-run` lists \(n == 1 ? "it" : "them"))"))
            }
        } catch let e as XlessError {
            checks.append(PreflightCheck("metadata", .failed, e.cause, fix: e.fix))
        }
        return checks
    }

    // MARK: The listing on App Store Connect

    func listing(_ input: Input) async throws -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        func missing(_ what: String, _ fix: String) { checks.append(PreflightCheck("listing", .failed, what, fix: fix)) }
        let push = "set it in appstore/ and `xless store push`"
        if input.app.attributes.contentRightsDeclaration == nil {
            missing("the app's content rights declaration is not answered", "set contentRights in app.yml and `xless store push`, or `xless apps update \(input.app.id) --content-rights …`")
        }
        let infos = try await asc.appInfos(of: input.app.id)
        let info = infos.first { StorePush.isEditableInfo($0.attributes) } ?? infos.first { StorePull.isLiveInfo($0.attributes) } ?? infos.first
        let primary = input.app.attributes.primaryLocale
        if let info {
            if info.resource.relatedID("primaryCategory") == nil { missing("the app has no primary category", "set categories.primary in app.yml and `xless store push`") }
            let locales = try await asc.appInfoLocalizations(of: info.id)
            for l in locales where (l.attributes.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                missing("\(l.attributes.locale ?? "?"): no app name", push)
            }
            let privacyURL = locales.first { $0.attributes.locale == primary }?.attributes.privacyPolicyUrl
            if (privacyURL ?? "").isEmpty { missing("\(primary ?? "the primary locale"): no privacy policy URL", "add privacy_url.txt to the primary locale and `xless store push`") }
        } else {
            missing("App Store Connect lists no app information for the app", "re-run; if it persists, report it")
        }
        let localizations = try await asc.versionLocalizations(of: input.version.id)
        if localizations.isEmpty { missing("version \(input.version.versionString) has no localization", push) }
        for l in localizations {
            let a = l.attributes
            let absent = [("description", a.description), ("keywords", a.keywords), ("support URL", a.supportUrl)]
                .filter { ($0.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
            if !absent.isEmpty { missing("\(a.locale ?? "?"): no \(absent.joined(separator: ", "))", push) }
        }
        if checks.isEmpty {
            checks.append(PreflightCheck("listing", .ok, "name, description, keywords and support URL in \(localizations.count) locale\(localizations.count == 1 ? "" : "s"); category, privacy policy URL, content rights"))
        }
        return checks
    }

    /// The display types App Review needs (one of each group), and those it needs only for some apps.
    static func screenshotGroups(_ platform: String) -> (required: [[String]], ifSupported: [(what: String, types: [String])]) {
        switch platform {
        case "IOS": ([["APP_IPHONE_67", "APP_IPHONE_65"]], [("iPad", ["APP_IPAD_PRO_3GEN_129", "APP_IPAD_PRO_129"])])
        default: ([ScreenshotDisplayType.required(for: platform)], [])
        }
    }

    func screenshots(_ input: Input) async throws -> [PreflightCheck] {
        let localizations = try await asc.versionLocalizations(of: input.version.id)
        guard !localizations.isEmpty else { return [PreflightCheck("screenshots", .failed, "no localization, so no screenshots", fix: "`xless store push`")] }
        let primary = input.app.attributes.primaryLocale
        var checks: [PreflightCheck] = []
        var broken: [String] = []
        var primarySets: [StoreRemoteSet] = []
        for l in localizations {
            let sets = try await asc.screenshotSets(of: l.id)
            if l.attributes.locale == primary || (primary == nil && l.id == localizations[0].id) { primarySets = sets }
            for set in sets {
                for item in set.items where item.attributes.state != "COMPLETE" && item.attributes.state != "UPLOAD_COMPLETE" && item.attributes.state != nil {
                    broken.append("\(l.attributes.locale ?? "?")/\(set.type)/\(item.attributes.fileName ?? item.id) (\(item.attributes.state!.lowercased()))")
                }
            }
        }
        let usable = { (types: [String]) in primarySets.contains { types.contains($0.type) && $0.items.contains { $0.attributes.state != "FAILED" } } }
        let locale = primary ?? localizations[0].attributes.locale ?? "the primary locale"
        let groups = Self.screenshotGroups(input.platform)
        for types in groups.required where !usable(types) {
            checks.append(PreflightCheck("screenshots", .failed, "\(locale): no screenshot for \(types.count == 1 ? types[0] : types.joined(separator: " or "))",
                                         fix: "add them to appstore/\(locale)/screenshots/\(types[0])/ and `xless store push`"))
        }
        for group in groups.ifSupported where !usable(group.types) {
            checks.append(PreflightCheck("screenshots", .warning, "\(locale): no \(group.what) screenshot (\(group.types.joined(separator: " or ")))",
                                         fix: "App Review needs them when the app runs on \(group.what)"))
        }
        if !broken.isEmpty {
            checks.append(PreflightCheck("screenshots", .failed, "\(broken.count) screenshot\(broken.count == 1 ? " is" : "s are") not usable: \(broken.prefix(5).joined(separator: ", "))\(broken.count > 5 ? ", …" : "")",
                                         fix: "`xless store push` uploads them again"))
        }
        if !checks.contains(where: { $0.status == .failed }) {
            checks.insert(PreflightCheck("screenshots", .ok, "\(locale) has the screenshots App Review needs"), at: 0)
        }
        return checks
    }

    func privacyCheck(_ input: Input) async throws -> PreflightCheck {
        guard let privacy else {
            return PreflightCheck("privacy", .warning, "App Privacy is not checked: it has no App Store Connect API",
                                  fix: "keep an Apple ID web session (`xless auth login --keep 30m`) and re-run to check it")
        }
        let state = try await privacy.publishState(app: input.app.id)
        guard state?.published == true else {
            return PreflightCheck("privacy", .failed, "the App Privacy answers are not published", fix: "set privacy: in app.yml and `xless store privacy push`")
        }
        return PreflightCheck("privacy", .ok, "App Privacy answers are published")
    }

    func pricing(_ input: Input) async throws -> [PreflightCheck] {
        let push = "set it in app.yml and `xless store push --only pricing`"
        var checks: [PreflightCheck] = []
        switch try await asc.priceSchedule(of: input.app.id) {
        case .value(let s) where !s.prices.isEmpty:
            let day = StoreASC.day(input.today)
            let base = s.prices.first { $0.territory == s.baseTerritory && $0.current(on: day) }
            checks.append(PreflightCheck("pricing", .ok, "price set\(base.map { " (\(s.baseTerritory ?? ""): \(CustomerPrice.display($0.customerPrice)))" } ?? "")"))
        case .value, .absent: checks.append(PreflightCheck("pricing", .failed, "the app has no price", fix: push))
        case .forbidden: checks.append(PreflightCheck("pricing", .warning, "this API key may not read the price schedule (HTTP 403)", fix: "use a key with the App Manager role"))
        }
        switch try await asc.availability(of: input.app.id) {
        case .value(let a) where !a.available.isEmpty:
            checks.append(PreflightCheck("availability", .ok, a.all ? "available in every territory" : "available in \(a.available.count) territor\(a.available.count == 1 ? "y" : "ies")"))
        case .value, .absent: checks.append(PreflightCheck("availability", .failed, "the app is available in no territory", fix: push))
        case .forbidden: checks.append(PreflightCheck("availability", .warning, "this API key may not read the availability (HTTP 403)", fix: "use a key with the App Manager role"))
        }
        return checks
    }

    // MARK: The build

    func build(_ input: Input) -> [PreflightCheck] {
        guard let b = input.build else {
            return [PreflightCheck("build", .failed, "version \(input.version.versionString) has no build",
                                   fix: "pass --build <version>+<build number>, or `xless release attach <build>` (`xless builds list` lists them)")]
        }
        var checks: [PreflightCheck] = []
        let name = "build \(b.name) (\(b.id))"
        if let owner = b.appID, owner != input.app.id {
            checks.append(PreflightCheck("build", .failed, "\(name) is a build of \(b.bundleID ?? owner), not of \(input.app.bundleID)", fix: "pick one of `xless builds list --app \(input.app.bundleID)`"))
        }
        if let platform = b.platform, platform != input.platform {
            checks.append(PreflightCheck("build", .failed, "\(name) is a \(BuildPlatform.display(platform)) build, the version is \(BuildPlatform.display(input.platform))",
                                         fix: "pick a \(BuildPlatform.display(input.platform)) build"))
        }
        if let v = b.appVersion, v != input.version.versionString {
            checks.append(PreflightCheck("build", .failed, "\(name) is version \(v), the App Store version is \(input.version.versionString)",
                                         fix: "upload a build of \(input.version.versionString), or submit version \(v) (`xless release create \(v)`)"))
        }
        if b.build.isExpired {
            checks.append(PreflightCheck("build", .failed, "\(name) has expired", fix: "upload a new build"))
        } else {
            switch b.build.processingState {
            case "VALID": break
            case "PROCESSING", "":
                checks.append(PreflightCheck("build", .failed, "\(name) is still processing", fix: "`xless builds wait \(b.id)`, then re-run"))
            case let state:
                checks.append(PreflightCheck("build", .failed, "\(name) is \(state.lowercased())", fix: "fix the build and upload it again with a higher build number"))
            }
        }
        if checks.isEmpty { checks.append(PreflightCheck("build", .ok, "\(name) is valid")) }
        let a = b.build.attributes
        if a.usesNonExemptEncryption == nil, b.encryptionDeclarationID == nil {
            checks.append(PreflightCheck("encryption", .failed, "export compliance of \(name) is not answered",
                                         fix: "`xless builds update \(b.id) --uses-non-exempt-encryption false` (or true, with --encryption-declaration)"))
        } else if a.usesNonExemptEncryption == true, b.encryptionDeclarationID == nil {
            checks.append(PreflightCheck("encryption", .warning, "\(name) uses non-exempt encryption and has no encryption declaration attached",
                                         fix: "attach one with `xless builds update \(b.id) --encryption-declaration <id>` unless its Info.plist names one"))
        } else {
            checks.append(PreflightCheck("encryption", .ok, "export compliance is answered"))
        }
        return checks
    }

    // MARK: App Review

    func reviewContact(_ input: Input) async throws -> PreflightCheck {
        let fix = "set review.contact in app.yml and `xless store push --only review`"
        switch try await asc.reviewDetail(of: input.version.id) {
        case .absent: return PreflightCheck("review contact", .failed, "version \(input.version.versionString) has no App Review details", fix: fix)
        case .forbidden: return PreflightCheck("review contact", .warning, "this API key may not read the App Review details (HTTP 403)", fix: "use a key with the App Manager role")
        case .value(let d):
            let absent = [("first name", d.contactFirstName), ("last name", d.contactLastName), ("phone", d.contactPhone), ("email", d.contactEmail)]
                .filter { ($0.1 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map(\.0)
            if !absent.isEmpty { return PreflightCheck("review contact", .failed, "the App Review contact has no \(absent.joined(separator: ", "))", fix: fix) }
            if d.demoAccountRequired == true, (d.demoAccountName ?? "").isEmpty {
                return PreflightCheck("review contact", .failed, "a demo account is required and has no name", fix: "set review.demoAccount in app.yml and `xless store push --only review`")
            }
            return PreflightCheck("review contact", .ok, "\([d.contactFirstName, d.contactLastName].compactMap { $0 }.joined(separator: " ")) <\(d.contactEmail ?? "")>")
        }
    }
}
