import Foundation
import Testing
@testable import XlessRun
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

private func makeSocket(_ path: String) -> Bool {
    #if canImport(Glibc)
    let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard s >= 0 else { return false }
    defer { close(s) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
}

/// Whether Windows is in reach of a build in WSL: told by looking, on any system.
@Suite struct WindowsReachTests {
    /// A root directory with sockets and files.
    private final class Root {
        let path: String
        init() throws {
            path = "/tmp/xless-reach-\(UUID().uuidString.prefix(8))" // (a socket's path is short)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
        func write(_ file: String, _ text: String) throws {
            let url = URL(fileURLWithPath: "\(path)/\(file)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func socket(_ name: String) throws {
            let directory = "\(path)/run/WSL"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            #expect(makeSocket("\(directory)/\(name)"))
        }
        func link(_ name: String, _ to: String) throws { try FileManager.default.createSymbolicLink(atPath: "\(path)/run/WSL/\(name)", withDestinationPath: to) }
        var look: WindowsReach { WindowsReach.look(root: path) }
    }

    @Test func aDistributionAsInstalledHasIt() throws {
        let root = try Root()
        #expect(root.look == WindowsReach()) // a container: none of it is there
        try root.socket("1_interop")
        #expect(root.look.interop) // on, unless it is turned off
        try root.socket("712_interop")
        try root.write("proc/self/mountinfo", """
        22 28 0:20 / /proc rw,nosuid shared:5 - proc proc rw
        70 28 0:40 / /usr/lib/wsl/drivers ro,nosuid,nodev,noatime - 9p drivers ro,aname=drivers;fmask=222;dmask=222,trans=fd
        83 28 0:51 / /mnt/c rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\;uid=1000;gid=1000;symlinkroot=/mnt/,trans=fd
        84 28 0:52 / /mnt/my\\040disk rw,noatime shared:9 master:1 - virtiofs drvfsd rw
        85 28 0:53 / /mnt/e ro,noatime - 9p E:\\134 rw,aname=drvfs
        86 28 0:54 / /mnt/f rw,noatime - 9p F:\\134 ro,aname=drvfs
        87 28 8:32 / / rw,relatime - ext4 /dev/sdc rw

        """)
        #expect(root.look == WindowsReach(interop: true, drives: ["/mnt/c", "/mnt/my disk"]))
        let note = try #require(root.look.note)
        #expect(note.contains("interop is on") && note.contains("/mnt/c, /mnt/my disk") && note.contains("/etc/wsl.conf") && note.contains("[interop] enabled=false")
            && note.contains("[automount] enabled=false") && note.contains("wsl --terminate") && note.contains("root") && !note.contains("\n"))
    }

    /// WSL's first process has its socket also where interop is off; a session has one where it is on.
    @Test func interopThatIsTurnedOffIsOff() throws {
        for conf in ["[interop]\nenabled=false\n", " [Interop] \r\n# x\n Enabled = FALSE # y\r\n", "[interop]\nenabled=0\n", "[interop]\nenabled = \"false\"\n", "[automount]\nenabled=true\n[interop]\nappendWindowsPath=false\nenabled=false"] {
            let root = try Root()
            try root.write("etc/wsl.conf", conf)
            try root.socket("1_interop")
            #expect(root.look == WindowsReach(), "\(conf)")
            #expect(root.look.note == nil)
            // systemd's init is 1 then, and WSL's another one, whose socket has that name as well
            let systemd = try Root()
            try systemd.write("etc/wsl.conf", conf)
            try systemd.socket("2_interop")
            try systemd.link("1_interop", "/run/WSL/2_interop")
            #expect(!systemd.look.interop)
            // the file says so since the distribution was started: it is on still
            try systemd.socket("900_interop")
            #expect(systemd.look.interop)
        }
        for conf in ["", "[interop]\n", "[interop]\nenabled=true\n", "[automount]\nenabled=false\n", "enabled=false\n[interop]\n", "[interop]\nenabled=no\n", "[interop]\n#enabled=false\n", "[interop]\nenabled=false\nenabled=true\n"] {
            let root = try Root()
            try root.write("etc/wsl.conf", conf)
            try root.socket("1_interop")
            #expect(root.look.interop, "\(conf)")
        }
        // a file of that name is none
        let root = try Root()
        try root.write("run/WSL/712_interop", "")
        #expect(!root.look.interop)
    }

    @Test func theLineSaysWhatThereIs() throws {
        let interop = try #require(WindowsReach(interop: true).note), drive = try #require(WindowsReach(drives: ["/mnt/c\u{1B}[2J\n"]).note)
        #expect(interop.contains("[interop]") && !interop.contains("[automount]"))
        #expect(drive.contains("[automount]") && !drive.contains("[interop]") && drive.contains("/mnt/c?[2J?") && drive.unicodeScalars.allSatisfy { $0.value >= 32 })
        #expect(interop.contains("docs/security.md#in-wsl"))
    }
}
