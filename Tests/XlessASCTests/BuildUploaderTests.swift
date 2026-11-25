import Testing
import Foundation
@testable import XlessASC
@testable import XlessCore

func tempIPA(_ bytes: Int) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).ipa")
    try Data(repeating: 7, count: bytes).write(to: u)
    return u
}

@Test func happyPathUploadsChunksAndWaitsForValid() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"APP1","attributes":{"bundleId":"a.b"}}]}"#),
        (201, #"{"data":{"type":"buildUploads","id":"U1","attributes":{}}}"#),
        (201, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{"uploadOperations":[{"method":"PUT","url":"https://up.example/1","offset":0,"length":6,"requestHeaders":[{"name":"Content-Type","value":"application/octet-stream"}]},{"method":"PUT","url":"https://up.example/2","offset":6,"length":4,"requestHeaders":[]}]}}}"#),
        (200, ""), (200, ""),
        (200, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{}}}"#),
        (200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"PROCESSING"}}}}"#),
        (200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"COMPLETE"}},"relationships":{"build":{"data":{"type":"builds","id":"B1"}}}}}"#),
        (200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"PROCESSING"}}}"#),
        (200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"VALID"}}}"#),
    ])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    let rec = try await up.upload(ipa: tempIPA(10), bundleID: "a.b", version: "1.0.0", build: "5", platform: .ios)
    #expect(rec.buildID == "B1" && rec.processingState == "VALID")
    #expect(t.requests[3].url!.absoluteString == "https://up.example/1" && t.requests[3].httpBody?.count == 6)
    #expect(t.requests[3].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(t.requests[4].httpBody?.count == 4)
    let patch = String(decoding: t.requests[5].httpBody!, as: UTF8.self)
    #expect(patch.contains("\"uploaded\":true") && patch.contains("MD5"))
    #expect(t.requests[7].url!.absoluteString.contains("/v1/buildUploads/U1") && t.requests[7].url!.query == "include=build")
    #expect(t.requests[8].url!.path == "/v1/builds/B1")
}

@Test func missingAppRecordExplainsFix() async throws {
    let t = MockTransport([(200, #"{"data":[]}"#)])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.fix.contains("App Store Connect")) }
}

@Test func failedProcessingExplainsKnownIssue() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"APP1","attributes":{"bundleId":"a.b"}}]}"#),
        (201, #"{"data":{"type":"buildUploads","id":"U1","attributes":{}}}"#),
        (201, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{"uploadOperations":[{"method":"PUT","url":"https://up.example/1","offset":0,"length":1,"requestHeaders":[]}]}}}"#),
        (200, ""),
        (200, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{}}}"#),
        (200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"FAILED","errors":[{"code":"90189","description":"ITMS-90189: Redundant Binary Upload"}]}}}}"#),
    ])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("build number")) }
}

@Test func duplicateBuildAtCreateIsExplained() async throws {
    let t = MockTransport([
        (200, #"{"data":[{"type":"apps","id":"APP1","attributes":{"bundleId":"a.b"}}]}"#),
        (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"The bundle version must be higher than the previously uploaded version."}]}"#),
    ])
    let up = BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: { _ in })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("build number")) }
}

private let appStep: MockTransport.Step = .response(200, #"{"data":[{"type":"apps","id":"APP1","attributes":{"bundleId":"a.b"}}]}"#)
private let uploadStep: MockTransport.Step = .response(201, #"{"data":{"type":"buildUploads","id":"U1","attributes":{}}}"#)
private func fileStep(length: Int = 1) -> MockTransport.Step {
    .response(201, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{"uploadOperations":[{"method":"PUT","url":"https://up.example/1","offset":0,"length":\#(length),"requestHeaders":[]}]}}}"#)
}
private let patchStep: MockTransport.Step = .response(200, #"{"data":{"type":"buildUploadFiles","id":"F1","attributes":{}}}"#)
private let completeStep: MockTransport.Step = .response(200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"COMPLETE"}},"relationships":{"build":{"data":{"type":"builds","id":"B1"}}}}}"#)

private func uploader(_ t: MockTransport, timeout: Duration = .seconds(3600), sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> BuildUploader {
    BuildUploader(client: ASCClient(credentials: testCreds, transport: t, sleep: { _ in }), sleep: sleep, timeout: timeout)
}

@Test func fileCreateServerErrorIsUploadStageError() async throws {
    let t = MockTransport(steps: [appStep, uploadStep] + Array(repeating: .response(500, ""), count: 5))
    do { _ = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload) }
}

@Test func storagePutFailureSaysRerun() async throws {
    let t = MockTransport(steps: [appStep, uploadStep, fileStep()] + Array(repeating: .failure(.timedOut), count: 5))
    do { _ = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.fix.contains("expire") && e.fix.contains("xless upload")) }
}

@Test func appLookupFailureIsUploadStageError() async throws {
    let t = MockTransport([(401, #"{"errors":[{"status":"401","code":"NOT_AUTHORIZED","detail":"bad token"}]}"#)])
    do { _ = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload) }
}

@Test func invalidBuildThrowsUploadError() async throws {
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, completeStep,
        .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"INVALID"}}}"#)])
    do { _ = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.cause.contains("INVALID")) }
}

@Test func pollTimesOutWhileProcessing() async throws {
    let processing: MockTransport.Step = .response(200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"PROCESSING"}}}}"#)
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep] + Array(repeating: processing, count: 50))
    let up = uploader(t, timeout: .milliseconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.cause.contains("still") && e.cause.contains("after")) }
}

