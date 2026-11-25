import Foundation
import Testing
import XlessCore
@testable import XlessAgent

/// A short temporary directory (socket paths are at most 103 bytes on macOS): removed at the end.
struct ScratchDirectory: ~Copyable {
    let path: String
    init() {
        var template = Array("/tmp/xa-XXXXXX".utf8CString)
        path = String(cString: template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) })
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

private func mode(_ path: String) -> mode_t {
    var st = stat()
    lstat(path, &st)
    return st.st_mode & 0o7777
}

@Test func theAgentsDirectoryIsInTheRuntimeDirectoryWhenThereIsOne() {
    #expect(AgentDirectory.location(env: ["XDG_RUNTIME_DIR": "/run/user/1000"]) == "/run/user/1000/xless-agent")
    let relative = AgentDirectory.location(env: ["XDG_RUNTIME_DIR": "run"])
    #expect(relative.hasPrefix("/"))
    #expect(!relative.hasPrefix("/run/user/1000/run"))
    let none = AgentDirectory.location(env: ["HOME": "/home/me"])
    #expect(none.hasPrefix("/"))
    #expect(!none.hasPrefix("/home/me")) // a project mount into a container could hold it
    #expect(none.contains("xless-agent"))
}

@Test func theDirectoryIsMadeForItsUserOnlyWhateverTheUmask() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/xless-agent")
    try d.prepare()
    #expect(mode(d.path) == 0o700)
    try d.prepare() // again: fine
    #expect(try d.verify())
}

@Test func aMissingDirectoryIsNoAgent() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/xless-agent")
    #expect(try d.verify() == false)
    #expect(try d.sockets() == [])
}

@Test func aDirectoryOthersCanUseIsRefused() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/xless-agent")
    try d.prepare()
    for bad: mode_t in [0o701, 0o710, 0o750, 0o755, 0o770, 0o777, 0o1777] {
        chmod(d.path, bad)
        #expect(throws: AgentError.self) { try d.verify() }
        #expect(throws: AgentError.self) { try d.prepare() }
        #expect(throws: AgentError.self) { try d.sockets() }
    }
}

@Test func aSymbolicLinkOrAFileInTheDirectorysPlaceIsRefused() throws {
    let scratch = ScratchDirectory()
    let real = scratch.path + "/real", link = scratch.path + "/xless-agent"
    try AgentDirectory(path: real).prepare()
    symlink(real, link)
    #expect(throws: AgentError.self) { try AgentDirectory(path: link).verify() }
    #expect(throws: AgentError.self) { try AgentDirectory(path: link).prepare() }
    unlink(link)
    FileManager.default.createFile(atPath: link, contents: Data())
    #expect(throws: AgentError.self) { try AgentDirectory(path: link).verify() }
}

@Test func aDirectoryOfAnotherUserIsRefused() throws {
    let scratch = ScratchDirectory()
    let mine = AgentDirectory(path: scratch.path + "/xless-agent")
    try mine.prepare() // 0700: only its owner is wrong
    let theirs = AgentDirectory(path: mine.path, user: geteuid() + 1) // as that user sees this one's
    #expect(throws: AgentError.self) { try theirs.verify() }
    #expect(throws: AgentError.self) { try theirs.prepare() }
    #expect(throws: AgentError.self) { try theirs.sockets() }
}

@Test func onlySocketsOfTheUserAreListedAndAtMostSoMany() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/xless-agent")
    try d.prepare()
    FileManager.default.createFile(atPath: d.path + "/0123456789abcdef.sock", contents: Data()) // not a socket
    symlink("/dev/null", d.path + "/0123456789abcde0.sock")
    let socket = try d.bind()
    defer { close(socket.fd) }
    #expect(try d.sockets() == [socket.path])
    #expect(mode(socket.path) == 0o600)
    #expect(socket.path.hasPrefix(d.path + "/"))
    let more = try (0..<(AgentLimits.sockets + 3)).map { _ in try d.bind() }
    defer { more.forEach { close($0.fd) } }
    #expect(try d.sockets().count == AgentLimits.sockets)
}

@Test func aPathTooLongForASocketIsAClearError() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/" + String(repeating: "d", count: 100))
    try d.prepare()
    do {
        _ = try d.bind()
        Issue.record("bound a socket with a path that is too long")
    } catch let e as AgentError {
        #expect(e.description.contains("too long"))
        #expect(e.description.contains("XDG_RUNTIME_DIR"))
    }
}
