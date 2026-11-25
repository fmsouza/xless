import Foundation
import Testing
@testable import XlessCore

@Test(arguments: [
    "a.txt", "en-US/description.txt", "en-US/screenshots/APP_IPHONE_67/01 home.png", "iap/com.example.coins.yml", "./a", "a/../b", ".hidden", "é.txt",
    "console.txt", "com.txt", "com10", "lpt", "nullable", "auxiliary/x", "com.example.con", "a.nul", "conin", "日本.txt",
])
func plainNamesAreFilesOnWindowsToo(_ name: String) {
    #expect(ProjectPath.problemOnWindows(name) == nil)
}

@Test(arguments: [
    "a.txt:stream", "a::$DATA", "C:x", "C:/x", "c:\\x", "\\\\server\\share\\x", "\\\\?\\C:\\x", "\\\\.\\NUL", "a\\b", "..\\x", "/x", "//server/x",
    "a<b", "a>b", "a\"b", "a|b", "a?b", "a*b", "a\u{0}b", "a\nb", "a\u{1f}",
    "a.", "a ", "a./b", "dir /b", "...", "a. .", "a.\u{301}x/ ",
    "NUL", "nul", "Nul.txt", "nul.tar.gz", "nul .txt", "x/CON", "con/x", "PRN", "aux.c", "COM1", "com9.yml", "COM0", "lpt1", "LPT\u{B9}", "com\u{b2}.x", "COM\u{b3}",
    "CONIN$", "conout$.txt", "clock$",
    "..\\\u{301}x", "a.txt:\u{301}s", "NUL:\u{301}", "/\u{301}x", "NUL/\u{301}x", "a?\u{200D}", "a\\\u{FE0F}b",
])
func whatWindowsTakesForSomethingElseIsRefused(_ name: String) {
    #expect(ProjectPath.problemOnWindows(name) != nil)
}

@Test func onlyWindowsRefusesNames() {
    #if os(Windows)
    #expect(ProjectPath.problem("nul.txt") != nil)
    let refused = #expect(throws: XlessError.self) { try ProjectPath.check("a:b", stage: .account) }
    #expect(refused?.stage == .account)
    #else
    #expect(ProjectPath.problem("nul.txt") == nil)
    #expect(ProjectPath.problem("a:b\\c.") == nil)
    #expect(throws: Never.self) { try ProjectPath.check("a:b", stage: .account) }
    #endif
}

@Test func aPathIsInsideWindowsDirectoriesByItsPartsWithoutCase() {
    #expect(ProjectPath.isInsideOnWindows(#"\\?\C:\Users\me\App\x.txt"#, #"\\?\c:\users\ME\app"#))
    #expect(ProjectPath.isInsideOnWindows(#"\\?\C:\a\b\c"#, #"\\?\C:\a\"#))
    #expect(!ProjectPath.isInsideOnWindows(#"\\?\C:\a"#, #"\\?\C:\a"#))
    #expect(!ProjectPath.isInsideOnWindows(#"\\?\C:\app-other\x"#, #"\\?\C:\app"#))
    #expect(!ProjectPath.isInsideOnWindows(#"\\?\D:\app\x"#, #"\\?\C:\app"#))
    #expect(!ProjectPath.isInsideOnWindows(#"\\?\C:\"#, #"\\?\C:\app"#))
    // As NTFS tells names apart, not as Swift does.
    #expect(!ProjectPath.isInsideOnWindows("\\\\?\\C:\\e\u{301}\\x", "\\\\?\\C:\\\u{e9}"))
    #expect(!ProjectPath.isInsideOnWindows("\\\\?\\C:\\\u{212A}\\x", "\\\\?\\C:\\k"))
    #expect(ProjectPath.isInsideOnWindows("\\\\?\\C:\\\u{e9}K\\x", "\\\\?\\C:\\\u{e9}k"))
    #expect(!ProjectPath.isInsideOnWindows("\\\\?\\C:\\app\\\u{301}x", "\\\\?\\C:\\app\\\u{301}y"))
    #expect(ProjectPath.isInsideOnWindows("\\\\?\\C:\\app\\\u{301}x", "\\\\?\\C:\\app"))
    #if os(Windows)
    #expect(ProjectPath.isInsideOnWindows("\\\\?\\C:\\\u{c9}\\x", "\\\\?\\C:\\\u{e9}"))
    #endif
}

private func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-inside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("root/in"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("root-other"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent("root/in/a.txt"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("root-other/a.txt"))
    return dir
}

@Test func whatIsInsideADirectoryIsTold() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("root")
    for inside in ["in", "in/a.txt", "in/missing.txt", "missing.txt"] {
        #expect(ProjectPath.isInside(root.appendingPathComponent(inside).standardizedFileURL, root), "\(inside)")
    }
    for outside in ["../root-other/a.txt", "../root-other/missing", "..", "in/../../root-other/a.txt"] {
        #expect(!ProjectPath.isInside(root.appendingPathComponent(outside).standardizedFileURL, root), "\(outside)")
    }
}

@Test func aLinkOutOfTheDirectoryIsOutside() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("root")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file"), withDestinationURL: dir.appendingPathComponent("root-other/a.txt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("root-other"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("own"), withDestinationURL: root.appendingPathComponent("in"))
    for outside in ["file", "link", "link/a.txt", "link/missing"] {
        #expect(!ProjectPath.isInside(root.appendingPathComponent(outside).standardizedFileURL, root), "\(outside)")
    }
    #expect(ProjectPath.isInside(root.appendingPathComponent("own/a.txt").standardizedFileURL, root))
}
