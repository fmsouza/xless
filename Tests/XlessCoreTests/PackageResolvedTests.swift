import Foundation
import Testing
@testable import XlessCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test func aPackageResolvedThatIsThereIsTakenOrRefused() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-resolved-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let project = root.appendingPathComponent("p"), wrapper = root.appendingPathComponent("w")
    for directory in [project, wrapper] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    let file = project.appendingPathComponent("Package.resolved"), copied = wrapper.appendingPathComponent("Package.resolved")
    let text = #"{"pins":[{"identity":"dep","state":{"revision":"r","version":"1.0.0"}}],"version":3}"#
    func copy() throws -> Bool { try PackageResolved.copy(from: project, to: wrapper) }

    #expect(try !copy() && !fm.fileExists(atPath: copied.path))
    #expect(try !PackageResolved.copy(from: project.appendingPathComponent("none"), to: wrapper))
    for good in [text, #"{"object":{"pins":[]},"version":1}"#] {
        try Data(good.utf8).write(to: file)
        #expect(try copy() && String(contentsOf: copied, encoding: .utf8) == good)
    }
    try fm.removeItem(at: file)
    try Data(text.utf8).write(to: root.appendingPathComponent("above"))
    try fm.createSymbolicLink(atPath: file.path, withDestinationPath: "../above")
    #expect(try copy() && String(contentsOf: copied, encoding: .utf8) == text)
    try fm.removeItem(at: copied)

    func refused(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let error = #expect(throws: XlessError.self, sourceLocation: sourceLocation) { try copy() }
        #expect(error?.stage == .build && error?.cause.contains(what) == true, "\(error?.cause ?? "-")", sourceLocation: sourceLocation)
        #expect(!fm.fileExists(atPath: copied.path), sourceLocation: sourceLocation)
        try? fm.removeItem(at: file)
    }
    try fm.removeItem(at: root.appendingPathComponent("above"))
    refused("a link to a file that is not there")
    try fm.createDirectory(at: file, withIntermediateDirectories: false)
    refused("it is not a file")
    #expect(mkfifo(file.path, 0o600) == 0)
    refused("it is not a file")
    try fm.createSymbolicLink(atPath: file.path, withDestinationPath: "/dev/zero")
    refused("it is not a file")
    for bad in ["", "{", "{}", "[]", "a secret", #"{"pins":{}}"#] {
        try Data(bad.utf8).write(to: file)
        refused("it has no pins")
    }
    try Data((text + String(repeating: " ", count: PackageResolved.limit)).utf8).write(to: file)
    refused("it is larger than 16 MB")
}

@Test func anOlderPackageResolvedNamesItsPackagesByURL() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-resolved-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let project = root.appendingPathComponent("p"), wrapper = root.appendingPathComponent("w")
    for directory in [project, wrapper] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    try Data(#"{"object":{"pins":[{"package":"Dep","repositoryURL":"https://example.com/x/Dep.git","state":{"branch":null,"revision":"r","version":"1.0.0"}}]},"version":1}"#.utf8)
        .write(to: project.appendingPathComponent("Package.resolved"))
    func note(_ version: String) throws -> String? {
        try Data(#"{"pins":[{"identity":"dep","state":{"revision":"r","version":"\#(version)"}}],"version":3}"#.utf8).write(to: wrapper.appendingPathComponent("Package.resolved"))
        return PackageResolved.unpinnedNote(project: project, wrapper: wrapper)
    }
    #expect(try note("1.0.0") == nil)
    #expect(try note("1.1.0")?.hasPrefix("Package.resolved does not name these, which were built: dep 1.1.0") == true)
}
