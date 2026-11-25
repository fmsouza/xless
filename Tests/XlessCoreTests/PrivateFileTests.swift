#if os(Windows)
import CXlessWindows
import CXlessWindowsTestSupport
import Foundation
import Testing
@testable import XlessCore

// What other systems have mode 0600, 0700 and an owner for.

/// A directory of the tests' own with a private one, `d`, in it; removed by `cleanup()`.
private struct Place {
    let root: URL
    var dir: String { root.appendingPathComponent("d").path }
    func file(_ name: String = "f") -> String { root.appendingPathComponent("d/\(name)").path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-private-\(UUID().uuidString)")
        try PrivateFile.makeDirectory(root.appendingPathComponent("d").path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func user() -> String {
    var text = [UInt16](repeating: 0, count: Int(XLESS_SID_LENGTH))
    #expect(xless_user_sid(&text) == 1)
    return String(wide: text)
}

private func security(_ path: String) -> String {
    var text = [UInt16](repeating: 0, count: 2048)
    let code = path.withWide { xless_test_security($0, &text, text.count) }
    #expect(code == 0, "\(path): Windows error \(code)")
    return String(wide: text)
}

/// What Windows writes for it (`%` is the user).
private func normal(_ sddl: String) -> String {
    var text = [UInt16](repeating: 0, count: 2048)
    #expect(sddl.replacingOccurrences(of: "%", with: user()).withWide { xless_test_normal($0, &text, text.count) } == 0)
    return String(wide: text)
}

/// Owner and access list as SDDL (`%` is the user).
private func set(_ path: String, _ sddl: String) {
    let text = sddl.replacingOccurrences(of: "%", with: user())
    let code = path.withWide { path in text.withWide { xless_test_set_security(path, $0) } }
    #expect(code == 0, "\(path) \(sddl): Windows error \(code)")
}

private func refusal<T>(_ body: () throws -> T) -> PrivateFile.Refusal? { #expect(throws: PrivateFile.Refusal.self) { try body() } }

@Test func aPrivateDirectoryAndFileAreTheUsersAlone() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("secret".utf8), .builtInDrive)
    // The user's own SID, also where the token's default owner is the administrators (an elevated one, as CI's).
    #expect(security(place.dir) == normal("O:%D:P(A;OICI;FA;;;%)"))
    #expect(security(place.file()) == normal("O:%D:P(A;;FA;;;%)"))
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 100) == Data("secret".utf8))
    #expect(try PrivateFile.inDirectory(place.dir, .builtInDrive) { 1 } == 1)
}

@Test func whatIsNotThereIsNotARefusal() throws {
    let place = try Place()
    defer { place.cleanup() }
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 1) == nil)
    #expect(try PrivateFile.read(place.file("no/such"), .builtInDrive, limit: 1) == nil)
    #expect(try PrivateFile.inDirectory(place.file("no"), .builtInDrive) { 1 } == nil)
    #expect(!PrivateFile.exists(place.file()))
}

@Test func aNewFileNeverReplacesOne() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("a".utf8))
    #expect(refusal { try PrivateFile.create(place.file(), Data("b".utf8)) }?.kind == .exists)
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 9) == Data("a".utf8))
    // Nor a directory, nor through a link.
    #expect(refusal { try PrivateFile.create(place.dir, Data()) } != nil)
    try FileManager.default.createSymbolicLink(atPath: place.file("link"), withDestinationPath: place.file("target"))
    #expect(refusal { try PrivateFile.create(place.file("link"), Data("b".utf8)) }?.kind == .exists)
    #expect(!PrivateFile.exists(place.file("target")))
}

