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

    public var version: String? { label(ImageLabel.version) }
    /// Which xless built it (`ImageLabel.id`).
    public var imageID: String? { label(ImageLabel.id) }

    /// The image holds all of `base`, and may hold more on top of it.
    public func isBuilt(on base: LocalImage) -> Bool { !base.layers.isEmpty && layers.starts(with: base.layers) }

    /// Why it cannot be the one of the xless named `version` (the part of the tag that names it) for `arch`: "which …", without
    /// its name. An image made by another xless of the same version (the same tag) is the same, so its ID starts with the
    /// release (`v<version>-`) or with the commit (`<version>-`), then 12 hex.
    func mismatch(arch: String, version: String) -> String? {
        for found in [architecture, labels[ImageLabel.arch] ?? ""] where found != arch { return "is for \(found.isEmpty ? "an unknown architecture" : found), not \(arch)" }
        guard let id = imageID else { return "holds an unknown xless (it has no \(ImageLabel.id) label)" }
        func isIt(_ start: String) -> Bool {
            guard id.hasPrefix(start) else { return false }
            let pins = id.dropFirst(start.count)
            return pins.count == 12 && pins.allSatisfy(\.isHexDigit)
        }
        guard isIt("v\(version)-") || isIt("\(version)-") else { return "is the image of xless \(id), not of \(version)" }
        return nil
    }
}
