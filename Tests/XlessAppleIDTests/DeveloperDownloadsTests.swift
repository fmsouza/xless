import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class DeveloperDownloadsTests: XCTestCase {
    var dir: URL!
    var xip: Data { testXip }
    let file = AppleDownload.File(filename: "Xcode_27.xip", remotePath: "/Developer_Tools/Xcode_27/Xcode_27.xip", fileSize: 100)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func client(_ mock: MockTransport) -> AppleWebClient { AppleWebClient(transport: mock) }

    func run(_ mock: MockTransport) async throws -> DeveloperDownloads.Result {
        try await DeveloperDownloads.download(file, into: dir, client: client(mock), progress: { _ in })
    }

    /// Apple's file server: the ADC auth call is answered 403 (as Apple does for Xcodes), the file with `reply`.
    func apple(_ reply: @escaping @Sendable (URLRequest) -> MockTransport.Reply) -> MockTransport {
        MockTransport { r in
            r.url!.host == "developerservices2.apple.com" ? .init(status: 403) : reply(r)
        }
    }

    // MARK: list

    func testListKeepsXcodeReleases() async throws {
        let mock = MockTransport { r in
            XCTAssertEqual(r.httpMethod, "POST")
            return .json(200, ["resultCode": 0, "downloads": [
                ["name": "Xcode 26.2", "dateModified": "12/01/25 18:00",
                 "files": [["filename": "Xcode_26.2_Universal.xip", "remotePath": "/Developer_Tools/Xcode_26.2/Xcode_26.2_Universal.xip", "fileSize": 3_000_000_000]]],
                ["name": "Command Line Tools for Xcode 26.2", "files": [["remotePath": "/x.dmg"]]],
                ["name": "Additional Tools for Xcode 26", "files": []],
            ]])
        }
        let list = try await DeveloperDownloads.list(client: client(mock))
        XCTAssertEqual(list.map(\.name), ["Xcode 26.2"])
        XCTAssertEqual(list[0].files[0].fileSize, 3_000_000_000)
        XCTAssertEqual(mock.requests[0].url, URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action"))
    }

    func testListReportsApplesRefusal() async {
        let mock = MockTransport { _ in .json(200, ["resultCode": 1100, "resultString": "Please accept the agreement."]) }
        do {
            _ = try await DeveloperDownloads.list(client: client(mock))
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("Please accept the agreement."))
        } catch { XCTFail("\(error)") }
    }

    // MARK: download

    func testDownloadsIntoPartThenRenames() async throws {
        let mock = apple { _ in .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: testXip) }
        let result = try await run(mock)
        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.url.lastPathComponent, "Xcode_27.xip")
        XCTAssertEqual(try Data(contentsOf: result.url), xip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path + ".part"))
        XCTAssertEqual(mock.requests.last?.url?.absoluteString, "https://download.developer.apple.com/Developer_Tools/Xcode_27/Xcode_27.xip")
        XCTAssertTrue(mock.requests.contains { $0.url?.host == "developerservices2.apple.com" })
    }

    func testResumeSendsRange() async throws {
        try xip.prefix(40).write(to: dir.appendingPathComponent("Xcode_27.xip.part"))
        let rest = xip.suffix(from: 40)
        let mock = apple { r in
            XCTAssertEqual(r.header("Range"), "bytes=40-")
            return .init(status: 206, headers: ["Content-Type": "application/octet-stream"], body: rest)
        }
        let result = try await run(mock)
        XCTAssertEqual(try Data(contentsOf: result.url), xip)
    }

    func testFullResponseRestartsPart() async throws {
        try Data("garbage!".utf8).write(to: dir.appendingPathComponent("Xcode_27.xip.part"))
        let mock = apple { _ in .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: testXip) }
        let result = try await run(mock)
        XCTAssertEqual(try Data(contentsOf: result.url), xip)
    }

    func testUnauthorizedRedirectIsAnError() async throws {
        try xip.prefix(40).write(to: dir.appendingPathComponent("Xcode_27.xip.part"))
        let mock = apple { r in
            r.url!.path.hasSuffix("unauthorized")
                ? .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
                : .init(status: 302, headers: ["Location": "https://developer.apple.com/unauthorized"])
        }
        await assertError(mock, contains: "did not authorise")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Xcode_27.xip.part")), xip.prefix(40), "partial download kept")
    }

    func testHTMLBodyIsAnError() async {
        let mock = apple { _ in .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<html>".utf8)) }
        await assertError(mock, contains: "did not authorise")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Xcode_27.xip").path))
    }

    func testForbiddenIsAnError() async {
        await assertError(apple { _ in .init(status: 403) }, contains: "did not authorise")
    }

    func testNonXarIsRejected() async {
        let notXip = Data(repeating: 1, count: 100)
        await assertError(apple { _ in .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: notXip) },
                          contains: "not an Xcode .xip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Xcode_27.xip.part").path))
    }

    func testShortFileKeepsThePartForResume() async {
        await assertError(apple { _ in .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: testXip.prefix(60)) },
                          contains: "re-run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Xcode_27.xip.part").path))
    }

    func testExistingFileIsSkipped() async throws {
        try xip.write(to: dir.appendingPathComponent("Xcode_27.xip"))
        let mock = apple { _ in XCTFail("no request expected"); return .init(status: 500) }
        let result = try await run(mock)
        XCTAssertTrue(result.skipped)
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func assertError(_ mock: MockTransport, contains text: String, line: UInt = #line) async {
        do {
            _ = try await run(mock)
            XCTFail("expected an error", line: line)
        } catch let e as XlessError {
            XCTAssertTrue(e.description.contains(text), e.description, line: line)
        } catch { XCTFail("\(error)", line: line) }
    }
}

let testXip = Data("xar!".utf8) + Data(repeating: 7, count: 96)
