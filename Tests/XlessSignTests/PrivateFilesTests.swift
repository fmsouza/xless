import Foundation
import Testing
import XlessCore
@testable import XlessSign

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func mode(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

private func entries(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path) }

@Test func privateFilesArePrivateAndGoAwayWithTheCall() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let key = try SigningKey.generate()
    let der = Data(try selfSigned(key))
    let seen = try PrivateFiles.with(stage: .sign, in: root) { files -> URL in
        let signer = try files.signer(key: key, certificate: der)
        #expect(try mode(files.directory) == 0o700)
        for file in [signer.key, signer.certificate] {
            #expect(file.deletingLastPathComponent().path == files.directory.path)
            #expect(try mode(file) == 0o600)
        }
        #expect(try String(contentsOf: signer.key, encoding: .utf8) == key.pem)
        let lines = try String(contentsOf: signer.certificate, encoding: .utf8).split(separator: "\n")
        #expect(lines.first == "-----BEGIN CERTIFICATE-----" && lines.last == "-----END CERTIFICATE-----")
        #expect(Data(base64Encoded: lines.dropFirst().dropLast().joined()) == der)
        #expect(lines.allSatisfy { $0.count <= 64 })
        return files.directory
    }
    #expect(!FileManager.default.fileExists(atPath: seen.path))
    #expect(try entries(root).isEmpty)
}

/// The directory is never readable by others, not even between making it and setting its mode: another thread looks while it
/// is made, again and again. (With a umask of 077 there is nothing to see.)
@Test func thePrivateDirectoryIsNeverOpenToOthers() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let look = Looking(root)
    let thread = Thread { look.run() }
    thread.start()
    for _ in 0..<400 { try PrivateFiles.with(stage: .sign, in: root) { _ in } }
    #expect(look.stop() == [])
}

/// Looks at the modes of what is in a directory, from a thread of its own, until told to stop.
private final class Looking: @unchecked Sendable {
    private let root: String, lock = NSLock(), done = DispatchSemaphore(value: 0)
    private var seen: Set<mode_t> = [], stopped = false
    init(_ root: URL) { self.root = root.path }

    func run() {
        while !lock.withLock({ stopped }) {
            guard let dir = opendir(root) else { continue }
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                var info = stat()
                guard name.hasPrefix("xless-keys-"), lstat("\(root)/\(name)", &info) == 0, info.st_mode & 0o7777 != 0o700 else { continue }
                _ = lock.withLock { seen.insert(info.st_mode & 0o7777) }
            }
            closedir(dir)
        }
        done.signal()
    }

    /// The modes seen that are not 0700.
    func stop() -> [String] {
        lock.withLock { stopped = true }
        done.wait()
        return lock.withLock { seen.map { String($0, radix: 8) }.sorted() }
    }
}

@Test func privateFilesHoldAPlistTheSameWay() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    try PrivateFiles.with(stage: .sign, in: root) { files in
        let url = try files.write(plist: ["get-task-allow": false], as: "ent.plist")
        #expect(try mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("<key>get-task-allow</key>"))
        #expect(throws: XlessError.self) { try files.write(plist: [:], as: "ent.plist") }
    }
}

@Test func privateFilesGoAwayWhenTheCallThrows() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    struct Stop: Error {}
    #expect(throws: Stop.self) {
        try PrivateFiles.with(stage: .package, in: root) { files in
            _ = try files.signer(key: try SigningKey.generate(), certificate: Data([1]))
            throw Stop()
        }
    }
    #expect(try entries(root).isEmpty)
}

@Test func privateFilesNeverWriteOverAFileAndSayNothingOfTheContents() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    try PrivateFiles.with(stage: .package, in: root) { files in
        let outside = root.appendingPathComponent("outside")
        try Data("mine".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: files.directory.appendingPathComponent("key.p8"), withDestinationURL: outside)
        do {
            _ = try files.write(Data("very-secret".utf8), as: "key.p8")
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.stage == .package && e.cause.hasPrefix("cannot write temporary key files"))
            #expect(!e.description.contains("very-secret"))
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine")
    }
}

@Test func privateFilesNeedADirectoryTheyCanMake() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file")
    try Data().write(to: file)
    do {
        try PrivateFiles.with(stage: .sign, in: file) { _ in Issue.record("no directory") }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .sign && e.cause.hasPrefix("cannot write temporary key files"))
        #expect(e.fix == "check free space and permissions of \(file.path)")
    }
}

/// A key file is gone also when a signal ends xless meanwhile (Ctrl-C, Ctrl-\, a CI runner's cancel, output nobody reads, a
/// fault of xless's own), whether a tool ever ran or not.
@Suite struct PrivateFilesOnSignalTests {
    @Test(arguments: [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM, SIGPIPE, SIGXCPU, SIGSYS, SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE, SIGILL]) func aSignalRemovesTheFiles(signal: Int32) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: parent) }
        await #expect(processExitsWith: .signal(signal)) { [signal = signal as Int32, parent = parent as String] in
            Foundation.signal(signal, SIG_DFL)
            try PrivateFiles.with(stage: .sign, in: URL(fileURLWithPath: parent)) { files in
                _ = try files.write(Data("secret".utf8), as: "key.pem")
                _ = try PrivateFiles.with(stage: .sign, in: files.directory) { inner in
                    _ = try inner.write(Data("another".utf8), as: "cert.pem")
                    kill(getpid(), signal)
                    sleep(20)
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty)
    }

    /// Also where a handler of another's is, which comes back (Swift's backtrace, on Linux): xless ends after it all the same.
    @Test(arguments: [SIGQUIT, SIGABRT, SIGSEGV]) func aHandlerThatGoesOnDoesNotKeepTheFiles(signal: Int32) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: parent) }
        await #expect(processExitsWith: .signal(signal)) { [signal = signal as Int32, parent = parent as String] in
            Foundation.signal(signal) { _ in }
            try PrivateFiles.with(stage: .sign, in: URL(fileURLWithPath: parent)) { files in
                _ = try files.write(Data("secret".utf8), as: "key.pem")
                kill(getpid(), signal)
                sleep(20)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty)
    }

    /// However many there are (an app with many extensions has an entitlements file for each).
    @Test func aSignalRemovesAllOfManyFiles() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: parent) }
        await #expect(processExitsWith: .signal(SIGTERM)) { [parent = parent as String] in
            Foundation.signal(SIGTERM, SIG_DFL)
            try PrivateFiles.with(stage: .sign, in: URL(fileURLWithPath: parent)) { files in
                for i in 0..<200 { _ = try files.write(plist: [:], as: "ent-\(i).plist") }
                _ = try files.make("key.json")
                kill(getpid(), SIGTERM)
                sleep(20)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty)
    }

    /// What is done with is forgotten: a file of the same name that is not xless's own stays.
    @Test func onlyWhatIsThereAtTheTimeIsRemoved() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: parent) }
        await #expect(processExitsWith: .signal(SIGTERM)) { [parent = parent as String] in
            Foundation.signal(SIGTERM, SIG_DFL)
            let file = try PrivateFiles.with(stage: .sign, in: URL(fileURLWithPath: parent)) { try $0.write(Data("secret".utf8), as: "key.pem") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("other".utf8).write(to: file)
            kill(getpid(), SIGTERM)
            sleep(20)
        }
        let directory = try #require(FileManager.default.contentsOfDirectory(atPath: parent).first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(parent)/\(directory)") == ["key.pem"])
    }
}