@Test func buildProcessingTimesOut() async throws {
    let building: MockTransport.Step = .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"PROCESSING"}}}"#)
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, completeStep] + Array(repeating: building, count: 50))
    let up = uploader(t, timeout: .milliseconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    do { _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .upload); #expect(e.cause.contains("still") && e.cause.contains("after")) }
}

@Test func warningsAreSurfacedInFailure() async throws {
    let failed: MockTransport.Step = .response(200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"FAILED","errors":[{"code":"1","description":"boom"}],"warnings":[{"code":"90717","description":"icon warn"}]}}}}"#)
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, failed])
    do { _ = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.cause.contains("icon warn") && e.cause.contains("boom")) }
}

final class RecordLog: @unchecked Sendable {
    var records: [UploadRecord] = []
    var fn: @Sendable (UploadRecord) throws -> Void { { [self] r in records.append(r) } }
}

@Test func recordIsReportedOnEveryStateChange() async throws {
    let processing: MockTransport.Step = .response(200, #"{"data":{"type":"buildUploads","id":"U1","attributes":{"state":{"state":"PROCESSING"}}}}"#)
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, processing, processing, completeStep,
        .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"PROCESSING"}}}"#),
        .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"VALID"}}}"#)])
    let log = RecordLog()
    let rec = try await uploader(t).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios, onRecord: log.fn)
    #expect(log.records.first?.buildUploadID == "U1")
    #expect(log.records.map(\.state) == ["AWAITING_UPLOAD", "PROCESSING", "COMPLETE", "COMPLETE", "COMPLETE"])
    #expect(log.records.map(\.processingState) == [nil, nil, nil, "PROCESSING", "VALID"])
    #expect(log.records.last == rec)
    // Every record says what was uploaded.
    #expect(log.records.allSatisfy { $0.bundleID == "a.b" && $0.version == "1" && $0.build == "1" && $0.platform == .ios })
}

@Test func recordIsReportedBeforeAFailure() async throws {
    let building: MockTransport.Step = .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"PROCESSING"}}}"#)
    let t = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, completeStep] + Array(repeating: building, count: 50))
    let log = RecordLog()
    let up = uploader(t, timeout: .milliseconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    await #expect(throws: XlessError.self) {
        _ = try await up.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios, onRecord: log.fn)
    }
    #expect(log.records.last?.buildID == "B1")
    #expect(log.records.last?.processingState == "PROCESSING")
}

@Test func afterCompleteFailuresSayDoNotReupload() async throws {
    let building: MockTransport.Step = .response(200, #"{"data":{"type":"builds","id":"B1","attributes":{"processingState":"PROCESSING"}}}"#)
    let timeout = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, completeStep] + Array(repeating: building, count: 50))
    let slow = uploader(timeout, timeout: .milliseconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    do { _ = try await slow.upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.fix.contains("uploaded") && e.fix.contains("TestFlight") && e.fix.contains("don't re-upload"))
        #expect(!e.fix.contains("re-run `xless upload`"))
    }
    let pollFail = MockTransport(steps: [appStep, uploadStep, fileStep(), .response(200, ""), patchStep, completeStep] + Array(repeating: .response(500, ""), count: 5))
    do { _ = try await uploader(pollFail).upload(ipa: tempIPA(1), bundleID: "a.b", version: "1", build: "1", platform: .ios); Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.fix.contains("don't re-upload"))
        #expect(!e.fix.contains("re-run `xless upload`"))
    }
}
