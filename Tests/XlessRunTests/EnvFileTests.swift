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

/// A problem is said with the line and the variable being set, and nothing of what follows the `=`: it may be a password.
@Test(arguments: ["\"hunter$SecretTail9\"", "Pa$SecretTail", "Pa$5SecretTail", "\"Pa$5SecretTail\"", "x${SecretTail", "x${SecretTail}", "\"x${SecretTail-y}\"", "x$(SecretTail)", "x`SecretTail`",
                  "'SecretTail", "\"SecretTail", "SecretTail more", "a;SecretTail", "SecretTail&", "~SecretTail", "x:~SecretTail", "$'SecretTail'", "$\"SecretTail\"", "$$SecretTail", "\"$@SecretTail\"", "$[SecretTail]"])
func aProblemNeverSaysAnyPartOfAValue(value: String) throws {
    for prefix in ["", "export "] {
        let p = try #require(problem("A=1\n\(prefix)MY_PASSWORD=\(value)\n"), "\(value)")
        #expect(p.line == 2 && p.what.contains("MY_PASSWORD") != p.what.contains("quote that is not closed"))
        for part in ["Secret", "Tail", "hunter", "Pa", "5", ";", "&", "more"] { #expect(!p.what.contains(part), "\(value): \(p.what)") }
    }
    // a wrapped key's line looks like a name: it is not said either
    #expect(problem("KEY=MIGTAgEA\nBG1SecretTail=$x\n")?.what.contains("Secret") == false)
}

/// What a shell does more than this with, is refused: never read as something else.
@Test func whatAShellReadsInAnotherWayIsRefused() throws {
    for text in ["A=$'a\\tb'", "A=$\"a\"", "A=$$", "A=$?", "A=$@", "A=$*", "A=$#", "A=$!", "A=$-", "A=$1", "A=\"$$\"", "A=\"$?\"", "A=\"$1\"", "A=$[1]", "A=~user/x", "A=~+", "A=~-/x", "A=x:~/y", "A=~:/x", "A=~/x:~"] {
        #expect(problem(text)?.line == 1, "\(text)")
    }
    // and these stand for themselves in one, too
    #expect(try read("A=\"a$\"\nB=a$\nC=\"$'x'\"\nD=a$/b$.c\nE='$$ $? ~x :~'\nF=\"~/x:~/y\"\nG=x~/y\nH=\\~/x\nI=a:\\~b\nJ=a\\$1\nK=~\nL=a$=b")
            == ["A": "a$", "B": "a$", "C": "$'x'", "D": "a$/b$.c", "E": "$$ $? ~x :~", "F": "~/x:~/y", "G": "x~/y", "H": "~/x", "I": "a:~b", "J": "a$1", "K": "/home/u", "L": "a$=b"])
}

@Test func theLastAssignmentWinsAndEarlierOnesCanBeUsed() throws {
    #expect(try read("D=/k\nA=$D/a\nA=$A.b") == ["D": "/k", "A": "/k/a.b"])
    #expect(try read("P=a$", [:]) == ["P": "a$"])
}
