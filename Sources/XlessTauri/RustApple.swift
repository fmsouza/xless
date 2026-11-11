import Foundation
import XlessCore
import XlessMachO

/// The Rust-for-Apple build environment, independent of the app framework on top: cargo's env for an iOS device or a
/// macOS target built from Linux (the SDK, the C toolchain told its target, the linker wrapper, clang for `host` build
/// scripts), the rustup steps that install a toolchain, and the universal executable of the two darwin slices.
/// Tauri (`TauriEnvironment`, `TauriMacEnvironment`, `TauriBuilder`) and plain cargo apps both build on it. Values and
/// reasons: docs/research/tauri-ios-contract.md, "Linux build — spike A/B findings" and "macOS — spike B".
public enum RustApple {
    public static let iosTarget = "aarch64-apple-ios"

    // MARK: cargo environment

    /// cargo's env for an iOS device build (`aarch64-apple-ios`) at deployment target `minOS`: SDKROOT, the deployment
    /// target, the C toolchain told its target, the iOS linker wrapper (written under `workRoot`) and clang for `host`
    /// build scripts. No `TAURI_*` keys. For a plain cargo app, whose executable cargo links itself: cargo does not strip
    /// (`CARGO_PROFILE_RELEASE_STRIP=false`, since rust-objcopy can leave a Mach-O that dyld refuses) and the wrapper's
    /// `-Wl,-x` drops local symbols instead. Tauri links through Xcode and builds its own env (`iosEnvironment`).
    /// `swift`: the image's app Swift toolchain (Ruling R10), whose clang compiles the iOS C code; nil: `clang` on PATH.
    public static func iosCargoEnv(minOS: String, sdk: DarwinSDK, workRoot: URL, host: String? = TauriEnvironment.defaultHost,
                                   swift: SwiftToolchain? = nil) throws -> [String: String] {
        try writeIOSLinkerWrapper(minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift, stripLocalSymbols: true)
        var env = try iosEnvironment(minOS: minOS, sdk: sdk, workRoot: workRoot, host: host, swift: swift)
        env["CARGO_PROFILE_RELEASE_STRIP"] = "false"
        return env
    }

    /// `iosCargoEnv` without writing the wrapper, for callers that write it themselves.
    static func iosEnvironment(minOS: String, sdk: DarwinSDK, workRoot: URL, host: String?, swift: SwiftToolchain?) throws -> [String: String] {
        let sdkRoot = try sdk.sdkPath("iphoneos").path
        let cflags = "--target=arm64-apple-ios\(minOS) -isysroot \(sdkRoot)"
        var env = [
            "SDKROOT": sdkRoot,
            "IPHONEOS_DEPLOYMENT_TARGET": minOS,
            "CC_aarch64_apple_ios": swift?.tool("clang") ?? "clang",
            "CXX_aarch64_apple_ios": swift?.tool("clang++") ?? "clang++",
            "AR_aarch64_apple_ios": "llvm-ar",
            "CFLAGS_aarch64_apple_ios": cflags,
            "CXXFLAGS_aarch64_apple_ios": cflags,
            "CARGO_TARGET_AARCH64_APPLE_IOS_LINKER": iosLinkerWrapper(workRoot: workRoot).path,
        ]
        addHost(host, to: &env)
        return env
    }

    /// cargo's env for one darwin `target` (`aarch64-apple-darwin` or `x86_64-apple-darwin`) at deployment target
    /// `minOS`: the iOS list's macOS counterpart, plus no stripping by cargo (rust-objcopy can leave a Mach-O that dyld
    /// refuses; the wrapper's `-Wl,-x` drops local symbols instead). Writes the target's linker wrapper under `workRoot`.
    public static func macCargoEnv(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, host: String? = TauriEnvironment.defaultHost,
                                   swift: SwiftToolchain? = nil) throws -> [String: String] {
        try writeMacLinkerWrapper(target: target, minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift)
        return try macEnvironment(target: target, minOS: minOS, sdk: sdk, workRoot: workRoot, host: host, swift: swift)
    }

    /// `macCargoEnv` without writing the wrapper, for callers that write it themselves.
    static func macEnvironment(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, host: String?, swift: SwiftToolchain?) throws -> [String: String] {
        let arch = try macArch(of: target)
        let sdkRoot = try sdk.sdkPath("macosx").path
        let cflags = "--target=\(arch)-apple-macos\(minOS) -isysroot \(sdkRoot)"
        let t = target.replacingOccurrences(of: "-", with: "_")
        var env = [
            "SDKROOT": sdkRoot,
            "MACOSX_DEPLOYMENT_TARGET": minOS,
            "CC_\(t)": swift?.tool("clang") ?? "clang",
            "CXX_\(t)": swift?.tool("clang++") ?? "clang++",
            "AR_\(t)": "llvm-ar",
            "CFLAGS_\(t)": cflags,
            "CXXFLAGS_\(t)": cflags,
            "CARGO_TARGET_\(t.uppercased())_LINKER": try macLinkerWrapper(target: target, workRoot: workRoot).path,
            "CARGO_PROFILE_RELEASE_STRIP": "false",
        ]
        addHost(host, to: &env)
        return env
    }

