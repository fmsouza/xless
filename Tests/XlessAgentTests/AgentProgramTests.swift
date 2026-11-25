#if os(macOS)
import CXlessProcess
import Foundation
import Testing
import XlessCore
@testable import XlessAgent

/// Programs built here (`cc`) that connect to a socket of the test and wait there.
private final class Programs {
    let scratch = ScratchBox()
    private let listener: Int32
    private var children: [Process] = []
    private var sockets: [Int32] = []

    init() throws {
        listener = xless_unix_listen(scratch.path + "/s", 8)
        try #require(listener >= 0)
        _ = fcntl(listener, F_SETFL, 0)
    }

    deinit {
        sockets.forEach { close($0) }
        close(listener)
        for child in children {
            if child.isRunning { child.terminate() } // a process this test started
            child.waitUntilExit()
        }
    }

    func path(_ name: String) -> String { scratch.path + "/" + name }

    private func run(_ tool: String, _ arguments: [String]) throws {
        try #require(try Shell.run(tool, arguments, stage: .build).status == 0)
    }

    func build(_ name: String, _ source: String, _ arguments: [String] = []) throws {
        try Data(source.utf8).write(to: URL(fileURLWithPath: path(name + ".c")))
        try run("/usr/bin/cc", ["-o", path(name), path(name + ".c")] + arguments)
    }

    /// Runs it, and asks the kernel who connected.
    func peer(_ name: String, _ arguments: [String] = []) throws -> (peer: xless_peer, pid: Int32) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path(name))
        child.arguments = [path("s")] + arguments
        try child.run()
        children.append(child)
        var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        try #require(poll(&p, 1, 60_000) == 1, "\(name) did not connect")
        let fd = accept(listener, nil, nil)
        try #require(fd >= 0)
        sockets.append(fd)
        var byte: UInt8 = 0
        try #require(recv(fd, &byte, 1, 0) == 1)
        var peer = xless_peer()
        try #require(xless_peer_of(fd, &peer) == 0)
        #expect(peer.pid == child.processIdentifier)
        return (peer, child.processIdentifier)
    }

    /// Connects to the first argument, says so and waits for the test to close it.
    static let connect = """
        #include <sys/socket.h>
        #include <sys/un.h>
        #include <string.h>
        #include <unistd.h>
        static int speak(const char *path) {
            struct sockaddr_un a = { .sun_family = AF_UNIX };
            strlcpy(a.sun_path, path, sizeof a.sun_path);
            int s = socket(AF_UNIX, SOCK_STREAM, 0);
            char b = 'x';
            if (connect(s, (struct sockaddr *)&a, sizeof a) != 0 || write(s, &b, 1) != 1) return 1;
            read(s, &b, 1);
            return 0;
        }

        """

    /// Has the reference's file mapped lowest and at its own path, and runs its own code.
    func buildFooling(_ name: String) throws {
        try Data((Self.connect + """
            #include <sys/mman.h>
            #include <fcntl.h>
            #include <stdio.h>
            int fool(const void *header, char **v) { // the program, the socket, the reference
                int f = open(v[2], O_RDONLY);
                if (f < 0 || mmap((void *)header, getpagesize(), PROT_READ, MAP_FIXED | MAP_PRIVATE, f, 0) == MAP_FAILED) return 2;
                char other[1100];
                snprintf(other, sizeof other, "%s.x", v[0]);
                if (link(v[2], other) != 0 || rename(other, v[0]) != 0) return 3;
                return speak(v[1]);
            }
            """).utf8).write(to: URL(fileURLWithPath: path("code.c")))
        try run("/usr/bin/cc", ["-dynamiclib", "-install_name", path("code.dylib"), "-o", path("code.dylib"), path("code.c")])
        try build(name, """
            #include <mach-o/ldsyms.h>
            int fool(const void *, char **);
            int main(int c, char **v) { return fool(&_mh_execute_header, v); }
            """, [path("code.dylib")])
    }
}

@Test func codeThatPutsAnotherProgramsFileInItsPlaceIsNotThatProgram() throws {
    let programs = try Programs()
    try programs.build("ref", Programs.connect + "int main(int c, char **v) { return speak(v[1]); }")
    try programs.build("twin", Programs.connect + "int main(int c, char **v) { return speak(v[1]) + 0 * c; }")
    try programs.buildFooling("fool")
    let reference = try programs.peer("ref"), again = try programs.peer("ref"), twin = try programs.peer("twin")
    let program = try #require(AgentProgram(of: reference.peer))
    #expect(AgentProgram(of: again.peer) == program)
    #expect(AgentProgram(of: twin.peer) != program)
    let fooling = try programs.peer("fool", [programs.path("ref")])
    // All that the files say is that it is the reference ...
    #expect(fooling.peer.exe_inode == reference.peer.exe_inode && fooling.peer.exe_device == reference.peer.exe_device)
    // ... and the code is not.
    #expect(AgentProgram(of: fooling.peer) == nil)
    #expect(AgentProgram(of: reference.peer) == program)
}

@Test func aProgramThatCannotBeToldIsNone() throws {
    let programs = try Programs()
    try programs.build("ref", Programs.connect + "int main(int c, char **v) { return speak(v[1]); }")
    let (peer, _) = try programs.peer("ref")
    #expect(AgentProgram(of: peer) != nil)
    var gone = peer
    gone.token.7 &+= 1 // another process version: a process that has ended
    #expect(AgentProgram(of: gone) == nil)
    var unnamed = peer
    (unnamed.exe_device, unnamed.exe_inode) = (0, 0)
    #expect(AgentProgram(of: unnamed) == nil)
    // Replaced by another program while it runs (an upgrade), then removed.
    try programs.build("new", "int main(void) { return 0; }")
    try #require(rename(programs.path("new"), programs.path("ref")) == 0)
    #expect(AgentProgram(of: peer) == nil)
    try #require(unlink(programs.path("ref")) == 0)
    #expect(AgentProgram(of: peer) == nil)
}

@Test func thisProgramIsToldByItsFileAndItsCode() throws {
    let mine = try #require(AgentProgram.current)
    #expect(mine.file == AgentExecutable.current)
    #expect(mine.code.count == 20)
    let channel = try TestAgent().link()
    #expect(channel.isSameSession)
}
#endif
