import Foundation
import Testing
@testable import XlessStore

// MARK: - Image headers and display types

@Test func pngHeadersGiveSizeAndAlpha() {
    #expect(ImageInfo.read(pngHeader(1290, 2796)) == ImageInfo(width: 1290, height: 2796, format: .png, hasAlpha: false))
    #expect(ImageInfo.read(pngHeader(10, 20, colorType: 6))?.hasAlpha == true, "RGBA")
    #expect(ImageInfo.read(pngHeader(10, 20, colorType: 4))?.hasAlpha == true, "grey + alpha")
    #expect(ImageInfo.read(pngHeader(10, 20, colorType: 3, transparency: true))?.hasAlpha == true, "palette with tRNS")
}

@Test func jpegHeadersGiveSize() {
    #expect(ImageInfo.read(jpegHeader(2868, 1320)) == ImageInfo(width: 2868, height: 1320, format: .jpeg))
    #expect(ImageInfo.read(jpegHeader(640, 960, sof: 0xC2))?.width == 640, "progressive")
}

@Test func anythingElseIsNoImage() {
    #expect(ImageInfo.read(Data("GIF89a".utf8)) == nil)
    #expect(ImageInfo.read(Data()) == nil)
    #expect(ImageInfo.read(pngHeader(1, 1).prefix(20)) == nil, "truncated IHDR")
    #expect(ImageInfo.read(Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])) == nil, "scan before any frame header")
}

@Test func displayTypesAcceptTheirSizesInBothOrientations() {
    #expect(ScreenshotDisplayType.accepts("APP_IPHONE_67", width: 1320, height: 2868) == true)
    #expect(ScreenshotDisplayType.accepts("APP_IPHONE_67", width: 2868, height: 1320) == true)
    #expect(ScreenshotDisplayType.accepts("APP_IPHONE_67", width: 1284, height: 2778) == false)
    #expect(ScreenshotDisplayType.accepts("APP_IPHONE_65", width: 1284, height: 2778) == true)
    #expect(ScreenshotDisplayType.accepts("IMESSAGE_APP_IPHONE_67", width: 1290, height: 2796) == true)
    #expect(ScreenshotDisplayType.accepts("APP_DESKTOP", width: 2880, height: 1800) == true)
    #expect(ScreenshotDisplayType.accepts("APP_IPHONE_99", width: 1, height: 1) == nil)
    #expect(ScreenshotDisplayType.sizes("APP_IPHONE_55") == ["1242x2208", "2208x1242"])
}

@Test func mediaIsOrderedByLeadingNumber() {
    #expect(MediaOrder.sorted(["10-c.png", "2-b.png", "01-a.png", "x.png"]) == ["01-a.png", "2-b.png", "10-c.png", "x.png"])
}

// MARK: - Reading

@Test func aCompleteManifestReadsWithoutIssues() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let result = ManifestReader.read(dir)
    #expect(result.issues.isEmpty)
    let app = result.manifest.app
    #expect(app.bundleID == "com.example.app" && app.version == "1.0" && app.primaryLocale == "en-US")
    #expect(app.review?.contact?.phone == "+1 555 0100")
    #expect(app.ageRating?["gambling"] == .bool(false) && app.ageRating?["violenceCartoonOrFantasy"] == .string("NONE"))
    #expect(app.eula == .standard && app.availability?.territories == .all && app.pricing?.price == "free")
    let en = try #require(result.manifest.locales["en-US"])
    #expect(en.name == "Example" && en.keywords == "tools,example" && en.supportURL == "https://example.com/support")
    #expect(en.screenshots == [MediaSet(type: "APP_IPHONE_67", files: ["en-US/screenshots/APP_IPHONE_67/01-home.png",
                                                                       "en-US/screenshots/APP_IPHONE_67/02-landscape.jpg"])])
}

@Test func textFilesLoseTrailingLineBreaksAndWindowsLineEnds() {
    #expect(ManifestText.normalize("Line one\r\nLine two\r\n\r\n", isURL: false) == "Line one\nLine two")
    #expect(ManifestText.normalize("  https://example.com \n", isURL: true) == "https://example.com")
    #expect(ManifestText.normalize("\n\n", isURL: false) == nil)
    #expect(ManifestText.normalize("  indented\n", isURL: false) == "  indented", "leading spaces of a text are kept")
}

