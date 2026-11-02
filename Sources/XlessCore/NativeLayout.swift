import Foundation

/// Where `xless setup` (native, the default on Linux) installs what the images otherwise carry: the pinned xtool and
/// rcodesign, the open-source Swift toolchain of the SDK's Xcode (Ruling R10) and that toolchain's record. Its root is
/// `$XLESS_NATIVE_HOME`, else `$XDG_DATA_HOME/xless-native`, else `~/.local/share/xless-native` (not
/// `~/.local/share/xless`, which install.sh replaces on every upgrade). The SDK and its metadata stay where
/// `xless sdk install` puts them (`DarwinSDKLocator`, `ToolchainMeta.defaultLocation`).
///
///     toolchains/swift-<version>/usr/bin/…   tools/xtool-<version>/AppRun   tools/rcodesign-<version>/rcodesign
///     bin/xtool, bin/rcodesign (links)       swift-toolchain.json (written last: a `SwiftToolchain` record)
public struct NativeLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        if let r = env["XLESS_NATIVE_HOME"], !r.isEmpty { root = URL(fileURLWithPath: r) }
        else if let d = env["XDG_DATA_HOME"], !d.isEmpty { root = URL(fileURLWithPath: d).appendingPathComponent("xless-native") }
        else { root = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".local/share/xless-native") }
    }

    public var bin: URL { root.appendingPathComponent("bin") }
    public var tools: URL { root.appendingPathComponent("tools") }
    public var toolchains: URL { root.appendingPathComponent("toolchains") }
    /// The native `SwiftToolchain` record (`XLESS_SWIFT_TOOLCHAIN`'s format).
    public var record: URL { root.appendingPathComponent("swift-toolchain.json") }

    public func toolchain(version: String) -> URL { toolchains.appendingPathComponent("swift-\(version)") }
    public func xtool(version: String) -> URL { tools.appendingPathComponent("xtool-\(version)") }
    public func rcodesign(version: String) -> URL { tools.appendingPathComponent("rcodesign-\(version)") }

    /// `path` with the toolchain's `usr/bin` and then `bin` first (each moved there if already present), so they win
    /// over any other `swift`, `xtool` or `rcodesign` on PATH (swiftly's, a distribution's).
    public static func path(_ path: String?, toolchain: SwiftToolchain, bin: URL) -> String {
        let first = [toolchain.bin.path, bin.path]
        let rest = (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            .filter { !first.contains($0) }
        return (first + rest).joined(separator: ":")
    }

    /// A native xless (outside an image, which records its toolchain at `SwiftToolchain.imageFile`) with a native
    /// install puts its tools first on this process's PATH, so every tool and child process uses them. A host without
    /// a native record (an image, an older native install) is left as it is.
    public static func activate(env: [String: String] = ProcessInfo.processInfo.environment) {
        guard !FileManager.default.fileExists(atPath: SwiftToolchain.imageFile) else { return }
        let layout = NativeLayout(env: env)
        guard let data = FileManager.default.contents(atPath: layout.record.path),
              let toolchain = try? JSONDecoder().decode(SwiftToolchain.self, from: data) else { return }
        let new = path(env["PATH"], toolchain: toolchain, bin: layout.bin)
        if new != env["PATH"] { setenv("PATH", new, 1) }
    }
}
