import CXlessProcess
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Who can change what is at a path: only root and this user, or somebody else too. (What this user owns every process of this user
/// can change, xless itself among it.)
public enum TrustedPath {
    /// Why somebody else could change the file or directory at `path`, or put another one there; nil: nobody could. Every directory
    /// from / to it is looked at, and, where a name on the way is a link, every one to what that names.
    public static func problem(_ path: String, user: UInt32 = geteuid()) -> String? { problem(path, user: user, volumeFlags: volumeFlags) }

    static func problem(_ path: String, user: UInt32, volumeFlags: (String) -> UInt32?) -> String? {
        guard let entries = entries(to: path) else { return "\(path) is not there" }
        for entry in entries { if let problem = problem(entry: entry, user: user, volumeFlags: volumeFlags) { return problem } }
        return nil
    }

    /// The directories, the links and the file that the system goes through for `path`; nil: it does not get there.
    static func entries(to path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var left = Array(path.split(separator: "/").map(String.init).reversed()), at = "", links = 0
        var entries = ["/"]
        while let name = left.popLast() {
            if name == "." { continue }
            if name == ".." {
                at = String(at[..<(at.lastIndex(of: "/") ?? at.startIndex)])
                continue
            }
            let next = "\(at)/\(name)"
            var st = stat()
            guard lstat(next, &st) == 0 else { return nil }
            entries.append(next)
            guard st.st_mode & S_IFMT == S_IFLNK else {
                at = next
                continue
            }
            links += 1
            guard links <= 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next), !target.isEmpty else { return nil }
            if target.hasPrefix("/") { at = "" }
            left += target.split(separator: "/").map(String.init).reversed()
        }
        return entries
    }

    /// The flags that a volume is mounted with (macOS); nil: not known.
    static func volumeFlags(of path: String) -> UInt32? {
        #if canImport(Darwin)
        var volume = statfs()
        return statfs(path, &volume) == 0 ? volume.f_flags : nil
        #else
        return 0
        #endif
    }

    private static func problem(entry path: String, user: UInt32, volumeFlags: (String) -> UInt32?) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\(path) is not there" }
        let isLink = st.st_mode & S_IFMT == S_IFLNK
        if let problem = problem(path: path, owner: st.st_uid, group: st.st_gid, mode: isLink ? 0 : UInt16(st.st_mode & 0o7777), // (a link's own says nothing)
                                 isDirectory: st.st_mode & S_IFMT == S_IFDIR, user: user) { return problem }
        #if canImport(Darwin)
        switch xless_acl_lets_others_write(path, user) {
        case 0: break
        case 1: return "\(path) can be written by other users (its access control list: ls -led)"
        default: return "the access control list of \(path) cannot be read"
        }
        guard let flags = isLink ? 0 : volumeFlags(path) else { return "the volume of \(path) cannot be looked at" }
        // Every file there is said to be this user's, whoever wrote it.
        if flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 { return "the volume of \(path) ignores who owns its files" }
        #endif
        return nil
    }

    /// `path`'s owner is neither root nor `user`, or others may write it. The groups wheel and admin may (as /Applications has it):
    /// their members are administrators of this Mac.
    static func problem(path: String, owner: UInt32, group: UInt32, mode: UInt16, isDirectory: Bool, user: UInt32) -> String? {
        guard owner == 0 || owner == user else { return "\(path) belongs to another user" }
        let sticky = isDirectory && mode & 0o1000 != 0
        guard mode & 0o002 == 0 || sticky, mode & 0o020 == 0 || sticky || group == 0 || group == 80 else {
            return "\(path) can be written by other users"
        }
        return nil
    }
}
