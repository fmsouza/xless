import Foundation
import XlessASC
import XlessCore

// The `text` part: the version (create, version string, copyright, release), its phased release, the app's primary
// locale, the categories, and per locale the app information (name, subtitle, privacy) and the version's text.

extension PushContext {
    mutating func planText() async throws {
        try planVersion()
        try await planPhasedRelease()
        try await planCategories()
        try await planInfoLocalizations()
        try await planVersionLocalizations()
        // After the localizations: the new primary locale may be one this push adds.
        planPrimaryLocale()
    }

    // MARK: The version

    mutating func planVersion() throws {
        let release = app.release
        let earliest = release?.type == "SCHEDULED" ? release?.earliestDate : nil
        let subject = "version \(target.versionString) (\(target.platform))"
        switch target.version {
        case .create:
            var attributes: [String: JSONValue] = ["platform": .string(target.platform), "versionString": .string(target.versionString)]
            var fields = [StoreFieldChange("versionString", from: nil, to: target.versionString)]
            for (key, value) in [("copyright", app.copyright), ("releaseType", release?.type), ("earliestReleaseDate", earliest)] {
                guard let value else { continue }
                attributes[key] = .string(value)
                fields.append(StoreFieldChange(key, from: nil, to: value))
            }
            add(StoreChange(.create, .text, subject, fields: fields,
                            requests: [.create("appStoreVersions", attributes: attributes, relationships: ["app": StoreRequest.link("apps", target.app.id)])],
                            replans: true))
        case .existing(let v), .rename(let v):
            var diff = FieldDiff()
            if case .rename = target.version { diff.text("versionString", want: target.versionString, have: v.attributes.versionString) }
            diff.text("copyright", want: app.copyright, have: v.attributes.copyright, clears: false)
            diff.text("releaseType", want: release?.type, have: v.attributes.releaseType, clears: false)
            if let earliest, !Self.sameInstant(earliest, v.attributes.earliestReleaseDate) {
                diff.attributes["earliestReleaseDate"] = .string(earliest)
                diff.fields.append(StoreFieldChange("earliestReleaseDate", from: v.attributes.earliestReleaseDate, to: earliest))
            }
            guard !diff.isEmpty else { return }
            try requireEditableVersion("the version's \(diff.fields.map(\.name).joined(separator: ", "))")
            add(StoreChange(.update, .text, subject, fields: diff.fields, requests: [.update("appStoreVersions", id: v.id, attributes: diff.attributes)]))
        }
    }

