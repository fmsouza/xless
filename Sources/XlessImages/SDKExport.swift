import Foundation

/// The Darwin SDK of an Xcode that an earlier `xless setup` left in the cache: an image is built from it without that Xcode.
public struct SDKExport: Equatable, Sendable {
    public var xcode: String
    public var directory: String

    public init(xcode: String, directory: String) { self.xcode = xcode; self.directory = directory }

    /// Those for `arch` in xless's cache directory, the newest Xcode's last.
    public static func all(in cache: URL, arch: String) -> [SDKExport] {
        let sdk = cache.appendingPathComponent("sdk")
        return ((try? FileManager.default.contentsOfDirectory(atPath: sdk.path)) ?? []).compactMap { name in
            guard let match = name.wholeMatch(of: /xcode([0-9]+\.[0-9]+(\.[0-9]+)?)-[A-Za-z0-9]+/),
                  FileManager.default.fileExists(atPath: sdk.appendingPathComponent("\(name)/\(arch)/darwin.xtoolsdk").path) else { return nil }
            return SDKExport(xcode: String(match.1), directory: sdk.appendingPathComponent(name).path)
        }.sorted { $0.xcode == $1.xcode ? $0.directory < $1.directory : ImageName.isOlder($0.xcode, than: $1.xcode) }
    }
}
