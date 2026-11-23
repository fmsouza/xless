import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

/// App Store Connect's upload side on top of a RoutedTransport: a reservation (POST of a media type) answers an ID
/// `UP<n>` and one upload operation for the whole file; reading the asset answers `state`.
func acceptUploads(_ t: RoutedTransport, state: String = "COMPLETE") {
    let previous = t.onRequest
    let types = [StoreMediaKind.screenshots, .previews, .reviewAttachments, .encryptionDocument, .iapReviewScreenshot, .subscriptionReviewScreenshot].map(\.itemType)
    t.onRequest = { r, t in
        previous?(r, t)
        guard r.httpMethod == "POST", let type = types.first(where: { r.url!.path == "/v1/\($0)" }) else { return }
        let doc = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let size = (((doc["data"] as? [String: Any])?["attributes"] as? [String: Any])?["fileSize"] as? Int) ?? 0
        let id = "UP\(t.requests.count)"
        t.routes["POST /v1/\(type)"] = (201, #"{"data":{"type":"\#(type)","id":"\#(id)","attributes":{"uploadOperations":[{"method":"PUT","url":"https://upload.example/\#(id)","offset":0,"length":\#(size),"requestHeaders":[]}]}}}"#)
        t.routes["/v1/\(type)/\(id)"] = (200, #"{"data":{"type":"\#(type)","id":"\#(id)","attributes":{"assetDeliveryState":{"state":"\#(state)"}}}}"#)
    }
}

/// - Parameter concurrency: 1 where a test reads the exact order of the requests.
func mediaSender(_ t: HTTPTransport, concurrency: Int = StoreSender.uploadConcurrency) -> StoreSender {
    let client = ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })
    return StoreSender(client: client, secret: { _ in "" },
                       uploader: AssetUploader(client: client, stage: .account, rerun: "re-run `xless store push`", sleep: { _ in }, pollInterval: .zero, timeout: .seconds(5)),
                       concurrency: concurrency)
}

/// "METHOD path" of every request but reads, PUTs to Apple's storage named `PUT <file>`.
func sent(_ t: RoutedTransport) -> [String] {
    t.requests.filter { $0.httpMethod != "GET" }.map { r in
        r.url!.host == "upload.example" ? "PUT storage" : "\(r.httpMethod!) \(r.url!.path)"
    }
}

func upload(_ dir: URL, _ path: String, bytes: Data = pngHeader(1320, 2868)) throws -> StoreUpload {
    try write(bytes, path, in: dir)
    let url = dir.appendingPathComponent(path)
    return StoreUpload(path: path, file: url, fileName: url.lastPathComponent, fileSize: bytes.count, md5: MD5Hex.of(bytes))
}

private func json(_ r: URLRequest) -> [String: Any] { (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

@Test func aNewSetIsCreatedInTheLocaleThenFilledAndOrdered() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try upload(dir, "en-US/screenshots/APP_IPHONE_65/01-a.png", bytes: pngHeader(1284, 2778))
    let b = try upload(dir, "en-US/screenshots/APP_IPHONE_65/02-b.png", bytes: pngHeader(1242, 2688))
    let t = RoutedTransport(fakeApp())
    acceptUploads(t)
    let sender = mediaSender(t, concurrency: 1)
    let work = StoreMediaWork(kind: .screenshots, container: .newSet(type: "APP_IPHONE_65", localization: .locale("en-US", versionID: "V2")),
                              slots: [.upload(a), .upload(b)], reorder: true)
    try await sender.apply(StoreChange(.create, .media, "screenshots en-US APP_IPHONE_65", requests: [], media: work))
    #expect(sent(t) == ["POST /v1/appScreenshotSets", "POST /v1/appScreenshots", "PUT storage", "PATCH /v1/appScreenshots/UP3",
                        "POST /v1/appScreenshots", "PUT storage", "PATCH /v1/appScreenshots/UP7",
                        "PATCH /v1/appScreenshotSets/NEW2/relationships/appScreenshots"])
    let set = json(t.requests.first { $0.url!.path == "/v1/appScreenshotSets" }!)["data"] as! [String: Any]
    #expect((set["attributes"] as! [String: String]) == ["screenshotDisplayType": "APP_IPHONE_65"])
    #expect("\(set["relationships"]!)".contains("VL1"), "the en-US localization, looked up when sent")
    let order = json(t.requests.last!)["data"] as! [[String: String]]
    #expect(order.map { $0["id"]! } == ["UP3", "UP7"])
    let put = t.requests.first { $0.url!.host == "upload.example" }!
    #expect(put.httpBody == pngHeader(1284, 2778), "the part is read from the file")
    #expect(sender.record.uploads == [a.path: MediaLock.Entry(md5: a.md5, appleChecksum: a.md5, id: "UP3"),
                                      b.path: MediaLock.Entry(md5: b.md5, appleChecksum: b.md5, id: "UP7")])
}