    /// Two ISO 8601 times that are the same instant (Apple may write fractions or another offset).
    static func sameInstant(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        if a == b { return true }
        func parse(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        guard let x = parse(a), let y = parse(b) else { return false }
        return x == y
    }

    mutating func planPhasedRelease() async throws {
        guard let phased = app.release?.phased else { return }
        let current: StorePart<ASCAnyResource> = if let id = target.versionID { try await asc.phasedReleaseResource(of: id) } else { .absent }
        switch current {
        case .forbidden: return
        case .absent:
            guard phased else { return }
            try requireEditableVersion("the phased release")
            add(StoreChange(.create, .text, "phased release", fields: [StoreFieldChange("phased", from: "false", to: "true")],
                            requests: [.create("appStoreVersionPhasedReleases", attributes: ["phasedReleaseState": .string("INACTIVE")],
                                               relationships: ["appStoreVersion": StoreRequest.link("appStoreVersions", target.versionID ?? "{version}")])]))
        case .value(let release):
            guard !phased else { return }
            let state = release.attributes?["phasedReleaseState"]?.string ?? "INACTIVE"
            guard state == "INACTIVE" else {
                note("the phased release of \(target.versionString) has started (\(state)); app.yml's `phased: false` is not applied to it")
                return
            }
            try requireEditableVersion("the phased release")
            add(StoreChange(.delete, .text, "phased release", fields: [StoreFieldChange("phased", from: "true", to: "false")],
                            requests: [.delete("appStoreVersionPhasedReleases", id: release.id)]))
        }
    }

    // MARK: The app and its information

    mutating func planPrimaryLocale() {
        guard let wanted = app.primaryLocale, wanted != target.app.attributes.primaryLocale else { return }
        add(StoreChange(.update, .text, "primary locale", fields: [StoreFieldChange("primaryLocale", from: target.app.attributes.primaryLocale, to: wanted)],
                        requests: [.update("apps", id: target.app.id, attributes: ["primaryLocale": .string(wanted)])]))
    }

    static let categorySlots: [(relationship: String, pick: @Sendable (AppYAML.Categories) -> String?)] = [
        ("primaryCategory", { $0.primary }),
        ("primarySubcategoryOne", { $0.primarySubcategories?.first }),
        ("primarySubcategoryTwo", { ($0.primarySubcategories ?? []).dropFirst().first }),
        ("secondaryCategory", { $0.secondary }),
        ("secondarySubcategoryOne", { $0.secondarySubcategories?.first }),
        ("secondarySubcategoryTwo", { ($0.secondarySubcategories ?? []).dropFirst().first }),
    ]

    mutating func planCategories() async throws {
        guard let wanted = app.categories, let info = target.info else { return }
        let have = StorePull.categories(info.resource) ?? AppYAML.Categories()
        var fields: [StoreFieldChange] = []
        var relationships: [String: JSONValue] = [:]
        for slot in Self.categorySlots {
            let (want, current) = (slot.pick(wanted), slot.pick(have))
            // An app always has a primary category: one app.yml does not give is left as it is.
            guard want != current, want != nil || slot.relationship != "primaryCategory" else { continue }
            fields.append(StoreFieldChange(slot.relationship, from: current, to: want))
            relationships[slot.relationship] = StoreRequest.link("appCategories", want)
        }
        guard !fields.isEmpty else { return }
        try requireEditableInfo("the categories")
        try await checkCategories(wanted)
        add(StoreChange(.update, .text, "categories", fields: fields, requests: [.update("appInfos", id: info.id, relationships: relationships)]))
    }

    /// The categories exist for the platform, each subcategory under its own category.
    func checkCategories(_ c: AppYAML.Categories) async throws {
        let offered = try await asc.categories(platform: target.platform)
        let fix = "use the IDs App Store Connect lists for \(target.platform): `xless api GET /v1/appCategories --paginate -f filter[platforms]=\(target.platform) -f include=subcategories`"
        for (key, top, subs) in [("primary", c.primary, c.primarySubcategories), ("secondary", c.secondary, c.secondarySubcategories)] {
            guard let top else { continue }
            guard let allowed = offered[top] else {
                throw XlessError(.account, "\(name)/app.yml: categories.\(key) \(top) is not a \(target.platform) category", fix: fix)
            }
            for sub in subs ?? [] where !allowed.contains(sub) {
                throw XlessError(.account, "\(name)/app.yml: categories.\(key)Subcategories: \(sub) is not a subcategory of \(top)",
                                 fix: allowed.isEmpty ? "\(top) has no subcategories: remove \(key)Subcategories" : "use one of \(allowed.sorted().joined(separator: ", "))")
            }
        }
    }

    mutating func planInfoLocalizations() async throws {
        guard !manifest.locales.isEmpty, let info = target.info else { return }
        let remote = Dictionary(try await asc.appInfoLocalizations(of: info.id).compactMap { l in l.attributes.locale.map { ($0, l) } }, uniquingKeysWith: { a, _ in a })
        for locale in manifest.orderedLocales {
            let listing = manifest.locales[locale]!
            var diff = FieldDiff()
            let have = remote[locale]?.attributes
            diff.text("name", want: listing.name, have: have?.name, clears: false)
            diff.text("subtitle", want: listing.subtitle, have: have?.subtitle)
            diff.text("privacyPolicyUrl", want: listing.privacyURL, have: have?.privacyPolicyUrl, isURL: true)
            diff.text("privacyChoicesUrl", want: listing.privacyChoicesURL, have: have?.privacyChoicesUrl, isURL: true)
            diff.text("privacyPolicyText", want: listing.privacyPolicyText, have: have?.privacyPolicyText)
            // A locale App Store Connect does not have yet starts with its name.
            if remote[locale] == nil, listing.name == nil {
                throw XlessError(.account, "\(name)/\(locale)/name.txt is missing: App Store Connect needs the app's name to add the locale \(locale)",
                                 fix: "write the app's name in \(name)/\(locale)/name.txt")
            }
            guard !diff.isEmpty else { continue }
            try requireEditableInfo("\(name)/\(locale)'s \(diff.fields.map(\.name).joined(separator: ", "))")
            if let existing = remote[locale] {
                add(StoreChange(.update, .text, "app info \(locale)", fields: diff.fields,
                                requests: [.update("appInfoLocalizations", id: existing.id, attributes: diff.attributes)]))
            } else {
                var attributes = diff.attributes.filter { $0.value != .null }
                attributes["locale"] = .string(locale)
                add(StoreChange(.create, .text, "app info \(locale)", fields: diff.fields.filter { $0.to != nil },
                                requests: [.create("appInfoLocalizations", attributes: attributes, relationships: ["appInfo": StoreRequest.link("appInfos", info.id)])]))
            }
        }
        // A version push creates gets the live locales; they are looked at once it exists.
        for (locale, l) in remote.sorted(by: { $0.key < $1.key }) where manifest.locales[locale] == nil && !target.creating {
            try planExtraLocale(locale, subject: "app info \(locale)", type: "appInfoLocalizations", id: l.id, editable: target.infoEditable)
        }
    }

    mutating func planVersionLocalizations() async throws {
        guard !manifest.locales.isEmpty else { return }
        let remote: [String: ASCKeptResource<StoreVersionLocalizationAttributes>]
        if let id = target.versionID {
            remote = Dictionary(try await asc.versionLocalizations(of: id).compactMap { l in l.attributes.locale.map { ($0, l) } }, uniquingKeysWith: { a, _ in a })
        } else {
            remote = [:]
        }
        for locale in manifest.orderedLocales {
            let listing = manifest.locales[locale]!
            let have = remote[locale]?.attributes
            var diff = FieldDiff()
            diff.text("description", want: listing.description, have: have?.description)
            diff.text("keywords", want: listing.keywords, have: have?.keywords)
            diff.text("promotionalText", want: listing.promotionalText, have: have?.promotionalText)
            diff.text("whatsNew", want: listing.whatsNew, have: have?.whatsNew)
            diff.text("supportUrl", want: listing.supportURL, have: have?.supportUrl, isURL: true)
            diff.text("marketingUrl", want: listing.marketingURL, have: have?.marketingUrl, isURL: true)
            guard !diff.isEmpty else { continue }
            // Promotional text changes at any time; the rest only while the version is being prepared.
            let locked = diff.fields.map(\.name).filter { $0 != "promotionalText" }
            if !locked.isEmpty { try requireEditableVersion("\(name)/\(locale)'s \(locked.joined(separator: ", "))") }
            if let existing = remote[locale] {
                add(StoreChange(.update, .text, "version text \(locale)", fields: diff.fields,
                                requests: [.update("appStoreVersionLocalizations", id: existing.id, attributes: diff.attributes)]))
            } else {
                var attributes = diff.attributes.filter { $0.value != .null }
                attributes["locale"] = .string(locale)
                add(StoreChange(.create, .text, "version text \(locale)", fields: diff.fields.filter { $0.to != nil },
                                requests: [.create("appStoreVersionLocalizations", attributes: attributes,
                                                   relationships: ["appStoreVersion": StoreRequest.link("appStoreVersions", target.versionID ?? "{version}")])]))
            }
        }
        for (locale, l) in remote.sorted(by: { $0.key < $1.key }) where manifest.locales[locale] == nil {
            try planExtraLocale(locale, subject: "version text \(locale)", type: "appStoreVersionLocalizations", id: l.id, editable: target.editable)
        }
    }

    /// A locale App Store Connect has and the manifest does not: reported, deleted with `--prune` (never the primary).
    mutating func planExtraLocale(_ locale: String, subject: String, type: String, id: String, editable: Bool) throws {
        guard options.prune else {
            note("\(subject) is on App Store Connect but has no directory in \(name)/: kept (--prune deletes it)")
            return
        }
        guard locale != (app.primaryLocale ?? target.app.attributes.primaryLocale) else {
            note("\(subject) is the primary locale: never deleted")
            return
        }
        guard editable else {
            note("\(subject) cannot be deleted while it is live: kept")
            return
        }
        add(StoreChange(.delete, .text, subject, requests: [.delete(type, id: id)]))
    }
}
