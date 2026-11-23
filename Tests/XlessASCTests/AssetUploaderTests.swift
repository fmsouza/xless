import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XlessASC
@testable import XlessCore

private func tempFile(_ bytes: [UInt8]) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID()).png")
    try Data(bytes).write(to: u)
    return u
}

private func uploader(_ t: MockTransport, timeout: Duration = .seconds(600), sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> AssetUploader {
    AssetUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), stage: .account, rerun: "re-run `xless store push`",
                  sleep: sleep, pollInterval: .seconds(1), timeout: timeout)
}

private func asset(_ file: URL, size: Int) throws -> AssetUpload {
    AssetUpload(type: "appScreenshots", file: file, fileName: "01-home.png", fileSize: size, md5: try AssetFile.md5(file),
                relationship: "appScreenshotSet", parentType: "appScreenshotSets", parentID: "SET1", display: "en-US/screenshots/APP_IPHONE_67/01-home.png")
}

private let reserved: MockTransport.Step = .response(201, #"{"data":{"type":"appScreenshots","id":"SS9","attributes":{"uploadOperations":[{"method":"PUT","url":"https://up.example/a","offset":0,"length":4,"requestHeaders":[{"name":"Content-Type","value":"image/png"}]},{"method":"PUT","url":"https://up.example/b","offset":4,"length":3,"requestHeaders":[]}]}}}"#)
private let committed: MockTransport.Step = .response(200, #"{"data":{"type":"appScreenshots","id":"SS9","attributes":{}}}"#)
private func state(_ s: String, errors: String = "[]") -> MockTransport.Step {
    .response(200, #"{"data":{"type":"appScreenshots","id":"SS9","attributes":{"assetDeliveryState":{"state":"\#(s)","errors":\#(errors)}}}}"#)
}

@Test func filesAreHashedAndSizedFromDisk() throws {
    let f = try tempFile(Array("hello".utf8))
    #expect(try AssetFile.size(f) == 5)
    #expect(try AssetFile.md5(f) == "5d41402abc4b2a76b9719d911017c592")
}

@Test func partsAreReadFromTheirOffsetsAndCommittedWithTheChecksum() async throws {
    let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
    let f = try tempFile(bytes)
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(200, ""), committed, state("UPLOAD_COMPLETE"), state("COMPLETE")])
    let result = try await uploader(t).upload(try asset(f, size: 7))
    #expect(result == .complete("SS9"))
    let reserve = String(decoding: t.requests[0].httpBody!, as: UTF8.self)
    #expect(t.requests[0].httpMethod == "POST" && t.requests[0].url!.path == "/v1/appScreenshots")
    #expect(reserve.contains(#""fileName":"01-home.png""#) && reserve.contains(#""fileSize":7"#) && reserve.contains(#""appScreenshotSet":{"data":{"id":"SET1","type":"appScreenshotSets"}}"#))
    #expect(t.requests[1].url!.absoluteString == "https://up.example/a" && t.requests[1].httpBody == Data([1, 2, 3, 4]))
    #expect(t.requests[1].value(forHTTPHeaderField: "Content-Type") == "image/png")
    #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(t.requests[2].httpBody == Data([5, 6, 7]))
    let commit = String(decoding: t.requests[3].httpBody!, as: UTF8.self)
    let md5 = try AssetFile.md5(f)
    #expect(t.requests[3].httpMethod == "PATCH" && t.requests[3].url!.path == "/v1/appScreenshots/SS9")
    #expect(commit.contains(#""uploaded":true"#) && commit.contains(#""sourceFileChecksum":"\#(md5)""#))
    #expect(t.requests[5].httpMethod == "GET" && t.requests[5].url!.path == "/v1/appScreenshots/SS9")
}

@Test func aFailedPartIsRetriedOnItsOwn() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(500, ""), .failure(.timedOut), .response(200, ""), committed, state("COMPLETE")])
    #expect(try await uploader(t).upload(try asset(f, size: 7)) == .complete("SS9"))
    let puts = t.requests.filter { $0.httpMethod == "PUT" }.map { $0.url!.lastPathComponent }
    #expect(puts == ["a", "b", "b", "b"])
}

