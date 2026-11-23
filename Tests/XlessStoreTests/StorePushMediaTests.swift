import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

// `store push`'s media: screenshots, previews, App Review attachments and the compliance document, against the
// path-routed fake App Store Connect of StorePullTests with the upload side of StoreMediaSenderTests.

/// The fake app with nothing pending (as StorePushTests' `synced`).
private func synced() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/accessibilityDeclarations"] = (200, list([
        #"{"type":"accessibilityDeclarations","id":"AC1","attributes":{"deviceFamily":"IPHONE","state":"PUBLISHED","supportsVoiceover":true,"supportsDarkInterface":true}}"#,
    ]))
    return routes
}

private func pulled(_ routes: [String: (Int, String)] = synced()) async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(routes), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    return (root, dir)
}

private func pusher(_ t: HTTPTransport, _ notes: Notes = Notes()) -> StorePush {
    StorePush(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })), say: { notes.say($0) })
}

private func manifest(_ dir: URL) -> StoreManifest { ManifestReader.read(dir).manifest }
private let media = StorePush.Options(parts: [.media])

private func item(_ type: String, _ id: String, _ checksum: String, name: String, extra: String = "") -> String {
    #"{"type":"\#(type)","id":"\#(id)","attributes":{"fileName":"\#(name)","sourceFileChecksum":"\#(checksum)","assetDeliveryState":{"state":"COMPLETE"}\#(extra)}}"#
}

