import Crypto
import Foundation
import XlessASC
import XlessCore
import Yams

/// `appstore/media.lock`: which App Store Connect asset each local screenshot, preview or attachment is.
///
/// App Store Connect serves a re-encoded copy of an uploaded image, never the file itself, so a local file cannot be
/// compared with Apple's by content. The lock records, per file, the MD5 of the local file and the `sourceFileChecksum`
/// Apple keeps for the upload it came from. While the local MD5 is unchanged, the file *is* that upload: `pull` keeps
/// the local original instead of downloading Apple's copy, and `store push` uploads nothing. `pull` and `push`
/// write it; people do not edit it.
public struct MediaLock: Codable, Sendable, Equatable {
    public static let fileName = "media.lock"

    public struct Entry: Codable, Sendable, Equatable {
        /// MD5 (hex) of the local file; nil for an upload App Store Connect has that pull could not download (still
        /// processing, or served only as a stream): it is there, with no local file, and `push` must leave it alone.
        public var md5: String?
        /// Apple's `sourceFileChecksum` of the upload this file is; nil for a file never uploaded.
        public var appleChecksum: String?
        /// The App Store Connect resource (appScreenshots / appPreviews) it was read from.
        public var id: String?
        public init(md5: String?, appleChecksum: String? = nil, id: String? = nil) {
            self.md5 = md5; self.appleChecksum = appleChecksum; self.id = id
        }
    }

    /// Path relative to the manifest directory (`en-US/screenshots/APP_IPHONE_67/01-home.png`) → entry.
    public var files: SortedMap<Entry>

    public init(files: [String: Entry] = [:]) { self.files = SortedMap(files) }

    /// The lock of `dir`; empty when there is none or it cannot be read (it is a cache of facts `pull` can re-learn).
    public static func read(_ dir: URL) -> MediaLock {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8),
              let lock = try? YAMLDecoder().decode(MediaLock.self, from: text) else { return MediaLock() }
        return lock
    }

    public func render() throws -> String {
        var options = YAMLEncoder.Options()
        options.allowUnicode = true
        options.width = -1
        let encoder = YAMLEncoder()
        encoder.options = options
        return "# Written by xless store pull and push: which App Store Connect upload each media file is. Do not edit.\n"
            + (try encoder.encode(self))
    }

    /// Writes `dir`'s media.lock (atomically: a crash leaves the old one).
    public func write(to dir: URL) throws {
        try Data(try render().utf8).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The entry whose upload has Apple's checksum `appleChecksum` and whose local file still has its recorded MD5.
    public func unchangedFile(for appleChecksum: String, in dir: URL) -> String? {
        for (path, entry) in files.values.sorted(by: { $0.key < $1.key }) where entry.appleChecksum == appleChecksum {
            if let recorded = entry.md5, ProjectPath.problem(path) == nil, let md5 = MD5Hex.file(dir.appendingPathComponent(path)), md5 == recorded { return path }
        }
        return nil
    }
}

public enum MD5Hex {
    public static func of(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The MD5 of a file, read in 1 MB pieces; nil when it cannot be read.
    public static func file(_ url: URL) -> String? { try? AssetFile.md5(url) }
}
