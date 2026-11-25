import Foundation
import Testing
@testable import XlessRun

@Test func theTopLevelValuesAreReadAsYAML() throws {
    let t = try RunTop(yaml: "type: \"react-native\"    # quoted, with a comment\nsource: '~/a b'\nbuild: 42   # fixed\nxcode: 26.2\nteamID: ABCDE12345\nnested:\n  type: no\nempty:\nnone: ~\n\"quoted\": yes\n")
    #expect(t["type"] == "react-native" && t["source"] == "~/a b" && t["build"] == "42" && t["xcode"] == "26.2" && t["teamID"] == "ABCDE12345" && t["quoted"] == "yes")
    #expect(t["nested"] == nil && t["empty"] == nil && t["none"] == nil)
    #expect(try RunTop(yaml: "")["type"] == nil)
    #expect(throws: (any Error).self) { try RunTop(yaml: "a: [") }
}

@Test func xcodeVersionsAreSpelledAsImageTagsAre() {
    for (version, tag) in [("26.2.0", "26.2"), ("26", "26.0"), ("26.0.0", "26.0"), ("26.0.1", "26.0.1"), ("27.10", "27.10")] { #expect(RunText.xcodeTag(version) == tag) }
    for bad in ["latest", "", "26.", "26.1.2.3", "26a"] { #expect(RunText.xcodeTag(bad) == nil) }
}

@Test func aMountIsOneWordWhateverThePath() {
    #expect(RunText.bind("/a b", "/source", readOnly: true) == "type=bind,src=/a b,dst=/source,readonly")
    #expect(RunText.bind("/a,b/\"c\"", "/x") == "type=bind,\"src=/a,b/\"\"c\"\"\",dst=/x")
    #expect(RunText.commandLine(["docker", "type=bind,\"src=/a,b\"", "it's"]) == "docker 'type=bind,\"src=/a,b\"' 'it'\\''s' ")
}

@Test func onlyADirectoryThatMaterializeMadeIsRemovedAsOne() {
    let id = String(repeating: "0a", count: 16)
    #expect(RunText.isSecretsDirectory("/run/user/1/xless/\(id)") && RunText.isSecretsDirectory("/home/u/.cache/xless/secrets/\(id)"))
    for bad in ["/", "", "/home/u", "xless/\(id)", "/a/xless/\(id)/", "/a/../xless/\(id)", "/a/./xless/\(id)", "/a/xless/\(id)0", "/a/xless/\(id.uppercased())", "/a/xless/other/\(id)"] {
        #expect(!RunText.isSecretsDirectory(bad), "\(bad)")
    }
}

/// To Swift a "/" and a mark that combines with it (or a line break's two bytes) are one character: paths and lines are bytes.
@Test(arguments: ["\u{301}", "\u{200D}", "\u{FE0F}"]) func pathsAndLinesAreBytes(mark: String) throws {
    let files = RunFiles(host: PosixRunHost(), home: "/home/u")
    #expect(RunFiles.parent("/a/\(mark)b/c").utf8.elementsEqual("/a/\(mark)b".utf8) && RunFiles.parent("/a/\(mark)b") == "/a" && RunFiles.parent("/\(mark)b") == "/")
    #expect(RunFiles.name("/a/\(mark)b.yml").utf8.elementsEqual("\(mark)b.yml".utf8))
    #expect(RunFiles.stem("/a/b.\(mark)yml") == "b" && RunFiles.stem("/a/b/") == "b" && RunFiles.stem("/a/b") == "b")
    #expect(files.absolute("/\(mark)a/../b") == "/b" && files.absolute("\(mark)a", in: "/x").utf8.elementsEqual("/x/\(mark)a".utf8))
    #expect(files.absolute("/a/.\(mark)") .utf8.elementsEqual("/a/.\(mark)".utf8))
    #expect(files.expanded("~/\(mark)a").utf8.elementsEqual("/home/u/\(mark)a".utf8) && files.expanded("~") == "/home/u")
    #expect(RunText.lines("a\r\n\nb\n\(mark)c").map { Array($0.utf8) } == ["a\r", "b", "\(mark)c"].map { Array($0.utf8) })
    #expect(RunText.value(of: "--to=", in: "--to=\(mark)x").map { Array($0.utf8) } == Array("\(mark)x".utf8))
    let id = String(repeating: "0a", count: 16)
    #expect(RunText.isSecretsDirectory("/a/\(mark)b/xless/\(id)"))
    for bad in ["/a/../\(mark)b/xless/\(id)", "/a/xless/\(id)\(mark)", "/a/\(mark)xless/\(id)", "/a//xless/\(id)", "/xless/\(mark)/\(id)"] { #expect(!RunText.isSecretsDirectory(bad), "\(bad)") }
    #expect(RunText.bind("/a,\(mark)b\"\(mark)c", "/x").utf8.elementsEqual("type=bind,\"src=/a,\(mark)b\"\"\(mark)c\",dst=/x".utf8))
    #expect(RunText.quoted("it'\(mark)s").utf8.elementsEqual("'it'\\''\(mark)s'".utf8))
}

@Test func whereAFileIsIsToldOrRefused() throws {
    let host = PosixRunHost(), home = try RunHome()
    let files = RunFiles(host: host, home: home.home)
    for mark in ["\u{301}", "\u{200D}", "\u{FE0F}", "\u{300}\u{301}"] {
        let below = "\(home.root)/src/\(mark)keys"
        try FileManager.default.createDirectory(atPath: below, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(below)/d.pem", contents: Data())
        #expect(try files.file("\(below)/d.pem", isIn: "\(home.root)/src") && !files.file("\(below)/d.pem", isIn: home.home))
        #expect(try files.directory(below, isIn: "\(home.root)/src"))
    }
    #expect(throws: RunStop.self) { try files.file("\(home.root)/none", isIn: home.root) }
    #expect(throws: RunStop.self) { try files.directory("\(home.root)/none", isIn: home.root) }
    #expect(throws: RunStop.self) { try files.directory(home.home, isIn: "\(home.root)/none") }
    #expect(throws: RunStop.self) { try files.isBroad("\(home.root)/none") }
    #expect(throws: RunStop.self) { try files.real("\(home.root)/none") }
    #expect(host.isSame(home.home, "\(home.root)/none") == nil && host.isSame(home.home, home.home) == true && host.isSame(home.home, home.root) == false)
}
