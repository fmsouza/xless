import Foundation
import Crypto
import XlessCore

/// Pinned prebuilt binaries (xcframework archives) that replace CocoaPods dependencies.
public enum BinaryDeps {
    public static func curl(_ url: URL, _ dest: URL) throws {
        try Shell.run("curl", ["-fsSL", "--retry", "3", "-o", dest.path, url.absoluteString], stage: .prepare)
    }

    /// Downloads (once, into `cache/<sha256>`), verifies, extracts and places each dependency under `work`.
    public static func install(
        _ deps: [BinaryDependency], into work: URL, cache: URL,
        fetch: (URL, URL) throws -> Void = BinaryDeps.curl
    ) throws {
        for dep in deps { try install(dep, into: work, cache: cache, fetch: fetch) }
    }

    private static func install(_ dep: BinaryDependency, into work: URL, cache: URL, fetch: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        guard let url = URL(string: dep.url) else {
            throw XlessError(.prepare, "\(dep.url) is not a valid URL", fix: "fix binaryDependencies[].url in the overlay")
        }
        let expected = dep.sha256.lowercased()

        // Placement is checked before any download, so a bad `to` fails fast and nothing is removed outside the work copy.
        let dest = work.appendingPathComponent(dep.to)
        try checkPlacement(dest, work: work)

        let cached = cache.appendingPathComponent(expected)
        if !fm.fileExists(atPath: cached.path) {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let partial = cache.appendingPathComponent(expected + ".partial")
            try? fm.removeItem(at: partial)
            do {
                try fetch(url, partial)
                let actual = try sha256(of: partial)
                guard actual == expected else {
                    throw XlessError(.prepare, "\(dep.url): sha256 is \(actual), overlay pins \(expected)", fix: "verify the download, then update binaryDependencies[].sha256 in the overlay")
                }
                try fm.moveItem(at: partial, to: cached)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
        }

        let temp = Files.temporary.appendingPathComponent("xless-bindep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        if url.path.hasSuffix(".zip") {
            try Shell.run("unzip", ["-q", cached.path, "-d", temp.path], stage: .prepare)
        } else {
            try Shell.run("tar", ["-xf", cached.path, "-C", temp.path], stage: .prepare)
        }
        let extracted = temp.appendingPathComponent(dep.extract)
        guard !dep.extract.split(separator: "/").contains(".."), fm.fileExists(atPath: extracted.path) else {
            throw XlessError(.prepare, "\(dep.url) has no \(dep.extract)", fix: "fix binaryDependencies[].extract to a path inside the archive")
        }

        if let min = dep.fixes?.minimumOSVersion { try setMinimumOSVersion(min, in: extracted) }

        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil || fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        do { try fm.moveItem(at: extracted, to: dest) } catch { try fm.copyItem(at: extracted, to: dest) }  // temp may be on another filesystem
    }

    /// The nearest existing ancestor of `dest`'s parent must resolve (through symlinks) to somewhere inside `work`.
    private static func checkPlacement(_ dest: URL, work: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let root = work.resolvingSymlinksInPath().standardizedFileURL.path
        var ancestor = dest.deletingLastPathComponent()
        while (try? fm.attributesOfItem(atPath: ancestor.path)) == nil, ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw XlessError(.prepare, "\(dest.path) resolves outside the work copy", fix: "remove the symlink in the path, or fix binaryDependencies[].to")
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Sets MinimumOSVersion in every `<slice>/<name>.framework/Info.plist`, keeping each plist's binary or XML format.
    private static func setMinimumOSVersion(_ version: String, in xcframework: URL) throws {
        let fm = FileManager.default
        for slice in (try? fm.contentsOfDirectory(atPath: xcframework.path)) ?? [] {
            let sliceDir = xcframework.appendingPathComponent(slice)
            for item in (try? fm.contentsOfDirectory(atPath: sliceDir.path)) ?? [] where item.hasSuffix(".framework") {
                let plist = sliceDir.appendingPathComponent(item).appendingPathComponent("Info.plist")
                guard fm.fileExists(atPath: plist.path) else { continue }
                var format = PropertyListSerialization.PropertyListFormat.xml
                guard var dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
                    throw XlessError(.prepare, "\(plist.lastPathComponent) in \(item) is not a dictionary", fix: "check the archive contents")
                }
                dict["MinimumOSVersion"] = version
                try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0).write(to: plist)
            }
        }
    }
}
