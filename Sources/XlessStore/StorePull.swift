import Foundation
import XlessASC
import XlessCore

/// `xless store pull`: an app's listing, as App Store Connect has it, written to an `appstore/` directory.
public struct StorePull: Sendable {
    /// Which App Store version's listing to read.
    public enum Selection: Sendable, Equatable {
        /// The editable version if there is one, else the live one, else the newest.
        case automatic
        case version(String)
        case live
        case editable
    }

    public struct Report: Encodable, Sendable, Equatable {
        public var appID: String
        public var bundleID: String
        public var platform: String
        public var version: String
        public var versionState: String
        public var directory: String
        public var locales: [String]
        public var screenshots: Int
        public var previews: Int
        /// Media files downloaded from App Store Connect.
        public var downloaded: Int
        /// Media files kept as they were (the local original of the same upload, per media.lock).
        public var kept: Int
        /// Media left out (still processing at Apple, or only streamable), by path.
        public var skipped: [String]

        public var text: String {
            var out = "Pulled \(bundleID) (\(platform) \(version), \(versionState)) into \(directory)/: \(locales.count) locale\(locales.count == 1 ? "" : "s") (\(locales.joined(separator: ", "))), "
            out += "\(screenshots) screenshot\(screenshots == 1 ? "" : "s"), \(previews) preview\(previews == 1 ? "" : "s")"
            out += " (\(downloaded) downloaded, \(kept) unchanged)\n"
            for path in skipped { out += "  not downloaded: \(path)\n" }
            return out
        }
    }

