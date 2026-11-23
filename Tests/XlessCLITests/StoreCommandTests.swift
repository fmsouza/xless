import ArgumentParser
import Foundation
import Testing
@testable import xless

private func manifest(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-cli-\(UUID().uuidString)")
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return root
}

@Test func validatePrintsEachIssueAndFails() throws {
    let root = try manifest([
        "appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.0\"\n",
        "appstore/en-US/name.txt": "Example\n",
        "appstore/en-US/keywords.txt": String(repeating: "é", count: 56) + "\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let out = StoreValidation.run(dir: root.appendingPathComponent("appstore"), draft: true, json: false)
    #expect(out.failed && out.stdout.isEmpty)
    let lines = out.stderr.split(separator: "\n").map(String.init)
    #expect(lines.first == "error: [account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten the keywords (comma-separated, counted in UTF-8 bytes)")
    #expect(lines.dropFirst().dropLast().allSatisfy { $0.hasPrefix("warning: ") }, "--draft: what is missing only warns")
    #expect(lines.last == "appstore/: 1 error, 9 warnings")
}

@Test func validateSaysValidAndJSONIsAContract() throws {
    let root = try manifest(["appstore/app.yml": "primaryLocale: en-US\n", "xless.yml": "not: [valid\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("appstore")
    let json = StoreValidation.run(dir: dir, draft: true, json: true)
    #expect(json.failed, "no bundleID and no usable xless.yml")
    #expect(json.stdout.hasPrefix("{\n  \"issues\" : [\n    {\n      \"fix\" : \"add `bundleID: com.example.app` to app.yml\",\n      \"message\" : \"no bundleID, and no usable xless.yml next to appstore/ to take it from\""))
    #expect(json.stdout.contains("\"valid\" : false"))
}

@Test func storeCommandsParse() throws {
    #expect(throws: (any Error).self) { try StorePullCommand.parse(["--live", "--editable"]) }
    #expect(throws: (any Error).self) { try StorePullCommand.parse(["--platform", "watchos"]) }
    let pull = try StorePullCommand.parse(["--app", "com.example.app", "--app-version", "1.2", "--dir", "listing"])
    #expect(pull.selection == .version("1.2") && pull.directory.dir == "listing")
    #expect(try StorePullCommand.parse([]).selection == .automatic)
    #expect(StorePlatform.parse("visionOS") == "VISION_OS" && StorePlatform.parse("mac") == "MAC_OS")
}
