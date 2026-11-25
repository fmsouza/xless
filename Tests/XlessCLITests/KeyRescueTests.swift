import ArgumentParser
import Foundation
import Testing
import XlessCore
@testable import xless

/// A private directory (0700) standing in for $XDG_RUNTIME_DIR; removed by `cleanup()`.
private struct RuntimeDir {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xless-runtime-\(UUID().uuidString)")
    var path: String { url.path }

    init(open: Bool = false) throws {
        if !open { try makePrivateDirectory(url); return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if !os(Windows) // there it has its directory's access list
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #endif
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private let key = SecretBytes(utf8: "-----BEGIN PRIVATE KEY-----\nMIG\n-----END PRIVATE KEY-----\n")
private let noTerminal: @Sendable (String) -> String? = { _ in nil }

@Test func aRescuedKeyGoesToANewPrivateFileInTheRuntimeDirectory() throws {
    let dir = try RuntimeDir()
    defer { dir.cleanup() }
    let rescue = KeyRescue(env: ["XDG_RUNTIME_DIR": dir.path], ask: noTerminal)
    let first = rescue.save(key, keyID: "2X9R4HXF34")
    let path = "\(dir.path)/xless-rescued-AuthKey_2X9R4HXF34.p8"
    #expect(first == .saved(path: path, temporary: true))
    #expect(FileManager.default.contents(atPath: path) == Data(key.utf8String().utf8))
    #expect(try isPrivateFile(path))
    // A second rescue of the same key never overwrites the first.
    #expect(rescue.save(SecretBytes(utf8: "other"), keyID: "2X9R4HXF34") == .saved(path: "\(dir.path)/xless-rescued-AuthKey_2X9R4HXF34.2.p8", temporary: true))
    #expect(FileManager.default.contents(atPath: path) == Data(key.utf8String().utf8))
}

@Test func aRuntimeDirectoryOthersCanEnterOrASymlinkIsNotUsed() throws {
    let open = try RuntimeDir(open: true)
    defer { open.cleanup() }
    let rescue = KeyRescue(env: ["XDG_RUNTIME_DIR": open.path], ask: noTerminal)
    guard case .notSaved(let why) = rescue.save(key, keyID: "K") else { Issue.record("saved"); return }
    #expect(why.contains("is not a private directory of yours") && why.contains("no terminal"), "\(why)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: open.path).isEmpty)

    let real = try RuntimeDir()
    defer { real.cleanup() }
    let link = real.url.deletingLastPathComponent().appendingPathComponent("xless-runtime-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.url)
    defer { try? FileManager.default.removeItem(at: link) }
    guard case .notSaved = KeyRescue(env: ["XDG_RUNTIME_DIR": link.path], ask: noTerminal).save(key, keyID: "K") else { Issue.record("saved"); return }
    #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)

    guard case .notSaved(let relative) = KeyRescue(env: ["XDG_RUNTIME_DIR": "run/user"], ask: noTerminal).save(key, keyID: "K") else { Issue.record("saved"); return }
    #expect(relative.contains("not an absolute path"))
}

@Test func withoutARuntimeDirectoryTheTerminalIsAskedForAPath() throws {
    let dir = try RuntimeDir()
    defer { dir.cleanup() }
    let answers = Answers(["", "ignored"])
    guard case .notSaved(let why) = KeyRescue(env: [:], ask: answers.next).save(key, keyID: "K") else { Issue.record("saved"); return }
    #expect(why == "no file was given") // Enter gives up
    #expect(answers.prompts.count == 1)
    #expect(answers.prompts.first?.contains("Apple offers once") == true)

    // `~/` is HOME's; a directory that does not exist is asked again.
    let retry = Answers(["\(dir.path)/missing/key.p8", "~/key.p8"])
    let saved = KeyRescue(env: ["HOME": dir.path, "USERPROFILE": dir.path], ask: retry.next).save(key, keyID: "K")
    #expect(saved == .saved(path: "\(dir.path)/key.p8", temporary: false))
    #expect(retry.prompts.last?.hasPrefix("Cannot write \(dir.path)/missing/key.p8") == true)
    #expect(try isPrivateFile("\(dir.path)/key.p8"))
}

@Test func secretsImportTakesTheRoleAndServicesARescueCarries() throws {
    let api = try SecretsImportCommand.parse(["ASC_KEY_P8@ABCDE12345", "--file", "k.p8", "--kind", "asc-api-key", "--role", "admin,FINANCE"])
    #expect(api.role == "admin,FINANCE")
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["X", "--file", "k.p8", "--kind", "asc-api-key", "--role", "BOSS"]) }
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["X", "--file", "k.p8", "--kind", "asc-api-key", "--role", ""]) }
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["X", "--file", "k.p8", "--kind", "password", "--role", "ADMIN"]) }
    let auth = try SecretsImportCommand.parse(["XLESS_AUTH_KEY@ABCDE12345", "--file", "k.p8", "--kind", "auth-key", "--services", "apns,siwa"])
    #expect(auth.services == "apns,siwa")
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["X", "--file", "k.p8", "--kind", "auth-key", "--services", "maps"]) }
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["X", "--file", "k.p8", "--kind", "auth-key", "--services", ""]) }
    #expect(throws: (any Error).self) { try SecretsImportCommand.parse(["ASC_KEY_P8", "--file", "k.p8", "--services", "apns"]) }
}

/// Scripted terminal answers, recording each prompt.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [String]
    private var asked: [String] = []
    init(_ answers: [String]) { left = answers }
    var prompts: [String] { lock.withLock { asked } }
    var next: @Sendable (String) -> String? {
        { [self] prompt in
            lock.withLock {
                asked.append(prompt)
                return left.isEmpty ? nil : left.removeFirst()
            }
        }
    }
}