/// An elevated administrator's privileges are no way around: it is the access list that is judged, not whether the file could be opened.
@Test(arguments: [
    ("D:P(A;;FA;;;%)(A;;FR;;;WD)", "S-1-1-0"),           // everyone
    ("D:P(A;;FA;;;%)(A;;0x1;;;BU)", "S-1-5-32-545"),     // users
    ("D:P(A;;FA;;;%)(A;;FA;;;AU)", "S-1-5-11"),          // whoever signed in
    ("D:P(A;;FA;;;%)(A;;FA;;;AN)", "S-1-5-7"),
    ("D:P(A;;FA;;;%)(A;;RC;;;IU)", "S-1-5-4"),
    ("D:P(A;;FA;;;%)(A;;FR;;;OW)", "S-1-3-4"),           // whoever will own it
    ("D:P(A;;FA;;;%)(A;;FR;;;AC)", "S-1-15-2-1"),        // app packages
    ("D:P(A;;FA;;;%)(A;;FA;;;LS)", "S-1-5-19"),
    ("D:P(D;;FR;;;BG)(A;;FA;;;%)(A;;FW;;;WD)", "S-1-1-0"),
    ("D:P(A;;FA;;;%)(A;;FA;;;S-1-5-21-1-2-3-1001)", "S-1-5-21-1-2-3-1001"),
])
func anybodyElsesAccessIsRefused(_ sddl: String, _ who: String) throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    try PrivateFile.withLock(place.file("lock"), .builtInDrive) {}
    set(place.file(), sddl)
    set(place.file("lock"), sddl)
    for refused in [refusal { try PrivateFile.read(place.file(), .anyDrive, limit: 9) }, refusal { try PrivateFile.withLock(place.file("lock"), .anyDrive) {} }] {
        #expect(refused?.kind == .unsafe)
        #expect(refused?.cause.contains("other users (\(who))") == true, "\(refused?.cause ?? "")")
        #expect(refused?.fix.contains("/remove:g *\(who)") == true)
        #expect(refused?.fix.contains("/grant:r \"*\(user()):F\"") == true)
    }
    // It is refused, not repaired.
    #expect(security(place.file()).contains("(A;"))
    set(place.dir, sddl)
    let directory = refusal { try PrivateFile.inDirectory(place.dir, .anyDrive) {} }
    #expect(directory?.kind == .unsafe)
    #expect(directory?.cause.contains(who) == true)
    set(place.dir, "D:P(A;OICI;FA;;;%)")
}

@Test(arguments: [
    "D:P(A;;FA;;;%)(A;;FA;;;SY)(A;;FA;;;BA)",     // root's counterparts, which others' software adds
    "D:P(A;;FA;;;%)(D;;FW;;;WD)",                 // nobody is let in by it
    "D:P(D;;FR;;;BG)(A;;FRFW;;;%)",
])
func theSystemAndTheAdministratorsAndRefusalsAreAccepted(_ sddl: String) throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    set(place.file(), sddl)
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 9) != nil)
    set(place.dir, sddl)
    #expect(try PrivateFile.inDirectory(place.dir, .builtInDrive) { 1 } == 1)
    set(place.dir, "D:P(A;OICI;FA;;;%)")
}

@Test func noAccessListIsRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    set(place.file(), "D:NO_ACCESS_CONTROL")
    let refused = refusal { try PrivateFile.read(place.file(), .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe)
    #expect(refused?.cause.contains("open to everyone") == true, "\(refused?.cause ?? "")")
}

@Test func anInheritedAccessListIsRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    // As any file made in the directory is: it lets in nobody but the user today, and whoever its directory lets in tomorrow.
    try Data("s".utf8).write(to: URL(fileURLWithPath: place.file()))
    set(place.file(), "O:%")
    let refused = refusal { try PrivateFile.read(place.file(), .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe)
    #expect(refused?.cause.contains("one of its own") == true, "\(refused?.cause ?? "")")
    // Its own entries, but not protected from more.
    try PrivateFile.create(place.file("own"), Data("s".utf8))
    set(place.file("own"), "D:AI(A;;FA;;;%)")
    #expect(refusal { try PrivateFile.read(place.file("own"), .builtInDrive, limit: 9) }?.kind == .unsafe)
    try FileManager.default.createDirectory(atPath: place.file("sub"), withIntermediateDirectories: false)
    set(place.file("sub"), "O:%")
    #expect(refusal { try PrivateFile.inDirectory(place.file("sub"), .builtInDrive) {} }?.kind == .unsafe)
}

