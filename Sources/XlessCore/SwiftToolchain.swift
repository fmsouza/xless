import Foundation

/// Ruling R10: the Swift toolchain that compiles an app's code is the one its pinned Xcode ships. Each Xcode pack holds
/// the open-source Swift release matching that Xcode's Swift (`XCODE_SWIFT_<build>` in versions.env), fitted by
/// scripts/fit-toolchain.sh into `<pack>/toolchain` (or the image's own Swift when they are the same), and records it in
/// `<pack>/swift-toolchain.json` (`XcodeEnvironment.toolchain`).
///
/// Every compile of app code uses it: Swift Build's toolset and `PATH` (React Native and the `xcodebuild` shim), and for
/// the other project kinds the build stage puts its `usr/bin` before the image's own Swift on `PATH` (`activate`), so
/// `swift build` (SwiftPM apps, Tauri's Swift packages), `clang`/`clang++` (Tauri's native code, cargo's C builds) and
/// `xcrun swiftc`/`xcrun clang` in build phases resolve to it. The build engine stays the image's own Swift
/// (`engineBin`): Swift Build's `swbuild` and SwiftPM's `dump-pif`, whose PIF that `swbuild` reads, are built with it.
public struct SwiftToolchain: Codable, Sendable, Equatable {
    /// The release `swiftc --version` names, e.g. "6.2.3" (`Swift version 6.2.3 (swift-6.2.3-RELEASE)`).
    public var version: String
    /// The toolchain's root: its tools are in `<root>/usr/bin` ("/" for the image's own Swift).
    public var root: String
    /// Flags Apple's clang of the same Xcode applies by default for Darwin targets and this toolchain's clang does not
    /// (docker/Dockerfile measures them against the Xcode's own clang: for Swift 6.2.3, `-fdefine-target-os-macros`
    /// and `-D` definitions of the four `TARGET_OS_*` macros it still lacks, docker/toolchain/target-os). The image's
    /// `clang`/`clang++` add them to every compile they run for a Darwin target, never for Linux; Swift Build also gets
    /// them as build settings, for its in-process dependency scanner (libclang) and Swift's Clang importer
    /// (`SwiftBuildEnvironment.overrides`).
    public var clangFlags: [String]?

    public init(version: String, root: String, clangFlags: [String]? = nil) {
        self.version = version; self.root = root; self.clangFlags = clangFlags
    }

    /// Where the image's own Swift lives: the swift:<SWIFT_VERSION>-jammy base, which built `swbuild`.
    public static let engineBin = "/usr/bin"

    /// The build engine's `swift` (SwiftPM's `dump-pif`, whose PIF the image's `swbuild` reads): the image's own when
    /// it records a toolchain, else the `swift` on PATH.
    public static func engineSwift(_ toolchain: SwiftToolchain?) -> String {
        toolchain == nil ? "swift" : engineBin + "/swift"
    }

    public var bin: URL { URL(fileURLWithPath: root).appendingPathComponent("usr/bin") }
    public var include: URL { URL(fileURLWithPath: root).appendingPathComponent("usr/include") }
    public func tool(_ name: String) -> String { bin.appendingPathComponent(name).path }
    /// True when it is the image's own Swift (nothing to put on PATH).
    public var isEngine: Bool { bin.standardizedFileURL.path == Self.engineBin }

    /// The release of the image's own Swift (`engineBin`'s `swiftc --version`), measured once; nil where there is none
    /// (no Swift there, or not Linux: only the images and a Linux host build with an engine).
    public static let engineRelease: String? = {
        #if os(Linux)
        let swiftc = engineBin + "/swiftc"
        guard FileManager.default.isExecutableFile(atPath: swiftc),
              let out = try? Shell.run(swiftc, ["--version"], stage: .build).stdout else { return nil }
        return parseVersion(out)
        #else
        return nil
        #endif
    }()

