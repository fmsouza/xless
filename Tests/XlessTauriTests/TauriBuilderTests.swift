import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore
import XlessMachO

private var fm: FileManager { .default }

private func tree(_ files: [String]) throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("builder-\(UUID().uuidString)", isDirectory: true)
    for f in files {
        let url = root.appendingPathComponent(f)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return root
}

@Suite struct TauriBuilderTests {
    @Test func picksThePackageManagerFromTheLockfile() throws {
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "pnpm-lock.yaml"]))?.arguments
                == ["corepack", "pnpm", "install", "--frozen-lockfile"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "package-lock.json"]))?.arguments == ["npm", "ci"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["package.json", "yarn.lock"]))?.arguments
                == ["corepack", "yarn", "install", "--frozen-lockfile"])
        #expect(try TauriBuilder.installCommand(appRoot: tree(["Cargo.toml"])) == nil)
    }

    @Test func refusesAmbiguousOrMissingLockfiles() throws {
        do {
            _ = try TauriBuilder.installCommand(appRoot: tree(["package.json", "pnpm-lock.yaml", "package-lock.json"]))
            Issue.record("two lockfiles accepted")
        } catch let e as XlessError {
            #expect(e.stage == .prepare && e.cause.contains("package-lock.json") && e.cause.contains("pnpm-lock.yaml"))
        }
        #expect(throws: XlessError.self) { try TauriBuilder.installCommand(appRoot: tree(["package.json"])) }
    }

    /// Every .m/.mm/.c/.cpp under the target's sources, skipping resources, folder references and `buildPhase: none`.
    @Test func findsNativeSources() throws {
        let apple = try tree(["Sources/app/main.mm", "Sources/app/bindings/bindings.h", "Sources/app/util.c", "Externals/arm64/release/libapp.a",
                              "app_iOS/Info.plist", "assets/x.c", "Skipped/y.m", "Extra/z.cpp", "Extra/w.m"])
        let sources: [XcodeGenTarget.Source] = [
            .init(path: "Sources", buildPhase: nil, type: nil), .init(path: "Externals", buildPhase: nil, type: nil),
            .init(path: "app_iOS", buildPhase: nil, type: nil), .init(path: "assets", buildPhase: "resources", type: "folder"),
            .init(path: "Skipped", buildPhase: "none", type: nil), .init(path: "Extra/z.cpp", buildPhase: nil, type: nil),
            .init(path: "Missing", buildPhase: nil, type: nil),
        ]
        let found = TauriBuilder.nativeSources(sources, appleDir: apple).map { String($0.path.dropFirst(apple.path.count + 1)) }
        #expect(found == ["Sources/app/main.mm", "Sources/app/util.c", "Extra/z.cpp"])
    }

    /// `LIBRARY_SEARCH_PATHS[arch=arm64]` of HelloTauri, expanded the way Xcode does for the release configuration.
    @Test func expandsHelloTauriLibrarySearchPaths() throws {
        let sdk = try fakeSDK(), (_, resolved) = try helloTauri()
        let work = URL(fileURLWithPath: "/W")
        let vars = try TauriBuilder.settingsVariables(resolved: resolved, workRoot: work, sdk: sdk)
        let paths = NativeLink.expandSettings(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: resolved.target.settings) ?? "", vars: vars)
        let sdkRoot = try sdk.sdkPath("iphoneos").path, tc = sdk.toolchain.path
        #expect(paths == ["/W/src-tauri/gen/apple/Externals/arm64/release", "\(sdkRoot)/usr/lib/swift",
                          "\(tc)/usr/lib/swift/iphoneos", "\(tc)/usr/lib/swift-5.0/iphoneos"])
    }
}

/// The iOS executable's debug map names the objects with debug info it was linked from. The Rust standard library's
/// always have some (rustup ships it with line tables); the app crate's only when the release profile has debug info.
@Suite struct TauriIOSDebugMapTests {
    let debugMap = [
        "/w/target/aarch64-apple-ios/release/deps/libapp_lib.a(core-57.core.5b-cgu.0.rcgu.o)",
        "/w/target/aarch64-apple-ios/release/deps/libapp_lib.a(app_lib-0c.app_lib.9f-cgu.0.rcgu.o)",
        "/w/target/aarch64-apple-ios/release/deps/libapp_lib.a(app_lib-0c.app_lib.9f-cgu.1.rcgu.o)",
        "/w/.xless/swift/.build/arm64-apple-ios/release/Tauri.build/Tauri.swift.o",
    ]

    @Test func appCrateObjectsAreTheCratesCodegenUnits() {
        #expect(TauriBuilder.appCrateObjects(debugMap: debugMap, crateLib: "app_lib") == Array(debugMap[1...2]))
        #expect(TauriBuilder.appCrateObjects(debugMap: [debugMap[0], debugMap[3]], crateLib: "app_lib").isEmpty)
        // A crate whose name extends the app's is another crate.
        #expect(TauriBuilder.appCrateObjects(debugMap: ["/w/libapp_lib.a(app_lib_ext-1.app_lib_ext.2-cgu.0.rcgu.o)"], crateLib: "app_lib").isEmpty)
        // An object linked by path, not from the archive.
        #expect(TauriBuilder.appCrateObjects(debugMap: ["/w/deps/app_lib-0c.app_lib.9f-cgu.0.rcgu.o"], crateLib: "app_lib").count == 1)
    }

