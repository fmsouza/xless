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
