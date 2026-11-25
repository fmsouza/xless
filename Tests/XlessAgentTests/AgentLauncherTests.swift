import Foundation
import Testing
import XlessCore
@testable import XlessAgent

/// Starts `script` in an agent's place, with the socket pair as its descriptor 3; why that failed.
private func start(_ script: String) throws -> AgentError.Kind? {
    try #require(AgentLauncher.obstacle() == nil, "these tests need a session whose leader still runs")
    let box = ScratchBox()
    let program = URL(fileURLWithPath: box.path + "/agent")
    try ExecutableFile.write("#!/usr/bin/env python3\n" + script, to: program, stage: .build)
    do {
        try AgentLauncher.start([], directory: AgentDirectory(path: box.path + "/xless-agent"), terms: AgentTerms(), executable: program.path)
        return nil
    } catch let e as AgentError {
        return e.kind
    }
}

private func refusing(_ why: AgentRefusal) -> String {
    """
    import os, socket, struct
    s = socket.socket(fileno=3)
    s.setblocking(True)
    s.recv(1 << 16)
    text = b"no"
    body = bytes([\(why.rawValue)]) + struct.pack(">I", len(text)) + text
    s.sendall(b"XLAG" + struct.pack(">HHHH", 1, \(AgentCode.refused.rawValue), 0, len(body)) + body)
    """
}

@Test func anAgentThatRefusesToStartIsNotOneThatCannotRunHere() throws {
    #expect(try start(refusing(.limit)) == .failed)
    #expect(try start(refusing(.unavailable)) == .unavailable)
    #expect(try start("raise SystemExit(1)") == .gone)
}

@Test func aProgramThatCannotBeStartedIsNotAnAgentThatCannotRunHere() throws {
    try #require(AgentLauncher.obstacle() == nil)
    let box = ScratchBox()
    do {
        try AgentLauncher.start([], directory: AgentDirectory(path: box.path + "/xless-agent"), terms: AgentTerms(), executable: box.path + "/none")
        Issue.record("started a program that is not there")
    } catch let e as AgentError {
        #expect(e.kind == .failed)
    }
}

@Test func anAgentSaysWhetherItCanRunHereAtAll() {
    #expect(AgentHost.refusal(of: AgentError(.unavailable, "-", fix: "-")) == .unavailable)
    #expect(AgentHost.refusal(of: AgentError(.failed, "-", fix: "-")) == .limit)
    #expect(AgentHost.refusal(of: AgentError.limit("-")) == .limit)
    #expect(AgentHost.refusal(of: AgentError(.unsafePath, "-", fix: "-")) == .limit)
    #expect(AgentHost.refusal(of: CancellationError()) == .limit)
}