@Test func theReservationIsSentOnceAndAFailedUploadIsRemoved() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let once = MockTransport(steps: [.response(500, #"{"errors":[{"status":"500","code":"UNEXPECTED"}]}"#)])
    await #expect(throws: XlessError.self) { _ = try await uploader(once).upload(try asset(f, size: 7)) }
    #expect(once.requests.count == 1, "a reservation is never retried")

    let parts = MockTransport(steps: [reserved] + Array(repeating: .failure(.timedOut), count: 5) + [.response(204, "")])
    do { _ = try await uploader(parts).upload(try asset(f, size: 7)); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.stage == .account && e.cause.contains("uploading bytes 0..<4 of en-US/screenshots/APP_IPHONE_67/01-home.png"))
    }
    #expect(parts.requests.last?.httpMethod == "DELETE" && parts.requests.last?.url!.path == "/v1/appScreenshots/SS9")
}

@Test func failedProcessingSaysWhatAppleSaid() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(200, ""), committed,
                                  state("FAILED", errors: #"[{"code":"IMAGE_INCORRECT_DIMENSIONS","description":"The dimensions of one or more screenshots are wrong."}]"#),
                                  .response(204, "")])
    do { _ = try await uploader(t).upload(try asset(f, size: 7)); Issue.record("expected throw") } catch let e as XlessError {
        #expect(e.stage == .account)
        #expect(e.cause.contains("01-home.png") && e.cause.contains("IMAGE_INCORRECT_DIMENSIONS The dimensions of one or more screenshots are wrong."))
        #expect(e.fix.contains("re-run `xless store push`"))
    }
    #expect(t.requests.last?.httpMethod == "DELETE", "the failed upload is removed so a re-run starts clean")
}

@Test func stillProcessingAfterTheTimeoutIsPending() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(200, ""), committed] + Array(repeating: state("UPLOAD_COMPLETE"), count: 50))
    let up = uploader(t, timeout: .milliseconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    #expect(try await up.upload(try asset(f, size: 7)) == .pending("SS9", state: "UPLOAD_COMPLETE"))
    #expect(!t.requests.contains { $0.httpMethod == "DELETE" })
}

@Test func previewsAreWatchedThroughTheirVideoState() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(200, ""), committed,
                                  .response(200, #"{"data":{"type":"appPreviews","id":"SS9","attributes":{"assetDeliveryState":{"state":"COMPLETE"},"videoDeliveryState":{"state":"PROCESSING"}}}}"#),
                                  .response(200, #"{"data":{"type":"appPreviews","id":"SS9","attributes":{"videoDeliveryState":{"state":"COMPLETE"}}}}"#)])
    var a = try asset(f, size: 7)
    a.type = "appPreviews"; a.commit = ["previewFrameTimeCode": .string("00:00:05:00")]
    #expect(try await uploader(t).upload(a) == .complete("SS9"))
    #expect(String(decoding: t.requests[3].httpBody!, as: UTF8.self).contains(#""previewFrameTimeCode":"00:00:05:00""#))
    #expect(t.requests.filter { $0.httpMethod == "GET" }.count == 2)
}

@Test func anOperationOutsideTheFileIsRefused() async throws {
    let f = try tempFile([1, 2, 3])
    let t = MockTransport(steps: [reserved, .response(204, "")])
    await #expect { _ = try await uploader(t).upload(try asset(f, size: 3)) } throws: { "\($0)".contains("invalid upload operation") }
}

@Test func aTransferEndsAtTheCommitAndTheWaitPollsWithBackoff() async throws {
    let f = try tempFile([1, 2, 3, 4, 5, 6, 7])
    let t = MockTransport(steps: [reserved, .response(200, ""), .response(200, ""), committed, state("UPLOAD_COMPLETE"), state("UPLOAD_COMPLETE"), state("COMPLETE")])
    let slept = Slept()
    let u = AssetUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), stage: .account, rerun: "re-run",
                          sleep: { slept.add($0) }, pollInterval: .seconds(2), timeout: .seconds(600), maxPollInterval: .seconds(3))
    let a = try asset(f, size: 7)
    let id = try await u.transfer(a)
    #expect(id == "SS9")
    #expect(t.requests.count == 4, "reserve, two parts, commit: no poll yet")
    #expect(try await u.wait(id: id, asset: a) == .complete("SS9"))
    #expect(slept.all == [.seconds(2), .seconds(3)], "1.5x, capped")
}

final class Slept: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func add(_ d: Duration) { lock.withLock { values.append(d) } }
    var all: [Duration] { lock.withLock { values } }
}
