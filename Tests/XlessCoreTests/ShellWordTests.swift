import Testing
@testable import XlessCore

@Test func shellWordsAreQuotedOnlyWhenNeeded() throws {
    #expect(ShellWord.quoted("ASC_KEY_P8@ABCDE12345") == "ASC_KEY_P8@ABCDE12345")
    #expect(ShellWord.quoted("/run/user/1000/xless-rescued-AuthKey_K.p8") == "/run/user/1000/xless-rescued-AuthKey_K.p8")
    #expect(ShellWord.quoted("ADMIN,FINANCE") == "ADMIN,FINANCE")
    #expect(ShellWord.quoted("/tmp/my key.p8") == "'/tmp/my key.p8'")
    #expect(ShellWord.quoted("it's") == "'it'\\''s'")
    #expect(ShellWord.quoted("") == "''")
    // To Swift a ' and the mark that combines with it are another Character.
    let marked = Array(#"'a'\''@; id'\'''"#.replacingOccurrences(of: "@", with: "\u{301}").utf8)
    #expect(Array(ShellWord.quoted("a'\u{301}; id'").utf8) == marked && Array(ShellWord.inQuotes("a'\u{301}; id'").utf8) == marked)
    #expect(Array("/\u{301}a/b".replacing(scalar: "/", with: "-").utf8) == Array("-\u{301}a-b".utf8) && "\u{301}/\u{301}".contains(scalar: "/") && !"a".contains(scalar: "/"))
    #expect(ShellWord.quoted("com.example.*") == "'com.example.*'")
    // zsh puts the path of a command in the place of `=command`, and any shell a home directory in that of `~`.
    #expect(ShellWord.quoted("=ls") == "'=ls'" && ShellWord.quoted("--name=a") == "--name=a" && ShellWord.quoted("~") == "'~'")
}