    /// True when its SwiftPM is the engine's release (`engine`, by default `engineRelease`): the engine itself, or a copy
    /// of the same release, as an Xcode pack whose Swift is the image's own holds (fitted to its SDK, so its tools stay on
    /// PATH: `isEngine` is false). It then builds as the engine's SwiftPM does, with the same arguments and in the same
    /// scratch directory, so its products are those of an image with that Xcode built in. Only another release builds its
    /// own way (Ruling R10). The engine's way (the triple, no product named) is SwiftPM 6.4's, so a copy below 6.4 never
    /// takes it, even where the engine is that release too (a Linux host's own Swift).
    public func isEngineRelease(_ engine: String? = SwiftToolchain.engineRelease) -> Bool {
        if isEngine { return true }
        guard let engine = engine.flatMap(DottedVersion.init), let mine = DottedVersion(version) else { return false }
        return engine == mine && mine >= Self.engineWayFrom
    }

    /// The first SwiftPM release that builds as the images' engine does (`isEngineRelease`): 6.4, measured.
    static let engineWayFrom = DottedVersion("6.4")!

    /// The record at `record`: a `root` relative to the record's directory (a pack's, which can be moved) is made
    /// absolute; an absolute one (an older record, `XLESS_SWIFT_TOOLCHAIN`'s) stays as it is.
    public static func load(record: URL, stage: Stage = .build) throws -> SwiftToolchain {
        guard let data = FileManager.default.contents(atPath: record.path) else {
            throw XlessError(stage, "the Swift toolchain record \(record.path) does not exist", fix: "run xless setup --xcode <Xcode.xip> again")
        }
        var toolchain: SwiftToolchain
        do { toolchain = try JSONDecoder().decode(SwiftToolchain.self, from: data) } catch {
            throw XlessError(stage, "the Swift toolchain record \(record.path) is invalid: \(error)", fix: "prepare the Xcode's pack again: xless setup --xcode <Xcode.xip> (xless setup --docker --xcode … for xless run --docker)")
        }
        if !toolchain.root.hasPrefix("/") {
            // `.` and `..` removed by hand: Foundation's standardizing would also rewrite the directory (/private/var → /var).
            var parts: [Substring] = []
            for part in (record.deletingLastPathComponent().path + "/" + toolchain.root).split(separator: "/") where part != "." {
                if part == ".." { _ = parts.popLast() } else { parts.append(part) }
            }
            toolchain.root = "/" + parts.joined(separator: "/")
        }
        return toolchain
    }

