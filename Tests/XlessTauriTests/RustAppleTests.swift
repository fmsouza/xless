import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// A Darwin SDK bundle stand-in with the MacOSX 27.0 SDK and libclang_rt.osx.a.
private func macSDK() throws -> DarwinSDK {
    let fm = FileManager.default
    let bundle = fm.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)/darwin.xtoolsdk", isDirectory: true)
    let sdk = bundle.appendingPathComponent("Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk")
    try fm.createDirectory(at: sdk, withIntermediateDirectories: true)
    try #"{"Version":"27.0"}"#.write(to: sdk.appendingPathComponent("SDKSettings.json"), atomically: true, encoding: .utf8)
    let rt = bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/23/lib/darwin")
    try fm.createDirectory(at: rt, withIntermediateDirectories: true)
    try Data().write(to: rt.appendingPathComponent("libclang_rt.osx.a"))
    return DarwinSDK(bundle: bundle)
}

@Suite struct RustAppleTests {
    @Test func rustupStepsPinnedToolchain() {
        #expect(RustApple.rustupSteps(toolchainFile: false, activeToolchain: false, toolchain: "1.97.0", targets: ["aarch64-apple-ios"]) == [
            ["rustup", "toolchain", "install", "1.97.0", "--profile", "minimal"],
            ["rustup", "target", "add", "--toolchain", "1.97.0", "aarch64-apple-ios"],
            ["rustup", "component", "add", "--toolchain", "1.97.0", "llvm-tools"],
        ])
    }

    @Test func rustupStepsUnpinnedUnchanged() {
        for (file, active) in [(true, true), (false, false), (false, true)] {
            for targets in [["aarch64-apple-ios"], TauriMacEnvironment.targets] {
                #expect(RustApple.rustupSteps(toolchainFile: file, activeToolchain: active, toolchain: nil, targets: targets)
                    == TauriBuilder.rustupSteps(toolchainFile: file, activeToolchain: active, targets: targets))
            }
        }
        #expect(RustApple.rustupSteps(toolchainFile: false, activeToolchain: false, targets: ["aarch64-apple-ios"]).contains(["rustup", "default", "stable"]))
    }

    @Test func iosCargoEnvHasNoTauriKeys() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let env = try RustApple.iosCargoEnv(minOS: "17.0", sdk: fakeSDK(), workRoot: work, host: nil)
        #expect(env["SDKROOT"] != nil)
        #expect(env["IPHONEOS_DEPLOYMENT_TARGET"] == "17.0")
        #expect(env["CARGO_TARGET_AARCH64_APPLE_IOS_LINKER"] == work.appendingPathComponent(".xless/bin/xless-ios-cc").path)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("TAURI_") })
        #expect(FileManager.default.isExecutableFile(atPath: work.appendingPathComponent(".xless/bin/xless-ios-cc").path))
        // cargo must not run rust-objcopy on the Mach-O; the wrapper strips local symbols at link time instead.
        #expect(env["CARGO_PROFILE_RELEASE_STRIP"] == "false")
        let wrapper = try String(contentsOf: work.appendingPathComponent(".xless/bin/xless-ios-cc"), encoding: .utf8)
        #expect(wrapper.contains(" -Wl,-x "))
    }

    @Test func tauriIOSLinkerWrapperKeepsLocalSymbols() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let url = try RustApple.writeIOSLinkerWrapper(minOS: "17.0", sdk: fakeSDK(), workRoot: work)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("-Wl,-x"))
    }

    @Test func macCargoEnvPerTarget() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let env = try RustApple.macCargoEnv(target: "x86_64-apple-darwin", minOS: "11.0", sdk: macSDK(), workRoot: work, host: nil)
        #expect(env["MACOSX_DEPLOYMENT_TARGET"] == "11.0")
        #expect(env["CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER"]?.hasSuffix("xless-macos-cc-x86_64") == true)
        #expect(env["CARGO_PROFILE_RELEASE_STRIP"] == "false")
        #expect(env.keys.allSatisfy { !$0.hasPrefix("TAURI_") })
        #expect(FileManager.default.isExecutableFile(atPath: work.appendingPathComponent(".xless/bin/xless-macos-cc-x86_64").path))
    }

    @Test func unsupportedMacTargetIsRefused() throws {
        #expect(throws: XlessError.self) {
            try RustApple.macCargoEnv(target: "riscv64-apple-darwin", minOS: "11.0", sdk: macSDK(), workRoot: URL(fileURLWithPath: "/nonexistent"), host: nil)
        }
    }
}