@Test func anEntryThatCannotBeJudgedIsRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    // A condition: who it lets in is not in the list.
    set(place.file(), "D:P(A;;FA;;;%)(XA;;FR;;;WD;(Member_of {SID(BA)}))")
    let refused = refusal { try PrivateFile.read(place.file(), .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe)
    #expect(refused?.cause.contains("cannot judge") == true, "\(refused?.cause ?? "")")
}

/// Only with the privilege to give a file away; CI's user has it. The administrators, whose member the user may be, are not the user.
@Test(.enabled(if: xless_test_may_set_owner() == 1), arguments: [("BA", "S-1-5-32-544"), ("SY", "S-1-5-18"), ("BU", "S-1-5-32-545")])
func anotherOwnersIsRefused(_ owner: String, _ sid: String) throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    set(place.file(), "O:\(owner)")
    let refused = refusal { try PrivateFile.read(place.file(), .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe)
    #expect(refused?.cause.contains("another user (\(sid))") == true, "\(refused?.cause ?? "")")
    set(place.dir, "O:\(owner)")
    #expect(refusal { try PrivateFile.inDirectory(place.dir, .builtInDrive) {} }?.cause.contains(sid) == true)
    set(place.dir, "O:%")
}

@Test func linksAreRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file("real"), Data("s".utf8))
    try PrivateFile.makeDirectory(place.file("sub"))
    // Symbolic links, where they may be made.
    try FileManager.default.createSymbolicLink(atPath: place.file("link"), withDestinationPath: place.file("real"))
    let file = refusal { try PrivateFile.read(place.file("link"), .builtInDrive, limit: 9) }
    #expect(file?.kind == .link)
    #expect(file?.cause.contains("is a link") == true)
    #expect(refusal { try PrivateFile.withLock(place.file("link"), .builtInDrive) {} }?.kind == .link)
    // A junction, which anybody may make.
    #expect(place.file("junction").withWide { link in place.file("sub").withWide { xless_test_junction(link, $0) } } == 0)
    #expect(refusal { try PrivateFile.inDirectory(place.file("junction"), .builtInDrive) {} }?.kind == .link)
    #expect(try PrivateFile.inDirectory(place.file("sub"), .builtInDrive) { 1 } == 1)
}

@Test func aSecondNameIsRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    #expect(place.file("second").withWide { name in place.file().withWide { xless_test_hard_link(name, $0) } } == 0)
    let refused = refusal { try PrivateFile.read(place.file(), .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe)
    #expect(refused?.cause.contains("hard links") == true)
}

@Test func theWrongKindIsRefused() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("s".utf8))
    #expect(refusal { try PrivateFile.read(place.dir, .builtInDrive, limit: 9) }?.kind == .notFile)
    #expect(refusal { try PrivateFile.inDirectory(place.file(), .builtInDrive) {} }?.kind == .unsafe)
    for path in [place.file() + ":stream", "\\\\.\\NUL", "NUL", "\\\\.\\pipe\\xless-none", "\\\\?\\GLOBALROOT\\Device\\Null"] {
        let refused = refusal { try PrivateFile.read(path, .anyDrive, limit: 9) }
        #expect(refused?.kind == .unsafe, "\(path): \(refused?.cause ?? "")")
        #expect(refusal { try PrivateFile.create(path, Data()) } != nil, "\(path)")
    }
    // A share of this very computer.
    let drive = place.file().replacingOccurrences(of: "/", with: "\\")
    let share = "\\\\localhost\\" + drive.replacingOccurrences(of: ":", with: "$")
    let refused = refusal { try PrivateFile.read(share, .builtInDrive, limit: 9) }
    #expect(refused?.kind == .unsafe, "\(share): \(refused?.cause ?? "")")
    #expect(refused?.cause.contains("not on a drive built into this computer") == true, "\(refused?.cause ?? "")")
}

