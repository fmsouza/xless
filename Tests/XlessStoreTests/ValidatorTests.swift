import Foundation
import Testing
@testable import XlessStore

/// The issue lines `validate` prints for the manifest at `dir`.
private func lines(_ dir: URL, draft: Bool = false, inherited: String? = nil) -> [String] {
    let read = ManifestReader.read(dir)
    return (read.issues + ManifestValidator.validate(read.manifest, at: dir, draft: draft, inheritedBundleID: inherited)).map(\.description)
}

private func withManifest(_ body: (URL) throws -> Void) throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try body(dir)
}

@Test func aCompleteManifestIsValid() throws {
    try withManifest { #expect(lines($0) == []) }
}

@Test func keywordsAreCountedInBytes() throws {
    try withManifest { dir in
        // 56 two-byte characters: 56 characters but 112 bytes.
        try write(String(repeating: "é", count: 56) + "\n", "en-US/keywords.txt", in: dir)
        #expect(lines(dir) == ["[account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten the keywords (comma-separated, counted in UTF-8 bytes)"])
    }
}

@Test func textLimitsAreCharacters() throws {
    try withManifest { dir in
        try write(String(repeating: "é", count: 30) + "\n", "en-US/name.txt", in: dir)
        try write(String(repeating: "a", count: 31), "en-US/subtitle.txt", in: dir)
        try write(String(repeating: "a", count: 171), "en-US/promotional_text.txt", in: dir)
        try write(String(repeating: "a", count: 4001), "en-US/description.txt", in: dir)
        try write(String(repeating: "a", count: 4001), "en-US/whats_new.txt", in: dir)
        #expect(lines(dir) == [
            "[account] appstore/en-US/subtitle.txt: 31 characters, Apple allows 30 — shorten it to 30 characters",
            "[account] appstore/en-US/description.txt: 4001 characters, Apple allows 4000 — shorten it to 4000 characters",
            "[account] appstore/en-US/promotional_text.txt: 171 characters, Apple allows 170 — shorten it to 170 characters",
            "[account] appstore/en-US/whats_new.txt: 4001 characters, Apple allows 4000 — shorten it to 4000 characters",
        ])
    }
}

@Test func urlsAndLocalesAreChecked() throws {
    try withManifest { dir in
        try write("example.com/support\n", "en-US/support_url.txt", in: dir)
        try write("ftp://example.com\n", "en-US/marketing_url.txt", in: dir)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("en-US"), to: dir.appendingPathComponent("de-de"))
        try write("Beispiel\n", "english/name.txt", in: dir)
        let out = lines(dir)
        #expect(out.contains("[account] appstore/en-US/support_url.txt: example.com/support is not an http(s) URL — write the full address, e.g. https://example.com/support"))
        #expect(out.contains("[account] appstore/en-US/marketing_url.txt: ftp://example.com is not an http(s) URL — write the full address, e.g. https://example.com/support"))
        #expect(out.contains("[account] appstore/de-de: App Store Connect spells this locale de-DE — rename the directory to de-DE"))
        #expect(out.contains("[account] appstore/english: english is not a locale — name each locale directory with App Store Connect's code, e.g. en-US, de-DE, ja"))
    }
}

@Test func screenshotsAreCheckedBySizeAlphaFormatAndCount() throws {
    try withManifest { dir in
        let set = "en-US/screenshots/APP_IPHONE_67"
        try write(pngHeader(1284, 2778), "\(set)/03-wrong.png", in: dir)
        try write(pngHeader(1320, 2868, colorType: 6), "\(set)/04-alpha.png", in: dir)
        try write(Data("GIF89a".utf8), "\(set)/05-gif.png", in: dir)
        try write(Data("GIF89a".utf8), "\(set)/06-anim.gif", in: dir)
        for n in 7...11 { try write(pngHeader(1320, 2868), "\(set)/\(n)-more.png", in: dir) }
        try write(pngHeader(1, 1), "en-US/screenshots/APP_IPHONE_99/01-x.png", in: dir)
        #expect(lines(dir) == [
            "[account] appstore/en-US/screenshots/APP_IPHONE_67: 11 screenshots, Apple allows 10 — keep at most 10",
            "[account] appstore/en-US/screenshots/APP_IPHONE_67/03-wrong.png: 1284x2778 is not a size APP_IPHONE_67 takes — use one of 1260x2736, 2736x1260, 1290x2796, 2796x1290, 1320x2868, 2868x1320",
            "[account] appstore/en-US/screenshots/APP_IPHONE_67/04-alpha.png: has an alpha channel (transparency) — export it without transparency (App Store Connect refuses it)",
            "[account] appstore/en-US/screenshots/APP_IPHONE_67/05-gif.png: is not a readable PNG or JPEG image — export it again as PNG or JPEG",
            "[account] appstore/en-US/screenshots/APP_IPHONE_67/06-anim.gif: is not a .png, .jpg or .jpeg file — App Store Connect takes PNG or JPEG screenshots",
            "warning: appstore/en-US/screenshots/APP_IPHONE_99: APP_IPHONE_99 is not a display type xless knows; its screenshots' sizes are not checked — check the spelling (App Store Connect's ScreenshotDisplayType, e.g. APP_IPHONE_67)",
        ])
    }
}