// MARK: - A Mac's own Rust

@Test func ofAMacsRustOnlyWhatIsMissingIsAdded() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-rustup-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("app/src-tauri"), bin = root.appendingPathComponent("bin"), calls = root.appendingPathComponent("calls")
    for directory in [app, bin] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    let env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path]
    func prepare(_ targets: [String], toolchain: String? = nil, llvmTools: Bool = false) throws -> [String] {
        try? fm.removeItem(at: calls)
        try RustApple.prepareNative(source: root.appendingPathComponent("app"), searchFrom: app, toolchain: toolchain, targets: targets, llvmTools: llvmTools, env: env, log: { _ in })
        return ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    func rustup(list: String) throws {
        try ExecutableFile.write("#!/bin/sh\nif [ \"$2\" = list ]; then \(list); else echo \"$(basename \"$PWD\"): $*\" >> '\(calls.path)'; fi\n", to: bin.appendingPathComponent("rustup"), stage: .prepare)
    }
    if (try? Shell.run("/bin/sh", ["-c", "command -v rustup"], baseEnvironment: env, stage: .prepare)) == nil {
        let error = #expect(throws: XlessError.self) { _ = try prepare(["a"]) }
        #expect(error?.cause.contains("rustup is not on PATH") == true && error?.fix.contains("--docker") == true)
    }
    try rustup(list: "echo aarch64-apple-ios; echo aarch64-apple-darwin")
    #expect(try prepare(["aarch64-apple-ios", "aarch64-apple-darwin"]).isEmpty)
    #expect(try prepare(["aarch64-apple-darwin", "x86_64-apple-darwin"]) == ["src-tauri: target add x86_64-apple-darwin"])
    #expect(try prepare(["x86_64-apple-darwin"], toolchain: "1.97.0") == ["src-tauri: target add --toolchain 1.97.0 x86_64-apple-darwin"])
    #expect(try prepare(["aarch64-apple-ios"], llvmTools: true) == ["src-tauri: component add llvm-tools"])
    try rustup(list: "echo aarch64-apple-ios; echo llvm-tools-aarch64-apple-darwin")
    #expect(try prepare(["aarch64-apple-ios"], llvmTools: true).isEmpty)
    // a toolchain that is not there
    try rustup(list: "exit 1")
    #expect(try prepare(["aarch64-apple-ios"], toolchain: "1.97.0") == ["src-tauri: toolchain install 1.97.0 --profile minimal", "src-tauri: target add --toolchain 1.97.0 aarch64-apple-ios"])
    #expect(try prepare(["aarch64-apple-ios"], toolchain: "1.97.0", llvmTools: true).last == "src-tauri: component add --toolchain 1.97.0 llvm-tools")
    #expect(try prepare(["aarch64-apple-ios"]).first == "src-tauri: toolchain install stable --profile minimal")
    try Data().write(to: root.appendingPathComponent("app/rust-toolchain.toml"))
    #expect(try prepare(["aarch64-apple-ios"]) == ["src-tauri: toolchain install", "src-tauri: target add aarch64-apple-ios"])
}

