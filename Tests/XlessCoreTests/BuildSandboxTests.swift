import Foundation
import Testing
@testable import XlessCore

@Test func aPathOfTheSandboxIsWhatTheSystemCallsIt() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-sandbox-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a"))
    let real = BuildSandbox.real(root.path)
    #expect(BuildSandbox.real(root.path + "/link/not/there") == real + "/a/not/there" && BuildSandbox.real("/not-there") == "/not-there" && BuildSandbox.real("/") == "/")
    #expect(try BuildSandbox.quoted(#"/a "b"\c"#) == #""/a \"b\"\\c""#)
    for bad in ["relative", "/", "/a\nb", "/a\u{7f}"] { #expect(throws: XlessError.self) { try BuildSandbox.quoted(bad) } }
    #expect(BuildSandbox.above("/a/b/c") == ["/a", "/a/b"] && BuildSandbox.above("/a") == [])
    #expect(BuildSandbox.isBelow("/a/b", "/a") && BuildSandbox.isBelow("/a", "/a") && !BuildSandbox.isBelow("/ab", "/a") && BuildSandbox.isBelow("/a", "/"))
}

@Test func secretsAreTheLastWordOfTheSandboxsRules() throws {
    let rules = try BuildSandbox(reads: ["/opt/r"], writes: ["/opt/w"], secrets: ["/opt/w/secret"], closed: ["/opt"]).profile().split(separator: "\n").map(String.init)
    func index(_ rule: String) throws -> Int { try #require(rules.firstIndex(of: rule), "\(rule)") }
    #expect(rules.prefix(3) == ["(version 1)", "(allow default)", "(deny file-write*)"])
    let closed = try index(#"(deny file-read-data file-read-xattr file-read-metadata (subpath "/opt"))"#), open = try index(#"(allow file-read-data file-read-xattr file-read-metadata (subpath "/opt/r") (subpath "/opt/w"))"#)
    let secret = try index(#"(deny file-read-data file-read-xattr file-read-metadata file-write* (subpath "/opt/w/secret"))"#)
    #expect(try closed < open && open < secret && index(#"(allow file-write* (subpath "/opt/w"))"#) < secret)
    #expect(rules.filter { $0.contains("secret") }.count == 1 && rules.suffix(from: secret + 1).allSatisfy { !$0.contains("file-") })
}

#if os(macOS)
/// A program in the sandbox of these tests, which is made for `work` below a closed directory.
private final class Sandboxed {
    let root: String, work: String
    var sandbox: BuildSandbox

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("xless sandbox \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made.appendingPathComponent("w"), withIntermediateDirectories: true)
        root = BuildSandbox.real(made.path)
        work = root + "/w"
        sandbox = BuildSandbox(reads: [root + "/r"], writes: [work], secrets: [work + "/secret"], closed: BuildSandbox.privatePlaces)
        try FileManager.default.createDirectory(atPath: root + "/r", withIntermediateDirectories: true)
        for file in ["private", "r/open", "w/mine", "w/secret"] { try Data("text of \(file)\n".utf8).write(to: URL(fileURLWithPath: "\(root)/\(file)")) }
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    func run(_ words: String...) throws -> (status: Int32, out: String) {
        let command = try sandbox.command(words[0], Array(words.dropFirst()))
        let out = URL(fileURLWithPath: work).appendingPathComponent("out-\(UUID().uuidString)") // (a program looks at its output file, too)
        _ = FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let tool = try ChildProcess.start(command.program, command.arguments, environment: ["PATH": "/usr/bin:/bin", "TMPDIR": work, "HOME": work], cwd: URL(fileURLWithPath: work),
                                          stdout: handle.fileDescriptor, stderr: handle.fileDescriptor, stage: .build)
        let status = tool.wait()
        return (status, try String(contentsOf: out, encoding: .utf8))
    }
    /// What `sh -c` says.
    func sh(_ script: String) throws -> (status: Int32, out: String) { try run("/bin/sh", "-c", script) }
}

@Test func theSandboxOpensWhatTheBuildHasAndNoMore() throws {
    let box = try Sandboxed()
    #expect(try box.sh("cat mine ../r/open").out == "text of w/mine\ntext of r/open\n")
    #expect(try box.sh("echo new > made && cat made").out == "new\n")
    for denied in ["cat ../private", "cat secret", "echo x > secret", "mv secret elsewhere", "ls ..", "echo x > ../r/open", "echo x > ../r/new", "rm ../private", "ln ../private stolen && cat stolen",
                   "echo x > /private/tmp/xless-sandbox-test", "ls /Users", "ls \(BuildSandbox.userHome!)", "ls /System/Volumes/Data\(BuildSandbox.userHome!)", "ls /Volumes",
                   "ls /private/var/folders", "ls \(ShellWord.quoted(FileManager.default.temporaryDirectory.path))", "ls /private/var/root"] {
        let answer = try box.sh(denied)
        #expect(answer.status != 0 && answer.out.lowercased().contains("not permitted"), "\(denied): \(answer.status) \(answer.out)")
    }
    #expect(!FileManager.default.fileExists(atPath: "/private/tmp/xless-sandbox-test"))
    // what is closed cannot be looked at, the way to what is open can
    #expect(try box.sh("test -e ../private || test -e secret").status == 1)
    #expect(try box.sh("test -d .. && test -d ../../ && cd ../r && pwd -P").out == box.root + "/r\n")
    // a tool that asks the system for a directory for temporary files makes do with the build's
    #expect(try box.sh("cd / && f=$(mktemp) && echo x > \"$f\" && echo \"${f%/*}\"").out == box.work + "\n")
    // a link of the build's own leads nowhere else
    #expect(try box.sh("ln -s ../private link && cat link").status != 0)
    // and it holds for all that it starts, in a session of its own too
    #expect(try box.sh("/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec(\"/bin/cat\", \"../private\")'").status != 0)
}

@Test func whatXlessUsesOfTheBuildOutsideItStaysItself() throws {
    let box = try Sandboxed()
    let fm = FileManager.default
    for directory in ["w/.x/build/signed", "other"] { try fm.createDirectory(atPath: "\(box.root)/\(directory)", withIntermediateDirectories: true) }
    box.sandbox.writes.append(box.root + "/other")
    box.sandbox.fixed = ["\(box.work)/.x", "\(box.work)/.x/build"]
    box.sandbox.readOnly = ["\(box.work)/.x/build/signed"]
    for denied in ["mv .x/build .x/b", "mv .x x", "mv \(ShellWord.quoted(box.work)) ../other/w", "rm -rf .x/build/signed", "rmdir .x/build/signed", "touch .x/build/signed/f", "rm -rf ../other", "rm -rf .x/build/signed; ln -sFh /etc .x/build"] {
        #expect(try box.sh(denied).status != 0, "\(denied)")
    }
    #expect(fm.fileExists(atPath: box.work + "/.x/build/signed") && fm.fileExists(atPath: box.root + "/other"))
    for allowed in ["mkdir -p .x/build/final/a && touch .x/build/final/a/f .x/f && mv .x/build/final .x/build/f && rm -r .x/build/f", "touch -t 202001010000 . .x/build && chmod 755 . .x", "mkdir ../other/d && rmdir ../other/d"] {
        let answer = try box.sh(allowed)
        #expect(answer.status == 0, "\(allowed): \(answer.out)")
    }
}

@Test func theSandboxReachesNoServiceThatCouldStartAProgramOutsideOrAskForASecret() throws {
    let box = try Sandboxed()
    #expect(try box.sh("lsappinfo list | grep .").status != 0)
    let label = "app.xless.sandbox-test-\(UUID().uuidString)"
    try Data("<plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array></dict></plist>".utf8)
        .write(to: URL(fileURLWithPath: box.work + "/job.plist"))
    #expect(try box.sh("launchctl bootstrap gui/$(id -u) \(ShellWord.quoted(box.work + "/job.plist"))").status != 0)
    #expect(throws: XlessError.self) { try Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], stage: .build) }
    // another sandbox cannot be put on, so nothing that is refused is allowed again
    #expect(try box.run(BuildSandbox.tool, "-p", "(version 1)(allow default)", "/usr/bin/true").status != 0)
    // a process outside is no business of its
    #expect(try box.sh("kill -0 \(getpid())").status != 0)
    // its own it can end
    #expect(try box.sh("sleep 30 & kill $!").status == 0)
}

@Test func theSandboxMountsNothingAndOpensNoDriver() throws {
    let box = try Sandboxed()
    let source = box.work + "/probe.c", probe = box.work + "/probe", mounted = box.work + "/mounted"
    try FileManager.default.createDirectory(atPath: mounted, withIntermediateDirectories: true)
    // what mounts a second /dev (with a terminal that no rule knows) over a directory of the user's, and opens a driver that every process may
    try Data("""
        #include <IOKit/IOKitLib.h>
        #include <string.h>
        #include <sys/mount.h>
        int main(int argc, char **argv) {
            if (!strcmp(argv[1], "mount")) return mount("devfs", argv[2], MNT_NOSUID | MNT_DONTBROWSE, 0) ? 3 : unmount(argv[2], 0) ? 4 : 0;
            io_connect_t driver = 0;
            return IOServiceOpen(IOServiceGetMatchingService(0, IOServiceMatching(argv[2])), mach_task_self(), 0, &driver) ? 3 : 0;
        }
        """.utf8).write(to: URL(fileURLWithPath: source))
    try Shell.run("/usr/bin/cc", ["-o", probe, source, "-framework", "IOKit"], stage: .build)
    for words in [["mount", mounted], ["open", "IOPMrootDomain"]] {
        try Shell.run(probe, words, stage: .build) // outside, it can
        #expect(try box.run(probe, words[0], words[1]).status == 3, "\(words)")
    }
}

@Test func socketsOfOthersAreClosedAndTheBuildsOwnOpen() throws {
    let box = try Sandboxed()
    let connect = "/usr/bin/perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 3)' "
    // (a socket's path is short)
    let outside = "/private/tmp/xless-\(getpid())-\(UInt16.random(in: 0 ... .max)).s"
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    server.arguments = ["-MIO::Socket::UNIX", "-e", "alarm 60; $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die; print \"ready\\n\"; $|=1; print \"\"; $s->accept; $s->accept", outside]
    let pipe = Pipe()
    server.standardOutput = pipe
    try server.run()
    defer {
        server.terminate()
        server.waitUntilExit()
        unlink(outside)
    }
    let until = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: outside), Date() < until { usleep(20_000) }
    #expect(try Shell.run("/bin/sh", ["-c", connect + outside], stage: .build).status == 0)
    #expect(try box.sh(connect + outside).status == 3)
    #expect(try box.sh("cd \(ShellWord.quoted(box.work)) && perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Local => q(s), Listen => 1) or exit 4; exit(IO::Socket::UNIX->new(Peer => q(s)) ? 0 : 3)'").status == 0)
}

@Test func xlessSeesWhetherItIsInTheSandbox() throws {
    #expect(!BuildSandbox.isInForce())
    let box = try Sandboxed()
    var lenient = box.sandbox
    lenient.closed = []
    #expect(try lenient.command("/usr/bin/true", []).arguments.count == 3)
    // (what a process in it sees: `xless` itself is asked in the tests of the command)
    #expect(try box.sh("ls \(BuildSandbox.userHome!)").out.contains("Operation not permitted"))
}
#else
@Test func thereIsNoSandboxElsewhere() {
    #expect(!BuildSandbox.isInForce())
    #expect(throws: XlessError.self) { try BuildSandbox(reads: [], writes: [], secrets: [], closed: []).command("/bin/true", []) }
}
#endif
