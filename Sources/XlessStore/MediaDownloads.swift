import Foundation
import XlessASC
import XlessCore

/// A media file `store pull` downloads once the whole listing has been read: Apple's copy, streamed to its staged file.
struct MediaDownload: Sendable {
    /// Relative to the manifest directory.
    var path: String
    var url: URL
    var staged: URL
    var appleChecksum: String?
    var id: String
    /// A preview: App Store Connect may serve only a stream playlist for it.
    var preview: Bool
    /// Counted in the report's `downloaded` (the version's screenshots and previews).
    var counted: Bool
}

enum MediaDownloadOutcome: Sendable, Equatable {
    /// On disk, with its MD5.
    case file(md5: String)
    /// A playlist (HLS), not the video: nothing kept.
    case stream
}

extension StorePull {
    /// How many media files pull downloads at once.
    public static let downloadConcurrency = 4

    /// Downloads `queue`, `downloadConcurrency` at a time, each straight to its staged file (never held whole in
    /// memory); the outcomes by path. The first failure stops the rest.
    func downloadAll(_ queue: [MediaDownload]) async throws -> [String: MediaDownloadOutcome] {
        try await withThrowingTaskGroup(of: (String, MediaDownloadOutcome).self) { group in
            var next = 0
            func start() {
                guard next < queue.count else { return }
                let item = queue[next]
                next += 1
                group.addTask { (item.path, try await fetch(item)) }
            }
            for _ in 0..<Self.downloadConcurrency { start() }
            var out: [String: MediaDownloadOutcome] = [:]
            while let (path, outcome) = try await group.next() {
                out[path] = outcome
                start()
            }
            return out
        }
    }

    func fetch(_ item: MediaDownload) async throws -> MediaDownloadOutcome {
        try ProjectPath.check(item.path, stage: .account)
        try FileManager.default.createDirectory(at: item.staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await download(item.url, item.staged)
        if item.preview, Self.startsWithPlaylist(item.staged) {
            try? FileManager.default.removeItem(at: item.staged)
            return .stream
        }
        return .file(md5: try AssetFile.md5(item.staged))
    }

    static func startsWithPlaylist(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let marker = Data("#EXTM3U".utf8)
        return (try? handle.read(upToCount: marker.count)) == marker
    }
}
