import Crypto
import Foundation
import Yams

/// `appstore/media.lock`: which App Store Connect asset each local screenshot or preview is.
///
/// App Store Connect serves a re-encoded copy of an uploaded image, never the file itself, so a local file cannot be
/// compared with Apple's by content. The lock records, per file, the MD5 of the local file and the `sourceFileChecksum`
/// Apple keeps for the upload it came from. While the local MD5 is unchanged, the file *is* that upload: `pull` keeps
/// the local original instead of downloading Apple's copy, and `store push` (#95) uploads nothing. `pull` and `push`
/// write it; people do not edit it.
public struct MediaLock: Codable, Sendable, Equatable {
    public static let fileName = "media.lock"

    public struct Entry: Codable, Sendable, Equatable {
        /// MD5 (hex) of the local file.
        public var md5: String
        /// Apple's `sourceFileChecksum` of the upload this file is; nil for a file never uploaded.
        public var appleChecksum: String?
        /// The App Store Connect resource (appScreenshots / appPreviews) it was read from.
        public var id: String?
        public init(md5: String, appleChecksum: String? = nil, id: String? = nil) {
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

    /// The entry whose upload has Apple's checksum `appleChecksum` and whose local file still has its recorded MD5.
    public func unchangedFile(for appleChecksum: String, in dir: URL) -> String? {
        for (path, entry) in files.values.sorted(by: { $0.key < $1.key }) where entry.appleChecksum == appleChecksum {
            if let md5 = MD5Hex.file(dir.appendingPathComponent(path)), md5 == entry.md5 { return path }
        }
        return nil
    }
}

public enum MD5Hex {
    public static func of(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The MD5 of a file, read in 1 MB pieces; nil when it cannot be read.
    public static func file(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        do {
            // At the end Foundation answers empty data, or nil on Linux.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        } catch { return nil }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
