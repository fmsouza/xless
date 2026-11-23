import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import XlessStore

// Media uploads at once: the same IDs, order and media.lock as one file at a time, against a fake App Store Connect
// that names what it creates after what it was asked for (so a run's IDs do not depend on the order requests arrive).

/// App Store Connect's upload side, deterministic: a new set is `SET-<localization>-<type>`, a reserved file
/// `UP-<parent>-<file name>`; reading a file answers COMPLETE, or FAILED for a file name in `failing`. Remembers each
/// reservation (file name, parent) and each committed checksum, to rebuild what App Store Connect has afterwards.
final class NamedUploads: @unchecked Sendable {
    struct Reserved: Equatable { var fileName: String; var parent: String }
    private let lock = NSLock()
    private var reserved: [String: Reserved] = [:]
    private var checksums: [String: String] = [:]
    let failing: Set<String>

    init(_ t: RoutedTransport, failing: Set<String> = []) {
        self.failing = failing
        let previous = t.onRequest
        t.onRequest = { [self] r, t in
            previous?(r, t)
            guard let method = r.httpMethod, method != "GET" else { return }
            let doc = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let data = doc["data"] as? [String: Any] ?? [:]
            let attributes = data["attributes"] as? [String: Any] ?? [:]
            let parent = ((data["relationships"] as? [String: Any])?.values.first as? [String: Any])?["data"] as? [String: Any]
            let path = r.url!.path
            if method == "POST", let set = ["appScreenshotSets": "screenshotDisplayType", "appPreviewSets": "previewType"].first(where: { path == "/v1/\($0.key)" }) {
                let id = "SET-\(parent?["id"] as? String ?? "?")-\(attributes[set.value] as? String ?? "?")"
                t.routes["POST \(path)"] = (201, #"{"data":{"type":"\#(set.key)","id":"\#(id)"}}"#)
            } else if method == "POST", let type = StoreMediaKind.allItemTypes.first(where: { path == "/v1/\($0)" }) {
                let name = attributes["fileName"] as? String ?? "?"
                let owner = parent?["id"] as? String ?? "?"
                let id = "UP-\(owner)-\(name)"
                let size = attributes["fileSize"] as? Int ?? 0
                lock.withLock { reserved[id] = Reserved(fileName: name, parent: owner) }
                t.routes["POST \(path)"] = (201, #"{"data":{"type":"\#(type)","id":"\#(id)","attributes":{"uploadOperations":[{"method":"PUT","url":"https://upload.example/\#(id)","offset":0,"length":\#(size),"requestHeaders":[]}]}}}"#)
                let state = failing.contains(name) ? #"FAILED","errors":[{"code":"IMAGE_INCORRECT_DIMENSIONS","description":"wrong size"}]"# : #"COMPLETE""#
                t.routes["/v1/\(type)/\(id)"] = (200, #"{"data":{"type":"\#(type)","id":"\#(id)","attributes":{"assetDeliveryState":{"state":"\#(state)}}}}"#)
            } else if method == "PATCH", let checksum = attributes["sourceFileChecksum"] as? String {
                lock.withLock { checksums[String(path.split(separator: "/").last!)] = checksum }
            }
        }
    }

    var reservations: [String: Reserved] { lock.withLock { reserved } }
    var committed: [String: String] { lock.withLock { checksums } }
}

/// Holds every PUT to Apple's storage a little, counting how many are in flight at once.
final class SlowStorage: HTTPTransport, @unchecked Sendable {
    let inner: HTTPTransport
    let delay: @Sendable (URLRequest) -> Duration
    private let lock = NSLock()
    private var now = 0
    private(set) var most = 0

    init(_ inner: HTTPTransport, delay: @escaping @Sendable (URLRequest) -> Duration = { _ in .milliseconds(15) }) { self.inner = inner; self.delay = delay }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.host == "upload.example" else { return try await inner.send(request) }
        lock.withLock { now += 1; most = max(most, now) }
        defer { lock.withLock { now -= 1 } }
        try await Task.sleep(for: delay(request))
        return try await inner.send(request)
    }
}

private func json(_ r: URLRequest) -> [String: Any] { (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

/// The order sent for each set: path → file IDs.
private func orders(_ t: RoutedTransport) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for r in t.requests where r.httpMethod == "PATCH" && r.url!.path.contains("/relationships/") {
        out[r.url!.path] = (json(r)["data"] as? [[String: String]] ?? []).map { $0["id"]! }
    }
    return out
}

private func shots(_ dir: URL, _ count: Int, _ prefix: String, size: (Int, Int) = (1284, 2778)) throws -> [StoreMediaWork.Slot] {
    try (1...count).map { i in .upload(try upload(dir, "\(prefix)/0\(i)-shot\(i).png", bytes: pngHeader(size.0, size.1) + Data([UInt8(i)]))) }
}

@Test func aSetsFilesGoUpAtOnceAndStayInTheirOrder() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let routed = RoutedTransport(fakeApp())
    let uploads = NamedUploads(routed)
    let slow = SlowStorage(routed)
    let slots = try shots(dir, 7, "en-US/screenshots/APP_IPHONE_65")
    let sender = mediaSender(slow)
    try await sender.apply(StoreChange(.create, .media, "screenshots en-US APP_IPHONE_65", requests: [],
                                       media: StoreMediaWork(kind: .screenshots, container: .newSet(type: "APP_IPHONE_65", localization: .id("VL1")),
                                                             slots: slots, reorder: true)))
    #expect(slow.most > 1, "files went up at once")
    #expect(slow.most <= StoreSender.uploadConcurrency, "never more than \(StoreSender.uploadConcurrency) at once")
    let expected = (1...7).map { "UP-SET-VL1-APP_IPHONE_65-0\($0)-shot\($0).png" }
    #expect(orders(routed) == ["/v1/appScreenshotSets/SET-VL1-APP_IPHONE_65/relationships/appScreenshots": expected])
    #expect(sender.record.uploads.values.compactMap(\.id).sorted() == expected)
    #expect(Set(uploads.committed.keys) == Set(expected))
}

@Test func oneFailedFileStopsNewTransfersButKeepsWhatWentUp() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let routed = RoutedTransport(fakeApp())
    let uploads = NamedUploads(routed, failing: ["01-shot1.png"])
    let slots = try shots(dir, 8, "en-US/screenshots/APP_IPHONE_67", size: (1320, 2868))
    // The failing file goes up at once; the others take a while, so the failure is known before most start.
    let sender = mediaSender(SlowStorage(routed, delay: { $0.url!.path.contains("01-shot1") ? .zero : .milliseconds(150) }), concurrency: 2)
    await #expect {
        try await sender.apply(StoreChange(.update, .media, "screenshots en-US APP_IPHONE_67", requests: [],
                                           media: StoreMediaWork(kind: .screenshots, container: .set("S1"), slots: [.keep("SS1")] + slots, reorder: true)))
    } throws: { "\($0)".contains("01-shot1.png") && "\($0)".contains("wrong size") }
    let bad = "UP-S1-01-shot1.png"
    // Every file App Store Connect accepted is in media.lock; the failed one was removed and is not.
    let recorded = Set(sender.record.uploads.values.compactMap(\.id))
    #expect(recorded == Set(uploads.reservations.keys).subtracting([bad]))
    #expect(!recorded.contains(bad))
    #expect(routed.requests.contains { $0.httpMethod == "DELETE" && $0.url!.path == "/v1/appScreenshots/\(bad)" })
    #expect(uploads.reservations.count <= 4, "no new transfer once one failed (\(uploads.reservations.keys.sorted()))")
    #expect(orders(routed).isEmpty, "a set with a failed file is not reordered")
}

