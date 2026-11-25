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
