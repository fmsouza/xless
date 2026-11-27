import Foundation

public struct PlatformSDKInfo: Codable, Sendable, Equatable {
    public var sdkName: String
    public var sdkVersion: String
    public var sdkBuild: String
    public var platformName: String
    public var platformVersion: String
    public var platformBuild: String

    public init(sdkName: String, sdkVersion: String, sdkBuild: String, platformName: String, platformVersion: String, platformBuild: String) {
        self.sdkName = sdkName; self.sdkVersion = sdkVersion; self.sdkBuild = sdkBuild
        self.platformName = platformName; self.platformVersion = platformVersion; self.platformBuild = platformBuild
    }
}

public struct ToolchainMeta: Codable, Sendable, Equatable {
    public static let clangCompiler = "com.apple.compilers.llvm.clang.1_0"

    public var xcodeVersion: String
    public var xcodeBuild: String
    public var buildMachineOSBuild: String
    public var compiler: String
    /// Keyed by Platform.sdkKey ("iphoneos", "macosx").
    public var platforms: [String: PlatformSDKInfo]
    /// The Swift this Xcode ships, from its toolchain's `swift --version` (e.g. "6.2.3"; Ruling R10). nil in metadata
    /// exported before that ruling.
    public var swiftVersion: String?

    public init(xcodeVersion: String, xcodeBuild: String, buildMachineOSBuild: String, compiler: String, platforms: [String: PlatformSDKInfo],
                swiftVersion: String? = nil) {
        self.xcodeVersion = xcodeVersion; self.xcodeBuild = xcodeBuild
        self.buildMachineOSBuild = buildMachineOSBuild; self.compiler = compiler; self.platforms = platforms
        self.swiftVersion = swiftVersion
    }

    public func sdk(for p: Platform) throws -> PlatformSDKInfo {
        guard let s = platforms[p.sdkKey] else {
            throw XlessError(.sdk, "toolchain-meta.json has no \(p.sdkKey) SDK", fix: "re-run `xless sdk export` on the Mac")
        }
        return s
    }

    public static func load(from url: URL) throws -> ToolchainMeta {
        guard let data = try? Data(contentsOf: url) else {
            throw XlessError(.sdk, "toolchain metadata not found at \(url.path)", fix: "prepare the Xcode's pack: `xless setup --xcode <Xcode.xip>` (`--docker` for xless run --docker)")
        }
        do { return try JSONDecoder().decode(ToolchainMeta.self, from: data) } catch {
            throw XlessError(.sdk, "toolchain metadata at \(url.path) is invalid: \(error)", fix: "re-run `xless sdk export` on the Mac")
        }
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url)
    }

    /// Where a native setup of before the Xcode packs writes it (`xless sdk install`): XLESS_TOOLCHAIN_META, else
    /// $XDG_CONFIG_HOME|~/.config /xless/toolchain-meta.json. A command reads the Xcode's metadata at `XcodeEnvironment.meta`.
    public static func defaultLocation(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = env["XLESS_TOOLCHAIN_META"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return olderLocation(env: env)
    }

    /// Where an older xless wrote it, whatever `XLESS_TOOLCHAIN_META` says now (that variable is live: it names a file the person uses,
    /// which `xless clean` must never take for an older install's): $XDG_CONFIG_HOME|~/.config /xless/toolchain-meta.json.
    public static func olderLocation(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(env["HOME"] ?? "~")/.config"
        return URL(fileURLWithPath: "\(base)/xless/toolchain-meta.json")
    }
}