    /// A thin arm64 executable with an LC_UUID and a symbol table whose N_OSO stabs name `objects`.
    private func executable(objects: [String]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        var strings = Data([0x20, 0]), nlist = Data()
        for o in objects {
            withUnsafeBytes(of: UInt32(strings.count).littleEndian) { nlist.append(contentsOf: $0) }
            nlist.append(contentsOf: [0x66, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
            strings.append(contentsOf: Array(o.utf8) + [0])
        }
        u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(2); u32(48); u32(0); u32(0)
        u32(0x1b); u32(24); d.append(Data(repeating: 0x11, count: 16))
        u32(0x2); u32(24); u32(80); u32(UInt32(objects.count)); u32(UInt32(80 + nlist.count)); u32(UInt32(strings.count))
        d.append(nlist); d.append(strings)
        return d
    }

    @Test func iosDSYMRunsDsymutilOnlyWhenTheAppCrateHasDebugInfo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tauri-dsym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("Hello")

        try executable(objects: [debugMap[0], debugMap[3]]).write(to: exe)
        let none = TauriBuilder.iosDSYM(executable: exe, crateLib: "app_lib") { _, _ in Issue.record("ran dsymutil") }
        guard case .missing(let reason) = none else { Issue.record("found a dSYM"); return }
        #expect(reason.contains("without debug info"))

        try executable(objects: debugMap).write(to: exe)
        var ran: [[String]] = []
        let made = TauriBuilder.iosDSYM(executable: exe, crateLib: "app_lib") { e, out in
            ran.append([e.path, out.path])
            try FileManager.default.createDirectory(at: out.appendingPathComponent("Contents/Resources/DWARF"), withIntermediateDirectories: true)
        }
        #expect(ran == [[exe.path, exe.path + ".dSYM"]])
        #expect(made == .found(URL(fileURLWithPath: exe.path + ".dSYM", isDirectory: true)))

        // A missing or failing dsymutil is the reason there is no dSYM; the build goes on.
        let failed = TauriBuilder.iosDSYM(executable: exe, crateLib: "app_lib") { _, _ in
            throw XlessError(.build, "the SDK's toolset has no dsymutil (/sdk/toolset/bin/dsymutil)", fix: "reinstall the SDK")
        }
        #expect(failed == .missing("the SDK's toolset has no dsymutil (/sdk/toolset/bin/dsymutil)"))
        // An executable that cannot be read, too.
        guard case .missing = TauriBuilder.iosDSYM(executable: dir.appendingPathComponent("absent"), crateLib: "app_lib", run: { _, _ in }) else {
            Issue.record("found a dSYM"); return
        }
    }
}

@Suite struct RustupStepsTests {
    @Test func toolchainFileDecides() {
        #expect(TauriBuilder.rustupSteps(toolchainFile: true, activeToolchain: true) == [
            ["rustup", "toolchain", "install"], ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
    }

    /// An app without rust-toolchain.toml (`tauri create`) gets stable, made the default only when there is none.
    @Test func withoutToolchainFileInstallsStable() {
        #expect(TauriBuilder.rustupSteps(toolchainFile: false, activeToolchain: false) == [
            ["rustup", "toolchain", "install", "stable", "--profile", "minimal"], ["rustup", "default", "stable"],
            ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
        #expect(TauriBuilder.rustupSteps(toolchainFile: false, activeToolchain: true) == [
            ["rustup", "toolchain", "install", "stable", "--profile", "minimal"],
            ["rustup", "target", "add", "aarch64-apple-ios"], ["rustup", "component", "add", "llvm-tools"]])
    }
}

