import Foundation
import XlessCore

/// What an upload left behind (`upload.json` in the build directory): rewritten at every state change, so it keeps the build
/// ID if processing fails or times out.
public struct UploadRecord: Codable, Sendable, Equatable {
    public var buildUploadID: String
    public var buildID: String?
    public var state: String
    public var processingState: String?
    public var messages: [String]
    /// What was uploaded; absent in the record of an earlier xless.
    public var bundleID: String?
    public var version: String?
    public var build: String?
    public var platform: Platform?

    public init(buildUploadID: String, buildID: String?, state: String, processingState: String?, messages: [String],
                bundleID: String? = nil, version: String? = nil, build: String? = nil, platform: Platform? = nil) {
        self.buildUploadID = buildUploadID; self.buildID = buildID; self.state = state; self.processingState = processingState
        self.messages = messages; self.bundleID = bundleID; self.version = version; self.build = build; self.platform = platform
    }

    /// The command that submits the processed build to App Review; nil when it is not processed, or anything in it is not
    /// what App Store Connect gives, or not plain text (it is printed, to be pasted into a shell).
    /// - Parameter project: the options that find the project from any directory (`--dir` or `--config`).
    public func submitCommand(_ project: [String]) -> String? {
        guard processingState == "VALID", let platform, let id = buildID, BuildReference.isBuildID(id), let bundleID, let version,
              bundleID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]*/) != nil, version.wholeMatch(of: /[0-9]+(\.[0-9]+){0,2}/) != nil,
              project.allSatisfy({ TerminalText.escaped($0) == $0 }) else { return nil }
        let words = ["xless", "release", "submit"] + project + ["--app", bundleID, "--platform", platform.rawValue, "--app-version", version, "--build", id]
        return words.map(ShellWord.quoted).joined(separator: " ")
    }

    /// A record on disk. It is only a hint, in a directory that build code can write: whoever uses one asks App Store
    /// Connect for every fact that decides something.
    public enum Found: Sendable {
        case none
        /// A file that is none (the reason is a sentence to show).
        case ignored(String)
        case found(UploadRecord)
    }

    public static let maxSize = 64 * 1024

    /// Reads the record at `url`: a plain file (no link is followed, nothing is waited for) of at most `maxSize` bytes.
    public static func read(_ url: URL) -> Found {
        func ignored(_ why: String) -> Found { .ignored("the record of the last upload, \(url.path), \(why): ignored") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .none
            case ELOOP, EMLINK: return ignored("is a link")
            default: return ignored("cannot be read")
            }
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return ignored("is not a file") }
        guard info.st_size <= maxSize else { return ignored("is too large") }
        guard let data = try? file.read(upToCount: maxSize + 1) ?? Data(), data.count <= maxSize,
              let record = try? JSONDecoder().decode(UploadRecord.self, from: data) else { return ignored("cannot be read") }
        return .found(record)
    }
}