@Test func previewsAreCheckedByFormatAndCount() throws {
    try withManifest { dir in
        for n in 1...4 { try write("x", "en-US/previews/IPHONE_67/0\(n)-p.mov", in: dir) }
        try write("x", "en-US/previews/IPHONE_67/05-p.avi", in: dir)
        #expect(lines(dir) == [
            "[account] appstore/en-US/previews/IPHONE_67: 5 previews, Apple allows 3 — keep at most 3",
            "[account] appstore/en-US/previews/IPHONE_67/05-p.avi: is not a .mov, .m4v or .mp4 file — App Store Connect takes app previews as .mov, .m4v or .mp4",
        ])
    }
}

@Test func whatASubmissionNeedsIsAnErrorOrWithDraftAWarning() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.0\"\n", "app.yml", in: dir)
    try write("Example\n", "en-US/name.txt", in: dir)
    let expected = [
        "appstore/app.yml: no copyright — add e.g. `copyright: 2026 Example Inc.`",
        "appstore/app.yml: no contentRights — add `contentRights: DOES_NOT_USE_THIRD_PARTY_CONTENT` (or USES_THIRD_PARTY_CONTENT)",
        "appstore/app.yml: no categories.primary — add the primary category, e.g. `categories: { primary: UTILITIES }`",
        "appstore/app.yml: no ageRating — answer the age rating questions in `ageRating:` (`xless store pull` writes them for an existing app; docs/appstore-manifest.md)",
        "appstore/app.yml: App Review's contact has no review.contact.firstName, review.contact.lastName, review.contact.phone, review.contact.email — add the person App Review can reach: review: { contact: { firstName, lastName, phone, email } }",
        "appstore/en-US/description.txt: missing — every locale needs its description",
        "appstore/en-US/keywords.txt: missing — every locale needs its keywords",
        "appstore/en-US/support_url.txt: missing — every locale needs its support url",
        "appstore/en-US/privacy_url.txt: missing — every app needs a privacy policy URL in its primary locale",
        "appstore/en-US/screenshots: no screenshots for any of APP_IPHONE_67, APP_IPHONE_65, APP_IPAD_PRO_3GEN_129, APP_IPAD_PRO_129 — add at least one screenshot in appstore/en-US/screenshots/APP_IPHONE_67/ (sizes: 1260x2736, 2736x1260, 1290x2796, 2796x1290, 1320x2868, 2868x1320)",
    ]
    #expect(lines(dir) == expected.map { "[account] " + $0 })
    #expect(lines(dir, draft: true) == expected.map { "warning: " + $0 })
}

@Test func appValuesAreChecked() throws {
    try withManifest { dir in
        var app = completeAppYAML.replacingOccurrences(of: "bundleID: com.example.app\n", with: "")
        app = app.replacingOccurrences(of: "platform: IOS", with: "platform: WATCH_OS")
        app = app.replacingOccurrences(of: "version: \"1.0\"", with: "version: 1.0.0.1")
        app = app.replacingOccurrences(of: "primary: UTILITIES", with: "primary: Utilities\n  primarySubcategories: [A, B, C]")
        app = app.replacingOccurrences(of: "email: ada@example.com", with: "email: ada")
        app = app.replacingOccurrences(of: "price: free", with: "price: $1")
        app = app.replacingOccurrences(of: "territories: all", with: "territories: [USA, us]")
        app += "release:\n  type: SCHEDULED\nreview2: x\n"
        try write(app, "app.yml", in: dir)
        #expect(lines(dir) == [
            "warning: appstore/app.yml: unknown key `review2` — remove it; the keys are listed in docs/appstore-manifest.md",
            "[account] appstore/app.yml: no bundleID, and no usable xless.yml next to appstore/ to take it from — add `bundleID: com.example.app` to app.yml (or pass the app's overlay with --config)",
            "[account] appstore/app.yml: platform WATCH_OS is not one App Store Connect knows — use one of IOS, MAC_OS, TV_OS, VISION_OS",
            "[account] appstore/app.yml: version 1.0.0.1 is not an App Store version — use 1 to 3 numbers separated by dots, quoted: version: \"1.0\"",
            "[account] appstore/app.yml: category Utilities is not an App Store Connect category ID — use IDs such as GAMES, GAMES_ACTION, UTILITIES (`xless api GET /v1/appCategories`)",
            "[account] appstore/app.yml: categories.primarySubcategories has 3 entries, Apple allows 2 — keep at most two",
            "[account] appstore/app.yml: release.type SCHEDULED needs release.earliestDate — add e.g. `earliestDate: 2026-12-01T08:00:00Z`",
            "[account] appstore/app.yml: review.contact.email ada is not an email address — fix the address",
            "[account] appstore/app.yml: pricing.price $1 is not a price — write `free` or the customer price in the base territory, quoted, e.g. \"0.99\"",
            "[account] appstore/app.yml: availability.territories: us is not a territory code — use App Store Connect's three-letter codes, e.g. USA, GBR, JPN",
        ])
        #expect(!lines(dir, inherited: "com.example.app").contains { $0.contains("no bundleID") }, "inherited from xless.yml")
    }
}

