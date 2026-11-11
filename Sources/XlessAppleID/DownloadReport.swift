import Foundation
import XlessCore

/// What `xless xcode download` tells the user around the downloads.
public enum DownloadReport {
    /// Whether a downloaded .xip (by its SHA-256) is one of versions.env's supported Xcodes.
    public static func identity(sha256: String, known: [KnownXcode]) -> String {
        let sum = sha256.lowercased()
        if let x = known.first(where: { $0.xipSHA256.contains { $0.lowercased() == sum } }) {
            return "supported: Xcode \(x.shortVersion) (\(x.build))"
        }
        return "not in xless's supported table yet; to add it, record XCODE_XIP_SHA256_<build>=\"\(sum)\" in versions.env"
    }

    /// Bytes left to download for `files` into `dir`: a finished file counts 0, a `.part` counts what it lacks, a file
    /// whose size Apple did not list counts 0.
    public static func bytesStillNeeded(_ files: [AppleDownload.File], in dir: URL) -> Int64 {
        files.reduce(0) { total, f in
            guard let size = f.fileSize, size > 0,
                  !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f.name).path) else { return total }
            return total + max(0, size - DeveloperDownloads.fileSize(dir.appendingPathComponent(f.name + ".part")))
        }
    }

    /// Decimal sizes: "3.2 GB", "850 MB".
    public static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
    }
}
