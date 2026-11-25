import Foundation
import Testing
@testable import XlessCore

/// A directory with what a build may leave in place of a file.
struct Strange {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-strange-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func pipe(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try #require(mkfifo(url.path, 0o600) == 0)
        return url
    }
    func link(_ name: String, to path: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: path)
        return url
    }
    func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    /// With nothing in it, of any size.
    func large(_ name: String, _ size: UInt64) throws -> URL {
        let url = try file(name), handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }
}

@Test func onlyAPlainFileIsRead() throws {
    let strange = try Strange()
    defer { strange.remove() }
    let file = try strange.file("file", "text")
    #expect(try PlainFile.read(file) == Data("text".utf8))
    func reading(_ url: URL, maxSize: Int = PlainFile.maxSize, followsLinks: Bool = false) -> PlainFile.Unread? {
        do { _ = try PlainFile.read(url, maxSize: maxSize, followsLinks: followsLinks); return nil } catch { return error }
    }
    #expect(reading(strange.root.appendingPathComponent("none")) == .absent)
    #expect(reading(try strange.pipe("pipe")) == .notFile) // and does not wait for who writes it
    #expect(reading(URL(fileURLWithPath: "/dev/zero")) == .notFile)
    #expect(reading(strange.root) == .notFile)
    #expect(reading(try strange.large("large", 1 << 40)) == .tooLarge)
    #expect(reading(file, maxSize: 3) == .tooLarge)
    #expect(reading(file, maxSize: 4) == nil)
    let link = try strange.link("link", to: file.path)
    #expect(reading(link) == .link)
    #expect(reading(link, followsLinks: true) == nil)
    #expect(reading(try strange.link("zero", to: "/dev/zero"), followsLinks: true) == .notFile)
}

@Test func aPropertyListIsAPlainFile() throws {
    let strange = try Strange()
    defer { strange.remove() }
    let file = strange.root.appendingPathComponent("Info.plist")
    try Plist.write(["A": "b"], to: file, stage: .sign)
    #expect(try Plist.read(try strange.link("link", to: "Info.plist"), stage: .sign)["A"] as? String == "b")
    for (url, reason) in [(try strange.pipe("pipe"), "is not a file"), (URL(fileURLWithPath: "/dev/zero"), "is not a file"), (try strange.large("large", 1 << 40), "is too large")] {
        #expect { try Plist.read(url, stage: .sign) } throws: { "\($0)".contains("cannot read \(url.path): it \(reason)") }
    }
    #expect { try Plist.read(strange.root.appendingPathComponent("none"), stage: .sign) } throws: { "\($0)".contains("cannot read") }
}

@Test func theRecordOfReplacedIdentifiersIsAPlainFile() throws {
    let strange = try Strange()
    defer { strange.remove() }
    #expect(try IdentifierReplacement.recorded(in: strange.root) == .none)
    let name = IdentifierReplacement.recordName
    let elsewhere = try strange.file("elsewhere", #"{"replace":{"com.a":"com.b"}}"#)
    let url = try strange.link(name, to: elsewhere.path)
    #expect(throws: XlessError.self) { try IdentifierReplacement.recorded(in: strange.root) }
    try FileManager.default.removeItem(at: url)
    _ = try strange.pipe(name)
    #expect(throws: XlessError.self) { try IdentifierReplacement.recorded(in: strange.root) }
}