@Suite struct TauriBuilderMacTests {
    /// prepareMac: both darwin targets and llvm-tools on top of the app's toolchain.
    @Test func rustupStepsForMacOS() {
        #expect(TauriBuilder.rustupSteps(toolchainFile: true, activeToolchain: true, targets: TauriMacEnvironment.targets) == [
            ["rustup", "toolchain", "install"], ["rustup", "target", "add", "aarch64-apple-darwin", "x86_64-apple-darwin"],
            ["rustup", "component", "add", "llvm-tools"]])
    }

    /// The Mac's argv (contract, "macOS (desktop)" › Environment; samples/HelloTauri/reference/macos/calls.json).
    @Test func cargoArgumentsMatchTheMacReference() throws {
        let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../samples/HelloTauri/reference/macos/calls.json"))) as? [String: Any]
        let recorded = (calls?["cargo"] as? [[String: Any]])?.map { $0["argv"] as? [String] ?? [] }
        #expect(TauriMacEnvironment.targets.map { TauriBuilder.macCargoArguments(target: $0, features: []) } == recorded)
        #expect(TauriBuilder.macCargoArguments(target: "x86_64-apple-darwin", features: ["a", "b"])
                == ["build", "--bins", "--features", "a b tauri/custom-protocol", "--release", "--target", "x86_64-apple-darwin"])
    }

    private func metadata(_ packages: String, manifest: String = "/W/src-tauri/Cargo.toml") -> Data {
        Data(#"{"packages":[\#(packages)],"target_directory":"/W/src-tauri/target"}"#.utf8)
    }

    /// tauri-cli's main binary: `default-run`, else the only bin, else the bin named like the package.
    @Test func mainBinaryFromCargoMetadata() throws {
        let manifest = URL(fileURLWithPath: "/W/src-tauri/Cargo.toml")
        func pkg(_ bins: [String], defaultRun: String? = nil) -> String {
            let targets = (["{\"name\":\"app_lib\",\"kind\":[\"staticlib\",\"cdylib\",\"rlib\"]}"] + bins.map { "{\"name\":\"\($0)\",\"kind\":[\"bin\"]}" }).joined(separator: ",")
            return #"{"name":"app","manifest_path":"/W/src-tauri/Cargo.toml","default_run":\#(defaultRun.map { "\"\($0)\"" } ?? "null"),"targets":[\#(targets)]}"#
        }
        #expect(try TauriBuilder.mainBinary(metadata: metadata(pkg(["only"])), manifest: manifest).bin == "only")
        #expect(try TauriBuilder.mainBinary(metadata: metadata(pkg(["tool", "app"])), manifest: manifest).bin == "app")
        #expect(try TauriBuilder.mainBinary(metadata: metadata(pkg(["tool", "app"], defaultRun: "tool")), manifest: manifest).bin == "tool")
        #expect(try TauriBuilder.mainBinary(metadata: metadata(pkg(["only"])), manifest: manifest).targetDir.path == "/W/src-tauri/target")
        #expect(throws: XlessError.self) { try TauriBuilder.mainBinary(metadata: metadata(pkg(["x", "y"])), manifest: manifest) }
        #expect(throws: XlessError.self) { try TauriBuilder.mainBinary(metadata: metadata(pkg([])), manifest: manifest) }
    }
}

@Suite struct TauriPrepareMacTests {
    private func git(_ dir: URL, _ args: String...) throws {
        try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare)
    }

    /// An in-contract app whose package.json has no lockfile, so prepare stops at the JS install step that follows the
    /// binary dependencies, and an overlay with a binary dependency that cannot be downloaded (nothing listens on port 1).
    private func fixture() throws -> (TauriMacBuildContext, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("prepare-mac-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        let files = [
            "package.json": #"{"devDependencies":{"@tauri-apps/cli":"~2.12.0"}}"#,
            "src-tauri/Cargo.lock": "[[package]]\nname = \"tauri\"\nversion = \"2.12.1\"\n",
            "src-tauri/tauri.conf.json": #"{"productName":"Demo","version":"1.0.0","identifier":"com.example.demo"}"#,
        ]
        for (path, text) in files {
            let url = src.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(src, "init", "-q"); try git(src, "add", "."); try git(src, "commit", "-q", "-m", "init")
        let overlay = try TauriOverlay.parse(yaml: """
            type: tauri
            bundleID: com.example.demo
            teamID: ABCDE12345
            binaryDependencies:
              - url: https://127.0.0.1:1/a.zip
                sha256: \(String(repeating: "a", count: 64))
                extract: a.xcframework
                to: src-tauri/gen/apple/Pods/a/a.xcframework
            """, name: "demo")
        let env = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": root.path,
                   "XLESS_CACHE": root.appendingPathComponent("cache").path]
        let work = root.appendingPathComponent("work", isDirectory: true)
        let ctx = TauriMacBuildContext(overlay: overlay, resolved: try TauriProject.resolveMac(overlay: overlay, source: src), sourceRoot: src,
                                       workRoot: work, paths: StagePaths(project: work, platform: .macos), env: env)
        return (ctx, root)
    }

    /// binaryDependencies are iOS-scoped (CocoaPods replacements): prepareMac never downloads them.
    @Test func prepareMacSkipsBinaryDependencies() async throws {
        let (ctx, root) = try fixture()
        defer { try? fm.removeItem(at: root) }
        do { try await TauriBuilder.prepareMac(ctx: ctx); Issue.record("expected throw") }
        catch let e as XlessError {
            #expect(e.stage == .prepare && e.cause.contains("has no lockfile"))   // got past the binary dependencies
        }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("cache/downloads").path))
        // The same work through the shared step with the dependencies (as iOS prepare passes them) does try the download.
        do { try TauriBuilder.syncAndInstall(ctx, rustTargets: [], binaryDependencies: ctx.overlay.binaryDependencies); Issue.record("expected throw") }
        catch let e as XlessError { #expect(e.stage == .prepare && !e.cause.contains("has no lockfile")) }
    }
}