// MARK: - A whole push, one file at a time and at once

private func synced() -> [String: (Int, String)] {
    var routes = fakeApp()
    routes["/v1/apps/123/accessibilityDeclarations"] = (200, list([
        #"{"type":"accessibilityDeclarations","id":"AC1","attributes":{"deviceFamily":"IPHONE","state":"PUBLISHED","supportsVoiceover":true,"supportsDarkInterface":true}}"#,
    ]))
    return routes
}

/// Two locales, three new sets in en-US and two in de-DE, 2 to 4 files each.
private func listing() async throws -> (root: URL, dir: URL) {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    _ = try await puller(RoutedTransport(synced()), FakeCDN(introStream.merging([homeURL: homePNG]) { $1 }))
        .run(app: fakeASCApp, platform: nil, selection: .automatic, into: dir, today: today)
    let sets: [(String, Int, (Int, Int))] = [
        ("en-US/screenshots/APP_IPHONE_65", 4, (1284, 2778)), ("en-US/screenshots/APP_IPAD_PRO_3GEN_129", 3, (2048, 2732)),
        ("en-US/screenshots/APP_IPHONE_61", 2, (1179, 2556)),
        ("de-DE/screenshots/APP_IPHONE_67", 3, (1320, 2868)), ("de-DE/screenshots/APP_IPHONE_65", 2, (1284, 2778)),
    ]
    for (prefix, count, size) in sets {
        for i in 1...count { try write(pngHeader(size.0, size.1) + Data(prefix.utf8) + Data([UInt8(i)]), "\(prefix)/0\(i)-shot\(i).png", in: dir) }
    }
    return (root, dir)
}

private struct Pushed {
    var lock: Data
    var orders: [String: [String]]
    var uploads: NamedUploads
    var most: Int
}

private func push(_ dir: URL, concurrency: Int) async throws -> Pushed {
    let routed = RoutedTransport(synced())
    let uploads = NamedUploads(routed)
    let slow = SlowStorage(routed)
    let push = StorePush(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: slow, sleep: { _ in })))
    let manifest = ManifestReader.read(dir).manifest
    let options = StorePush.Options(parts: [.media])
    let (plan, _) = try await push.plan(app: fakeASCApp, manifest: manifest, dir: dir, options: options)
    #expect(plan.changes.count == 5)
    let applied = try await push.apply(plan, app: fakeASCApp, manifest: manifest, dir: dir, options: options, sender: mediaSender(slow, concurrency: concurrency))
    #expect(applied.sent.map(\.subject) == plan.changes.map(\.subject), "sent in plan order")
    return Pushed(lock: try Data(contentsOf: dir.appendingPathComponent(MediaLock.fileName)), orders: orders(routed), uploads: uploads, most: slow.most)
}

