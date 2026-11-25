import Crypto
import Foundation
import XlessCore

/// The toolchains that some kinds of app need besides xless's own image: a Dockerfile shipped with xless for each, which is
/// built on the local image of the project's Xcode. They are the only Dockerfiles that xless builds by itself.
public enum Kit: String, CaseIterable, Sendable {
    case tauri
    case reactNative = "react-native"

    /// A kit by the name of what it is for.
    public init?(named name: String) {
        switch name {
        case "tauri", "cargo": self = .tauri
        case "react-native", "expo": self = .reactNative
        default: return nil
        }
    }

    public static let names = ["tauri", "cargo", "react-native", "expo"]

    /// The kit of an overlay's `type:`.
    public init(overlayType: String?) { self = overlayType == "react-native" ? .reactNative : .tauri }

    public var apps: String { self == .tauri ? "Tauri and Cargo apps" : "React Native and Expo apps" }
    public var holds: String { self == .tauri ? "Node, pnpm and Rust's installer" : "Node, pnpm, Ruby, Bundler and hermesc" }
    /// How long the first build of it takes, roughly.
    public var estimate: String { self == .tauri ? "~1 min" : "~3 min" }

    public func directory(share: URL) -> URL { share.appendingPathComponent("docker/\(rawValue)") }

    /// Its image on `base`: the name follows the Xcode, also where `base` has the tag without one.
    public func image(on base: LocalImage) -> String { "\(ImageName.base(arch: base.architecture, xcode: base.xcode ?? ""))-\(rawValue)" }

    public enum State: Equatable, Sendable {
        case current(LocalImage)
        case missing
        /// It is there, but why it is not the one.
        case stale(String)
    }

    /// The SHA-256 of what it is built from: every file of its folder, by path.
    public func recipe(share: URL) throws -> String {
        // (an install can be links: what they lead to is what docker builds)
        let directory = directory(share: share).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Dockerfile").path) else {
            throw ImageProblem("xless's Dockerfile for \(apps) is missing: \(directory.path)/Dockerfile", fix: "install xless again, or set XLESS_SHARE to its share directory")
        }
        var hash = SHA256()
        let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
        guard paths.contains("Dockerfile") else {
            throw ImageProblem("\(directory.path) cannot be listed, which xless's Dockerfile for \(apps) is in", fix: "check its permissions, or install xless again")
        }
        for path in paths {
            let file = directory.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let content = try Data(contentsOf: file)
            hash.update(data: Data("\(path)\0\(content.count)\0".utf8))
            hash.update(data: content)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// docker's arguments that build it on `base`. Nothing is in the context but its folder of xless's share directory, and no
    /// argument or layer holds anything of a project or a person.
    public func build(on base: LocalImage, share: URL, builder: String? = nil) throws -> [String] {
        ["build"] + (builder.map { ["--builder", $0] } ?? []) + ["--platform", "linux/\(base.architecture)", "--pull=false", "--provenance=false", "--build-arg", "XLESS_IMAGE=\(base.name)",
         "--label", "\(ImageLabel.kit)=\(rawValue)", "--label", "\(ImageLabel.kitBase)=\(base.id)", "--label", "\(ImageLabel.kitRecipe)=\(try recipe(share: share))",
         "-t", image(on: base), directory(share: share).path]
    }
}
