import Foundation
import Testing
@testable import XlessRun

/// The checks that keep secrets out of what a build container mounts, against other spellings of a path.
@Suite struct RunFilesTests {
    let host = PosixRunHost()

    private func inDirectory(_ body: (String) throws -> Void) throws {
        let root = host.realPath(FileManager.default.temporaryDirectory.path)! + "/xless-files-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { host.removeTree(root) }
        try body(root)
    }

    private func make(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: RunFiles.parent(path), withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: path))
    }

    @Test func aSymbolicLinkHidesNothing() throws {
        try inDirectory { root in
            let files = RunFiles(host: host, home: root + "/home")
            try make(root + "/app/keys/key.p8")
            try FileManager.default.createDirectory(atPath: root + "/home", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/app/keys")
            try FileManager.default.createSymbolicLink(atPath: root + "/key", withDestinationPath: "link/key.p8")
            #expect(try files.file(root + "/key", isIn: root + "/app"))
            #expect(try files.file(root + "/app/keys/key.p8", isIn: root + "/link"))
            #expect(try !files.file(root + "/key", isIn: root + "/home"))
        }
    }

    /// Where the file system takes two spellings for one name (macOS's do, Linux's do not), they are one name here too.
    @Test func anotherCaseOrCompositionHidesNothing() throws {
        try inDirectory { root in
            try make(root + "/Caf\u{e9}/Sub/key.p8")
            for other in ["/CAF\u{c9}", "/cafe\u{301}", "/Cafe\u{301}", "/caf\u{e9}"] {
                let there = FileManager.default.fileExists(atPath: root + other)
                let files = RunFiles(host: host, home: root + other + "/sub")
                #if os(macOS)
                #expect(there == (host.isSame(root, root.uppercased()) == true || other == "/Cafe\u{301}"), "\(other)")
                #endif
                guard there else { // another name: what is not there cannot be told
                    #expect(throws: RunStop.self, "\(other)") { try files.file(root + "/Caf\u{e9}/Sub/key.p8", isIn: root + other) }
                    #expect(throws: RunStop.self, "\(other)") { try files.isBroad(root) }
                    continue
                }
                #expect(try files.file(root + "/Caf\u{e9}/Sub/key.p8", isIn: root + other), "\(other)")
                #expect(try files.file(root + other + "/Sub/key.p8", isIn: root + "/Caf\u{e9}"), "\(other)")
                #expect(try files.directory(root + "/Caf\u{e9}/Sub", isIn: root + other), "\(other)")
                #expect(try files.isBroad(root + "/Caf\u{e9}"), "\(other)")
            }
        }
    }

    /// A place that cannot be told is never taken for another one.
    @Test func whatCannotBeToldThrows() throws {
        try inDirectory { root in
            try make(root + "/app/key.p8")
            let files = RunFiles(host: host, home: root)
            for none in [root + "/none", root + "/app/none"] {
                #expect(throws: RunStop.self) { try files.directory(none, isIn: root) }
                #expect(throws: RunStop.self) { try files.directory(root, isIn: none) }
                #expect(throws: RunStop.self) { try files.file(none, isIn: root) }
                #expect(throws: RunStop.self) { try files.file(root + "/app/key.p8", isOrIsIn: none) }
                #expect(throws: RunStop.self) { try files.isBroad(none) }
            }
            // a system that does not say what a file system calls a directory
            let fake = FakeRunHost()
            fake.physical = { $0.hasSuffix("/app") ? nil : $0 }
            let blind = RunFiles(host: fake, home: root)
            #expect(throws: RunStop.self) { try blind.file(root + "/app/key.p8", isIn: "/usr") }
            #expect(throws: RunStop.self) { try blind.directory(root + "/app", isIn: "/usr") }
        }
    }

    /// One that may be searched but not read is there all the same.
    @Test func aDirectoryThatIsNotReadableIsKnown() throws {
        try inDirectory { root in
            try make(root + "/app/key.p8")
            defer { chmod(root + "/app", 0o755) }
            chmod(root + "/app", 0o111)
            let files = RunFiles(host: host, home: root + "/app")
            #expect(try files.file(root + "/app/key.p8", isIn: root + "/app") && files.isBroad(root) && !files.directory(root, isIn: root + "/app"))
        }
    }

    #if os(macOS)
    /// /Users is a folder of the data volume, which is mounted elsewhere too.
    @Test func aFolderMacOSShowsInTwoPlacesIsOne() throws {
        let files = RunFiles(host: host, home: "/Users/Shared")
        try #require(host.isSame("/Users", "/System/Volumes/Data/Users"))
        for above in ["/", "/Users", "/Users/Shared", "/System/Volumes/Data", "/System/Volumes/Data/Users", "/System/Volumes", "/System",
                      "/System/Volumes/Data/Users/Shared"] {
            #expect(try files.isBroad(above), "\(above)")
        }
        #expect(try files.directory("/System/Volumes/Data/Users/Shared", isIn: "/Users"))
        for beside in ["/Library", "/usr", "/System/Volumes/Preboot", "/System/Library"] { #expect(try !files.isBroad(beside), "\(beside)") }
        try inDirectory { root in
            try make(root + "/app/key.p8")
            #expect(try files.file(root + "/app/key.p8", isIn: "/System/Volumes/Data"))
            #expect(try files.file("/System/Volumes/Data" + root + "/app/key.p8", isIn: root + "/app"))
        }
    }
    #endif
}
