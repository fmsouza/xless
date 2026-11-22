import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where the store lives: `$XDG_DATA_HOME/xless/vault/` (else `~/.local/share/xless/vault/`), a directory of mode 0700
/// holding `secrets.vault` and the writers' `lock`, both 0600. A symlink, another owner or any group/world permission
/// bit on any of them is refused, never repaired.
public struct VaultLocation: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public var file: URL { directory.appendingPathComponent("secrets.vault") }
    var lockFile: URL { directory.appendingPathComponent("lock") }

    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> VaultLocation {
        // XDG: a relative XDG_DATA_HOME is invalid and ignored.
        let base: URL
        if let xdg = env["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/share", isDirectory: true)
        }
        return VaultLocation(directory: base.appendingPathComponent("xless/vault", isDirectory: true))
    }

    /// Whether the directory entry for the store's file exists at all (without following a symlink).
    public var fileExists: Bool {
        var st = stat()
        return lstat(file.path, &st) == 0
    }

    /// The directory, checked; nil when it does not exist.
    func checkDirectory() throws -> Bool {
        var st = stat()
        guard lstat(directory.path, &st) == 0 else {
            if errno == ENOENT { return false }
            throw VaultError(.io, "cannot inspect \(directory.path): \(String(cString: strerror(errno)))", fix: "check the path's permissions")
        }
        try Self.check(st, path: directory.path, directory: true)
        return true
    }

    /// Creates the directory (0700) and its missing parents, then checks it.
    func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw VaultError(.io, "cannot create \(directory.path): \(String(cString: strerror(errno)))", fix: "check the parent directory's permissions")
        }
        _ = try checkDirectory()
    }

    /// Refuses a symlink, the wrong file type, another owner, or a group/world permission bit.
    static func check(_ st: stat, path: String, directory: Bool) throws {
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK {
            throw VaultError(.unsafePath, "\(path) is a symlink; the secret store refuses to follow one",
                             fix: "replace the symlink with the real \(directory ? "directory" : "file")")
        }
        guard type == (directory ? S_IFDIR : S_IFREG) else {
            throw VaultError(.unsafePath, "\(path) is not a \(directory ? "directory" : "regular file")", fix: "move it aside")
        }
        guard st.st_uid == geteuid() else {
            throw VaultError(.unsafePath, "\(path) belongs to another user (uid \(st.st_uid))",
                             fix: "the secret store must belong to the user running xless; check who created it")
        }
        let wide = st.st_mode & 0o077
        guard wide == 0 else {
            throw VaultError(.unsafePath, "\(path) is accessible to other users (mode \(String(st.st_mode & 0o777, radix: 8)))",
                             fix: "chmod \(directory ? "700" : "600") \(path), and consider whether its content was exposed")
        }
    }
}
