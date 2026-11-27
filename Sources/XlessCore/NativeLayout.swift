import Foundation

/// Where `xless setup` (native, the default on Linux) installs the tools the images otherwise carry: the pinned xtool and
/// rcodesign. Its root is `$XLESS_NATIVE_HOME`, else `$XDG_DATA_HOME/xless-native`, else `~/.local/share/xless-native` (not
/// `~/.local/share/xless`, which install.sh replaces on every upgrade). Its `xcodes` directory is the default store of
/// Xcode packs (`XcodeStore`), which hold everything that depends on an Xcode: its Swift toolchain, the SDK, the record.
///
///     tools/xtool-<version>/AppRun   tools/rcodesign-<version>/rcodesign   bin/xtool, bin/rcodesign (links)   xcodes/
///
/// An xless of before the packs also put here `toolchains/swift-<version>/` and `swift-toolchain.json`, with the SDK and
/// its metadata where `xless sdk install` put them (`DarwinSDKLocator`, `ToolchainMeta.defaultLocation`): nothing reads
/// them any more; `toolchains`, `toolchain(version:)` and `record` name them for setup's note and for `xless clean`.
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
    /// The `SwiftToolchain` record of a native install of before the packs (no longer written or read).
    public var record: URL { root.appendingPathComponent("swift-toolchain.json") }

    public func toolchain(version: String) -> URL { toolchains.appendingPathComponent("swift-\(version)") }
    public func xtool(version: String) -> URL { tools.appendingPathComponent("xtool-\(version)") }
    public func rcodesign(version: String) -> URL { tools.appendingPathComponent("rcodesign-\(version)") }

    /// `path` with the toolchain's `usr/bin` and then `bin` first (each moved there if already present), so they win
    /// over any other `swift`, `xtool` or `rcodesign` on PATH (swiftly's, a distribution's). The `usr/bin` of another
    /// Xcode's toolchain (`isOtherToolchain`: a pack's or a native install's, put there by an earlier activation) is
    /// dropped, so only one Xcode's Swift is on it.
    public static func path(_ path: String?, toolchain: SwiftToolchain, bin: URL, isOtherToolchain: (String) -> Bool = { _ in false }) -> String {
        let first = [toolchain.bin.path, bin.path]
        let rest = (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            .filter { !first.contains($0) && !isOtherToolchain($0) }
        return (first + rest).joined(separator: ":")
    }

    /// Whether this host runs the toolchains of the packs and of the native setup (they are Linux's; a Mac builds with
    /// its Xcode).
    public static var isLinuxHost: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    /// The PATH a native xless runs with: the Xcode's Swift toolchain (`XcodeEnvironment.toolchain`: its pack's, by the pin
    /// in `env`) and then `bin` first, without another pack's `usr/bin` (nor that of a native install of before the packs). nil: PATH stays as it is, on a host that is not Linux (`linux`), with `XLESS_SWIFT_TOOLCHAIN`
    /// set (an image's), without a toolchain, and when it already is that.
    public static func activatedPath(env: [String: String], linux: Bool = isLinuxHost) -> String? {
        guard linux, (env["XLESS_SWIFT_TOOLCHAIN"] ?? "").isEmpty, let toolchain = (try? XcodeEnvironment.lookup(env: env))??.toolchain else { return nil }
        let layout = NativeLayout(env: env)
        let new = path(env["PATH"], toolchain: toolchain, bin: layout.bin) { entry in
            let dir = URL(fileURLWithPath: entry)
            guard dir.lastPathComponent == "bin", dir.deletingLastPathComponent().lastPathComponent == "usr" else { return false }
            let root = dir.deletingLastPathComponent().deletingLastPathComponent()
            if root.deletingLastPathComponent().path == layout.toolchains.path { return true }
            return root.lastPathComponent == "toolchain"
                && FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("pack.json").path)
        }
        return new == env["PATH"] ? nil : new
    }

    /// Puts `activatedPath` on this process's PATH, so every tool and child process uses that toolchain. Every command
    /// does it at its start; a command that loads a project with an `xcode:` pin does it again once the pin is set.
    public static func activate(env: [String: String] = ProcessInfo.processInfo.environment, linux: Bool = isLinuxHost) {
        if let new = activatedPath(env: env, linux: linux) { setenv("PATH", new, 1) }
    }
}