    /// `path` with `bin` inserted right before the image's own Swift (`/usr/bin`), so it wins over that Swift and
    /// nothing else (the image's shim directories stay first); at the front when `/usr/bin` is not on it. Unchanged for
    /// the image's own Swift, and when `bin` is already there.
    public func path(_ path: String?) -> String {
        let entries = (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !isEngine, !entries.contains(bin.path) else { return entries.joined(separator: ":") }
        var out = entries
        out.insert(bin.path, at: entries.firstIndex(of: Self.engineBin) ?? 0)
        return out.joined(separator: ":")
    }

    /// The version in `swift --version` / `swiftc --version` output: open-source `Swift version 6.2.3 (swift-6.2.3-RELEASE)`
    /// or Apple's `Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)` → "6.2.3".
    public static func parseVersion(_ output: String) -> String? {
        guard let m = output.firstMatch(of: /Swift version (\d+(?:\.\d+){0,2})\b/) else { return nil }
        return String(m.1)
    }

    /// The map's rule: an Xcode's Swift (Apple's, e.g. 6.2.3) maps to the open-source release with the same major.minor
    /// and the highest patch not above Apple's. This checks the first two parts of that rule (the highest-patch choice is
    /// made when the map entry is written, versions.env).
    public static func matches(openSource: String, apple: String) -> Bool {
        guard let o = DottedVersion(openSource), let a = DottedVersion(apple) else { return false }
        return o.parts[0] == a.parts[0] && o.parts[1] == a.parts[1] && o.parts[2] <= a.parts[2]
    }

    /// Runs `<bin>/swiftc --version` and checks it names `version`; returns its first line.
    public func verifiedCompiler(stage: Stage = .build) throws -> String {
        let out: String
        do { out = try Shell.run(tool("swiftc"), ["--version"], stage: stage).stdout } catch {
            throw XlessError(stage, "the Swift toolchain \(root) cannot run swiftc: \(error)", fix: "prepare the Xcode's pack again: xless setup --xcode <Xcode.xip> (xless setup --docker --xcode … for xless run --docker)")
        }
        let line = out.split(separator: "\n").first.map(String.init) ?? ""
        guard let have = Self.parseVersion(out), DottedVersion(have) == DottedVersion(version) else {
            throw XlessError(stage, "\(tool("swiftc")) says \"\(line)\", but the toolchain's record (swift-toolchain.json) says Swift \(version)",
                             fix: "prepare the Xcode's pack again: xless setup --xcode <Xcode.xip> (xless setup --docker --xcode … for xless run --docker)")
        }
        return line
    }

    /// The build stage's check (Ruling R10): the toolchain must be the one the pack's Xcode ships (`meta.swiftVersion`,
    /// measured from that Xcode by `xless sdk export`). nil when the Xcode has no toolchain record: refused for a pinned
    /// project, otherwise the `swift` on PATH compiles. Metadata from before Ruling R10 (no `swiftVersion`) is not checked.
    public static func check(_ toolchain: SwiftToolchain?, meta: ToolchainMeta?, pin: String?, stage: Stage = .build) throws -> BuildSwiftRecord? {
        guard let toolchain else {
            guard let pin else { return nil }
            throw XlessError(stage, "xcode: \"\(pin)\" is pinned, but its Xcode records no Swift toolchain (no swift-toolchain.json): it was set up before Ruling R10",
                             fix: "set up Xcode \(pin) again (xless setup --xcode <path to Xcode \(pin)'s .xip>, with --docker for xless run --docker)")
        }
        let compiler = try toolchain.verifiedCompiler(stage: stage)
        if let meta, let apple = meta.swiftVersion, !matches(openSource: toolchain.version, apple: apple) {
            throw XlessError(stage, "the Xcode's pack compiles with Swift \(toolchain.version), but its SDK's Xcode \(XcodePin.xcodeVersion(meta)) (\(meta.xcodeBuild)) ships Swift \(apple)",
                             fix: "prepare that Xcode's pack again with xless setup --xcode <Xcode.xip> (with --docker for xless run --docker), which installs the toolchain versions.env maps it to (XCODE_SWIFT_\(meta.xcodeBuild))")
        }
        return BuildSwiftRecord(version: toolchain.version, root: toolchain.root, compiler: compiler, xcodeSwiftVersion: meta?.swiftVersion)
    }

    /// Puts `bin` on this process's PATH (`path(_:)`), so every tool the build runs from here inherits it.
    public func activate() {
        let current = ProcessInfo.processInfo.environment["PATH"]
        let new = path(current)
        if new != current { setenv("PATH", new, 1) }
    }
}

/// The compiler the build stage used, in `BuildSDKRecord` (`sdk.json`) and the log.
public struct BuildSwiftRecord: Codable, Sendable, Equatable {
    /// The open-source release, e.g. "6.2.3".
    public var version: String
    public var root: String
    /// `swiftc --version`'s first line.
    public var compiler: String
    /// The Swift of the SDK's Xcode (`ToolchainMeta.swiftVersion`), when the metadata has it.
    public var xcodeSwiftVersion: String?

    public init(version: String, root: String, compiler: String, xcodeSwiftVersion: String?) {
        self.version = version; self.root = root; self.compiler = compiler; self.xcodeSwiftVersion = xcodeSwiftVersion
    }

    /// `Swift 6.2.3 (swift-6.2.3-RELEASE) from /xcodes/26.2-17C52-arm64/toolchain, Xcode's Swift 6.2.3`.
    public var summary: String {
        let release = compiler.firstMatch(of: /\((swift-[^)]*)\)/).map { " (\($0.1))" } ?? ""
        return "Swift \(version)\(release) from \(root == "/" ? "/usr" : root)" + (xcodeSwiftVersion.map { ", Xcode's Swift \($0)" } ?? "")
    }
}

extension DarwinSDK {
    /// Xcode's `clang` (or `clang++`), else that of the image's Swift, else the one on PATH.
    public func compiler(_ name: String, swift: SwiftToolchain?) -> String { isXcode ? tool(name).path : swift?.tool(name) ?? name }
}
