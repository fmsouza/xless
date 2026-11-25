import Foundation

/// An image on this machine, as `docker image inspect` shows it.
public struct LocalImage: Equatable, Sendable {
    public var name: String
    public var id: String
    public var architecture: String
    public var labels: [String: String]
    /// The layers of its file system, the first one at the bottom. An image built on another has that one's, then its own.
    public var layers: [String]

    public init(name: String, id: String, architecture: String, labels: [String: String], layers: [String]) {
        self.name = name
        self.id = id
        self.architecture = architecture
        self.labels = labels
        self.layers = layers
    }

    static func parse(_ json: String, name: String) -> LocalImage? {
        struct Inspected: Decodable {
            struct Config: Decodable { var Labels: [String: String]? }
            struct RootFS: Decodable { var Layers: [String]? }
            var Id: String
            var Architecture: String?
            var Config: Config?
            var RootFS: RootFS?
        }
        guard let found = try? JSONDecoder().decode(Inspected.self, from: Data(json.utf8)), !found.Id.isEmpty else { return nil }
        return LocalImage(name: name, id: found.Id, architecture: found.Architecture ?? "", labels: found.Config?.Labels ?? [:], layers: found.RootFS?.Layers ?? [])
    }

    private func label(_ name: String) -> String? { labels[name].flatMap { $0.isEmpty ? nil : $0 } }

    public var sdk: String? { label(ImageLabel.sdk) }
    public var xcode: String? { label(ImageLabel.xcode) }
    public var version: String? { label(ImageLabel.version) }

    /// The image holds all of `base`, and may hold more on top of it.
    public func isBuilt(on base: LocalImage) -> Bool { !base.layers.isEmpty && layers.starts(with: base.layers) }

    /// Why it cannot be the one for `arch` and, when that is given, for Xcode `xcode`: "which …", without its name.
    func mismatch(arch: String, xcode: String?) -> String? {
        for found in [architecture, labels[ImageLabel.arch] ?? ""] where found != arch { return "is for \(found.isEmpty ? "an unknown architecture" : found), not \(arch)" }
        if let xcode, self.xcode != xcode { return "holds the SDK of Xcode \(self.xcode ?? "?") (\(sdk ?? "?")), not Xcode \(xcode)'s" }
        guard let version, let parts = version.wholeMatch(of: /([0-9]+\.[0-9]+\.[0-9]+)(-.*)?/) else { return "holds an unknown xless" }
        // 0.0.0-dev is a source build, as new as its checkout
        if version != "0.0.0-dev", ImageName.isOlder(String(parts.1), than: ImageLabel.minimumVersion) {
            return "holds xless \(version), and this xless needs \(ImageLabel.minimumVersion) or later there"
        }
        return nil
    }
}