/// The `swift` that a crate's build script finds on a Mac: no second sandbox, and Tauri's packages get the pinned SwiftRs.
@Test func aBuildScriptsSwiftStartsNoSandboxAndHasThePinnedSwiftRs() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless swift-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("Xcode 27.app"), bin = app.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")
    let work = root.appendingPathComponent("work"), plugin = root.appendingPathComponent("plugin/ios"), api = root.appendingPathComponent("plugin/.tauri/tauri-api"), other = root.appendingPathComponent("other")
    for directory in [bin, plugin, api, other] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    try ExecutableFile.write("#!/bin/sh\nfor a in \"$@\"; do echo \"<$a>\"; done\n", to: bin.appendingPathComponent("swift"), stage: .build)
    try Data("// https://github.com/Brendonovich/swift-rs".utf8).write(to: api.appendingPathComponent("Package.swift"))
    for directory in [plugin, other] { try Data("// a package".utf8).write(to: directory.appendingPathComponent("Package.swift")) }
    try RustApple.writeSwiftWrapper(sdk: DarwinSDK(xcode: InstalledXcode(app: app, version: "27.2", build: "27B52", source: "-")), workRoot: work)
    func swift(_ arguments: String..., in directory: URL) throws -> String {
        try Shell.run(work.path + "/.xless/bin/swift", arguments, cwd: directory, stage: .build).stdout.split(separator: "\n").joined()
    }
    #expect(try swift("-target", "arm64-apple-ios15.0", "-print-target-info", in: plugin) == "<-target><arm64-apple-ios15.0><-print-target-info>")
    #expect(!fm.fileExists(atPath: plugin.path + "/Package.resolved"))
    #expect(try swift("build", "-c", "release", "a b", in: plugin) == "<build><--disable-sandbox><-c><release><a b>")
    for directory in [api, other] { _ = try swift("build", in: directory) }
    for directory in [plugin, api] {
        #expect(try String(contentsOfFile: directory.path + "/Package.resolved", encoding: .utf8).contains(SwiftPackages.swiftRs.revision))
    }
    #expect(!fm.fileExists(atPath: other.path + "/Package.resolved"))
    try Data("its own".utf8).write(to: api.appendingPathComponent("Package.resolved"))
    _ = try swift("build", in: api)
    #expect(try String(contentsOfFile: api.path + "/Package.resolved", encoding: .utf8) == "its own")
}

@Test func anInstalledXcodesToolsAreCargosCompilerAndLinker() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("xless-rust-xcode-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("Xcode 27.app"), bin = app.path + "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    for (platform, runtime) in [("iPhoneOS", "ios"), ("MacOSX", "osx")] {
        try fm.createDirectory(atPath: app.path + "/Contents/Developer/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk", withIntermediateDirectories: true)
        let lib = app.path + "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin"
        try fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: "\(lib)/libclang_rt.\(runtime).a"))
    }
    let sdk = DarwinSDK(xcode: InstalledXcode(app: app, version: "27.2", build: "27B52", source: "-"))
    let ios = try RustApple.iosCargoEnv(minOS: "17.0", sdk: sdk, workRoot: root, host: nil)
    #expect(ios["CC_aarch64_apple_ios"] == bin + "/clang" && ios["CXX_aarch64_apple_ios"] == bin + "/clang++" && ios["AR_aarch64_apple_ios"] == bin + "/ar")
    #expect(ios["SDKROOT"] == app.path + "/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
    let mac = try RustApple.macCargoEnv(target: "aarch64-apple-darwin", minOS: "14.0", sdk: sdk, workRoot: root, host: nil,
                                        debugLink: RustApple.DebugLink(dir: root, dsymutil: sdk.dsymutil))
    #expect(mac["AR_aarch64_apple_darwin"] == bin + "/ar" && sdk.dsymutil.path == bin + "/dsymutil")
    for name in ["CARGO_TARGET_AARCH64_APPLE_IOS_LINKER", "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"] {
        let wrapper = try String(contentsOfFile: #require(ios[name] ?? mac[name]), encoding: .utf8)
        #expect(wrapper.contains("'\(bin)/clang' -") && !wrapper.contains("fuse-ld") && !wrapper.contains("mlinker-version") && wrapper.contains("/lib/darwin/libclang_rt."))
    }
}
