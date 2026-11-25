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
