import Foundation
import Testing
@testable import XlessCore

private func app() throws -> (strange: Strange, app: URL) {
    let strange = try Strange(), app = strange.root.appendingPathComponent("A.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks/F.framework/Versions/A"), withIntermediateDirectories: true)
    _ = try strange.file("A.app/A")
    _ = try strange.file("A.app/Icon@2x.png")
    _ = try strange.file("A.app/Grüße 你好 👩‍👩‍👧.txt")
    _ = try strange.file("A.app/Frameworks/F.framework/Versions/A/F")
    _ = try strange.link("A.app/Frameworks/F.framework/Versions/Current", to: "A")
    _ = try strange.link("A.app/Frameworks/F.framework/F", to: "Versions/Current/F")
    _ = try strange.link("A.app/Frameworks/F.framework/up", to: "../../A")
    _ = try strange.link("A.app/nowhere", to: "gone")
    _ = try strange.link("A.app/Frameworks/F.framework/Headers", to: "Versions/Current/Headers") // stripped
    _ = try strange.link("A.app/Frameworks/F.framework/back", to: "Versions/gone/../../F")
    return (strange, app)
}

@Test func aBundleOfFilesDirectoriesAndItsOwnLinksIsTaken() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    try BuiltTree.check(app, stage: .sign)
    // Where it is reached through a link, as /tmp is on a Mac.
    let place = try strange.link("place", to: strange.root.path)
    try BuiltTree.check(place.appendingPathComponent("A.app"), stage: .sign)
}

@Test(arguments: [("pipe", "neither a file"), ("absolute", "leads out"), ("out", "leads out"), ("lexical", "leads out"), ("through", "leads out"), ("loop", "leads out"),
                  ("absent", "leads out"), ("absentLater", "leads out"), ("absentAbsolute", "leads out"), ("mark", "leads out"), ("markUp", "leads out"), ("long", "leads out"),
                  ("newline", "control character"), ("escape", "control character"), ("deep", "nested deeper"), ("notDirectory", "is not a directory"), ("linked", "is not a directory")])
func whatABuildMayNotLeaveInABundleIsRefused(_ what: String, _ why: String) throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let fm = FileManager.default
    var root = app
    switch what {
    case "pipe": _ = try strange.pipe("A.app/Frameworks/pipe")
    case "absolute": _ = try strange.link("A.app/l", to: app.appendingPathComponent("A").path)
    case "out": _ = try strange.file("secret"); _ = try strange.link("A.app/Frameworks/l", to: "../../secret")
    case "lexical": _ = try strange.link("A.app/l", to: "../A.app/A") // in this place only
    case "through": // every one of them stays in the bundle by its text
        try fm.createDirectory(at: app.appendingPathComponent("x/y"), withIntermediateDirectories: true)
        _ = try strange.file("secret")
        _ = try strange.link("A.app/x/y/top", to: "../..")
        _ = try strange.link("A.app/x/y/l", to: "top/../secret")
    case "absent": // what is not there yet is beside the bundle, by way of a link that stays
        _ = try strange.link("A.app/d", to: ".")
        _ = try strange.link("A.app/l", to: "d/../name")
    case "absentLater": _ = try strange.link("A.app/l", to: "gone/../../name")
    case "absentAbsolute":
        _ = try strange.link("A.app/x", to: "Frameworks/F.framework/Versions/Current/up")
        _ = try strange.link("A.app/Frameworks/F.framework/Versions/A/up", to: "../../../..")
        _ = try strange.link("A.app/l", to: "x/../name")
    case "mark": _ = try strange.link("A.app/l", to: "/\u{301}abs") // a / that is another Character
    case "markUp": _ = try strange.link("A.app/l", to: "../\u{301}x")
    case "long": // each of them leads to the next, none of them out
        for n in 0 ..< 100 { _ = try strange.link("A.app/l\(n)", to: "l\(n + 1)") }
        _ = try strange.file("A.app/l100")
    case "loop": _ = try strange.link("A.app/l", to: "m"); _ = try strange.link("A.app/m", to: "l")
    case "newline": _ = try strange.file("A.app/a\n..b")
    case "escape": _ = try strange.file("A.app/a\u{1B}[2J")
    case "deep":
        var path = app.path
        for _ in 0 ..< BuiltTree.maxDepth + 1 { path += "/d"; try #require(mkdir(path, 0o755) == 0) }
    case "notDirectory": root = app.appendingPathComponent("A")
    default: root = try strange.link("B.app", to: "A.app")
    }
    #expect {
        try BuiltTree.check(root, stage: .sign)
    } throws: { error in
        let text = "\(error)"
        return text.hasPrefix("[sign] ") && text.contains(why) && !text.contains("\n") && !text.contains("\u{1B}")
    }
}