    /// The Linux image has no `cc` for rustc's and the `cc` crate's host builds: point them at clang.
    private static func addHost(_ host: String?, to env: inout [String: String]) {
        guard let host else { return }
        let underscored = host.replacingOccurrences(of: "-", with: "_")
        env["CARGO_TARGET_\(underscored.uppercased())_LINKER"] = "clang"
        env["CC_\(underscored)"] = "clang"
        env["CXX_\(underscored)"] = "clang++"
    }

    // MARK: linker wrappers

    /// clang's name for a darwin target's architecture.
    static func macArch(of target: String) throws -> String {
        switch target {
        case "aarch64-apple-darwin": return "arm64"
        case "x86_64-apple-darwin": return "x86_64"
        default: throw XlessError(.build, "unsupported macOS target '\(target)'", fix: "use aarch64-apple-darwin or x86_64-apple-darwin")
        }
    }

    /// The file name must NOT end in `ld` (`ld`, `ld64`, `lld`, `-ld`): rustc infers the linker flavor from the linker's
    /// file name, and an `ld`-style name selects the ld64 flavor, which passes raw ld arguments (`-platform_version`,
    /// `-syslibroot`, `-dylib`, …) that this clang wrapper rejects. A `cc` name selects the cc flavor. RUSTFLAGS is
    /// deliberately not set to force the flavor: that would override the project's own `rustflags` configuration.
    static func iosLinkerWrapper(workRoot: URL) -> URL { workRoot.appendingPathComponent(".xless/bin/xless-ios-cc") }

    /// Like the iOS wrapper, the file name must NOT end in `ld`/`ld64`/`lld`: rustc infers the linker flavor from it.
    static func macLinkerWrapper(target: String, workRoot: URL) throws -> URL {
        workRoot.appendingPathComponent(".xless/bin/xless-macos-cc-\(try macArch(of: target))")
    }

    /// cargo's linker for aarch64-apple-ios: `cargo rustc --crate-type staticlib` restricts only the app crate, and a
    /// dependency declaring `crate-type = ["cdylib", …]` is still linked as an iOS dylib (spike B difference 4).
    /// A wrapper, because cargo's `linker` takes no arguments. `stripLocalSymbols`: add `-Wl,-x` (the executable link of a
    /// cargo app, as on the Mac).
    @discardableResult
    public static func writeIOSLinkerWrapper(minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil,
                                             stripLocalSymbols: Bool = false) throws -> URL {
        let url = iosLinkerWrapper(workRoot: workRoot)
        let strip = stripLocalSymbols ? " -Wl,-x" : ""
        let text = """
            #!/bin/sh
            # Generated by xless: cargo's linker for aarch64-apple-ios (dependencies that declare a cdylib crate type).
            exec \(swift.map { quote($0.tool("clang")) } ?? "clang") -target arm64-apple-ios\(minOS) -isysroot \(quote(try sdk.sdkPath("iphoneos").path)) -fuse-ld=\(quote(sdk.ld64.path)) -mlinker-version=907\(strip) "$@" \(quote(try sdk.clangRuntime(platform: "ios").path))

            """
        try write(text, to: url)
        return url
    }

