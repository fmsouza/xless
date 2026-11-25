import CXlessProcess
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
    FileManager.default.createFile(atPath: d.path + "/0123456789abcdef01234567.sock", contents: Data()) // not a socket
    symlink("/dev/null", d.path + "/0123456789abcdef01234568.sock")
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

@Test func aSocketsNameSaysWhichProcessListens() throws {
    let scratch = ScratchDirectory()
    let d = AgentDirectory(path: scratch.path + "/xless-agent")
    let mine = try d.bind()
    defer { close(mine.fd) }
    let owner = try #require(AgentDirectory.Owner(of: mine.path))
    #expect(owner == .current)
    #expect(owner.pid == getpid())
    #expect(owner.isRunning)
    #expect(!AgentDirectory.Owner(pid: owner.pid, start: owner.start &+ 1).isRunning) // its pid is another process's by now
    let other = AgentDirectory.Owner(pid: 4_194_303, start: .max)
    #expect(AgentDirectory.Owner(of: "/d/" + AgentDirectory.name(other)) == other)
    #expect(AgentDirectory.name(other) != AgentDirectory.name(other))
    #expect(AgentDirectory.Owner(of: "/d/x.sock") == nil)
}

@Test func aProcessThatEndedIsNoOwner() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let owner = try #require(AgentDirectory.Owner(runningAs: p.processIdentifier))
    #expect(owner.isRunning)
    kill(p.processIdentifier, SIGKILL)
    p.waitUntilExit()
    #expect(!owner.isRunning)
}

@Test func onlyTheProcessThatMadeTheSocketAndRunsThisProgramIsEnded() {
    let me = AgentExecutable(device: 1, inode: 2), owner = AgentDirectory.Owner(pid: 77, start: 7)
    func peer(pid: Int32 = 77, uid: uid_t = geteuid(), inode: UInt64 = 2) -> xless_peer {
        var p = xless_peer()
        (p.pid, p.uid, p.exe_device, p.exe_inode) = (pid, uid, 1, inode)
        return p
    }
    func ends(_ p: xless_peer, owner o: AgentDirectory.Owner? = owner, running: Bool = true) -> Bool {
        AgentLink.maySafelyEnd(p, owner: o, program: me, isRunning: { _ in running })
    }
    #expect(ends(peer()))
    #expect(!ends(peer(pid: 78))) // another xless has the socket, or the pid the kernel kept
    #expect(!ends(peer(), running: false)) // the agent has ended: its pid is another one's
    #expect(!ends(peer(), owner: nil))
    #expect(!ends(peer(uid: geteuid() &+ 1)))
    #expect(!ends(peer(inode: 3)))
    #expect(!ends(peer(pid: getpid()), owner: AgentDirectory.Owner(pid: getpid(), start: 7))) // never itself
}

@Test func whatKeepsASocketOutOfTheDirectoryIsFoundBeforeOneIsMade() throws {
    let scratch = ScratchDirectory()
    let fine = AgentDirectory(path: scratch.path + "/xless-agent")
    #expect(fine.obstacle() == nil)
    #expect(!FileManager.default.fileExists(atPath: fine.path)) // nothing is made to find that out
    try fine.prepare()
    #expect(fine.obstacle() == nil)
    #expect(AgentDirectory(path: scratch.path + "/" + String(repeating: "x", count: 100)).obstacle()?.kind == .unavailable)
    #expect(AgentDirectory(path: scratch.path + "/nothing/xless-agent").obstacle()?.kind == .unavailable)
    try Data().write(to: URL(fileURLWithPath: scratch.path + "/file"))
    #expect(AgentDirectory(path: scratch.path + "/file/xless-agent").obstacle()?.kind == .unavailable)
    if geteuid() != 0 { // root may write anywhere
        mkdir(scratch.path + "/shut", 0o500)
        #expect(AgentDirectory(path: scratch.path + "/shut/xless-agent").obstacle()?.kind == .unavailable)
        chmod(fine.path, 0o500)
        #expect(fine.obstacle()?.kind == .unavailable)
    }
    chmod(fine.path, 0o755)
    #expect(fine.obstacle()?.kind == .unsafePath)
}

/// The longest directory a socket still fits into, and one byte more.
@Test func theObstacleOfALongPathIsThatOfBinding() throws {
    let scratch = ScratchDirectory()
    let room = Int(xless_unix_path_max()) - "/000000000000000000000000.sock".utf8.count - scratch.path.utf8.count - 1
    let longest = AgentDirectory(path: scratch.path + "/" + String(repeating: "x", count: room))
    #expect(longest.obstacle() == nil)
    let bound = try longest.bind()
    close(bound.fd)
    let longer = AgentDirectory(path: longest.path + "x")
    let obstacle = try #require(longer.obstacle())
    #expect(throws: obstacle) { _ = try longer.bind() }
}