@Test func anUnquotedNumericVersionStillReadsAsText() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("version: 1.10\nprimaryLocale: en-US\n", "app.yml", in: dir)
    let result = ManifestReader.read(dir)
    #expect(result.manifest.app.version == "1.10")
}

@Test func unknownKeysWarnAndAreKept() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("primarylocale: en-US\nprivacy:\n  collectsData: false\n", "app.yml", in: dir)
    let result = ManifestReader.read(dir)
    #expect(result.issues.map(\.description) == ["warning: appstore/app.yml: unknown key `primarylocale` — did you mean `primaryLocale`?"])
    #expect(result.manifest.extras.map(\.key) == ["primarylocale"])
    #expect(result.manifest.app.privacy == AppYAML.Privacy(collectsData: false))
}

@Test func privacyAnswersRoundTripThroughAppYAML() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let yaml = """
    privacy:
      collectsData: true
      data:
      - category: EMAIL_ADDRESS
        purposes:
        - APP_FUNCTIONALITY
        linkedToYou: true
        tracking: false

    """
    try write(yaml, "app.yml", in: dir)
    let manifest = ManifestReader.read(dir).manifest
    #expect(manifest.app.privacy == AppYAML.Privacy(collectsData: true, data: [
        .init(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY"], linkedToYou: true, tracking: false)]))
    #expect(try ManifestWriter.renderApp(manifest).hasSuffix(yaml))
}

@Test func typeErrorsNameTheKey() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("review:\n  contact: [a, b]\n", "app.yml", in: dir)
    #expect(ManifestReader.read(dir).issues.map(\.description) == ["[account] appstore/app.yml: `review.contact` should be a mapping — compare it with docs/appstore-manifest.md"])
    try write("eula: custom\n", "app.yml", in: dir)
    #expect(ManifestReader.read(dir).issues.first?.message.contains("`eula`") == true)
    try write("primaryLocale: [en-US\n", "app.yml", in: dir)
    #expect(ManifestReader.read(dir).issues.first?.message.hasPrefix("is not valid YAML") == true)
}

@Test func strayFilesInALocaleAreWarnedAbout() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("primaryLocale: en-US\n", "app.yml", in: dir)
    try write("x\n", "en-US/Keywords.txt", in: dir)
    try write(pngHeader(1, 1), "en-US/screenshots/loose.png", in: dir)
    #expect(ManifestReader.read(dir).issues.map(\.description) == [
        "warning: appstore/en-US/Keywords.txt: is not part of the listing; xless ignores it — rename it to keywords.txt",
        "warning: appstore/en-US/screenshots/loose.png: is not inside a display type directory — move it into appstore/en-US/screenshots/<display type>/ (e.g. APP_IPHONE_67)",
    ])
}

@Test func aMissingDirectoryOrAppFileIsAnError() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ManifestReader.read(root.appendingPathComponent("appstore")).issues.first?.message == "no such directory")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("appstore"), withIntermediateDirectories: true)
    #expect(ManifestReader.read(root.appendingPathComponent("appstore")).issues.map(\.description)
            == ["[account] appstore/app.yml: missing — run `xless store pull`, or write it (docs/appstore-manifest.md)"])
}

// MARK: - Writing

@Test func writtenManifestsReadBackTheSame() throws {
    let source = try completeManifest()
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()); try? FileManager.default.removeItem(at: root) }
    var manifest = ManifestReader.read(source).manifest
    manifest.app.review?.notes = "Line one\nLine two"
    manifest.app.eula = .custom(file: "eula.txt", territories: .only(["USA", "CAN"]))
    manifest.locales["en-US"]?.description = "Café — 東京\nSecond line"
    manifest.locales["en-US"]?.screenshots = []
    let dir = root.appendingPathComponent("appstore")
    try ManifestWriter.write(manifest, files: ["eula.txt": .data(Data("Terms\n".utf8))], lock: MediaLock(), to: dir)
    let back = ManifestReader.read(dir)
    #expect(back.issues.isEmpty)
    #expect(back.manifest == manifest)
    #expect(read("en-US/description.txt", in: dir) == "Café — 東京\nSecond line\n")
    let app = try #require(read("app.yml", in: dir))
    #expect(app.contains("version: '1.0'") || app.contains("version: \"1.0\""), "a version stays a string")
    #expect(app.range(of: "bundleID")!.lowerBound < app.range(of: "ageRating")!.lowerBound, "keys in the documented order")
    #expect(app.range(of: "gambling")!.lowerBound < app.range(of: "violenceCartoonOrFantasy")!.lowerBound, "map keys sorted")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(MediaLock.fileName).path), "no lock without media")
}