@Test func onlyWhatLastsMeansThatNoAgentCanRunHere() {
    for e in [EACCES, EPERM, EROFS, ENOENT, ENOTDIR, EAFNOSUPPORT, EOPNOTSUPP, ENOSYS] { #expect(AgentError.Kind(system: e) == .unavailable, "\(e)") }
    for e in [EADDRINUSE, EMFILE, ENFILE, ENOMEM, ENOSPC, EIO, EINTR] { #expect(AgentError.Kind(system: e) == .failed, "\(e)") }
}

@Test func anAgentsDirectoryRemovedBeforeItsSocketIsBoundIsNoLastingObstacle() {
    // It was just made: ENOENT is of the moment there, where for making it it means that its parent is not there.
    #expect(AgentError.Kind(binding: ENOENT) == .failed)
    for e in [EACCES, EROFS, EAFNOSUPPORT] { #expect(AgentError.Kind(binding: e) == .unavailable, "\(e)") }
    #expect(AgentError.Kind(binding: ENOSPC) == .failed)
}

@Test func onlyAKernelWithoutPidfdsMeansThatNoAgentCanRunHere() {
    #expect(AgentLauncher.obstacle(pidfd: ENOSYS).kind == .unavailable)
    #expect(AgentLauncher.obstacle(pidfd: ENOSYS).cause.contains("Linux 5.3"))
    // A seccomp profile's refusal lasts as long as the container.
    #expect(AgentLauncher.obstacle(pidfd: EPERM).kind == .unavailable)
    #expect(AgentLauncher.obstacle(pidfd: EPERM).fix.contains("seccomp"))
    for e in [EMFILE, ENFILE, ENOMEM, ENODEV, EINVAL] {
        let obstacle = AgentLauncher.obstacle(pidfd: e)
        #expect(obstacle.kind == .failed && !obstacle.cause.contains("Linux 5.3"), "\(e)")
    }
}

#if os(macOS)
@Test func anAgentThatCannotTellItsOwnProgramDoesNotStart() throws {
    let mine = try #require(AgentProgram.current)
    #expect(try AgentHost.program(mine) == mine)
    try #require(AgentSession.current.isUsable)
    var fds: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { close(fds[1]) }
    let scratch = ScratchBox(), directory = AgentDirectory(path: scratch.path + "/xless-agent"), channel = try AgentChannel(fd: fds[0])
    var w = WireWriter()
    w.put(directory.path)
    w.put(Int64(AgentSession.current.id))
    w.put(false)
    AgentTerms().write(&w)
    w.put(UInt32(0))
    let frame = w.frame(code: .configure)
    let message = AgentMessage(header: try #require(frame.withUnsafeBytes { try? AgentFrame.header($0) }), pages: frame)
    do {
        _ = try AgentHost.configure(message, channel, own: nil)
        Issue.record("it starts, and serves any program")
    } catch let e as AgentError {
        #expect(e.kind == .unavailable)
        #expect(AgentHost.refusal(of: e) == .unavailable)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path)) // nothing to ask
    #expect(try AgentHost.configure(message, channel).options.program == mine)
}

@Test func whyThisProgramIsNotToldIsSaid() throws {
    func why(_ mapped: AgentExecutable?, _ program: AgentProgram?) -> AgentError? {
        do { _ = try AgentLauncher.executablePath(mapped: mapped, program: program); return nil } catch { return error as? AgentError }
    }
    let mine = try #require(AgentProgram.current)
    #expect(why(mine.file, mine) == nil)
    let replaced = try #require(why(AgentExecutable(device: 1, inode: 1), mine))
    #expect(replaced.kind == .failed && replaced.cause.contains("replaced or removed"))
    for e in [why(nil, mine), why(mine.file, nil)] {
        let untold = try #require(e)
        #expect(untold.kind == .unavailable && untold.cause.contains("does not say which program") && !untold.cause.contains("replaced"))
    }
}

/// What `swift build` makes where the linker signs nothing: that there is no signature is said, and the command that makes one.
@Test func aProgramWithoutASignatureIsToldToSignItself() throws {
    func run(_ tool: String, _ arguments: [String]) throws { try #require(try Shell.run(tool, arguments, stage: .build).status == 0) }
    let scratch = ScratchBox()
    let path = scratch.path + "/it's mine"
    try Data("int main(void) { return 0; }".utf8).write(to: URL(fileURLWithPath: scratch.path + "/p.c"))
    try run("/usr/bin/cc", ["-Wl,-adhoc_codesign", "-o", path, scratch.path + "/p.c"])
    #expect(AgentLauncher.untold(path).cause.contains("does not say which program"))
    try run("/usr/bin/codesign", ["--remove-signature", path])
    let unsigned = AgentLauncher.untold(path)
    #expect(unsigned.kind == .unavailable && unsigned.cause.contains("no code signature"))
    let command = try #require(unsigned.fix.range(of: "codesign --sign - ").map { String(unsigned.fix[$0.lowerBound...]) })
    try run("/bin/sh", ["-c", command])
    #expect(AgentLauncher.untold(path).cause.contains("does not say which program"))
    // Nothing to look at: what is not known is not said.
    #expect(AgentLauncher.untold(nil).cause.contains("does not say which program"))
    #expect(AgentLauncher.untold(scratch.path + "/none").cause.contains("does not say which program"))
}

@Test func anAgentsProgramIsComparedWithThisOnesOnlyWhenThatIsKnown() throws {
    let mine = try #require(AgentProgram.current)
    let other = AgentProgram(file: mine.file, code: [1])
    func why(_ theirs: AgentProgram?, _ mine: AgentProgram?) -> AgentError? {
        do { try AgentLink.compare(theirs, with: mine, version: "1"); return nil } catch { return error as? AgentError }
    }
    #expect(why(mine, mine) == nil)
    for e in [why(other, mine), why(nil, mine)] { #expect(e?.kind == .version) }
    for theirs in [mine, nil] { #expect(why(theirs, nil)?.kind == .unavailable) } // not "another xless", which no `xless lock` would help
}
#endif
