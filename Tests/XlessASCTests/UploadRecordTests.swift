import Foundation
import Testing
@testable import XlessASC
@testable import XlessCore

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-record-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let record = UploadRecord(buildUploadID: "U1", buildID: "B1", state: "COMPLETE", processingState: "VALID", messages: [],
                                  bundleID: "com.example.app", version: "1.1", build: "42", platform: .ios)

@Test func anUploadRecordIsReadBack() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("upload.json")
    guard case .none = UploadRecord.read(file) else { Issue.record("no file, no record"); return }
    try JSONEncoder().encode(record).write(to: file)
    guard case .found(let read) = UploadRecord.read(file) else { Issue.record("expected the record"); return }
    #expect(read == record)
}

@Test func aRecordOfAnEarlierXlessIsStillReadable() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("upload.json")
    try Data(#"{"buildUploadID":"U1","buildID":"B1","state":"COMPLETE","processingState":"VALID","messages":[]}"#.utf8).write(to: file)
    guard case .found(let read) = UploadRecord.read(file) else { Issue.record("expected the record"); return }
    #expect(read.buildID == "B1" && read.bundleID == nil && read.version == nil && read.platform == nil)
}

/// The record is only a hint, in a directory build code can write: nothing it is can stop the command or be followed.
@Test func aRecordThatIsNoPlainSmallJSONFileIsIgnored() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let good = root.appendingPathComponent("good.json")
    try JSONEncoder().encode(record).write(to: good)
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
    let large = root.appendingPathComponent("large.json")
    try Data(count: UploadRecord.maxSize + 1).write(to: large)
    let text = root.appendingPathComponent("text.json")
    try Data("\u{1b}[2Jnot json".utf8).write(to: text)
    let directory = root.appendingPathComponent("dir.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fifo = root.appendingPathComponent("fifo.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    for (file, why) in [(link, "is a link"), (large, "is too large"), (text, "cannot be read"), (directory, "is not a file"), (fifo, "is not a file")] {
        guard case .ignored(let reason) = UploadRecord.read(file) else { Issue.record("\(file.lastPathComponent) was taken"); continue }
        #expect(reason == "the record of the last upload, \(file.path), \(why): ignored")
    }
}

@Test func theNextCommandNamesTheAppTheVersionAndTheBuild() {
    #expect(record.submitCommand == "xless release submit --app com.example.app --platform ios --app-version 1.1 --build B1")
    var mac = record
    mac.platform = .macos
    #expect(mac.submitCommand == "xless release submit --app com.example.app --platform macos --app-version 1.1 --build B1")
    var processing = record
    processing.processingState = "PROCESSING"
    #expect(processing.submitCommand == nil)
    // Nothing that a shell or a terminal would read as more than a word.
    for odd in ["1.1; rm -rf ~", "$(id)", "\u{1b}[2J", ""] {
        var r = record
        r.version = odd
        #expect(r.submitCommand == nil)
        r = record
        r.bundleID = odd
        #expect(r.submitCommand == nil)
    }
}
