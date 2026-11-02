import Foundation

/// Ruling R10: the Swift toolchain that compiles an app's code is the one its pinned Xcode ships. Each xless image chain
/// is made from one Xcode (Ruling R8) and carries the open-source Swift release matching that Xcode's Swift
/// (`XCODE_SWIFT_<build>` in versions.env, installed by docker/Dockerfile.sdk under `/opt/xless/toolchains/swift-<ver>`;
/// the image's own Swift when they are the same). The image records it in `/opt/xless/swift-toolchain.json`.
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
    /// (docker/Dockerfile.sdk measures them against the Xcode's own clang: for Swift 6.2.3, `-fdefine-target-os-macros`
    /// and `-D` definitions of the four `TARGET_OS_*` macros it still lacks, docker/toolchain/target-os). The image's
    /// `clang`/`clang++` add them to every compile they run for a Darwin target, never for Linux; Swift Build also gets
    /// them as build settings, for its in-process dependency scanner (libclang) and Swift's Clang importer
    /// (`SwiftBuildEnvironment.overrides`).
    public var clangFlags: [String]?

    public init(version: String, root: String, clangFlags: [String]? = nil) {
        self.version = version; self.root = root; self.clangFlags = clangFlags
    }

    /// The image's record (docker/Dockerfile.sdk).
    public static let imageFile = "/opt/xless/swift-toolchain.json"
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

    /// `XLESS_SWIFT_TOOLCHAIN` (a record file), else the image's record, else the native install's (`NativeLayout`);
    /// nil when there is none (a host without an xless toolchain: the `swift` on PATH compiles, as before Ruling R10).
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage = .build) throws -> SwiftToolchain? {
        let path = env["XLESS_SWIFT_TOOLCHAIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (FileManager.default.fileExists(atPath: imageFile) ? imageFile : NativeLayout(env: env).record.path)
        guard let data = FileManager.default.contents(atPath: path) else {
            if env["XLESS_SWIFT_TOOLCHAIN"].map({ !$0.isEmpty }) ?? false {
                throw XlessError(stage, "XLESS_SWIFT_TOOLCHAIN names \(path), which does not exist", fix: "unset it, or point it at a toolchain record")
            }
            return nil
        }
        do { return try JSONDecoder().decode(SwiftToolchain.self, from: data) } catch {
            throw XlessError(stage, "the Swift toolchain record \(path) is invalid: \(error)", fix: "run xless setup --xcode <Xcode.xip> again (with --docker for the images)")
        }
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
            throw XlessError(stage, "the Swift toolchain \(root) cannot run swiftc: \(error)", fix: "run xless setup --xcode <Xcode.xip> again (with --docker for the images)")
        }
        let line = out.split(separator: "\n").first.map(String.init) ?? ""
        guard let have = Self.parseVersion(out), DottedVersion(have) == DottedVersion(version) else {
            throw XlessError(stage, "\(tool("swiftc")) says \"\(line)\", but the image records Swift \(version)",
                             fix: "run xless setup --xcode <Xcode.xip> again (with --docker for the images)")
        }
        return line
    }

    /// The build stage's check (Ruling R10): the toolchain must be the one the image's Xcode ships (`meta.swiftVersion`,
    /// measured from that Xcode by `xless sdk export`). nil when the image has no toolchain record: refused for a pinned
    /// project, otherwise the `swift` on PATH compiles. Metadata from before Ruling R10 (no `swiftVersion`) is not checked.
    public static func check(_ toolchain: SwiftToolchain?, meta: ToolchainMeta?, pin: String?, stage: Stage = .build) throws -> BuildSwiftRecord? {
        guard let toolchain else {
            guard let pin else { return nil }
            throw XlessError(stage, "xcode: \"\(pin)\" is pinned, but this image records no Swift toolchain (\(imageFile)): it predates Ruling R10",
                             fix: "set up Xcode \(pin) again (xless setup --xcode <path to Xcode \(pin)'s .xip>, with --docker for its images)")
        }
        let compiler = try toolchain.verifiedCompiler(stage: stage)
        if let meta, let apple = meta.swiftVersion, !matches(openSource: toolchain.version, apple: apple) {
            throw XlessError(stage, "this image compiles with Swift \(toolchain.version), but its SDK's Xcode \(XcodePin.xcodeVersion(meta)) (\(meta.xcodeBuild)) ships Swift \(apple)",
                             fix: "set up that Xcode again with xless setup --xcode <Xcode.xip> (with --docker for its images), which installs the toolchain versions.env maps it to (XCODE_SWIFT_\(meta.xcodeBuild))")
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

    /// `Swift 6.2.3 (swift-6.2.3-RELEASE) from /opt/xless/toolchains/swift-6.2.3, Xcode's Swift 6.2.3`.
    public var summary: String {
        let release = compiler.firstMatch(of: /\((swift-[^)]*)\)/).map { " (\($0.1))" } ?? ""
        return "Swift \(version)\(release) from \(root == "/" ? "/usr" : root)" + (xcodeSwiftVersion.map { ", Xcode's Swift \($0)" } ?? "")
    }
}
