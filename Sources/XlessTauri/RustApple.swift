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
    /// `debugLink`: the wrapper also makes the executable's dSYM (`DebugLink`).
    public static func iosCargoEnv(minOS: String, sdk: DarwinSDK, workRoot: URL, host: String? = TauriEnvironment.defaultHost,
                                   swift: SwiftToolchain? = nil, debugLink: DebugLink? = nil) throws -> [String: String] {
        try writeIOSLinkerWrapper(minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift, stripLocalSymbols: true, debugLink: debugLink)
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
    /// refuses; the wrapper's `-Wl,-x` drops local symbols instead). Writes the target's linker wrapper under `workRoot`;
    /// with `debugLink`, the wrapper also makes the executable's dSYM (`DebugLink`).
    public static func macCargoEnv(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, host: String? = TauriEnvironment.defaultHost,
                                   swift: SwiftToolchain? = nil, debugLink: DebugLink? = nil) throws -> [String: String] {
        try writeMacLinkerWrapper(target: target, minOS: minOS, sdk: sdk, workRoot: workRoot, swift: swift, debugLink: debugLink)
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
    /// cargo app, as on the Mac). `debugLink`: also the executable's dSYM (`DebugLink`).
    @discardableResult
    public static func writeIOSLinkerWrapper(minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil,
                                             stripLocalSymbols: Bool = false, debugLink: DebugLink? = nil) throws -> URL {
        let url = iosLinkerWrapper(workRoot: workRoot)
        let clang = "\(swift.map { quote($0.tool("clang")) } ?? "clang") -target arm64-apple-ios\(minOS) -isysroot \(quote(try sdk.sdkPath("iphoneos").path)) -fuse-ld=\(quote(sdk.ld64.path)) -mlinker-version=907"
        try write(wrapper(comment: "cargo's linker for aarch64-apple-ios (dependencies that declare a cdylib crate type)", clang: clang,
                          stripLocalSymbols: stripLocalSymbols, runtime: quote(try sdk.clangRuntime(platform: "ios").path), debugLink: debugLink), to: url)
        return url
    }

    /// cargo's linker for a darwin target: the executable link and any dependency or app library declaring a `cdylib`
    /// crate type. `-Wl,-framework,Foundation` before the arguments makes the webview crate's cookie-name constants bind
    /// to Foundation as on the Mac (not CFNetwork); `-Wl,-x` strips local symbols the way Xcode's `strip -x` does.
    /// `debugLink`: also the executable's dSYM (`DebugLink`).
    @discardableResult
    public static func writeMacLinkerWrapper(target: String, minOS: String, sdk: DarwinSDK, workRoot: URL, swift: SwiftToolchain? = nil,
                                             debugLink: DebugLink? = nil) throws -> URL {
        let arch = try macArch(of: target)
        let url = try macLinkerWrapper(target: target, workRoot: workRoot)
        let clang = "\(swift.map { quote($0.tool("clang")) } ?? "clang") --target=\(arch)-apple-macos\(minOS) -isysroot \(quote(try sdk.sdkPath("macosx").path)) -fuse-ld=\(quote(sdk.ld64.path)) -mlinker-version=907 -Wl,-framework,Foundation"
        try write(wrapper(comment: "cargo's linker for \(target)", clang: clang, stripLocalSymbols: true,
                          runtime: quote(try sdk.clangRuntime(platform: "osx").path), debugLink: debugLink), to: url)
        return url
    }

    /// The dSYM of a Rust executable cargo links through the wrapper (docs/pipeline.md, "dSYMs of Rust apps").
    /// `ld64.lld -x` drops the debug map entries of local and hidden functions, nearly every Rust function, so dsymutil
    /// cannot describe them from the executable cargo ships. When the crate's own objects carry DWARF (a `__debug_info`
    /// section: the release profile has debug info), the wrapper links the same arguments again, without `-x`, into
    /// `dir/<name>` and runs `dsymutil` on that link into `dir/<name>.dSYM`, while rustc's objects (and its temporary
    /// `symbols.o`) still exist. The executable cargo gets is the `-x` link, the same bytes as without a debug link;
    /// `DSYM.debugLinkDSYM` then matches the two by their code. A dylib link gets no debug link, and a failure of either
    /// step is reported without failing the build.
    public struct DebugLink: Equatable, Sendable {
        public var dir: URL
        public var dsymutil: URL
        public init(dir: URL, dsymutil: URL) { self.dir = dir; self.dsymutil = dsymutil }
    }

    /// The debug link directory of one cargo target in the work copy. It is kept between builds: cargo relinks an
    /// executable only when it changed, and the wrapper replaces the debug links of the crate of each executable it
    /// links, or records that it had no debug info (`<name>.nodebug`) or that the second link failed (`<name>.failed`).
    public static func debugLinkDir(target: String, workRoot: URL) -> URL {
        workRoot.appendingPathComponent(".xless/dsym/\(target)", isDirectory: true)
    }

    /// The debug link of the SDK's toolset dsymutil for `target`, or nil when the toolset has no dsymutil.
    public static func debugLink(target: String, workRoot: URL, sdk: DarwinSDK) -> DebugLink? {
        FileManager.default.isExecutableFile(atPath: sdk.dsymutil.path)
            ? DebugLink(dir: debugLinkDir(target: target, workRoot: workRoot), dsymutil: sdk.dsymutil) : nil
    }

    /// cargo links an executable only when it changed, and the work copy keeps the source's file times, so the first
    /// build with a debug link (or one after its directory was removed) would get none for an executable cargo
    /// already linked. When `debugLink.dir` holds no link and no record of `bin`'s crate, its linked output in
    /// `<release>/deps` (`<crate>-<hash>`, no extension) is removed, which makes cargo link it again, through the
    /// wrapper. Returns the names removed.
    @discardableResult
    public static func linkAgainWithoutRecord(bin: String, release: URL, debugLink: DebugLink) -> [String] {
        let fm = FileManager.default
        let prefix = bin.replacingOccurrences(of: "-", with: "_") + "-"
        let recorded = ((try? fm.contentsOfDirectory(atPath: debugLink.dir.path)) ?? []).contains { $0.hasPrefix(prefix) }
        guard !recorded else { return [] }
        let deps = release.appendingPathComponent("deps", isDirectory: true)
        let linked = ((try? fm.contentsOfDirectory(atPath: deps.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.count > prefix.count && $0.dropFirst(prefix.count).allSatisfy(\.isHexDigit) }
            .sorted()
        for name in linked { try? fm.removeItem(at: deps.appendingPathComponent(name)) }
        return linked
    }

    /// The wrapper's text. Without `debugLink`, one `exec` of `clang`, the arguments and `runtime`, as xless has always
    /// written it.
    static func wrapper(comment: String, clang: String, stripLocalSymbols: Bool, runtime: String, debugLink: DebugLink?) -> String {
        let strip = stripLocalSymbols ? " -Wl,-x" : ""
        guard let debugLink else {
            return """
                #!/bin/sh
                # Generated by xless: \(comment).
                exec \(clang)\(strip) "$@" \(runtime)

                """
        }
        return """
            #!/bin/sh
            # Generated by xless: \(comment).
            link() {
                \(clang) "$@" \(runtime)
            }
            link\(strip) "$@" || exit
            # The executable's dSYM (docs/pipeline.md, "dSYMs of Rust apps"): when the crate's own objects carry debug
            # info, the same link without -x (which drops the debug map of local symbols), and dsymutil on it.
            out='' prev=''
            for a in "$@"; do
                case "$prev" in -o) out=$a ;; esac
                case "$a" in -dynamiclib|-bundle|-r) exit 0 ;; esac
                prev=$a
            done
            [ -n "$out" ] || exit 0
            debug=\(quote(debugLink.dir.path)) name=${out##*/}
            # Earlier debug links of this crate (cargo names the link <crate>-<hash>; the hash changes with the profile).
            rm -rf "$debug/${name%-*}-"*
            mkdir -p "$debug" || exit 0
            for a in "$@"; do
                case "$a" in
                *.o) if grep -q -a -m 1 __debug_info "$a" 2>/dev/null; then
                        if ! { link "$@" -o "$debug/$name" && \(quote(debugLink.dsymutil.path)) "$debug/$name" -o "$debug/$name.dSYM"; }; then
                            echo "xless: no dSYM for $name: the link without -x or dsymutil failed" >&2
                            : > "$debug/$name.failed"
                        fi
                        exit 0
                     fi ;;
                esac
            done
            # The record that this executable was linked without debug info.
            : > "$debug/$name.nodebug"

            """
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