@Test func theDemoAccountNamesASecretNeverHoldsIt() throws {
    try withManifest { dir in
        try write(completeAppYAML.replacingOccurrences(of: "    email: ada@example.com\n", with: "    email: ada@example.com\n  demoAccount:\n    required: true\n    name: demo\n    passwordSecret: hunter2 hunter2\n"),
                  "app.yml", in: dir)
        #expect(lines(dir) == ["[account] appstore/app.yml: review.demoAccount.passwordSecret hunter2 hunter2 is not a secret name — name the secret-store entry (or environment variable) that holds the password, e.g. XLESS_DEMO_PASSWORD; never the password itself"])
        try write(completeAppYAML.replacingOccurrences(of: "    email: ada@example.com\n", with: "    email: ada@example.com\n  demoAccount:\n    required: true\n    name: demo\n"),
                  "app.yml", in: dir)
        #expect(lines(dir).first?.contains("without review.demoAccount.passwordSecret") == true)
    }
}

@Test func aCustomEulaNeedsItsFile() throws {
    try withManifest { dir in
        try write(completeAppYAML.replacingOccurrences(of: "eula: standard", with: "eula:\n  file: eula.txt\n  territories: all"), "app.yml", in: dir)
        #expect(lines(dir) == ["[account] appstore/eula.txt: is missing (app.yml's eula.file) — write the licence agreement there, or use `eula: standard`"])
        try write("Terms\n", "eula.txt", in: dir)
        #expect(lines(dir) == [])
    }
}

@Test func anUnreadableAppFileDoesNotCascade() throws {
    try withManifest { dir in
        try write(completeAppYAML.replacingOccurrences(of: "  contact:\n", with: "  contact: [a, b]\n  x:\n"), "app.yml", in: dir)
        let read = ManifestReader.read(dir)
        #expect(!read.appReadable)
        let out = (read.issues + ManifestValidator.validate(read.manifest, at: dir, checkApp: read.appReadable)).map(\.description)
        #expect(out.count == 1 && out[0].contains("appstore/app.yml"), "only the reader's error, no missing-key flood: \(out)")
    }
}

@Test func pricesTerritoriesAndScheduledChangesAreChecked() throws {
    try withManifest { dir in
        let app = completeAppYAML.replacingOccurrences(of: "  price: free\n", with: """
              price: 0.99
              territories:
                JPN: "150"
                USA: "1.99"
                gb: "0.99"
                CAN: 1,99
              changes:
                - date: 2027-01-01
                  price: 1.99
                - date: "2027-01-01"
                  territory: USA
                  price: "2.99"
                - date: 2027-02-30
                  territory: jp
                  price: lots

            """)
        try write(app, "app.yml", in: dir)
        let read = ManifestReader.read(dir)
        #expect(read.manifest.app.pricing?.price == "0.99", "an unquoted price reads as written")
        #expect(read.manifest.app.pricing?.changes?.first == AppYAML.Pricing.Change(date: "2027-01-01", price: "1.99"), "so does an unquoted date")
        #expect(lines(dir) == [
            "[account] appstore/app.yml: pricing.territories.CAN: 1,99 is not a price — write `free` or the customer price in CAN's currency, quoted, e.g. \"0.99\"",
            "[account] appstore/app.yml: pricing.territories lists the base territory USA — set its price with pricing.price, and remove it from pricing.territories",
            "[account] appstore/app.yml: pricing.territories: gb is not a territory code — use App Store Connect's three-letter codes, e.g. GBR, JPN",
            "[account] appstore/app.yml: pricing.changes has two changes for USA on 2027-01-01 — keep one",
            "[account] appstore/app.yml: pricing.changes: 2027-02-30 is not a date — write it as YYYY-MM-DD, quoted, e.g. \"2027-01-01\"",
            "[account] appstore/app.yml: pricing.changes: jp is not a territory code — use App Store Connect's three-letter codes, or leave territory out for the base territory",
            "[account] appstore/app.yml: pricing.changes: lots (2027-02-30) is not a price — write `free` or the customer price, quoted, e.g. \"0.99\"",
        ])
    }
}
