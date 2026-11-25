import Testing
@testable import XlessCore

@Test func shellWordsAreQuotedOnlyWhenNeeded() throws {
    #expect(ShellWord.quoted("ASC_KEY_P8@ABCDE12345") == "ASC_KEY_P8@ABCDE12345")
    #expect(ShellWord.quoted("/run/user/1000/xless-rescued-AuthKey_K.p8") == "/run/user/1000/xless-rescued-AuthKey_K.p8")
    #expect(ShellWord.quoted("ADMIN,FINANCE") == "ADMIN,FINANCE")
    #expect(ShellWord.quoted("/tmp/my key.p8") == "'/tmp/my key.p8'")
    #expect(ShellWord.quoted("it's") == "'it'\\''s'")
    #expect(ShellWord.quoted("") == "''")
    #expect(ShellWord.quoted("com.example.*") == "'com.example.*'")
    // zsh puts the path of a command in the place of `=command`, and any shell a home directory in that of `~`.
    #expect(ShellWord.quoted("=ls") == "'=ls'" && ShellWord.quoted("--name=a") == "--name=a" && ShellWord.quoted("~") == "'~'")
}