@Test func uploadingAtOnceEndsWhereOneAtATimeEnds() async throws {
    let (rootA, one) = try await listing()
    let (rootB, many) = try await listing()
    defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
    let sequential = try await push(one, concurrency: 1)
    let concurrent = try await push(many, concurrency: 4)
    #expect(sequential.most == 1)
    #expect(concurrent.most > 1 && concurrent.most <= 4)
    #expect(String(decoding: concurrent.lock, as: UTF8.self) == String(decoding: sequential.lock, as: UTF8.self), "media.lock is the same")
    #expect(concurrent.orders == sequential.orders, "every set in the directory's order")
    #expect(concurrent.orders.count == 5)
    #expect(concurrent.orders["/v1/appScreenshotSets/SET-VL1-APP_IPHONE_65/relationships/appScreenshots"]
        == (1...4).map { "UP-SET-VL1-APP_IPHONE_65-0\($0)-shot\($0).png" })

    // App Store Connect now has what the concurrent push sent: a second push uploads nothing.
    var after = synced()
    let created = Dictionary(grouping: concurrent.orders.keys.map { path -> (localization: String, set: String, type: String) in
        let set = path.split(separator: "/")[2]
        let parts = set.split(separator: "-", maxSplits: 2)
        return (String(parts[1]), String(set), String(parts[2]))
    }, by: \.localization)
    after["/v1/appStoreVersionLocalizations/VL1/appScreenshotSets"] = (200, list(
        [#"{"type":"appScreenshotSets","id":"S1","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}"#]
        + (created["VL1"] ?? []).map { #"{"type":"appScreenshotSets","id":"\#($0.set)","attributes":{"screenshotDisplayType":"\#($0.type)"}}"# }))
    after["/v1/appStoreVersionLocalizations/VL2/appScreenshotSets"] = (200, list(
        (created["VL2"] ?? []).map { #"{"type":"appScreenshotSets","id":"\#($0.set)","attributes":{"screenshotDisplayType":"\#($0.type)"}}"# }))
    let committed = concurrent.uploads.committed
    let reserved = concurrent.uploads.reservations
    for (path, ids) in concurrent.orders {
        after["/v1/appScreenshotSets/\(path.split(separator: "/")[2])/appScreenshots"] = (200, list(ids.map { id in
            #"{"type":"appScreenshots","id":"\#(id)","attributes":{"fileName":"\#(reserved[id]!.fileName)","sourceFileChecksum":"\#(committed[id]!)","assetDeliveryState":{"state":"COMPLETE"}}}"#
        }))
    }
    let again = RoutedTransport(after)
    let (second, _) = try await StorePush(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: again, sleep: { _ in })))
        .plan(app: fakeASCApp, manifest: ManifestReader.read(many).manifest, dir: many, options: StorePush.Options(parts: [.media]))
    #expect(second.changes.isEmpty, "\(second.changes.map(\.text))")
}

@Test func aFailedSetStopsThePushAfterTheOthersAreRecorded() async throws {
    let (root, dir) = try await listing()
    defer { try? FileManager.default.removeItem(at: root) }
    let routed = RoutedTransport(synced())
    let uploads = NamedUploads(routed)
    let accept = routed.onRequest
    routed.onRequest = { r, t in
        accept?(r, t)
        if r.httpMethod == "POST", r.url!.path == "/v1/appScreenshotSets", String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("APP_IPHONE_61") {
            t.routes["POST /v1/appScreenshotSets"] = (500, #"{"errors":[{"status":"500","code":"UNEXPECTED","title":"boom"}]}"#)
        }
    }
    let notes = Notes()
    let push = StorePush(resources: ASCResources(client: ASCClient(credentials: storeCreds, transport: routed, sleep: { _ in })), say: { notes.say($0) })
    let manifest = ManifestReader.read(dir).manifest
    let options = StorePush.Options(parts: [.media])
    let (plan, _) = try await push.plan(app: fakeASCApp, manifest: manifest, dir: dir, options: options)
    await #expect(throws: ASCError.self) {
        _ = try await push.apply(plan, app: fakeASCApp, manifest: manifest, dir: dir, options: options, sender: mediaSender(routed))
    }
    // The other sets' files were uploaded and are in media.lock.
    let lock = MediaLock.read(dir)
    let inLock = Set(lock.files.values.values.compactMap(\.id))
    #expect(!uploads.reservations.isEmpty)
    #expect(Set(uploads.reservations.keys).isSubset(of: inLock))
    #expect(!lock.files.values.keys.contains { $0.contains("APP_IPHONE_61") })
    #expect(notes.lines.contains { $0.contains("of 5 changes") && $0.contains("sent before this failure") })
}
