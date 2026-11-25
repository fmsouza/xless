import CXlessProcess
import Foundation
import XlessCore

/// The directory of the agents' sockets: the user's alone (0700, owned by them, no symbolic link), checked before
/// anything in it is bound or connected to. Each agent has a socket of its own, with a random name.
public struct AgentDirectory: Sendable {
    public let path: String
    let user: uid_t

    public init(path: String, user: uid_t = geteuid()) {
        self.path = path
        self.user = user
    }

    public init(env: [String: String] = ProcessInfo.processInfo.environment) { self.init(path: Self.location(env: env)) }

    /// `$XDG_RUNTIME_DIR/xless-agent`; without it the user's own temporary directory on macOS, `/run/user/<uid>` or
    /// `/tmp/xless-agent-<uid>` on Linux. Never in the home directory: a container may have a project of it mounted.
    static func location(env: [String: String]) -> String {
        if let runtime = env["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            return (runtime.hasSuffix("/") ? String(runtime.dropLast()) : runtime) + "/xless-agent"
        }
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if size > 1, size <= buffer.count {
            let dir = String(decoding: buffer[..<(size - 1)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (dir.hasSuffix("/") ? dir : dir + "/") + "xless-agent"
        }
        #else
        var st = stat()
        let run = "/run/user/\(geteuid())"
        if lstat(run, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 { return run + "/xless-agent" }
        #endif
        return "/tmp/xless-agent-\(geteuid())"
    }

    /// Whether the directory is there. Throws when something else is, or a directory others could use.
    @discardableResult
    func verify() throws -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw unsafe("cannot be looked at: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw unsafe("is not a directory") }
        guard st.st_uid == user else { throw unsafe("belongs to another user") }
        guard st.st_mode & 0o7077 == 0 else { throw unsafe("can be used by others (mode \(String(st.st_mode & 0o7777, radix: 8)), not 700)") }
        return true
    }

    /// Makes the directory when it is missing, and checks it.
    func prepare() throws {
        if mkdir(path, 0o700) == 0 {
            // mkdir takes bits off with the umask, never adds any: give the owner theirs back.
            _ = chmod(path, 0o700)
        } else if errno != EEXIST {
            throw AgentError(.unavailable, "the xless agent's directory \(path) cannot be made: \(String(cString: strerror(errno)))",
                             fix: "set XDG_RUNTIME_DIR to a directory of yours")
        }
        try verify()
    }

    /// The agents' sockets: the user's, at most `AgentLimits.sockets`, newest name order aside.
    func sockets() throws -> [String] {
        guard try verify(), let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return Array(names.filter { $0.wholeMatch(of: /[0-9a-f]{16}\.sock/) != nil }.sorted().map { "\(path)/\($0)" }
            .filter { isSocket($0) }.prefix(AgentLimits.sockets))
    }

    func isSocket(_ path: String) -> Bool { identity(of: path) != nil }

    struct Identity: Equatable { let device: UInt64, inode: UInt64 }

    /// A socket of the user's at `path`: which file it is.
    func identity(of path: String) -> Identity? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == user else { return nil }
        return Identity(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino))
    }

    struct Bound { let fd: Int32, path: String, identity: Identity }

    /// A new listening socket in the directory.
    func bind() throws -> Bound {
        try prepare()
        var rng = SystemRandomNumberGenerator()
        let name = String(UInt64.random(in: 0...UInt64.max, using: &rng), radix: 16)
        let path = "\(path)/\(String(repeating: "0", count: 16 - name.count))\(name).sock"
        guard path.utf8.count <= xless_unix_path_max() else {
            throw AgentError(.unavailable, "the path of the xless agent's socket is too long (\(path), at most \(xless_unix_path_max()) bytes)",
                             fix: "set XDG_RUNTIME_DIR to a directory with a shorter path")
        }
        let fd = xless_unix_listen(path, 128)
        guard fd >= 0 else {
            throw AgentError(.unavailable, "the xless agent cannot listen on \(path): \(String(cString: strerror(-fd)))", fix: "set XDG_RUNTIME_DIR to a directory of yours")
        }
        guard let identity = identity(of: path) else {
            close(fd)
            throw unsafe("changed while the agent started")
        }
        return Bound(fd: fd, path: path, identity: identity)
    }

    private func unsafe(_ what: String) -> AgentError {
        AgentError(.unsafePath, "the xless agent's directory \(path) \(what)", fix: "remove it (or point XDG_RUNTIME_DIR at a directory of yours), and run `xless unlock` again")
    }
}