    public static let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]
    public static let liveStates: Set<String> = ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION"]
    /// The secret name a pulled manifest gives the demo account's password when it has none yet.
    public static let defaultDemoSecret = "XLESS_DEMO_PASSWORD"

    public let asc: StoreASC
    /// Fetches a media file from its delivery URL (https, no credentials).
    public let download: @Sendable (URL) async throws -> Data
    public let say: @Sendable (String) -> Void

    public init(resources: ASCResources, download: @escaping @Sendable (URL) async throws -> Data, say: @escaping @Sendable (String) -> Void = { _ in }) {
        asc = StoreASC(resources: resources, say: say)
        self.download = download
        self.say = say
    }

    /// Reads `app`'s listing and replaces `dir` with it (built aside and swapped in: a failure leaves `dir` as it was).
    /// - Parameter platform: IOS, MAC_OS, TV_OS or VISION_OS; nil: the existing manifest's, else the only platform the
    ///   app has versions for, else IOS.
    public func run(app: ASCApp, platform requested: String?, selection: Selection, into dir: URL, today: Date = Date()) async throws -> Report {
        let existing = try Self.existingManifest(dir)
        let old = existing?.app
        let oldLock = MediaLock.read(dir)

        let versions = try await asc.versions(of: app.id)
        let platform = try choosePlatform(requested ?? old?.platform, versions: versions)
        let version = try chooseVersion(selection, platform: platform, versions: versions.filter { $0.attributes.platform == platform })
        let isLive = Self.isLive(version.attributes)

        var manifest = StoreManifest()
        manifest.extras = existing?.extras ?? []
        var a = AppYAML()
        a.bundleID = app.bundleID
        a.sku = app.attributes.sku
        a.platform = platform
        a.primaryLocale = app.attributes.primaryLocale
        a.version = version.attributes.versionString
        a.copyright = version.attributes.copyright
        a.contentRights = app.attributes.contentRightsDeclaration

        // App info: the live one for a live version, else the one being edited.
        let infos = try await asc.appInfos(of: app.id)
        let info = infos.first { (Self.isLiveInfo($0.attributes)) == isLive } ?? infos.first
        if let info {
            a.categories = Self.categories(info.resource)
            switch try await asc.ageRating(of: info.id) {
            case .value(let answers): a.ageRating = Self.scalars(answers).nonEmpty
            case .absent: break
            case .forbidden: a.ageRating = old?.ageRating
            }
            for l in try await asc.appInfoLocalizations(of: info.id) {
                guard let locale = usableLocale(l.attributes.locale) else { continue }
                var listing = manifest.locales[locale] ?? LocaleListing()
                listing.name = Self.text(l.attributes.name)
                listing.subtitle = Self.text(l.attributes.subtitle)
                listing.privacyURL = Self.url(l.attributes.privacyPolicyUrl)
                listing.privacyChoicesURL = Self.url(l.attributes.privacyChoicesUrl)
                listing.privacyPolicyText = Self.text(l.attributes.privacyPolicyText)
                manifest.locales[locale] = listing
            }
        }

        let type = version.attributes.releaseType
        let phased: Bool?
        switch try await asc.phasedRelease(of: version.id) {
        case .value(let p): phased = p
        case .absent: phased = false
        case .forbidden: phased = old?.release?.phased
        }
        a.release = AppYAML.Release(type: type, earliestDate: type == "SCHEDULED" ? version.attributes.earliestReleaseDate : nil, phased: phased)
        switch try await asc.reviewDetail(of: version.id) {
        case .value(let detail): a.review = review(detail, existing: old?.review)
        case .absent: a.review = nil
        case .forbidden: a.review = old?.review
        }
        // App Store Connect gives no way to download App Review attachments: the files app.yml lists stay as they are.
        if let attachments = old?.review?.attachments {
            var review = a.review ?? AppYAML.Review()
            review.attachments = attachments
            a.review = review
        }

        var files: [String: ManifestWriter.Content] = [:]
        var lock = MediaLock()
        var report = Report(appID: app.id, bundleID: app.bundleID, platform: platform, version: version.attributes.versionString ?? "",
                            versionState: version.attributes.appVersionState ?? version.attributes.appStoreState ?? "", directory: dir.lastPathComponent,
                            locales: [], screenshots: 0, previews: 0, downloaded: 0, kept: 0, skipped: [])
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent).download-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var media = MediaFetch(pull: self, dir: dir, staging: staging, oldLock: oldLock)

        for l in try await asc.versionLocalizations(of: version.id) {
            guard let locale = usableLocale(l.attributes.locale) else { continue }
            var listing = manifest.locales[locale] ?? LocaleListing()
            listing.description = Self.text(l.attributes.description)
            listing.keywords = Self.text(l.attributes.keywords)
            listing.promotionalText = Self.text(l.attributes.promotionalText)
            listing.whatsNew = Self.text(l.attributes.whatsNew)
            listing.supportURL = Self.url(l.attributes.supportUrl)
            listing.marketingURL = Self.url(l.attributes.marketingUrl)
            for set in try await asc.screenshotSets(of: l.id) where usableSetType(set.type) {
                listing.screenshots.append(try await media.fetch(set, kind: "screenshots", locale: locale, files: &files, lock: &lock, report: &report))
            }
            for set in try await asc.previewSets(of: l.id) where usableSetType(set.type) {
                listing.previews.append(try await media.fetch(set, kind: "previews", locale: locale, files: &files, lock: &lock, report: &report))
            }
            listing.screenshots.sort { $0.type < $1.type }
            listing.previews.sort { $0.type < $1.type }
            manifest.locales[locale] = listing
        }

        switch try await asc.encryption(of: app.id) {
        case .value(let encryption):
            let kept = ["appDescription", "availableOnFrenchStore", "containsProprietaryCryptography", "containsThirdPartyCryptography", "exempt", "usesEncryption"]
            a.encryption = Self.scalars(encryption.filter { kept.contains($0.key) }).nonEmpty
        case .absent: break
        case .forbidden: a.encryption = old?.encryption
        }
        a.encryptionDocument = old?.encryptionDocument
        switch try await asc.accessibility(of: app.id) {
        case .value(let declarations): a.accessibility = Self.accessibility(declarations, live: isLive)
        case .absent: break
        case .forbidden: a.accessibility = old?.accessibility
        }
        switch try await asc.eula(of: app.id) {
        case .value(let eula):
            files["eula.txt"] = .data(Data(ManifestText.render(eula.text).utf8))
            var territories = StoreTerritories.only(eula.territories.sorted())
            if case .value(let everywhere) = try await asc.territories(), !everywhere.isEmpty, Set(eula.territories).isSuperset(of: everywhere) { territories = .all }
            a.eula = .custom(file: "eula.txt", territories: territories)
        case .absent:
            a.eula = .standard
        case .forbidden:
            a.eula = old?.eula
            if case .custom(let file, _)? = old?.eula, let url = StoreManifest.resolve(file, in: dir), FileManager.default.fileExists(atPath: url.path) {
                files[file] = .file(url)
            }
        }
        switch try await asc.pricing(of: app.id, today: today) {
        case .value(let pricing): a.pricing = pricing
        case .absent: break
        case .forbidden: a.pricing = old?.pricing
        }
        switch try await asc.availability(of: app.id) {
        case .value(let availability):
            a.availability = AppYAML.Availability(territories: availability.all ? .all : .only(availability.available), newTerritories: availability.newTerritories)
        case .absent: break
        case .forbidden: a.availability = old?.availability
        }

        a.previewFrames = media.frames.isEmpty ? nil : SortedMap(media.frames)
        manifest.app = a
        report.locales = manifest.orderedLocales
        // Attachments and the compliance document are not pulled: their lock entries stay.
        let named = Set((old?.review?.attachments ?? []) + (old?.encryptionDocument.map { [$0] } ?? []))
        for (path, entry) in oldLock.files.values
        where named.contains(path) || path.split(separator: "/").first.map({ ManifestReader.reservedDirectories.contains(String($0)) }) == true {
            lock.files[path] = entry
        }
        // Local media App Store Connect does not have (never pushed) are not part of what was pulled: say so.
        let localMedia = (existing?.locales.values ?? [:].values).flatMap { ($0.screenshots + $0.previews).flatMap(\.files) }
        // (Only a file the lock ties to an upload can be kept.)
        for path in localMedia.sorted() where oldLock.files[path]?.appleChecksum == nil {
            say("note: \(path) is not on App Store Connect (never uploaded), so the pulled listing does not have it")
        }
        try ManifestWriter.write(manifest, files: files, lock: lock, to: dir)
        return report
    }

    /// The manifest at `dir` that pull replaces; nil when there is none. Refuses a directory pull must not replace: one
    /// that is not a manifest (no app.yml, not empty), or whose app.yml cannot be read (its keys would be lost).
    static func existingManifest(_ dir: URL) throws -> StoreManifest? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        let name = dir.lastPathComponent
        guard fm.fileExists(atPath: dir.appendingPathComponent(ManifestReader.appFile).path) else {
            let entries = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
            guard entries.isEmpty else {
                throw XlessError(.account, "\(dir.path) is not an App Store manifest (it has no app.yml) and is not empty",
                                 fix: "pull into a new or empty directory (--dir appstore)")
            }
            return nil
        }
        let read = ManifestReader.read(dir)
        let appIssues = read.issues.filter { $0.severity == .error && $0.path == "\(name)/\(ManifestReader.appFile)" }
        if let first = appIssues.first {
            throw XlessError(.account, "\(first.path) cannot be read: \(first.message); pulling would lose what it holds",
                             fix: "fix it (`xless store validate` lists the problems), or move it aside, then re-run")
        }
        return read.manifest
    }

    /// A locale App Store Connect sent, when it is safe as a directory name.
    func usableLocale(_ locale: String?) -> String? {
        guard let locale, locale.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            say("note: App Store Connect sent a localization with an unusable locale (\(locale ?? "none")); it is left out")
            return nil
        }
        return locale
    }

    /// A display or preview type App Store Connect sent, when it is safe as a directory name.
    func usableSetType(_ type: String) -> Bool {
        guard type.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil else {
            say("note: App Store Connect sent a media set of an unusable type (\(type)); it is left out")
            return false
        }
        return true
    }

    // MARK: - Choices

    func choosePlatform(_ wanted: String?, versions: [ASCKeptResource<StoreVersionAttributes>]) throws -> String {
        let platforms = Array(Set(versions.compactMap(\.attributes.platform))).sorted()
        if let wanted { return wanted }
        if platforms.count == 1 { return platforms[0] }
        if platforms.count > 1 {
            say("note: the app has App Store versions for \(platforms.joined(separator: ", ")); pulling IOS (choose with --platform)")
        }
        return "IOS"
    }

    func chooseVersion(_ selection: Selection, platform: String, versions: [ASCKeptResource<StoreVersionAttributes>]) throws -> ASCKeptResource<StoreVersionAttributes> {
        let listed = versions.compactMap(\.attributes.versionString).joined(separator: ", ")
        guard !versions.isEmpty else {
            throw XlessError(.account, "the app has no App Store version for \(platform)",
                             fix: "pass --platform for another platform, or create the version in App Store Connect (`xless store push` will, #94)")
        }
        let editable = versions.first { Self.isEditable($0.attributes) }
        let live = versions.first { Self.isLive($0.attributes) }
        switch selection {
        case .version(let v):
            guard let found = versions.first(where: { $0.attributes.versionString == v }) else {
                throw XlessError(.account, "the app has no \(platform) App Store version \(v)", fix: "use one of: \(listed)")
            }
            return found
        case .live:
            guard let live else { throw XlessError(.account, "the app has no \(platform) version on the App Store yet", fix: "pull the version being prepared (--editable), or one of: \(listed)") }
            return live
        case .editable:
            guard let editable else { throw XlessError(.account, "no \(platform) version of the app can be edited now", fix: "pull the live version (--live), or one of: \(listed)") }
            return editable
        case .automatic:
            return editable ?? live ?? versions.max { ($0.attributes.createdDate ?? "") < ($1.attributes.createdDate ?? "") }!
        }
    }

    static func isEditable(_ v: StoreVersionAttributes) -> Bool {
        [v.appVersionState, v.appStoreState].contains { $0.map(editableStates.contains) ?? false }
    }

    static func isLive(_ v: StoreVersionAttributes) -> Bool {
        [v.appVersionState, v.appStoreState].contains { $0.map(liveStates.contains) ?? false }
    }

    static func isLiveInfo(_ i: StoreAppInfoAttributes) -> Bool {
        [i.state, i.appStoreState].contains { $0.map(liveStates.contains) ?? false }
    }

    // MARK: - Mapping

    static func text(_ value: String?) -> String? { value.flatMap { ManifestText.normalize($0, isURL: false) } }
    static func url(_ value: String?) -> String? { value.flatMap { ManifestText.normalize($0, isURL: true) } }

    static func categories(_ info: ASCAnyResource) -> AppYAML.Categories? {
        func id(_ name: String) -> String? { info.relationships?[name]?["data"]?["id"]?.string }
        let c = AppYAML.Categories(primary: id("primaryCategory"),
                                   primarySubcategories: [id("primarySubcategoryOne"), id("primarySubcategoryTwo")].compactMap { $0 }.nilIfEmpty,
                                   secondary: id("secondaryCategory"),
                                   secondarySubcategories: [id("secondarySubcategoryOne"), id("secondarySubcategoryTwo")].compactMap { $0 }.nilIfEmpty)
        return c == AppYAML.Categories() ? nil : c
    }

    /// Apple's scalar attribute values, nulls and nested values left out.
    static func scalars(_ attributes: [String: JSONValue]) -> SortedMap<StoreScalar> {
        var out: [String: StoreScalar] = [:]
        for (key, value) in attributes {
            switch value {
            case .bool(let b): out[key] = .bool(b)
            case .int(let i): out[key] = .int(i)
            case .double(let d): out[key] = .double(d)
            case .string(let s): out[key] = .string(s)
            case .null, .array, .object: continue
            }
        }
        return SortedMap(out)
    }

    /// Device family → its `supports…` answers, from the declaration being edited (DRAFT) or, for a live pull, the
    /// published one.
    static func accessibility(_ declarations: [ASCAnyResource], live: Bool) -> SortedMap<SortedMap<Bool>>? {
        let order = live ? ["PUBLISHED", "DRAFT"] : ["DRAFT", "PUBLISHED"]
        var chosen: [String: (rank: Int, answers: [String: Bool])] = [:]
        for d in declarations {
            guard let family = d.attributes?["deviceFamily"]?.string else { continue }
            let rank = order.firstIndex(of: d.attributes?["state"]?.string ?? "") ?? order.count
            guard rank < order.count, rank < (chosen[family]?.rank ?? Int.max) else { continue }
            var answers: [String: Bool] = [:]
            for (key, value) in d.attributes ?? [:] where key.hasPrefix("supports") {
                if case .bool(let b) = value { answers[key] = b }
            }
            chosen[family] = (rank, answers)
        }
        return chosen.isEmpty ? nil : SortedMap(chosen.mapValues { SortedMap($0.answers) })
    }

    func review(_ detail: StoreReviewDetailAttributes?, existing: AppYAML.Review?) -> AppYAML.Review? {
        guard let detail else { return existing }
        var r = AppYAML.Review()
        let contact = AppYAML.Contact(firstName: Self.text(detail.contactFirstName), lastName: Self.text(detail.contactLastName),
                                      phone: Self.text(detail.contactPhone), email: Self.text(detail.contactEmail))
        if contact != AppYAML.Contact() { r.contact = contact }
        r.notes = Self.text(detail.notes)
        let name = Self.text(detail.demoAccountName)
        var secret = existing?.demoAccount?.passwordSecret
        if detail.demoAccountRequired == true, secret == nil {
            secret = Self.defaultDemoSecret
            say("note: App Review signs in with a demo account; its password is not pulled. Store it once: `xless secrets import \(Self.defaultDemoSecret) --file <file> --kind password`")
        }
        if detail.demoAccountRequired != nil || name != nil {
            r.demoAccount = AppYAML.DemoAccount(required: detail.demoAccountRequired, name: name, passwordSecret: secret)
        }
        return r == AppYAML.Review() ? nil : r
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

private extension SortedMap {
    var nonEmpty: SortedMap? { isEmpty ? nil : self }
}

/// Fetching one set's media: keep the local original of an unchanged upload, else download Apple's copy.
struct MediaFetch {
    let pull: StorePull
    let dir: URL
    let staging: URL
    let oldLock: MediaLock
    /// Poster frames of the previews written: path → `previewFrameTimeCode`.
    var frames: [String: String] = [:]

    mutating func fetch(_ set: StoreRemoteSet, kind: String, locale: String, files: inout [String: ManifestWriter.Content],
                        lock: inout MediaLock, report: inout StorePull.Report) async throws -> MediaSet {
        var paths: [String] = []
        for (index, item) in set.items.enumerated() {
            let a = item.attributes
            let name = Self.fileName(index: index + 1, original: a.fileName, kind: kind)
            let path = "\(locale)/\(kind)/\(set.type)/\(name)"
            if kind == "screenshots" { report.screenshots += 1 } else { report.previews += 1 }
            if let checksum = a.sourceFileChecksum, let local = oldLock.unchangedFile(for: checksum, in: dir) {
                files[path] = .file(dir.appendingPathComponent(local))
                lock.files[path] = MediaLock.Entry(md5: oldLock.files[local]?.md5, appleChecksum: checksum, id: item.id)
                report.kept += 1
                paths.append(path)
                if kind == "previews", let frame = a.previewFrameTimeCode { frames[path] = frame }
                continue
            }
            guard a.assetDeliveryState?.state == nil || a.assetDeliveryState?.state == "COMPLETE", let url = Self.deliveryURL(a, kind: kind, name: name) else {
                report.skipped.append("\(path) (\(a.assetDeliveryState?.state.map { "processing: \($0)" } ?? "no delivery URL"))")
                lock.files[path] = MediaLock.Entry(md5: nil, appleChecksum: a.sourceFileChecksum, id: item.id)
                continue
            }
            let data = try await pull.download(url)
            if kind == "previews", data.starts(with: Data("#EXTM3U".utf8)) {
                report.skipped.append("\(path) (App Store Connect serves it only as a stream)")
                lock.files[path] = MediaLock.Entry(md5: nil, appleChecksum: a.sourceFileChecksum, id: item.id)
                continue
            }
            let staged = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: staged)
            files[path] = .file(staged)
            lock.files[path] = MediaLock.Entry(md5: MD5Hex.of(data), appleChecksum: a.sourceFileChecksum, id: item.id)
            report.downloaded += 1
            paths.append(path)
            if kind == "previews", let frame = a.previewFrameTimeCode { frames[path] = frame }
        }
        return MediaSet(type: set.type, files: paths)
    }

    /// `NN-<original name>`: the display position, then the uploaded file's name without a position of its own, in
    /// file-name-safe characters.
    static func fileName(index: Int, original: String?, kind: String) -> String {
        var base = original ?? ""
        if let dash = base.firstIndex(of: "-"), !base[..<dash].isEmpty, base[..<dash].allSatisfy({ $0.isASCII && $0.isNumber }) {
            base = String(base[base.index(after: dash)...])
        }
        base = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
        while base.hasPrefix(".") { base.removeFirst() }
        let ext = (base as NSString).pathExtension.lowercased()
        let allowed = kind == "screenshots" ? ScreenshotDisplayType.extensions : PreviewType.extensions
        if base.isEmpty || !allowed.contains(ext) {
            base = (base.isEmpty ? (kind == "screenshots" ? "screenshot" : "preview") : (base as NSString).deletingPathExtension) + (kind == "screenshots" ? ".png" : ".mov")
        }
        return String(format: "%02d-", index) + base
    }

    /// Where Apple serves the item: a screenshot's image template at its full size, in its own format; a preview's video.
    static func deliveryURL(_ a: StoreMediaAttributes, kind: String, name: String) -> URL? {
        let text: String?
        if kind == "screenshots" {
            guard let asset = a.imageAsset, let template = asset.templateUrl, let w = asset.width, let h = asset.height else { return nil }
            let format = ["jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()) ? "jpg" : "png"
            text = template.replacingOccurrences(of: "{w}", with: "\(w)").replacingOccurrences(of: "{h}", with: "\(h)").replacingOccurrences(of: "{f}", with: format)
        } else {
            text = a.videoUrl
        }
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
