import CXlessProcess
import Foundation
import XlessCore

/// Who is at the other end, by the kernel's word.
struct AgentPeer: Equatable, Sendable {
    let pid: Int32
    let uid: uid_t
    let session: AgentSession
    /// The program it runs (macOS; nil on Linux, where a command that holds secrets hides its /proc entry).
    let executable: AgentExecutable?
}

/// A program, as the file it is.
struct AgentExecutable: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    /// This process's.
    static var current: AgentExecutable? {
        guard let path = AgentLauncher.executablePath else { return nil }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return AgentExecutable(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino))
    }
}

extension AgentSession {
    /// This process's POSIX session.
    public static var current: AgentSession { AgentSession(of: getsid(0)) }

    init(of id: pid_t) { self.init(id: id, leaderStart: id > 0 ? xless_process_start(id) : 0) }

    /// Whether the session's leader (the login shell of a terminal) still runs.
    var isAlive: Bool { isUsable && xless_process_start(id) == leaderStart }
}

/// One message.
struct AgentMessage {
    let header: AgentFrame.Header
    private let pages: SecretPages

    init(header: AgentFrame.Header, pages: SecretPages) { self.header = header; self.pages = pages }

    var code: AgentCode? { AgentCode(rawValue: header.code) }

    /// Reads the body, which must hold nothing more than `read` takes.
    func body<R>(_ read: (inout WireReader) throws -> R) throws -> R {
        try pages.withUnsafeBytes { bytes in
            var reader = WireReader(UnsafeRawBufferPointer(rebasing: bytes[AgentFrame.headerSize..<(AgentFrame.headerSize + header.length)]))
            let r = try read(&reader)
            try reader.end()
            return r
        }
    }
}

/// A connected socket that reads and writes whole messages without blocking, and knows which one process is at its
/// other end: Linux says which process sent each byte (`SCM_CREDENTIALS`), and a pidfd keeps hold of it, so its pid is
/// not another's by the time its session is asked; macOS has the audit token of the process that used the other end
/// last, whose process version tells a reused pid apart. A second process on the same connection is an error.
final class AgentChannel {
    private(set) var fd: Int32
    private(set) var pid: Int32 = 0
    private var pidfd: Int32 = -1
    private var input = SecretPages(count: AgentFrame.headerSize)
    private var filled = 0
    private var output: [SecretPages] = []
    private var sent = 0

    /// Owns `fd` from here on, also when it throws: when the other end is another user's.
    init(fd: Int32) throws {
        self.fd = fd
        _ = xless_unix_passcred(fd)
        guard xless_unix_peer_uid(fd) == Int(geteuid()) else {
            throw AgentError(.unsafePath, "the other end of the xless agent's socket belongs to another user", fix: "remove the socket's directory and run `xless unlock` again")
        }
    }

    deinit { end() }

    /// Closes it.
    func end() {
        if fd >= 0 { close(fd) }
        if pidfd >= 0 { close(pidfd) }
        fd = -1
        pidfd = -1
    }

    /// The next message, nil when it has not all come yet. Throws `gone` when the other end closed.
    func next(limit: Int) throws -> AgentMessage? {
        while true {
            var need = AgentFrame.headerSize
            if filled >= AgentFrame.headerSize, let header = try input.withUnsafeBytes({ try AgentFrame.header($0) }) {
                guard header.length <= limit else { throw AgentError.malformed("\(header.length) bytes") }
                need += header.length
                if filled == need {
                    defer {
                        input = SecretPages(count: AgentFrame.headerSize)
                        filled = 0
                    }
                    return AgentMessage(header: header, pages: input)
                }
                if input.count < need {
                    let larger = SecretPages(count: need)
                    input.withUnsafeBytes { from in larger.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: from[..<filled])) } }
                    input = larger
                }
            }
            var sender: Int32 = 0, uid: UInt32 = 0
            let n = input.withUnsafeMutableBytes { xless_unix_recv(fd, $0.baseAddress! + filled, need - filled, &sender, &uid) }
            if n == -Int(EAGAIN) || n == -Int(EWOULDBLOCK) { return nil }
            guard n > 0 else { throw AgentError.gone }
            try note(sender: sender)
            filled += n
        }
    }

    private func note(sender: Int32) throws {
        #if os(Linux)
        if sender == pid { return }
        guard pid == 0 else { throw AgentError.malformed("another process speaks") }
        let held = xless_pidfd_open(sender)
        guard held >= 0 else {
            throw AgentError(.unavailable, "the system cannot say who is at the other end of a socket: \(String(cString: strerror(-held)))",
                             fix: "the xless agent needs Linux 5.3 or newer")
        }
        pid = sender
        pidfd = held
        #endif
    }

    /// Who is at the other end. It is there now: on Linux the process that sent what was read since `next` first returned
    /// a message still runs, so the session asked of its pid is its own.
    func peer() throws -> AgentPeer {
        #if os(Linux)
        guard pidfd >= 0 else { throw AgentError.gone }
        let session = AgentSession(of: getsid(pid))
        guard xless_pidfd_alive(pidfd) == 1 else { throw AgentError.gone }
        return AgentPeer(pid: pid, uid: geteuid(), session: session, executable: nil)
        #else
        var peer = xless_peer()
        guard xless_peer_of(fd, &peer) == 0 else { throw AgentError.gone }
        if pid != 0, pid != peer.pid { throw AgentError.malformed("another process speaks") }
        pid = peer.pid
        return AgentPeer(pid: peer.pid, uid: peer.uid, session: AgentSession(of: peer.sid),
                         executable: peer.exe_inode == 0 ? nil : AgentExecutable(device: peer.exe_device, inode: peer.exe_inode))
        #endif
    }

    /// Sends what is to be sent and waits for the next message; nil when it has not come in time.
    func wait(limit: Int, milliseconds: Int) throws -> AgentMessage? {
        let deadline = xless_clock_awake_ms() + Int64(milliseconds)
        while true {
            try flush()
            if let message = try next(limit: limit) { return message }
            let left = deadline - xless_clock_awake_ms()
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN) | (hasOutput ? Int16(POLLOUT) : 0), revents: 0)
            _ = poll(&p, 1, Int32(left))
        }
    }

    func send(_ message: SecretPages) { output.append(message) }

    var hasOutput: Bool { !output.isEmpty }

    /// Sends what the other end takes now. Throws `gone` when it closed.
    func flush() throws {
        while let first = output.first {
            let n = first.withUnsafeBytes { xless_unix_send(fd, $0.baseAddress! + sent, $0.count - sent) }
            if n == -Int(EAGAIN) || n == -Int(EWOULDBLOCK) { return }
            guard n >= 0 else { throw AgentError.gone }
            sent += n
            if sent == first.count {
                output.removeFirst()
                sent = 0
            }
        }
    }
}
