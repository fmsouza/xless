import Foundation
import Testing
@testable import XlessRun

private func read(_ text: String, _ environment: [String: String] = ["HOME": "/home/u"]) throws -> [String: String] {
    Dictionary(try EnvFile.parse(text, environment: environment).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
}

private func problem(_ text: String) -> EnvFile.Problem? {
    do { _ = try EnvFile.parse(text, environment: ["HOME": "/home/u"]); return nil } catch { return error as? EnvFile.Problem }
}

@Test func theDocumentedFileIsReadAsAShellReadsIt() throws {
    let e = try read("""
    # ~/.config/xless/testflight.env
    ASC_KEY_ID=ABC123DEFG                          # the API key's ID

    ASC_ISSUER_ID_FILE=$HOME/keys/asc-issuer-id    # file holding the issuer ID
      export ASC_KEY_P8_FILE="${HOME}/my keys/AuthKey_$ASC_KEY_ID.p8"
    XLESS_DIST_KEY_FILE=~/keys/dist-key.pem
    XLESS_IMAGE='img:$1 #2'
    XLESS_SOURCE=/a\\ b
    EMPTY=
    HASH=a#b
    """)
    #expect(e == ["ASC_KEY_ID": "ABC123DEFG", "ASC_ISSUER_ID_FILE": "/home/u/keys/asc-issuer-id", "ASC_KEY_P8_FILE": "/home/u/my keys/AuthKey_ABC123DEFG.p8",
                  "XLESS_DIST_KEY_FILE": "/home/u/keys/dist-key.pem", "XLESS_IMAGE": "img:$1 #2", "XLESS_SOURCE": "/a b", "EMPTY": "", "HASH": "a#b"])
}

@Test func aQuotedValueMayHaveLinesOfItsOwn() throws {
    #expect(try read("A=\"one\ntwo \\\"x\\\" \\$H\"\r\nB='x\ny'\r\n") == ["A": "one\ntwo \"x\" $H", "B": "x\ny"])
    #expect(try read("A=\"it's\"'\"'x") == ["A": "it's\"x"])
}

/// The old script ran the file with bash; nothing in it is run any more, and a line that would be is named.
@Test func whatWouldRunSomethingIsRefusedWithItsLine() {
    for (text, line) in [("A=$(touch /tmp/x)", 1), ("\nA=`id`", 2), ("A=\"$(id)\"", 1), ("A=\"`id`\"", 1), ("touch /tmp/x", 1), ("A=1; touch x", 1), ("A=1\nB=2 touch x", 2),
                         ("A=1 | cat", 1), ("A=x>y", 1), ("A=(1 2)", 1), ("A=${HOME:-x}", 1), (". other.env", 1), ("if true; then", 1), ("A=$NOPE", 1), ("A='x", 1), ("A=\"x", 1),
                         ("set -a", 1), ("export A", 1), ("A =1", 1)] {
        #expect(problem(text)?.line == line, "\(text)")
    }
    // and never with a value, which may be a secret
    #expect(problem("A=hunter2; x")?.what.contains("hunter2") == false)
}

@Test func theLastAssignmentWinsAndEarlierOnesCanBeUsed() throws {
    #expect(try read("D=/k\nA=$D/a\nA=$A.b") == ["D": "/k", "A": "/k/a.b"])
    #expect(try read("P=a$", [:]) == ["P": "a$"])
}