/// A path that says no drive is one of the current directory's, or of its drive's root, where others may write.
@Test func aStoresPathNamesItsDrive() {
    for path in ["f", "\\f", "/f", "C:f", "//localhost/C$/f"] {
        #expect(refusal { try PrivateFile.read(path, .builtInDrive, limit: 9) }?.kind == .unsafe, "\(path)")
        #expect(refusal { try PrivateFile.create(path, Data(), .builtInDrive) }?.kind == .unsafe, "\(path)")
        #expect(refusal { try PrivateFile.withLock(path, .builtInDrive) {} }?.kind == .unsafe, "\(path)")
        #expect(refusal { try PrivateFile.makeDirectory(path) }?.kind == .unsafe, "\(path)")
    }
    #expect(throws: XlessError.self) { try UserConfig.read(URL(fileURLWithPath: "\\\\localhost\\C$\\config.yml")) }
}

@Test func aLimitIsKept() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data(repeating: 7, count: 200_000))
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 300_000) == Data(repeating: 7, count: 200_000))
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 200_000)?.count == 200_000)
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 1000)?.count == 1001)
}

@Test func replacingIsOneStepAlsoForAReader() throws {
    let place = try Place()
    defer { place.cleanup() }
    try PrivateFile.create(place.file(), Data("old".utf8))
    // An open reader keeps what it opened.
    var why = xless_private()
    let reader = place.file().withWide { xless_private_open($0, 1, &why, nil) }
    defer { xless_private_close(reader) }
    try PrivateFile.replace(place.file(), with: Data("new".utf8), through: place.file("tmp"), .builtInDrive)
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 9) == Data("new".utf8))
    var bytes = [UInt8](repeating: 0, count: 9), code: UInt32 = 0
    #expect(xless_private_read(reader, &bytes, 9, &code) == 3)
    #expect(bytes.prefix(3) == ArraySlice("old".utf8))
    #expect(security(place.file()) == normal("O:%D:P(A;;FA;;;%)"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: place.dir) == ["f"])
    // Nor while another program has it open and lets nobody replace it: what is there stays, and the new one is gone.
    let other = try #require(FileHandle(forReadingAtPath: place.file()))
    #expect(refusal { try PrivateFile.replace(place.file(), with: Data("newer".utf8), through: place.file("tmp"), .builtInDrive) }?.kind == .failed)
    try other.close()
    #expect(try PrivateFile.read(place.file(), .builtInDrive, limit: 9) == Data("new".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: place.dir) == ["f"])
    try PrivateFile.makeDirectory(place.file("sub"))
    try PrivateFile.create(place.file("sub/x"), Data())
    #expect(refusal { try PrivateFile.replace(place.file("sub"), with: Data("new".utf8), through: place.file("tmp"), .builtInDrive) }?.kind == .failed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: place.dir).sorted() == ["f", "sub"])
}

@Test func aHeldDirectoryIsNotRenamed() throws {
    let place = try Place()
    defer { place.cleanup() }
    let moved = place.root.appendingPathComponent("moved").path
    _ = try PrivateFile.inDirectory(place.dir, .builtInDrive) {
        #expect(throws: (any Error).self) { try FileManager.default.moveItem(atPath: place.dir, toPath: moved) }
        try PrivateFile.create(place.file(), Data("s".utf8))
    }
    try FileManager.default.moveItem(atPath: place.dir, toPath: moved)
}

@Test func oneHolderOfALockAtATime() throws {
    let place = try Place()
    defer { place.cleanup() }
    let lock = NSLock()
    nonisolated(unsafe) var inside = 0, most = 0, errors: [String] = []
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
        do {
            try PrivateFile.withLock(place.file("lock"), .builtInDrive) {
                lock.withLock { inside += 1; most = max(most, inside) }
                Thread.sleep(forTimeInterval: 0.005)
                lock.withLock { inside -= 1 }
            }
        } catch { lock.withLock { errors.append("\(error)") } }
    }
    #expect(most == 1)
    #expect(errors == [])
}

