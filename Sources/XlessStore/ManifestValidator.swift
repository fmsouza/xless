import Foundation
import XlessASC
import XlessCore

/// `xless store validate`: what App Store Connect would refuse, found offline (no network, no Apple tool).
///
/// Two kinds of finding: a value that is wrong (always an error) and a value a submission needs that is missing (an
/// error, or with `draft` a warning: a listing being written, or `store push` of a part of it).
public enum ManifestValidator {
    /// Field limits (Apple's): characters, except keywords (UTF-8 bytes).
    public static let limits: [String: Int] = [
        "name.txt": 30, "subtitle.txt": 30, "keywords.txt": 100, "promotional_text.txt": 170, "description.txt": 4000, "whats_new.txt": 4000,
    ]
    public static let platforms = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]
    public static let releaseTypes = ["MANUAL", "AFTER_APPROVAL", "SCHEDULED"]
    public static let deviceFamilies = ["IPHONE", "IPAD", "MAC", "APPLE_TV", "APPLE_WATCH", "VISION"]

    /// Whether a `passwordSecret` names one of xless's other secrets, or something named like a key or token: `store push`
    /// would send its value to App Store Connect as the demo password, where App Review (and the app's team) can read it.
    public static func isReservedSecret(_ name: String) -> Bool {
        let base = (name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name).uppercased()
        if base == "XLESS_DEMO_PASSWORD" { return false }
        if SecretEnvironment.isSecret(base) || base.hasPrefix("ASC_") { return true }
        return ["_KEY", "_TOKEN", "_P8", "_PEM", "_SECRET"].contains { base.hasSuffix($0) || base.hasSuffix($0 + "_FILE") }
    }

    /// - Parameters:
    ///   - dir: the manifest directory (its name starts every issue's path).
    ///   - inheritedBundleID: the bundle ID of the project next to the manifest (`xless.yml`), used when `app.yml` has none.
    ///   - checkApp: false when `app.yml` is missing or could not be read (the reader said why): its values are not
    ///     checked, so one bad value does not also report every key as missing.
    public static func validate(_ manifest: StoreManifest, at dir: URL, draft: Bool = false, inheritedBundleID: String? = nil,
                                checkApp: Bool = true) -> [StoreIssue] {
        var v = Run(manifest: manifest, dir: dir, draft: draft)
        if checkApp { v.app(inheritedBundleID: inheritedBundleID) }
        for locale in manifest.orderedLocales { v.locale(locale, manifest.locales[locale]!) }
        v.submission()
        return v.issues
    }

    struct Run {
        let manifest: StoreManifest
        let dir: URL
        let draft: Bool
        var issues: [StoreIssue] = []

        init(manifest: StoreManifest, dir: URL, draft: Bool) { self.manifest = manifest; self.dir = dir; self.draft = draft }

        var name: String { dir.lastPathComponent }
        var appPath: String { "\(name)/\(ManifestReader.appFile)" }
        var app: AppYAML { manifest.app }

        mutating func error(_ path: String, _ message: String, _ fix: String) { issues.append(StoreIssue(path, message, fix: fix)) }
        mutating func warn(_ path: String, _ message: String, _ fix: String) { issues.append(StoreIssue(path, message, fix: fix, severity: .warning)) }
        mutating func missing(_ path: String, _ message: String, _ fix: String) {
            issues.append(StoreIssue(path, message, fix: fix, severity: draft ? .warning : .error))
        }

        func oneOf(_ values: [String]) -> String { values.joined(separator: ", ") }

        // MARK: app.yml

        mutating func app(inheritedBundleID: String?) {
            if let id = app.bundleID {
                if (try? BundleIdentifier.validate(id)) == nil || id.contains("*") {
                    error(appPath, "bundleID \(id) is not an explicit bundle identifier", "use the app's bundle ID, e.g. com.example.app")
                }
            } else if inheritedBundleID == nil {
                error(appPath, "no bundleID, and no usable xless.yml next to \(name)/ to take it from", "add `bundleID: com.example.app` to app.yml")
            }
            if let p = app.platform, !ManifestValidator.platforms.contains(p) {
                error(appPath, "platform \(p) is not one App Store Connect knows", "use one of \(oneOf(ManifestValidator.platforms))")
            }
            if let locale = app.primaryLocale {
                if let normal = try? AppLocale.normalize(locale) {
                    if normal != locale { error(appPath, "primaryLocale \(locale) is spelled \(normal) by App Store Connect", "write primaryLocale: \(normal)") }
                    else if !manifest.locales.isEmpty, manifest.locales[locale] == nil {
                        error(appPath, "the primary locale \(locale) has no directory", "create \(name)/\(locale)/ with its name.txt, description.txt…")
                    }
                } else {
                    error(appPath, "primaryLocale \(locale) is not a locale", "use App Store Connect's code, e.g. en-US")
                }
            } else {
                missing(appPath, "no primaryLocale", "add `primaryLocale: en-US` (the app's primary language)")
            }
            if let version = app.version {
                if version.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) == nil {
                    error(appPath, "version \(version) is not an App Store version", "use 1 to 3 numbers separated by dots, quoted: version: \"1.0\"")
                }
            } else {
                missing(appPath, "no version", "add `version: \"1.0\"` (the App Store version this listing is for)")
            }
            if app.copyright == nil { missing(appPath, "no copyright", "add e.g. `copyright: 2026 Example Inc.`") }
            if let rights = app.contentRights {
                if AppContentRights(rawValue: rights) == nil {
                    error(appPath, "contentRights \(rights) is not a declaration App Store Connect knows",
                          "use \(oneOf(AppContentRights.allCases.map(\.rawValue)))")
                }
            } else {
                missing(appPath, "no contentRights", "add `contentRights: DOES_NOT_USE_THIRD_PARTY_CONTENT` (or USES_THIRD_PARTY_CONTENT)")
            }
            categories()
            if app.ageRating?.isEmpty ?? true {
                missing(appPath, "no ageRating", "answer the age rating questions in `ageRating:` (`xless store pull` writes them for an existing app; docs/appstore-manifest.md)")
            }
            release()
            review()
            eula()
            attachedFiles()
            previewFrames()
            pricing()
            if let families = app.accessibility?.values.keys {
                for family in families.sorted() where !ManifestValidator.deviceFamilies.contains(family) {
                    warn(appPath, "accessibility.\(family) is not a device family xless knows", "use \(oneOf(ManifestValidator.deviceFamilies))")
                }
            }
        }

        mutating func categories() {
            guard let c = app.categories, let primary = c.primary else {
                missing(appPath, "no categories.primary", "add the primary category, e.g. `categories: { primary: UTILITIES }`")
                return
            }
            let all = [primary] + (c.primarySubcategories ?? []) + (c.secondary.map { [$0] } ?? []) + (c.secondarySubcategories ?? [])
            for id in all where id.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) == nil {
                error(appPath, "category \(id) is not an App Store Connect category ID", "use IDs such as GAMES, GAMES_ACTION, UTILITIES (`xless api GET /v1/appCategories`)")
            }
            for (key, list) in [("primarySubcategories", c.primarySubcategories), ("secondarySubcategories", c.secondarySubcategories)] {
                if let list, list.count > 2 { error(appPath, "categories.\(key) has \(list.count) entries, Apple allows 2", "keep at most two") }
            }
            if c.secondary == nil, !(c.secondarySubcategories ?? []).isEmpty {
                error(appPath, "categories.secondarySubcategories without categories.secondary", "add the secondary category, or remove its subcategories")
            }
        }

        mutating func release() {
            guard let r = app.release else { return }
            if let type = r.type, !ManifestValidator.releaseTypes.contains(type) {
                error(appPath, "release.type \(type) is not one App Store Connect knows", "use \(oneOf(ManifestValidator.releaseTypes))")
            }
            if r.type == "SCHEDULED" {
                if let date = r.earliestDate {
                    if ISO8601DateFormatter().date(from: date) == nil {
                        error(appPath, "release.earliestDate \(date) is not an ISO 8601 date and time", "write it as 2026-12-01T08:00:00Z")
                    }
                } else {
                    error(appPath, "release.type SCHEDULED needs release.earliestDate", "add e.g. `earliestDate: 2026-12-01T08:00:00Z`")
                }
            }
        }

        mutating func review() {
            let contact = app.review?.contact
            let fields: [(String, String?)] = [("firstName", contact?.firstName), ("lastName", contact?.lastName), ("phone", contact?.phone), ("email", contact?.email)]
            let absent = fields.filter { $0.1?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }.map(\.0)
            if !absent.isEmpty {
                missing(appPath, "App Review's contact has no \(absent.map { "review.contact.\($0)" }.joined(separator: ", "))",
                        "add the person App Review can reach: review: { contact: { firstName, lastName, phone, email } }")
            }
            if let email = contact?.email, !email.isEmpty, email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) == nil {
                error(appPath, "review.contact.email \(email) is not an email address", "fix the address")
            }
            guard let demo = app.review?.demoAccount else { return }
            if let secret = demo.passwordSecret, !Self.isSecretName(secret) {
                error(appPath, "review.demoAccount.passwordSecret \(secret) is not a secret name",
                      "name the secret-store entry (or environment variable) that holds the password, e.g. XLESS_DEMO_PASSWORD; never the password itself")
            } else if let secret = demo.passwordSecret, ManifestValidator.isReservedSecret(secret) {
                error(appPath, "review.demoAccount.passwordSecret \(secret) names a key or token, not a password",
                      "keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD (`xless secrets import XLESS_DEMO_PASSWORD --file <file> --kind password`)")
            }
            if demo.required == true {
                if demo.name?.isEmpty ?? true { missing(appPath, "review.demoAccount.required without review.demoAccount.name", "add the demo account's user name") }
                if demo.passwordSecret == nil {
                    missing(appPath, "review.demoAccount.required without review.demoAccount.passwordSecret",
                            "store the password (`xless secrets import XLESS_DEMO_PASSWORD --file <file> --kind password`) and add `passwordSecret: XLESS_DEMO_PASSWORD`")
                }
            }
        }

        /// The secret store's entry names (letters, digits and `. _ @ -`, starting with a letter or digit).
        static func isSecretName(_ name: String) -> Bool {
            name.count <= 128 && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._@-]*$", options: .regularExpression) != nil
        }

        /// App Review attachments and the compliance document: files inside the manifest, each listed once.
        mutating func attachedFiles() {
            let listed = (app.review?.attachments ?? []).map { ("review.attachments", $0, "review") }
                + (app.encryptionDocument.map { [("encryptionDocument", $0, "compliance")] } ?? [])
            var seen: Set<String> = []
            for (key, file, folder) in listed {
                guard let url = StoreManifest.resolve(file, in: dir) else {
                    error(appPath, "\(key): \(file) is outside \(name)/", "keep the file inside the manifest, e.g. \(folder)/\((file as NSString).lastPathComponent)")
                    continue
                }
                if !seen.insert(url.standardizedFileURL.path).inserted { error(appPath, "\(key) lists \(file) twice", "list each file once"); continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    error("\(name)/\(file)", "is missing (app.yml's \(key))", "put the file there, or remove it from \(key)")
                    continue
                }
                if (try? AssetFile.size(url)) == 0 { error("\(name)/\(file)", "is empty (app.yml's \(key))", "App Store Connect takes no empty file") }
            }
        }

        /// Poster frames: a preview of the manifest each, as `HH:MM:SS:FF`.
        mutating func previewFrames() {
            guard let frames = app.previewFrames else { return }
            let previews = Set(manifest.locales.values.flatMap { $0.previews.flatMap(\.files) })
            for (path, code) in frames.values.sorted(by: { $0.key < $1.key }) {
                if !previews.contains(path) {
                    warn(appPath, "previewFrames: \(path) is not a preview in \(name)/", "use a preview's path, e.g. en-US/previews/IPHONE_67/01-intro.mov, or remove the entry")
                }
                if code.range(of: "^[0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{2}$", options: .regularExpression) == nil {
                    error(appPath, "previewFrames: \(code) (\(path)) is not a time code", "write HH:MM:SS:FF, e.g. 00:00:05:00 (frame 0 of second 5)")
                }
            }
        }

        mutating func eula() {
            guard case .custom(let file, let territories) = app.eula else { return }
            guard let url = StoreManifest.resolve(file, in: dir) else {
                error(appPath, "eula.file \(file) is outside \(name)/", "keep the licence text inside the manifest, e.g. eula.txt")
                return
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                error("\(name)/\(file)", "is missing (app.yml's eula.file)", "write the licence agreement there, or use `eula: standard`")
            } else {
                switch ManifestText.read(url, isURL: false) {
                case .success(nil): error("\(name)/\(file)", "is empty", "write the licence agreement, or use `eula: standard`")
                case .success: break
                case .failure(let problem): error("\(name)/\(file)", problem.message, problem.fix)
                }
            }
            territoryList(territories, key: "eula.territories")
        }

        mutating func territoryList(_ territories: StoreTerritories?, key: String) {
            guard case .only(let list)? = territories else { return }
            if list.isEmpty { error(appPath, "\(key) is an empty list", "list territories (USA, CAN…) or write `all`") }
            for t in list where t.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil {
                error(appPath, "\(key): \(t) is not a territory code", "use App Store Connect's three-letter codes, e.g. USA, GBR, JPN")
            }
        }

        mutating func pricing() {
            if let p = app.pricing {
                if let base = p.baseTerritory, base.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil {
                    error(appPath, "pricing.baseTerritory \(base) is not a territory code", "use a three-letter code, e.g. USA")
                }
                if let price = p.price, CustomerPrice.parse(price) == nil {
                    error(appPath, "pricing.price \(price) is not a price", "write `free` or the customer price in the base territory, quoted, e.g. \"0.99\"")
                }
                for (territory, price) in (p.territories?.values ?? [:]).sorted(by: { $0.key < $1.key }) {
                    if !Self.isTerritory(territory) {
                        error(appPath, "pricing.territories: \(territory) is not a territory code", "use App Store Connect's three-letter codes, e.g. GBR, JPN")
                    } else if territory == p.baseTerritory {
                        error(appPath, "pricing.territories lists the base territory \(territory)", "set its price with pricing.price, and remove it from pricing.territories")
                    }
                    if CustomerPrice.parse(price) == nil {
                        error(appPath, "pricing.territories.\(territory): \(price) is not a price", "write `free` or the customer price in \(territory)'s currency, quoted, e.g. \"0.99\"")
                    }
                }
                var seen: Set<String> = []
                for change in p.changes ?? [] {
                    let territory = change.territory ?? p.baseTerritory ?? "the base territory"
                    if !Self.isDay(change.date) {
                        error(appPath, "pricing.changes: \(change.date) is not a date", "write it as YYYY-MM-DD, quoted, e.g. \"2027-01-01\"")
                    }
                    if let t = change.territory, !Self.isTerritory(t) {
                        error(appPath, "pricing.changes: \(t) is not a territory code", "use App Store Connect's three-letter codes, or leave territory out for the base territory")
                    }
                    if CustomerPrice.parse(change.price) == nil {
                        error(appPath, "pricing.changes: \(change.price) (\(change.date)) is not a price", "write `free` or the customer price, quoted, e.g. \"0.99\"")
                    }
                    // Without baseTerritory, a change naming no territory is for USA (push's default base territory).
                    if !seen.insert("\(change.territory ?? p.baseTerritory ?? "USA") \(change.date)").inserted {
                        error(appPath, "pricing.changes has two changes for \(territory) on \(change.date)", "keep one")
                    }
                }
            }
            territoryList(app.availability?.territories, key: "availability.territories")
        }

        static func isTerritory(_ code: String) -> Bool { code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }

        /// YYYY-MM-DD, a real day.
        static func isDay(_ text: String) -> Bool {
            guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            f.isLenient = false
            return f.date(from: text).map { f.string(from: $0) == text } ?? false
        }

        // MARK: Locales

        mutating func locale(_ locale: String, _ listing: LocaleListing) {
            let base = "\(name)/\(locale)"
            do {
                let normal = try AppLocale.normalize(locale)
                if normal != locale { error(base, "App Store Connect spells this locale \(normal)", "rename the directory to \(normal)") }
            } catch {
                self.error(base, "\(locale) is not a locale", "name each locale directory with App Store Connect's code, e.g. en-US, de-DE, ja")
            }
            for (file, field) in LocaleListing.textFields {
                guard let value = listing[keyPath: field] else { continue }
                let path = "\(base)/\(file)"
                if let limit = ManifestValidator.limits[file] {
                    if file == "keywords.txt" {
                        let bytes = value.utf8.count
                        if bytes > limit { error(path, "\(bytes) bytes, Apple allows \(limit)", "shorten the keywords (comma-separated, counted in UTF-8 bytes)") }
                    } else if value.count > limit {
                        error(path, "\(value.count) characters, Apple allows \(limit)", "shorten it to \(limit) characters")
                    }
                }
                if file == "name.txt", value.count < 2 { error(path, "\(value.count) character, Apple needs at least 2", "write the app's name") }
                if LocaleListing.urlFiles.contains(file), !Self.isWebURL(value) {
                    error(path, "\(value) is not an http(s) URL", "write the full address, e.g. https://example.com/support")
                }
                if value.contains("\u{0}") { error(path, "contains a NUL character", "remove it") }
            }
            for set in listing.screenshots { screenshots(set, base: base) }
            for set in listing.previews { previews(set, base: base) }
        }

        static func isWebURL(_ text: String) -> Bool {
            guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
            return true
        }

        mutating func screenshots(_ set: MediaSet, base: String) {
            let setPath = "\(base)/screenshots/\(set.type)"
            let known = ScreenshotDisplayType.isKnown(set.type)
            if !known {
                warn(setPath, "\(set.type) is not a display type xless knows; its screenshots' sizes are not checked",
                     "check the spelling (App Store Connect's ScreenshotDisplayType, e.g. APP_IPHONE_67)")
            }
            if set.files.isEmpty { warn(setPath, "has no screenshots", "add screenshots, or remove the directory") }
            if set.files.count > ScreenshotDisplayType.maxPerSet {
                error(setPath, "\(set.files.count) screenshots, Apple allows \(ScreenshotDisplayType.maxPerSet)", "keep at most \(ScreenshotDisplayType.maxPerSet)")
            }
            for file in set.files {
                let path = "\(name)/\(file)"
                let ext = (file as NSString).pathExtension.lowercased()
                guard ScreenshotDisplayType.extensions.contains(ext) else {
                    error(path, "is not a .png, .jpg or .jpeg file", "App Store Connect takes PNG or JPEG screenshots")
                    continue
                }
                guard let info = ImageInfo.read(contentsOf: dir.appendingPathComponent(file)) else {
                    error(path, "is not a readable PNG or JPEG image", "export it again as PNG or JPEG")
                    continue
                }
                if info.hasAlpha { error(path, "has an alpha channel (transparency)", "export it without transparency (App Store Connect refuses it)") }
                if known, ScreenshotDisplayType.accepts(set.type, width: info.width, height: info.height) == false {
                    error(path, "\(info.width)x\(info.height) is not a size \(set.type) takes",
                          "use one of \(ScreenshotDisplayType.sizes(set.type).joined(separator: ", "))")
                }
            }
        }

        mutating func previews(_ set: MediaSet, base: String) {
            let setPath = "\(base)/previews/\(set.type)"
            if !PreviewType.known.contains(set.type) {
                warn(setPath, "\(set.type) is not a preview type xless knows", "check the spelling (App Store Connect's PreviewType, e.g. IPHONE_67)")
            }
            if set.files.count > PreviewType.maxPerSet {
                error(setPath, "\(set.files.count) previews, Apple allows \(PreviewType.maxPerSet)", "keep at most \(PreviewType.maxPerSet)")
            }
            for file in set.files {
                let path = "\(name)/\(file)"
                guard PreviewType.extensions.contains((file as NSString).pathExtension.lowercased()) else {
                    error(path, "is not a .mov, .m4v or .mp4 file", "App Store Connect takes app previews as .mov, .m4v or .mp4")
                    continue
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.size] as? Int) ?? 0
                if size > PreviewType.maxBytes { error(path, "\(size / (1024 * 1024)) MB, Apple allows 500 MB", "compress it (H.264, 10–12 Mbps)") }
            }
        }

        // MARK: What a submission needs

        mutating func submission() {
            if manifest.locales.isEmpty {
                missing(name, "has no locale directory", "create \(name)/<locale>/ (e.g. en-US) with name.txt, description.txt, keywords.txt, support_url.txt")
                return
            }
            for locale in manifest.orderedLocales {
                let listing = manifest.locales[locale]!
                for (file, field) in [("name.txt", \LocaleListing.name), ("description.txt", \.description), ("keywords.txt", \.keywords),
                                      ("support_url.txt", \.supportURL)] where listing[keyPath: field] == nil {
                    missing("\(name)/\(locale)/\(file)", "missing", "every locale needs its \(file.replacingOccurrences(of: ".txt", with: "").replacingOccurrences(of: "_", with: " "))")
                }
            }
            guard let primary = app.primaryLocale, let listing = manifest.locales[primary] else { return }
            if listing.privacyURL == nil {
                missing("\(name)/\(primary)/privacy_url.txt", "missing", "every app needs a privacy policy URL in its primary locale")
            }
            let required = ScreenshotDisplayType.required(for: app.platform)
            if !listing.screenshots.contains(where: { required.contains($0.type) && !$0.files.isEmpty }) {
                missing("\(name)/\(primary)/screenshots", "no screenshots for \(required.count == 1 ? required[0] : "any of " + required.joined(separator: ", "))",
                        "add at least one screenshot in \(name)/\(primary)/screenshots/\(required[0])/ (sizes: \(ScreenshotDisplayType.sizes(required[0]).joined(separator: ", ")))")
            }
        }
    }
}
