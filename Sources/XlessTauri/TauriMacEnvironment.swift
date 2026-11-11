import Foundation
import XlessCore

/// The environment of the two programs xless runs on Tauri's behalf for the macOS (universal) build.
/// Values: docs/research/tauri-ios-contract.md, "macOS (desktop)" (what `tauri build` sets on the Mac) and "macOS — spike B"
/// (what the Linux host needs on top).
public enum TauriMacEnvironment {
    public static let targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]

    /// The `beforeBuildCommand` hook env, once for both architectures. TAURI_ENV_PLATFORM_VERSION is the host macOS version
    /// on a Mac; on Linux it is the macOS SDK version (open question 5). TAURI_ENV_DEBUG is not set for a release build.
    public static func frontend(sdk: DarwinSDK) throws -> [String: String] {
        [
            "TAURI_ENV_PLATFORM": "darwin",
            "TAURI_ENV_ARCH": "universal",
            "TAURI_ENV_TARGET_TRIPLE": "universal-apple-darwin",
            "TAURI_ENV_FAMILY": "unix",
            "TAURI_ENV_PLATFORM_VERSION": try sdk.sdkVersion("macosx"),
        ]
    }

    /// cargo's env for one `target`. As on the Mac: MACOSX_DEPLOYMENT_TARGET. Added for Linux (spike B): SDKROOT, the C
    /// toolchain told its target, the target's linker wrapper, clang for `host` build scripts, and no stripping by cargo
    /// (rust-objcopy can leave a Mach-O that dyld refuses; the wrapper's `-Wl,-x` drops local symbols instead).
    /// `swift`: the image's app Swift toolchain (Ruling R10), whose clang compiles the target's C code; nil: `clang` on PATH.
    public static func cargo(resolved: ResolvedTauriMac, target: String, sdk: DarwinSDK, workRoot: URL,
                             host: String? = TauriEnvironment.defaultHost, swift: SwiftToolchain? = nil) throws -> [String: String] {
        let minOS = try resolved.config.platform(.macos).minimumOS
        var env = try RustApple.macEnvironment(target: target, minOS: minOS, sdk: sdk, workRoot: workRoot, host: host, swift: swift)
        // TAURI_CONFIG (a merge patch) only when the overlay changes the identifier or version tauri.conf.json would compile in.
        var patch: [String: String] = [:]
        if resolved.config.bundleID != resolved.tauri.identifier { patch["identifier"] = resolved.config.bundleID }
        if resolved.config.version != resolved.tauri.version { patch["version"] = resolved.config.version }
        if !patch.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
            env["TAURI_CONFIG"] = String(decoding: data, as: UTF8.self)
        }
        return env
    }

    /// clang's name for a darwin target's architecture.
    static func arch(of target: String) throws -> String { try RustApple.macArch(of: target) }

    static func linkerWrapper(target: String, workRoot: URL) throws -> URL { try RustApple.macLinkerWrapper(target: target, workRoot: workRoot) }

    /// cargo's linker for a darwin target (see `RustApple.writeMacLinkerWrapper`).
    @discardableResult
    public static func writeLinkerWrapper(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil,
                                          debugLink: RustApple.DebugLink? = nil) throws -> URL {
        try RustApple.writeMacLinkerWrapper(target: target, minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift, debugLink: debugLink)
    }
}