@Test func deletionsComeFirstOnlyWhenTheSetWouldOverflow() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try upload(dir, "en-US/screenshots/APP_IPHONE_67/02-new.png")
    for first in [true, false] {
        let t = RoutedTransport(fakeApp())
        acceptUploads(t)
        let sender = mediaSender(t)
        let work = StoreMediaWork(kind: .screenshots, container: .set("S1"), slots: [.keep("SS1"), .upload(a)], deletes: ["SS2"], deleteFirst: first)
        try await sender.apply(StoreChange(.update, .media, "screenshots en-US APP_IPHONE_67", requests: [], media: work))
        let writes = sent(t)
        #expect((writes.firstIndex(of: "DELETE /v1/appScreenshots/SS2")! < writes.firstIndex(of: "POST /v1/appScreenshots")!) == first)
        #expect(!writes.contains { $0.contains("relationships") }, "no reorder asked")
        #expect(sender.record.deleted == ["SS2"])
    }
}

@Test func aFileHangsFromWhatTheChangeCreated() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try upload(dir, "review/walkthrough.mov", bytes: Data("movie".utf8))
    let t = RoutedTransport(fakeApp())
    acceptUploads(t)
    let change = StoreChange(.create, .review, "App Review details",
                             requests: [.create("appStoreReviewDetails", attributes: [:], relationships: ["appStoreVersion": StoreRequest.link("appStoreVersions", "V2")])],
                             media: StoreMediaWork(kind: .reviewAttachments, container: .parent("{id}"), slots: [.upload(a)]))
    try await mediaSender(t).apply(change)
    let reserve = json(t.requests.first { $0.url!.path == "/v1/appStoreReviewAttachments" }!)["data"] as! [String: Any]
    #expect("\(reserve["relationships"]!)".contains("NEW1") && "\(reserve["relationships"]!)".contains("appStoreReviewDetails"))
    #expect((reserve["attributes"] as! [String: Any])["fileName"] as? String == "walkthrough.mov")
}

@Test func aPrunedFileLeavesTheLock() async throws {
    let t = RoutedTransport(fakeApp())
    let sender = mediaSender(t)
    try await sender.apply(StoreChange(.delete, .media, "screenshots en-US APP_IPHONE_67 old.png", requests: [.delete("appScreenshots", id: "SS3")]))
    try await sender.apply(StoreChange(.delete, .text, "version text de-DE", requests: [.delete("appStoreVersionLocalizations", id: "VL2")]))
    #expect(sender.record.deleted == ["SS3"])
}

@Test func anUploadStillProcessingIsANote() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try upload(dir, "en-US/previews/IPHONE_67/01-intro.mov", bytes: Data("movie".utf8))
    let t = RoutedTransport(fakeApp())
    acceptUploads(t, state: "PROCESSING")
    let client = ASCClient(credentials: storeCreds, transport: t, sleep: { _ in })
    let sender = StoreSender(client: client, secret: { _ in "" },
                             uploader: AssetUploader(client: client, stage: .account, rerun: "re-run", sleep: { _ in try await Task.sleep(for: .milliseconds(2)) },
                                                     pollInterval: .zero, timeout: .milliseconds(1)))
    try await sender.apply(StoreChange(.update, .media, "previews en-US IPHONE_67", requests: [],
                                       media: StoreMediaWork(kind: .previews, container: .set("PS1"), slots: [.upload(a)])))
    #expect(sender.record.takeNotes() == ["en-US/previews/IPHONE_67/01-intro.mov is uploaded; App Store Connect is still processing it (PROCESSING)"])
    #expect(sender.record.takeNotes().isEmpty)
}