@Test func longPathsAndSpacesAndOtherLettersWork() throws {
    let place = try Place()
    defer { place.cleanup() }
    var dir = place.dir
    for _ in 0..<6 { dir += "/" + String(repeating: "lång name ", count: 6) + "x" }
    #expect(dir.count > 300)
    try PrivateFile.makeDirectory(dir)
    let path = dir + "/日本.vault"
    try PrivateFile.create(path, Data("s".utf8))
    #expect(try PrivateFile.read(path, .builtInDrive, limit: 9) == Data("s".utf8))
    #expect(PrivateFile.exists(path))
}

@Test func anInputIsAPlainFileOfAnyones() throws {
    let place = try Place()
    defer { place.cleanup() }
    try Data("abc".utf8).write(to: URL(fileURLWithPath: place.file()))
    #expect(try InputFile.read(place.file(), limit: 3) == Data("abc".utf8))
    #expect(refusal { try InputFile.read(place.file(), limit: 2) }?.kind == .tooLarge)
    #expect(refusal { try InputFile.read(place.file("none"), limit: 2) }?.kind == .missing)
    #expect(refusal { try InputFile.read(place.dir, limit: 2) }?.kind == .notFile)
    for path in ["NUL", "\\\\.\\NUL", "CON", "\\\\.\\pipe\\xless-none", place.file() + "::$DATA"] {
        #expect(refusal { try InputFile.read(path, limit: 9) } != nil, "\(path)")
    }
    try FileManager.default.createSymbolicLink(atPath: place.file("link"), withDestinationPath: place.file())
    #expect(try InputFile.read(place.file("link"), limit: 9) == Data("abc".utf8))
    #expect(refusal { try InputFile.read(place.file("link"), limit: 9, throughLinks: false) }?.kind == .link)
}

@Test func anOutputIsANewFile() throws {
    let place = try Place()
    defer { place.cleanup() }
    let output = try OutputFile(creating: place.file("out"))
    try output.write(Data("ab".utf8))
    try output.write(Data("c".utf8))
    try output.synchronize()
    output.close()
    #expect(try Data(contentsOf: URL(fileURLWithPath: place.file("out"))) == Data("abc".utf8))
    #expect(refusal { try OutputFile(creating: place.file("out")) }?.kind == .exists)
    try Data("old".utf8).write(to: URL(fileURLWithPath: place.file("there")))
    #expect(refusal { try OutputFile.move(place.file("out"), to: place.file("there"), replacing: false) }?.kind == .exists)
    try OutputFile.move(place.file("out"), to: place.file("there"), replacing: true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: place.file("there"))) == Data("abc".utf8))
    #expect(!PrivateFile.exists(place.file("out")))
}

@Test func theUsersFilesAreInLocalAppData() throws {
    let standard = UserPaths.directory(xdg: "XDG_DATA_HOME", env: [:])
    #expect(standard.lastPathComponent == "xless")
    #expect(standard.deletingLastPathComponent().lastPathComponent == "Local")
    // The system's word for where it is, not a variable's.
    #expect(UserPaths.directory(xdg: "XDG_DATA_HOME", env: ["LOCALAPPDATA": "C:\\elsewhere", "HOME": "C:\\home"]) == standard)
    for ignored in ["", "relative", "\\rooted", "/rooted", "C:relative", "\\\\server\\share", "\\\\?\\C:\\x", "\\\\.\\C:\\x"] {
        #expect(UserPaths.directory(xdg: "XDG_DATA_HOME", env: ["XDG_DATA_HOME": ignored]) == standard, "\(ignored)")
    }
    for (honoured, path) in [("C:\\data", "C:/data/xless"), ("d:/data", "d:/data/xless")] {
        #expect(UserPaths.directory(xdg: "XDG_DATA_HOME", env: ["xdg_data_home": honoured]).path.lowercased() == path.lowercased())
    }
    #expect(UserConfig.file(env: [:]) == standard.appendingPathComponent("config.yml"))
}

@Test func aSecretsFileIsNoDevice() throws {
    for path in ["NUL", "\\\\.\\pipe\\xless-none"] {
        let refused = #expect(throws: XlessError.self) { try Secrets(env: ["X_TEST_FILE": path], fallback: nil).optional("X_TEST") }
        #expect(refused?.cause.contains("unreadable") == true)
    }
}
#endif
