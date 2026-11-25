import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file in a directory that build code can write, read where a secret is in reach: whatever the build put there instead (a pipe,
/// which nobody writes; a device, which never ends; a link to a file of the user's; a file that no memory holds), the read ends at once.
public enum PlainFile {
    public enum Unread: Error, Equatable {
        case absent, link, notFile, tooLarge, failed

        /// What is said of the file.
        public var reason: String {
            switch self {
            case .absent: "does not exist"
            case .link: "is a link"
            case .notFile: "is not a file"
            case .tooLarge: "is too large"
            case .failed: "cannot be read"
            }
        }
    }

    /// More than a property list, a JSON record or an Xcode project ever is.
    public static let maxSize = 64 << 20

    public static func read(_ url: URL, maxSize: Int = maxSize, followsLinks: Bool = false) throws(Unread) -> Data {
        #if os(Windows)
        if followsLinks { // No secret and no trust hangs on it: it may be on another machine or in WSL, where `InputFile` reads nothing.
            guard FileManager.default.fileExists(atPath: url.path) else { throw .absent }
            guard let data = try? Data(contentsOf: url) else { throw .failed }
            guard data.count <= maxSize else { throw .tooLarge }
            return data
        }
        do { return try InputFile.read(url.path, limit: maxSize, throughLinks: false) } catch let refusal as PrivateFile.Refusal {
            switch refusal.kind {
            case .missing: throw .absent
            case .link: throw .link
            case .notFile: throw .notFile
            case .tooLarge: throw .tooLarge
            default: throw .failed
            }
        } catch { throw .failed }
        #else
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followsLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw .absent
            case ELOOP, EMLINK: throw .link
            default: throw .failed
            }
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notFile }
        guard info.st_size <= maxSize else { throw .tooLarge }
        guard let data = try? file.read(upToCount: maxSize + 1) ?? Data() else { throw .failed }
        guard data.count <= maxSize else { throw .tooLarge } // it grew
        return data
        #endif
    }
}
