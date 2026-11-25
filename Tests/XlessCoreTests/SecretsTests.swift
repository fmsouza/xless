import Testing
import Foundation
@testable import XlessCore

@Test func readsEnvAndTrimsIdentifiers() throws {
    let s = Secrets(env: ["ASC_KEY_ID": " ABC123\r\n"])
    #expect(try s.identifier("ASC_KEY_ID", stage: .upload) == "ABC123")
}

@Test func readsFileVariant() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n".write(to: url, atomically: true, encoding: .utf8)
    let s = Secrets(env: ["ASC_KEY_P8_FILE": url.path])
    #expect(try s.required("ASC_KEY_P8", stage: .upload).contains("BEGIN PRIVATE KEY"))
}

@Test func aByteOrderMarkIsNoPartOfASecret() throws {
    #expect(Secrets.withoutMark(Data([0xEF, 0xBB, 0xBF, 0x61])) == Data([0x61]))
    #expect(Secrets.withoutMark(Data([0x61, 0xEF, 0xBB, 0xBF])).count == 4 && Secrets.withoutMark(Data([0xEF, 0xBB])).count == 2 && Secrets.withoutMark(Data()).isEmpty)
    #if os(Windows) // Windows PowerShell's Set-Content -Encoding UTF8 writes one
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([0xEF, 0xBB, 0xBF] + "p\u{e4}ss".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try Secrets(env: ["XLESS_DEMO_PASSWORD_FILE": url.path]).required("XLESS_DEMO_PASSWORD", stage: .config)
    #expect(text.unicodeScalars.elementsEqual("p\u{e4}ss".unicodeScalars))
    #endif
}

@Test func missingSecretNamesBothVariables() {
    let s = Secrets(env: [:])
    do { _ = try s.required("XLESS_DIST_KEY", stage: .sign); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.description.contains("XLESS_DIST_KEY_FILE")) }
    catch { Issue.record("\(error)") }
}

@Test func emptyValueIsMissing() throws {
    #expect(try Secrets(env: ["X": ""]).optional("X") == nil)
}

/// A store that records what it was asked and answers from a table.
private final class FakeStore: SecretFallback, @unchecked Sendable {
    let values: [String: String]
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.withLock { _asked } }
    init(_ values: [String: String]) { self.values = values }
    func lookup(_ name: String, stage: Stage) throws -> String? {
        lock.withLock { _asked.append(name) }
        return values[name]
    }
}

@Test func theEnvironmentWinsOverTheStoreAndTheStoreIsNeverAsked() throws {
    let store = FakeStore(["ASC_KEY_ID": "FROMSTORE"])
    let s = Secrets(env: ["ASC_KEY_ID": "FROMENV"], fallback: store)
    #expect(try s.identifier("ASC_KEY_ID", stage: .upload) == "FROMENV")
    #expect(store.asked.isEmpty)
}

@Test func theFileVariantWinsOverTheStoreAndTheStoreIsNeverAsked() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "FROMFILE".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = FakeStore(["XLESS_DIST_KEY": "FROMSTORE"])
    let s = Secrets(env: ["XLESS_DIST_KEY_FILE": url.path], fallback: store)
    #expect(try s.required("XLESS_DIST_KEY", stage: .sign) == "FROMFILE")
    #expect(store.asked.isEmpty)
}

@Test func theStoreIsTheLastResort() throws {
    let store = FakeStore(["XLESS_DIST_KEY": "FROMSTORE"])
    let s = Secrets(env: [:], fallback: store)
    #expect(try s.required("XLESS_DIST_KEY", stage: .sign) == "FROMSTORE")
    #expect(store.asked == ["XLESS_DIST_KEY"])
    #expect(try s.optional("NOT_THERE") == nil)
}

@Test func aMissingSecretPointsAtTheStore() {
    do { _ = try Secrets(env: [:], fallback: FakeStore([:])).required("XLESS_DIST_KEY", stage: .sign); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix.contains("xless secrets import XLESS_DIST_KEY")) }
    catch { Issue.record("\(error)") }
    do { _ = try Secrets(env: [:], fallback: nil).identifier("ASC_ISSUER_ID", stage: .upload); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.fix.contains("xless secrets import ASC_KEY_P8")) }
    catch { Issue.record("\(error)") }
}

@Test func noStoreIsInstalledByDefault() {
    #expect(Secrets.installedFallback == nil)
}