@Test func rewritingKeepsWhatTheFormatDoesNotOwn() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try write("# notes\n", "README.md", in: dir)
    try write("product: x\n", "iap/x.yml", in: dir)
    try write("old\n", "fr-FR/name.txt", in: dir)
    try write("privacy:\n  collectsData: false\n", "app.yml", in: dir)
    var manifest = ManifestReader.read(dir).manifest
    manifest.locales["fr-FR"] = nil
    manifest.app.primaryLocale = "en-US"
    try ManifestWriter.write(manifest, files: [:], lock: MediaLock(), to: dir)
    #expect(read("README.md", in: dir) == "# notes\n")
    #expect(read("iap/x.yml", in: dir) == "product: x\n")
    #expect(read("fr-FR/name.txt", in: dir) == nil, "a locale the new listing lacks is not carried over")
    #expect(read("en-US/screenshots/APP_IPHONE_67/01-home.png", in: dir) == nil, "media come only from `files`")
    #expect(read("app.yml", in: dir)?.hasSuffix("primaryLocale: en-US\nprivacy:\n  collectsData: false\n") == true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
    #expect(leftovers == ["appstore"])
}

@Test func aFailedWriteLeavesTheOldDirectoryAlone() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let before = read("app.yml", in: dir)
    #expect(throws: (any Error).self) {
        try ManifestWriter.write(StoreManifest(), files: ["a.png": .file(dir.appendingPathComponent("does-not-exist"))], lock: MediaLock(), to: dir)
    }
    #expect(read("app.yml", in: dir) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path) == ["appstore"])
}

@Test func theLockFindsAnUnchangedOriginal() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let png = pngHeader(1320, 2868)
    try write(png, "en-US/screenshots/APP_IPHONE_67/01-home.png", in: root)
    let lock = MediaLock(files: ["en-US/screenshots/APP_IPHONE_67/01-home.png": .init(md5: MD5Hex.of(png), appleChecksum: "abc", id: "S1")])
    try write(try lock.render(), MediaLock.fileName, in: root)
    let back = MediaLock.read(root)
    #expect(back == lock)
    #expect(back.unchangedFile(for: "abc", in: root) == "en-US/screenshots/APP_IPHONE_67/01-home.png")
    #expect(back.unchangedFile(for: "other", in: root) == nil)
    try write(pngHeader(1, 1), "en-US/screenshots/APP_IPHONE_67/01-home.png", in: root)
    #expect(back.unchangedFile(for: "abc", in: root) == nil, "an edited file is no longer Apple's upload")
}

@Test func rewritingThroughASymlinkedPathKeepsRelativePaths() throws {
    let real = try tempDir()
    defer { try? FileManager.default.removeItem(at: real) }
    let link = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: link) }
    let dir = link.appendingPathComponent("appstore")
    try write("primaryLocale: en-US\n", "app.yml", in: dir)
    try write("# notes\n", "README.md", in: dir)
    try write("old\n", "en-US/name.txt", in: dir)
    try ManifestWriter.write(StoreManifest(app: ManifestReader.read(dir).manifest.app), files: [:], lock: MediaLock(), to: dir)
    #expect(read("README.md", in: dir) == "# notes\n")
    #expect(read("en-US/name.txt", in: dir) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["README.md", "app.yml"])
}

@Test func filesAppYMLNamesStayInsideTheManifest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    try write("x", "eula.txt", in: dir)
    try write("x", "outside.txt", in: root)
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("outside.txt"))
    #expect(StoreManifest.resolve("eula.txt", in: dir) != nil)
    #expect(StoreManifest.resolve("not-yet.txt", in: dir) != nil, "a missing file inside")
    #expect(StoreManifest.resolve("../outside.txt", in: dir) == nil)
    #expect(StoreManifest.resolve("/etc/passwd", in: dir) == nil)
    #expect(StoreManifest.resolve("link.txt", in: dir) == nil, "a symbolic link out of the manifest")
}
