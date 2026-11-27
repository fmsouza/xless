import Foundation

/// A piece of an Xcode pack that is prepared on its own; the pack's `parts` record the recipe hash of each one present.
public enum PackPart: String, Codable, CaseIterable, Sendable { case sdk, swiftBuild = "swift-build" }

/// Whether a pack's Darwin SDK is its own copy or kept apart from the pack.
public enum FitMode: String, Codable, Sendable { case own, separate }

/// What `pack.json` says about a pack: which Xcode build it was made from and which parts are done. Written last, so a
/// pack with a `pack.json` is a complete one.
public struct PackManifest: Codable, Equatable, Sendable {
    /// The pack layout version (`PackRecipe.format`).
    public var format: Int
    /// The canonical Xcode version, "26.2".
    public var xcode: String
    /// The Xcode build, "17C52".
    public var build: String
    /// "arm64" or "amd64".
    public var arch: String
    /// The Swift that Xcode ships, "6.2.3".
    public var swift: String
    public var mode: FitMode
    /// `PackPart.rawValue` to the recipe hash it was made with; an absent key is an absent part.
    public var parts: [String: String]

    public init(format: Int, xcode: String, build: String, arch: String, swift: String, mode: FitMode, parts: [String: String]) {
        self.format = format; self.xcode = xcode; self.build = build; self.arch = arch
        self.swift = swift; self.mode = mode; self.parts = parts
    }

    public static func load(from url: URL) throws -> PackManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XlessError(.sdk, "pack manifest not found at \(url.path)", fix: "run `xless setup` to prepare the pack again")
            }
            throw XlessError(.sdk, "pack manifest at \(url.path) cannot be read: \(error.localizedDescription)",
                             fix: "make it readable (its permissions), or remove that pack and run `xless setup` again")
        }
        do { return try JSONDecoder().decode(PackManifest.self, from: data) } catch {
            throw XlessError(.sdk, "pack manifest at \(url.path) is invalid: \(error)", fix: "remove that pack and run `xless setup` again")
        }
    }

    /// Writes the manifest beside `url` and renames it into place, so a reader never sees half of it.
    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try enc.encode(self).write(to: tmp)
        #if os(Windows)
        // Windows' rename does not replace an existing file: MoveFileExW with MOVEFILE_REPLACE_EXISTING does.
        do { try OutputFile.move(tmp.path, to: url.path, replacing: true) } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw XlessError(.sdk, (error as? PrivateFile.Refusal)?.cause ?? "cannot write \(url.path): \(error)", fix: "check that its directory is writable")
        }
        #else
        // rename(2) replaces an existing file atomically and also works when there is none; Foundation's
        // `replaceItemAt` fails on Linux (NSCocoaErrorDomain 260) when the destination does not exist yet.
        guard rename(tmp.path, url.path) == 0 else {
            let error = errno
            try? FileManager.default.removeItem(at: tmp)
            throw XlessError(.sdk, "cannot write \(url.path): \(String(cString: strerror(error)))", fix: "check that its directory is writable")
        }
        #endif
    }
}

/// A directory holding everything that depends on one Xcode build, and the manifest that describes it.
public struct XcodePack: Equatable, Sendable {
    public let root: URL
    public let manifest: PackManifest

    public init(root: URL, manifest: PackManifest) { self.root = root; self.manifest = manifest }

    /// The directory name of a pack, "26.2-17C52-arm64".
    public static func name(xcode: String, build: String, arch: String) -> String { "\(xcode)-\(build)-\(arch)" }

    /// The pack at `root`, or nil when there is no `pack.json` there. Throws when there is one that cannot be read.
    public static func open(_ root: URL) throws -> XcodePack? {
        let file = root.appendingPathComponent("pack.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return XcodePack(root: root, manifest: try PackManifest.load(from: file))
    }

    public var name: String { Self.name(xcode: manifest.xcode, build: manifest.build, arch: manifest.arch) }
    public var manifestFile: URL { root.appendingPathComponent("pack.json") }
    /// The SwiftPM config home that holds the installed SDK.
    public var configHome: URL { root.appendingPathComponent("config") }
    public var sdkBundle: URL { configHome.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle") }
    public var meta: URL { root.appendingPathComponent("toolchain-meta.json") }
    /// That Xcode's Swift toolchain (`usr/bin/swiftc` inside).
    public var toolchain: URL { root.appendingPathComponent("toolchain") }
    public var record: URL { root.appendingPathComponent("swift-toolchain.json") }
    /// `swift/bridging` and `module.modulemap`.
    public var include: URL { root.appendingPathComponent("include") }
    /// `swbuild`, `SWBBuildServiceBundle` and the `SwiftBuild_*` bundles.
    public var swiftBuild: URL { root.appendingPathComponent("swift-build") }

    public func has(_ part: PackPart) -> Bool { manifest.parts[part.rawValue] != nil }
}