    /// cargo's linker for a darwin target: the executable link and any dependency or app library declaring a `cdylib`
    /// crate type. `-Wl,-framework,Foundation` before the arguments makes the webview crate's cookie-name constants bind
    /// to Foundation as on the Mac (not CFNetwork); `-Wl,-x` strips local symbols the way Xcode's `strip -x` does.
    @discardableResult
    public static func writeMacLinkerWrapper(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil) throws -> URL {
        let arch = try macArch(of: target)
        let url = try macLinkerWrapper(target: target, workRoot: workRoot)
        let text = """
            #!/bin/sh
            # Generated by xless: cargo's linker for \(target).
            exec \(swift.map { quote($0.tool("clang")) } ?? "clang") --target=\(arch)-apple-macos\(minOS) -isysroot \(quote(try sdk.sdkPath("macosx").path)) -fuse-ld=\(quote(sdk.ld64.path)) -mlinker-version=907 -Wl,-framework,Foundation -Wl,-x "$@" \(quote(try sdk.clangRuntime(platform: "osx").path))

            """
        try write(text, to: url)
        return url
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: rustup

    /// With `toolchain` nil: the toolchain `rust-toolchain.toml` selects; without one (apps from `tauri create`), stable,
    /// made the default when nothing else is. With `toolchain`: exactly that version, never made the default, and the
    /// targets and `llvm-tools` added to it by name. Then, because an app's toolchain file need not list them, the
    /// build's targets and `llvm-tools` (spike B difference 1; macOS spike B step 1).
    public static func rustupSteps(toolchainFile: Bool, activeToolchain: Bool, toolchain: String? = nil,
                                   targets: [String] = [iosTarget]) -> [[String]] {
        if let toolchain {
            return [
                ["rustup", "toolchain", "install", toolchain, "--profile", "minimal"],
                ["rustup", "target", "add", "--toolchain", toolchain] + targets,
                ["rustup", "component", "add", "--toolchain", toolchain, "llvm-tools"],
            ]
        }
        var steps = [toolchainFile ? ["rustup", "toolchain", "install"] : ["rustup", "toolchain", "install", "stable", "--profile", "minimal"]]
        if !toolchainFile && !activeToolchain { steps.append(["rustup", "default", "stable"]) }
        return steps + [["rustup", "target", "add"] + targets, ["rustup", "component", "add", "llvm-tools"]]
    }

    /// rustup itself (`rustup-init` when missing), then `rustupSteps` run in `searchFrom`. With `toolchain` nil, whether a
    /// `rust-toolchain(.toml)` selects the toolchain is looked up from `searchFrom` up to `workRoot`; otherwise exactly
    /// `toolchain` is installed. `env`: additions to `baseEnvironment` for every child (PATH with rustup's bin dir first).
    public static func bootstrap(searchFrom: URL, workRoot: URL, toolchain: String?, targets: [String], env: [String: String?],
                                 baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, log: (String) -> Void) throws {
        func run(_ argv: [String], cwd: URL?) throws {
            try Shell.run(argv[0], Array(argv.dropFirst()), cwd: cwd, env: env, baseEnvironment: baseEnvironment, stage: .prepare, passthrough: true)
        }
        if (try? Shell.run("sh", ["-c", "command -v rustup"], env: env, baseEnvironment: baseEnvironment, stage: .prepare)) == nil {
            log("rustup-init (toolchains in \(baseEnvironment["RUSTUP_HOME"] ?? "~/.rustup"))")
            try run(["rustup-init", "-y", "--no-modify-path", "--default-toolchain", "none"], cwd: nil)
        }
        var toolchainFile = false, active = true
        if toolchain == nil {
            let fm = FileManager.default
            var dir = searchFrom.standardizedFileURL
            let root = workRoot.standardizedFileURL.path
            while dir.path.hasPrefix(root) {
                if ["rust-toolchain.toml", "rust-toolchain"].contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { toolchainFile = true; break }
                if dir.path == root { break }
                dir = dir.deletingLastPathComponent()
            }
            active = toolchainFile || (try? Shell.run("rustup", ["show", "active-toolchain"], cwd: searchFrom, env: env,
                                                      baseEnvironment: baseEnvironment, stage: .prepare)) != nil
        }
        for step in rustupSteps(toolchainFile: toolchainFile, activeToolchain: active, toolchain: toolchain, targets: targets) {
            try run(step, cwd: searchFrom)
        }
    }

    // MARK: universal executable

    /// The macOS executable of a build of one or both darwin targets: the one thin executable as it is (checked as
    /// `universal` checks a slice), or the universal file of two.
    public static func macExecutable(_ thins: [(triple: String, url: URL)], binary: String) throws -> Data {
        guard thins.count == 1, let only = thins.first else { return try universal(thins, binary: binary) }
        let (arch, data) = try thin(only.triple, only.url, binary: binary)
        try check(arch, of: only.triple)
        return data
    }

    /// One thin executable per darwin target → a universal file (x86_64 slice first, like `lipo -create`). Refuses a
    /// missing slice, a file that is not a thin Mach-O of its target's architecture, and the same architecture twice.
    public static func universal(_ thins: [(triple: String, url: URL)], binary: String) throws -> Data {
        var slices: [String: Data] = [:]
        for (triple, url) in thins {
            let (arch, data) = try thin(triple, url, binary: binary)
            guard slices[arch] == nil else {
                throw XlessError(.build, "both executables are \(arch); the universal app needs one arm64 and one x86_64 slice", fix: "check CARGO_TARGET_*_LINKER and the cargo output above")
            }
            try check(arch, of: triple)
            slices[arch] = data
        }
        for arch in ["arm64", "x86_64"] where slices[arch] == nil {
            throw XlessError(.build, "no \(arch) slice for the universal executable \(binary)", fix: "build both aarch64-apple-darwin and x86_64-apple-darwin")
        }
        return try MachO.makeFat([slices["x86_64"]!, slices["arm64"]!])
    }

    /// cargo's executable for `triple` and its architecture; refuses a missing file and one that is not a thin Mach-O.
    private static func thin(_ triple: String, _ url: URL, binary: String) throws -> (arch: String, data: Data) {
        let want = try macArch(of: triple)
        guard let data = try? Data(contentsOf: url) else {
            throw XlessError(.build, "no \(want) slice: cargo left no \(binary) for \(triple) (\(url.path))", fix: "check the cargo output above")
        }
        guard !MachO.isFat(data), let arch = try? MachO.sliceArchitectures(in: data).first?.name else {
            throw XlessError(.build, "\(url.path) is not a thin Mach-O executable", fix: "check the linker wrapper and the cargo output above")
        }
        return (arch, data)
    }

    private static func check(_ arch: String, of triple: String) throws {
        let want = try macArch(of: triple)
        guard arch == want else {
            throw XlessError(.build, "the \(triple) executable is \(arch), not \(want)", fix: "check CARGO_TARGET_*_LINKER and the cargo output above")
        }
    }
}