@Test func threeNewScreenshotsUploadOnceAndASecondPushUploadsNothing() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let shots = [pngHeader(1284, 2778), pngHeader(2778, 1284), pngHeader(1242, 2688)]
    for (i, png) in shots.enumerated() { try write(png, "en-US/screenshots/APP_IPHONE_65/0\(i + 1)-shot.png", in: dir) }
    let t = RoutedTransport(synced())
    acceptUploads(t)
    let push = pusher(t)
    let (plan, report) = try await push.plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    #expect(report.planText.hasSuffix("""
          + screenshots en-US APP_IPHONE_65
              01-shot.png: "upload"
              02-shot.png: "upload"
              03-shot.png: "upload"
        1 change: 1 to create

        """))
    #expect(plan.changes[0].media?.container == .newSet(type: "APP_IPHONE_65", localization: .id("VL1")))
    let applied = try await push.apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media, sender: mediaSender(t))
    #expect(applied.sent.count == 1)
    #expect(sent(t).filter { $0 == "PUT storage" }.count == 3)
    #expect(sent(t).first == "POST /v1/appScreenshotSets")
    #expect(sent(t).last?.hasPrefix("PATCH /v1/appScreenshotSets/NEW") == true && sent(t).last?.hasSuffix("/relationships/appScreenshots") == true)

    // App Store Connect now has them, with the checksums xless sent.
    let lock = MediaLock.read(dir)
    let paths = (1...3).map { "en-US/screenshots/APP_IPHONE_65/0\($0)-shot.png" }
    #expect(paths.allSatisfy { lock.files[$0]?.md5 == MD5Hex.of(shots[paths.firstIndex(of: $0)!]) && lock.files[$0]?.id?.hasPrefix("UP") == true })
    #expect(lock.files["en-US/screenshots/APP_IPHONE_67/01-home.png"]?.appleChecksum == "apple-home", "entries pull wrote stay")
    var after = synced()
    after["/v1/appStoreVersionLocalizations/VL1/appScreenshotSets"] = (200, list([
        #"{"type":"appScreenshotSets","id":"S1","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}"#,
        #"{"type":"appScreenshotSets","id":"S2","attributes":{"screenshotDisplayType":"APP_IPHONE_65"}}"#,
    ]))
    after["/v1/appScreenshotSets/S2/appScreenshots"] = (200, list(shots.enumerated().map { i, png in item("appScreenshots", "N\(i)", MD5Hex.of(png), name: "0\(i + 1)-shot.png") }))
    let again = RoutedTransport(after)
    let (second, _) = try await pusher(again).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    #expect(second.changes.isEmpty, "\(second.changes.map(\.text))")
}

@Test func aChangedScreenshotReplacesItsUploadInPlace() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let changed = pngHeader(1290, 2796)
    try write(changed, "en-US/screenshots/APP_IPHONE_67/01-home.png", in: dir)
    let t = RoutedTransport(synced())
    acceptUploads(t)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    #expect(plan.changes.map(\.text) == [#"~ screenshots en-US APP_IPHONE_67: 01-home.png: "old upload" → "upload""#])
    #expect(plan.deletes.isEmpty, "a replacement is not a deletion to confirm")
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media, sender: mediaSender(t))
    let writes = sent(t)
    #expect(writes.prefix(3) == ["POST /v1/appScreenshots", "PUT storage", "PATCH /v1/appScreenshots/UP\(t.requests.firstIndex { $0.httpMethod == "POST" }! + 1)"])
    #expect(writes.contains("DELETE /v1/appScreenshots/SS1"))
    let order = (try JSONSerialization.jsonObject(with: t.requests.last!.httpBody!) as! [String: Any])["data"] as! [[String: String]]
    #expect(order.map { $0["id"]!.hasPrefix("UP") ? "new" : $0["id"]! } == ["new", "SS2"], "the new upload takes the old one's place")
    let entry = MediaLock.read(dir).files["en-US/screenshots/APP_IPHONE_67/01-home.png"]
    #expect(entry?.md5 == MD5Hex.of(changed) && entry?.appleChecksum == MD5Hex.of(changed))
}

@Test func renumberingOnlyReordersTheSet() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.moveItem(at: dir.appendingPathComponent("en-US/screenshots/APP_IPHONE_67/01-home.png"),
                                     to: dir.appendingPathComponent("en-US/screenshots/APP_IPHONE_67/03-home.png"))
    let t = RoutedTransport(synced())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    #expect(plan.changes.map(\.text) == [#"~ screenshots en-US APP_IPHONE_67: order: "as in en-US/screenshots/APP_IPHONE_67""#])
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media, sender: mediaSender(t))
    #expect(sent(t) == ["PATCH /v1/appScreenshotSets/S1/relationships/appScreenshots"])
    let order = (try JSONSerialization.jsonObject(with: t.requests.last!.httpBody!) as! [String: Any])["data"] as! [[String: String]]
    #expect(order == [["type": "appScreenshots", "id": "SS2"], ["type": "appScreenshots", "id": "SS1"]])
}

@Test func whatTheDirectoryLacksIsKeptOrPruned() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = synced()
    routes["/v1/appScreenshotSets/S1/appScreenshots"] = (200, list([
        #"{"type":"appScreenshots","id":"SS1","attributes":{"fileName":"01-home.png","sourceFileChecksum":"apple-home","assetDeliveryState":{"state":"COMPLETE"}}}"#,
        #"{"type":"appScreenshots","id":"SS2","attributes":{"fileName":"Settings Screen.png","sourceFileChecksum":"apple-settings","assetDeliveryState":{"state":"UPLOAD_COMPLETE"}}}"#,
        item("appScreenshots", "SS3", "apple-old", name: "old.png"),
        #"{"type":"appScreenshots","id":"SS4","attributes":{"fileName":"broken.png","assetDeliveryState":{"state":"FAILED"}}}"#,
    ]))
    routes["/v1/appStoreVersionLocalizations/VL1/appPreviewSets"] = (200, list([#"{"type":"appPreviewSets","id":"PS9","attributes":{"previewType":"IPHONE_65"}}"#]))
    routes["/v1/appPreviewSets/PS9/appPreviews"] = (200, list([]))
    let (kept, _) = try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    #expect(kept.changes.map(\.text) == [#"~ screenshots en-US APP_IPHONE_67: broken.png: "failed upload" → (none)"#])
    #expect(kept.changes[0].media?.deletes == ["SS4"] && kept.changes[0].media?.slots == [.keep("SS1"), .keep("SS2"), .keep("SS3")])
    #expect(kept.notes == [
        "screenshots en-US APP_IPHONE_67 has 1 file on App Store Connect that appstore/en-US/screenshots/APP_IPHONE_67/ does not (old.png): kept, after the directory's (--prune deletes them)",
        "previews en-US IPHONE_65 is on App Store Connect but has no directory in appstore/en-US/previews/: kept (--prune deletes it)",
    ])

    let prune = StorePush.Options(parts: [.media], prune: true)
    let (pruned, _) = try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: prune)
    #expect(pruned.deletes.map(\.text) == ["- screenshots en-US APP_IPHONE_67 old.png", #"- previews en-US IPHONE_65: files: "0" → (none)"#])
    #expect(pruned.deletes.flatMap(\.requests).map(\.path) == ["/v1/appScreenshots/SS3", "/v1/appPreviewSets/PS9"])
}

@Test func aSetOverAppleLimitAsksForPrune() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    var routes = synced()
    routes["/v1/appScreenshotSets/S1/appScreenshots"] = (200, list(
        [#"{"type":"appScreenshots","id":"SS1","attributes":{"fileName":"01-home.png","sourceFileChecksum":"apple-home","assetDeliveryState":{"state":"COMPLETE"}}}"#]
            + (1...10).map { item("appScreenshots", "X\($0)", "x\($0)", name: "x\($0).png") }))
    await #expect {
        _ = try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    } throws: { "\($0)".contains("would hold 11 files, Apple allows 10") && "\($0)".contains("--prune") }
}

@Test func aNewLocalesScreenshotsGoIntoTheLocaleTheTextPartCreates() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("Exemple\n", "fr-FR/name.txt", in: dir)
    try write(pngHeader(1320, 2868), "fr-FR/screenshots/APP_IPHONE_67/01-accueil.png", in: dir)
    let t = RoutedTransport(synced())
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir)
    #expect(plan.changes.map(\.subject).suffix(1) == ["screenshots fr-FR APP_IPHONE_67"])
    #expect(plan.changes.last?.media?.container == .newSet(type: "APP_IPHONE_67", localization: .locale("fr-FR", versionID: "V2")))
    await #expect {
        _ = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    } throws: { "\($0)".contains("no version text for fr-FR") && "\($0)".contains("push the text part too") }
}

@Test func aLiveVersionTakesNoMedia() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(pngHeader(1284, 2778), "en-US/screenshots/APP_IPHONE_65/01-shot.png", in: dir)
    var m = manifest(dir)
    m.app.version = "1.0"
    var routes = synced()
    routes["/v1/appStoreVersions/V1/appStoreVersionLocalizations"] = routes["/v1/appStoreVersions/V2/appStoreVersionLocalizations"]
    await #expect {
        _ = try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: m, dir: dir, options: media)
    } throws: { "\($0)".contains("screenshots en-US APP_IPHONE_65") && "\($0)".contains("cannot be edited") }
}

@Test func posterFramesAreSentWithUploadsAndChangedOnPreviewsAppleHas() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = Data("movie".utf8), other = Data("other movie".utf8)
    try write(movie, "en-US/previews/IPHONE_67/01-intro.mov", in: dir)
    try write(other, "en-US/previews/IPHONE_67/02-more.mov", in: dir)
    var m = manifest(dir)
    m.app.previewFrames = ["en-US/previews/IPHONE_67/01-intro.mov": "00:00:05:00", "en-US/previews/IPHONE_67/02-more.mov": "00:00:02:10"]
    var routes = synced()
    routes["/v1/appStoreVersionLocalizations/VL1/appPreviewSets"] = (200, list([#"{"type":"appPreviewSets","id":"PS2","attributes":{"previewType":"IPHONE_67"}}"#]))
    routes["/v1/appPreviewSets/PS2/appPreviews"] = (200, list([item("appPreviews", "PV2", MD5Hex.of(movie), name: "01-intro.mov", extra: #","previewFrameTimeCode":"00:00:01:00""#)]))
    let t = RoutedTransport(routes)
    acceptUploads(t)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: media)
    #expect(plan.changes.map(\.text) == ["""
        ~ previews en-US IPHONE_67
            01-intro.mov previewFrameTimeCode: "00:00:01:00" → "00:00:05:00"
            02-more.mov: "upload"
        """])
    #expect(plan.changes[0].requests == [.update("appPreviews", id: "PV2", attributes: ["previewFrameTimeCode": .string("00:00:05:00")])])
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: media, sender: mediaSender(t))
    let commit = t.requests.first { $0.httpMethod == "PATCH" && $0.url!.path.hasPrefix("/v1/appPreviews/UP") }!
    #expect(String(decoding: commit.httpBody!, as: UTF8.self).contains(#""previewFrameTimeCode":"00:00:02:10""#))
}

@Test func reviewAttachmentsAreUploadedOntoTheReviewDetails() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(Data("walkthrough".utf8), "review/walkthrough.mov", in: dir)
    var m = manifest(dir)
    m.app.review?.attachments = ["review/walkthrough.mov"]
    var routes = synced()
    routes["/v1/appStoreReviewDetails/R1/appStoreReviewAttachments"] = (200, list([item("appStoreReviewAttachments", "RA1", "old", name: "old.pdf")]))
    let t = RoutedTransport(routes)
    acceptUploads(t)
    let notes = Notes()
    let review = StorePush.Options(parts: [.review])
    let (plan, _) = try await pusher(t, notes).plan(app: fakeASCApp, manifest: m, dir: dir, options: review)
    #expect(plan.changes.map(\.text) == [#"~ App Review attachments: walkthrough.mov: "upload""#])
    #expect(plan.notes == ["App Review attachments: App Store Connect has old.pdf, which app.yml does not list: kept (--prune deletes it)"])
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: review, sender: mediaSender(t))
    let reserve = t.requests.first { $0.httpMethod == "POST" && $0.url!.path == "/v1/appStoreReviewAttachments" }!
    #expect(String(decoding: reserve.httpBody!, as: UTF8.self).contains(#""appStoreReviewDetail":{"data":{"id":"R1","type":"appStoreReviewDetails"}}"#))
    #expect(MediaLock.read(dir).files["review/walkthrough.mov"]?.md5 == MD5Hex.of(Data("walkthrough".utf8)))

    let (pruned, _) = try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: m, dir: dir, options: .init(parts: [.review], prune: true))
    #expect(pruned.deletes.map(\.text) == ["- App Review attachments old.pdf"])
}

@Test func theComplianceDocumentGoesWithItsDeclaration() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = Data("%PDF-1.4 export".utf8)
    try write(pdf, "compliance/export.pdf", in: dir)
    var m = manifest(dir)
    m.app.encryptionDocument = "compliance/export.pdf"
    let declarations = StorePush.Options(parts: [.declarations])

    // The latest declaration has no document: it is uploaded onto it.
    var routes = synced()
    routes["/v1/appEncryptionDeclarations/E2/appEncryptionDeclarationDocument"] = (200, single(nil))
    let t = RoutedTransport(routes)
    acceptUploads(t)
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: m, dir: dir, options: declarations)
    #expect(plan.changes.map(\.text) == [#"+ export compliance document: export.pdf: "upload""#])
    try await pusher(t).apply(plan, app: fakeASCApp, manifest: m, dir: dir, options: declarations, sender: mediaSender(t))
    let reserve = t.requests.first { $0.httpMethod == "POST" && $0.url!.path == "/v1/appEncryptionDeclarationDocuments" }!
    #expect(String(decoding: reserve.httpBody!, as: UTF8.self).contains(#""appEncryptionDeclaration":{"data":{"id":"E2","type":"appEncryptionDeclarations"}}"#))

    // It has it: nothing to send.
    routes["/v1/appEncryptionDeclarations/E2/appEncryptionDeclarationDocument"] = (200, single(item("appEncryptionDeclarationDocuments", "D1", MD5Hex.of(pdf), name: "export.pdf")))
    #expect(try await pusher(RoutedTransport(routes)).plan(app: fakeASCApp, manifest: m, dir: dir, options: declarations).0.changes.isEmpty)

    // A new declaration takes it.
    m.app.encryption = ["appDescription": .string("Uses HTTPS only."), "availableOnFrenchStore": .bool(true),
                        "containsProprietaryCryptography": .bool(true), "containsThirdPartyCryptography": .bool(false)]
    let fresh = RoutedTransport(routes)
    acceptUploads(fresh)
    let (create, _) = try await pusher(fresh).plan(app: fakeASCApp, manifest: m, dir: dir, options: declarations)
    let change = create.changes.first { $0.subject == "export compliance" }!
    #expect(change.fields.last?.text == #"export.pdf: "upload""# && change.media?.container == .parent("{id}"))
    #expect(!create.notes.contains { $0.contains("compliance document") })
    try await pusher(fresh).apply(create, app: fakeASCApp, manifest: m, dir: dir, options: declarations, sender: mediaSender(fresh))
    let document = fresh.requests.first { $0.httpMethod == "POST" && $0.url!.path == "/v1/appEncryptionDeclarationDocuments" }!
    let declaration = fresh.requests.firstIndex { $0.httpMethod == "POST" && $0.url!.path == "/v1/appEncryptionDeclarations" }!
    #expect(String(decoding: document.httpBody!, as: UTF8.self).contains(#""id":"NEW\#(declaration + 1)""#))
}

@Test func uploadsBeforeAFailureAreRecordedInTheLock() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(pngHeader(1284, 2778), "en-US/screenshots/APP_IPHONE_65/01-shot.png", in: dir)
    try write(Data("movie".utf8), "en-US/previews/IPHONE_65/01-intro.mov", in: dir)
    let t = RoutedTransport(synced())
    acceptUploads(t)
    let accept = t.onRequest
    t.onRequest = { r, t in
        accept?(r, t)
        t.routes["POST /v1/appPreviewSets"] = (500, #"{"errors":[{"status":"500","code":"UNEXPECTED","title":"boom"}]}"#)
    }
    let notes = Notes()
    let (plan, _) = try await pusher(t).plan(app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media)
    #expect(plan.changes.map(\.subject) == ["screenshots en-US APP_IPHONE_65", "previews en-US IPHONE_65"])
    await #expect(throws: (any Error).self) {
        _ = try await pusher(t, notes).apply(plan, app: fakeASCApp, manifest: manifest(dir), dir: dir, options: media, sender: mediaSender(t))
    }
    #expect(MediaLock.read(dir).files["en-US/screenshots/APP_IPHONE_65/01-shot.png"]?.id?.hasPrefix("UP") == true)
    #expect(notes.lines.contains { $0.contains("1 of 2 changes was sent") })
}

@Test func attachedFilesAndPosterFramesAreValidated() throws {
    let dir = try completeManifest()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try write(Data(), "review/empty.pdf", in: dir)
    var m = ManifestReader.read(dir).manifest
    m.app.review?.attachments = ["review/missing.mov", "review/empty.pdf", "../outside.pdf"]
    m.app.encryptionDocument = "compliance/export.pdf"
    m.app.previewFrames = ["en-US/previews/IPHONE_67/01-intro.mov": "5 seconds"]
    let issues = ManifestValidator.validate(m, at: dir).map(\.description)
    #expect(issues.contains("[account] appstore/review/missing.mov: is missing (app.yml's review.attachments) — put the file there, or remove it from review.attachments"))
    #expect(issues.contains { $0.contains("appstore/review/empty.pdf: is empty") })
    #expect(issues.contains { $0.contains("review.attachments: ../outside.pdf is outside appstore/") })
    #expect(issues.contains { $0.contains("appstore/compliance/export.pdf: is missing (app.yml's encryptionDocument)") })
    #expect(issues.contains { $0.contains("previewFrames: 5 seconds") })
    #expect(issues.contains { $0.hasPrefix("warning:") && $0.contains("previewFrames: en-US/previews/IPHONE_67/01-intro.mov is not a preview") })
    #expect(ManifestReader.read(dir).manifest.locales["review"] == nil, "review/ is not a locale")
}

@Test func pullKeepsAttachmentsTheDocumentAndTheirLock() async throws {
    let (root, dir) = try await pulled()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(Data("walkthrough".utf8), "review/walkthrough.mov", in: dir)
    var m = manifest(dir)
    m.app.review?.attachments = ["review/walkthrough.mov"]
    m.app.encryptionDocument = "compliance/export.pdf"
    try Data(try ManifestWriter.renderApp(m).utf8).write(to: dir.appendingPathComponent("app.yml"))
    var lock = MediaLock.read(dir)
    lock.files["review/walkthrough.mov"] = .init(md5: "m", appleChecksum: "m", id: "RA1")
    try lock.write(to: dir)
    _ = try await puller(RoutedTransport(synced()), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 })).run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    let again = manifest(dir)
    #expect(again.app.review?.attachments == ["review/walkthrough.mov"] && again.app.encryptionDocument == "compliance/export.pdf")
    #expect(MediaLock.read(dir).files["review/walkthrough.mov"]?.id == "RA1")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("review/walkthrough.mov").path))
}