@Test func aStageTakesOnlySuchABundleFromTheOneBefore() throws {
    let strange = try Strange()
    defer { strange.remove() }
    let paths = StagePaths(project: strange.root, platform: .ios)
    try FileManager.default.createDirectory(at: paths.final.appendingPathComponent("A.app"), withIntermediateDirectories: true)
    _ = try paths.bundle(in: paths.final, stage: .sign)
    try #require(mkfifo(paths.final.appendingPathComponent("A.app/pipe").path, 0o600) == 0)
    #expect(throws: XlessError.self) { try paths.bundle(in: paths.final, stage: .sign) }
}

@Test func theAppOfAStageIsADirectoryThere() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-stage-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let paths = StagePaths(project: root, platform: .ios), other = root.appendingPathComponent("other/A.app")
    for directory in [other, paths.app.appendingPathComponent("A.app"), paths.root] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    #expect(try paths.bundle(in: paths.app, stage: .assets).lastPathComponent == "A.app")
    try fm.createSymbolicLink(at: paths.final, withDestinationURL: root.appendingPathComponent("other"))
    #expect(throws: XlessError.self) { try paths.bundle(in: paths.final, stage: .sign) }
    try fm.createDirectory(at: paths.assets, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: paths.assets.appendingPathComponent("A.app"), withDestinationURL: other)
    #expect(throws: XlessError.self) { try paths.bundle(in: paths.assets, stage: .finalize) }
}

@Test func aTreeIsCopiedAsItIs() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let fm = FileManager.default, copy = strange.root.appendingPathComponent("B.app"), date = Date(timeIntervalSince1970: 1_000_000_000)
    let run = app.appendingPathComponent("run"), bytes = Data((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try bytes.write(to: run)
    for (path, mode) in [(run, 0o755), (app.appendingPathComponent("A"), 0o640), (app.appendingPathComponent("Frameworks"), 0o750)] {
        try fm.setAttributes([.posixPermissions: mode, .modificationDate: date], ofItemAtPath: path.path)
    }
    let link = app.appendingPathComponent("nowhere"), then = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000_000, tv_nsec: 0)]
    try #require(utimensat(AT_FDCWD, link.path, then, AT_SYMLINK_NOFOLLOW) == 0)
    try BuiltTree.copy(app, to: copy, stage: .sign)
    #expect(try fm.attributesOfItem(atPath: copy.appendingPathComponent("nowhere").path)[.modificationDate] as? Date == date)
    #expect(try fm.subpathsOfDirectory(atPath: copy.path).sorted() == fm.subpathsOfDirectory(atPath: app.path).sorted())
    #expect(try Data(contentsOf: copy.appendingPathComponent("run")) == bytes)
    for (path, mode) in [("run", 0o755), ("A", 0o640), ("Frameworks", 0o750)] {
        let attributes = try fm.attributesOfItem(atPath: copy.appendingPathComponent(path).path)
        #expect(attributes[.posixPermissions] as? Int == mode && attributes[.modificationDate] as? Date == date, "\(path)")
    }
    #expect(try fm.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("nowhere").path) == "gone")
    try BuiltTree.check(copy, stage: .sign)
    #expect(throws: XlessError.self) { try BuiltTree.copy(app, to: copy, stage: .sign) } // nothing is written over
}

@Test func whatIsNoPlainTreeIsNotCopied() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let to = strange.root.appendingPathComponent("B.app")
    #expect(throws: XlessError.self) { try BuiltTree.copy(strange.link("L.app", to: "A.app"), to: to, stage: .sign) }
    #expect(throws: XlessError.self) { try BuiltTree.copy(strange.root.appendingPathComponent("none"), to: to, stage: .sign) }
    _ = try strange.pipe("A.app/pipe")
    #expect { try BuiltTree.copy(app, to: to, stage: .sign) } throws: { "\($0)".contains("pipe in A.app: it is neither") }
}

/// What was a file or a directory when it was looked at is a link to the user's own, or a pipe, when it is opened.
@Test(arguments: [("A", "own/key"), ("Frameworks/F.framework/Versions/A", "own"), ("A", nil)])
func whatComesBetweenLookingAndOpeningIsNotCopied(_ path: String, _ target: String?) throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    try FileManager.default.createDirectory(at: strange.root.appendingPathComponent("own"), withIntermediateDirectories: true)
    for name in ["F", "key"] { _ = try strange.file("own/\(name)", "secret") }
    let to = strange.root.appendingPathComponent("copy"), place = app.appendingPathComponent(path)
    var came = false
    #expect(throws: XlessError.self) {
        try BuiltTree.copy(app, to: to, stage: .sign) { looked in
            guard looked == path else { return }
            came = rename(place.path, strange.root.appendingPathComponent("aside").path) == 0
                && (target.map { symlink(strange.root.appendingPathComponent($0).path, place.path) } ?? mkfifo(place.path, 0o600)) == 0
        }
    }
    #expect(came)
    for case let file as URL in FileManager.default.enumerator(at: to, includingPropertiesForKeys: nil)! where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        #expect(try String(contentsOf: file, encoding: .utf8) != "secret", "\(file.path)")
    }
}

@Test func theHolesOfAFileAreNotWrittenOut() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let sparse = app.appendingPathComponent("sparse"), fd = open(sparse.path, O_WRONLY | O_CREAT, 0o600), size = off_t(64 << 20), bytes = Array("end".utf8)
    defer { close(fd) }
    try #require(fd >= 0 && pwrite(fd, bytes, 3, size) == 3 && ftruncate(fd, 2 * size + 1) == 0)
    let to = strange.root.appendingPathComponent("copy")
    try BuiltTree.copy(app, to: to, stage: .sign)
    var info = stat()
    #expect(lstat(to.appendingPathComponent("sparse").path, &info) == 0 && info.st_size == 2 * size + 1 && info.st_blocks * 512 < size)
    let copy = try FileHandle(forReadingFrom: to.appendingPathComponent("sparse"))
    defer { try? copy.close() }
    try copy.seek(toOffset: UInt64(size) - 1)
    #expect(try copy.read(upToCount: 5) == Data([0] + bytes + [0]))
}

#if canImport(Darwin)
@Test func aFileThatMayNotBeChangedIsOneOfXlesssInTheCopy() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let locked = app.appendingPathComponent("A"), to = strange.root.appendingPathComponent("copy")
    try #require(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { for file in [locked, to.appendingPathComponent("A")] { chflags(file.path, 0) } }
    try BuiltTree.copy(app, to: to, stage: .sign)
    try BuiltTree.write(Data("new".utf8), at: "A", in: to, stage: .sign)
    try FileManager.default.removeItem(at: to)
}
#endif

/// A process that the build left makes a directory a link to the user's own again and again.
@Test func nothingOfTheUsersOwnIsCopiedThroughALinkThatComesBetween() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    let fm = FileManager.default, own = strange.root.appendingPathComponent("own")
    try fm.createDirectory(at: own, withIntermediateDirectories: true)
    for name in ["F", "key"] { _ = try strange.file("own/\(name)", "secret") }
    let place = app.appendingPathComponent("Frameworks/F.framework/Versions/A").path, aside = strange.root.appendingPathComponent("aside").path
    let swap = Thread {
        while !Thread.current.isCancelled {
            rename(place, aside)
            symlink(own.path, place)
            unlink(place)
            rename(aside, place)
        }
    }
    swap.start()
    defer { swap.cancel(); while !swap.isFinished { usleep(1000) } }
    for n in 0 ..< 400 {
        let to = strange.root.appendingPathComponent("copy\(n)")
        try? BuiltTree.copy(app, to: to, stage: .sign)
        for case let file as URL in fm.enumerator(at: to, includingPropertiesForKeys: nil)! where (try? fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular {
            #expect(try String(contentsOf: file, encoding: .utf8) != "secret")
        }
        try fm.removeItem(at: to)
    }
}

@Test func aFileIsWrittenIntoATreeAndThroughNoLink() throws {
    let (strange, app) = try app()
    defer { strange.remove() }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    let data = Data("new".utf8), own = try strange.file("own", "mine")
    for target in [own.path, "A", "gone"] {
        _ = try? FileManager.default.removeItem(at: app.appendingPathComponent("l"))
        _ = try strange.link("A.app/l", to: target)
        try BuiltTree.write(data, at: "l", in: app, stage: .sign)
        #expect(try text(app.appendingPathComponent("l")) == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("l").path)) == nil)
    }
    #expect(try text(own) == "mine" && text(app.appendingPathComponent("A")) == "x" && !FileManager.default.fileExists(atPath: app.appendingPathComponent("gone").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o764], ofItemAtPath: app.appendingPathComponent("A").path)
    try BuiltTree.write(data, at: "A", in: app, stage: .sign) // a file's mode is kept
    #expect(try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("A").path)[.posixPermissions] as? Int == 0o764)
    try BuiltTree.write(data, at: "Contents/deep/file", in: app, stage: .sign)
    #expect(try text(app.appendingPathComponent("Contents/deep/file")) == "new")
    _ = try strange.link("A.app/dir", to: "Frameworks")
    for path in ["dir/file", "Frameworks", "A/file", ""] { #expect(throws: XlessError.self, "\(path)") { try BuiltTree.write(data, at: path, in: app, stage: .sign) } }
    #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/file").path))
}
