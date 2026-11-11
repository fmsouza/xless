import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore
import XlessMachO

private var fm: FileManager { .default }

private func scratch(_ tag: String) -> URL {
    fm.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
}

private func write(_ text: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A Darwin SDK stand-in with the iPhoneOS and MacOSX 27.0 SDKs and their libclang_rt (what the cargo environments
/// read), and the toolset's dsymutil (`dsymutil: false` leaves it out).
private func fakeSDK(dsymutil: Bool = true) throws -> DarwinSDK {
    let bundle = scratch("sdk").appendingPathComponent("darwin.xtoolsdk", isDirectory: true)
    if dsymutil {
        try write("#!/bin/sh\nexit 0\n", bundle.appendingPathComponent("toolset/bin/dsymutil"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("toolset/bin/dsymutil").path)
    }
    for platform in ["MacOSX", "iPhoneOS"] {
        try write(#"{"Version":"27.0"}"#, bundle.appendingPathComponent("Developer/Platforms/\(platform).platform/Developer/SDKs/\(platform)27.0.sdk/SDKSettings.json"))
    }
    for name in ["osx", "ios"] {
        try write("", bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.\(name).a"))
    }
    return DarwinSDK(bundle: bundle)
}

private func git(_ root: URL, _ args: [String]) throws -> String {
    try Shell.run("git", ["-C", root.path] + args, stage: .build).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite struct CargoBuilderPureTests {
    @Test func iosCargoArguments() {
        #expect(CargoBuilder.cargoArguments(platform: .ios, target: "aarch64-apple-ios", package: "hello-mobile", bin: "hello-ios", features: [])
                == ["build", "--release", "--locked", "-p", "hello-mobile", "--bin", "hello-ios", "--target", "aarch64-apple-ios"])
    }

    @Test func macCargoArgumentsWithFeatures() {
        let args = CargoBuilder.cargoArguments(platform: .macos, target: "x86_64-apple-darwin", package: "hello", bin: "hello", features: ["heif", "raw"])
        #expect(Array(args.suffix(2)) == ["--features", "heif,raw"])
        #expect(args.prefix(8) == ["build", "--release", "--locked", "-p", "hello", "--bin", "hello", "--target"])
        #expect(CargoBuilder.cargoArguments(platform: .macos, target: "x86_64-apple-darwin", package: "hello", bin: "hello", features: ["heif"]).suffix(2)
                == ["--features", "heif"])
    }

    @Test func environmentPrecedence() {
        let env = CargoBuilder.buildEnvironment(
            base: ["A": "base", "B": "base", "C": "base", "D": "base"],
            overlayEnv: ["B": "overlay", "C": "overlay"],
            inputs: ["A": "input", "B": "input", "C": "input"],
            toolchain: "1.97.0", platformEnv: ["C": "platform"])
        #expect(env == ["A": "input", "B": "overlay", "C": "platform", "D": "base", "RUSTUP_TOOLCHAIN": "1.97.0"])
        #expect(CargoBuilder.buildEnvironment(base: ["A": "x"], overlayEnv: [:], inputs: [:], toolchain: nil, platformEnv: [:]) == ["A": "x"])
    }

    @Test func metadataSinglesOutTheOnlyBin() throws {
        let json = #"{"target_directory":"/t","packages":[{"name":"hello","targets":[{"name":"hello-cli","kind":["bin"]},{"name":"hello","kind":["lib"]}]},{"name":"other","targets":[{"name":"a","kind":["bin"]},{"name":"b","kind":["bin"]}]}]}"#
        let one = try CargoBuilder.readMetadata(json, package: "hello")
        #expect(one.onlyBin == "hello-cli" && one.targetDir.path == "/t")
        #expect(try CargoBuilder.readMetadata(json, package: "other").onlyBin == nil)
        #expect(try CargoBuilder.readMetadata(json, package: "missing").onlyBin == nil)
        #expect(throws: XlessError.self) { try CargoBuilder.readMetadata("{}", package: "hello") }
    }
}

/// `prepare`'s record and `build` end to end with a fake `cargo` on PATH: `metadata` answers fixed JSON and `build
/// --target <t>` writes a thin Mach-O of <t>'s architecture where cargo would, logging the call and the variables it saw.
@Suite struct CargoBuilderBuildTests {
    private struct Fixture {
        var ctx: CargoBuildContext
        var log: URL
        var source: URL
    }

    private func fixture(_ platform: Platform, toolchain: Bool = true, architectures: String? = nil, debugInfo: Bool = false,
                         dsymutil: Bool = true) throws -> Fixture {
        let root = scratch("cargobuild"), bin = root.appendingPathComponent("bin")
        let source = root.appendingPathComponent("source"), work = root.appendingPathComponent("work"), inputDir = root.appendingPathComponent("fonts")
        try write("fn main() {}\n", source.appendingPathComponent("src/main.rs"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"]] {
            _ = try git(source, args)
        }
        try write("icns", work.appendingPathComponent("hello.icns"))
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>AppBuildCommit</key><string>@BUILD_SHA@</string><key>AppBuild</key><string>@BUILD_NUMBER@</string></dict></plist>
            """, work.appendingPathComponent("mac/Info.plist.in"))
        try write("font", inputDir.appendingPathComponent("a.ttf"))
        try write(#"{"target_directory":"\#(root.path)/target","packages":[]}"#, bin.appendingPathComponent("metadata.json"))
        try write("""
            #!/bin/sh
            set -e
            dir="$(dirname "$0")"
            echo "$RUSTUP_TOOLCHAIN|$FONTS_DIR|$GREETING|[$ASC_KEY_ID]|$*" >> "$dir/calls.log"
            case "$1" in
            metadata) cat "$dir/metadata.json" ;;
            build)
              t=""; b=""; prev=""
              for a in "$@"; do [ "$prev" = "--target" ] && t="$a"; [ "$prev" = "--bin" ] && b="$a"; prev="$a"; done
              case "$t" in
                aarch64-apple-darwin|aarch64-apple-ios) cpu='\\014\\000\\000\\001' ;;
                x86_64-apple-darwin) cpu='\\007\\000\\000\\001' ;;
                *) echo "unexpected target $t" >&2; exit 1 ;;
              esac
              echo "$CARGO_PROFILE_RELEASE_STRIP" >> "$dir/strip.log"
              mkdir -p "\(root.path)/target/$t/release"
              if [ -z "${FAKE_DEBUG_INFO:-}" ]; then
                { printf '\\317\\372\\355\\376'; printf "$cpu"; head -c 24 /dev/zero; printf '%s' "$t"; } > "\(root.path)/target/$t/release/$b"
              else
                # An image with one LC_UUID of 16 times byte $1 (octal); what the linker wrapper leaves with debug info:
                # the shipped -x link, and in its debug directory the link without -x (another UUID) and its dSYM.
                mach() { printf '\\317\\372\\355\\376'; printf "$cpu"; printf '\\000\\000\\000\\000\\002\\000\\000\\000\\001\\000\\000\\000\\030\\000\\000\\000'
                         head -c 8 /dev/zero; printf '\\033\\000\\000\\000\\030\\000\\000\\000'; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do printf "$1"; done; }
                debug="\(work.path)/.xless/dsym/$t"
                mkdir -p "$debug/$b-1.dSYM/Contents/Resources/DWARF"
                mach '\\021' > "\(root.path)/target/$t/release/$b"
                mach '\\042' > "$debug/$b-1"
                mach '\\042' > "$debug/$b-1.dSYM/Contents/Resources/DWARF/$b-1"
                echo '<plist/>' > "$debug/$b-1.dSYM/Contents/Info.plist"
              fi
              ;;
            *) echo "unexpected cargo $*" >&2; exit 1 ;;
            esac

            """, bin.appendingPathComponent("cargo"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("cargo").path)
        try write("#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/rustup.log\"\n", bin.appendingPathComponent("rustup"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("rustup").path)

        let overlay = try CargoOverlay.parse(yaml: """
            type: cargo
            bundleID: com.example.hello
            teamID: ABCDE12345
            version: "0.10.0-rc.1"
            build: "42"
            \(toolchain ? "rust: { toolchain: \"1.97.0\" }" : "")
            env: { GREETING: hi }
            plistVars: { BUILD_SHA: "@GIT_SHA@" }
            inputs:
              - { name: craft-fonts, path: \(inputDir.path), env: FONTS_DIR }
            ios:
              package: hello-mobile
              product: Hello
              minimumOS: "17.0"
              assets: Assets.xcassets
            macos:
              bundleID: com.example.hello.mac
              package: hello
              product: Hello
              minimumOS: "11.0"
              icon: hello.icns
              infoPlist: mac/Info.plist.in
            \(architectures.map { "  architectures: \($0)" } ?? "")
            """, name: "hello")
        let resolved = try CargoProject.resolve(overlay: overlay, platform: platform, source: source)
        var env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "CARGO_HOME": root.appendingPathComponent("cargo-home").path,
                   "ASC_KEY_ID": "SECRET"]
        if debugInfo { env["FAKE_DEBUG_INFO"] = "1" }
        let ctx = CargoBuildContext(overlay: overlay, resolved: resolved, platform: platform, sourceRoot: source, workRoot: work,
                                    paths: StagePaths(project: root, platform: platform), sdk: try fakeSDK(dsymutil: dsymutil), env: env)
        // What prepare leaves for build.
        try CargoBuilder.writeRecord(.init(env: ["FONTS_DIR": inputDir.path], paths: ["craft-fonts": inputDir.path]), to: ctx.inputsRecord)
        return Fixture(ctx: ctx, log: bin.appendingPathComponent("calls.log"), source: source)
    }

    private func files(under dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path
        return Files.regularFiles(under: dir).map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }.sorted()
    }

    @Test func buildWithFakeCargoMakesAUniversalMacApp() async throws {
        let f = try fixture(.macos)
        let app = try await CargoBuilder.build(ctx: f.ctx)
        #expect(app.lastPathComponent == "Hello.app" && app.deletingLastPathComponent().lastPathComponent == "app")
        let exe = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Hello"))
        #expect(try MachO.sliceArchitectures(in: exe).map(\.name) == ["x86_64", "arm64"])
        #expect(files(under: app).contains("Contents/Resources/Hello.icns"))

        let info = try Plist.read(app.appendingPathComponent("Contents/Info.plist"), stage: .build)
        #expect(info["AppBuildCommit"] as? String == (try git(f.source, ["rev-parse", "HEAD"])))
        #expect(info["AppBuild"] as? String == "42")
        #expect(info["CFBundleIdentifier"] as? String == "com.example.hello.mac")

        // metadata, then one build per triple; the pinned toolchain, input and overlay env reach every call, secrets none.
        let calls = try String(contentsOf: f.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.count == 3)
        #expect(calls[0] == "1.97.0|\(f.ctx.workRoot.deletingLastPathComponent().path)/fonts|hi|[]|metadata --format-version 1 --no-deps")
        #expect(calls.dropFirst().allSatisfy { $0.hasPrefix("1.97.0|") && $0.contains("|hi|[]|build --release --locked -p hello --bin hello --target ") })
        #expect(calls.dropFirst().compactMap { $0.split(separator: " ").last }.sorted() == ["aarch64-apple-darwin", "x86_64-apple-darwin"])
    }

    @Test func buildWithOneMacArchitectureMakesAThinApp() async throws {
        for (yaml, triple, arch) in [("[arm64]", "aarch64-apple-darwin", "arm64"), ("[x86_64]", "x86_64-apple-darwin", "x86_64")] {
            let f = try fixture(.macos, architectures: yaml)
            let app = try await CargoBuilder.build(ctx: f.ctx)
            let exe = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Hello"))
            #expect(!MachO.isFat(exe))
            #expect(try MachO.sliceArchitectures(in: exe).map(\.name) == [arch])
            // metadata, then one build for the one triple.
            let calls = try String(contentsOf: f.log, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(calls.count == 2)
            #expect(calls[1].hasSuffix("|hi|[]|build --release --locked -p hello --bin hello --target \(triple)"))
        }
    }

    @Test func prepareInstallsOnlyTheChosenMacTargets() async throws {
        let f = try fixture(.macos, architectures: "[arm64]")
        try await CargoBuilder.prepare(ctx: f.ctx)
        let rustup = try String(contentsOf: f.log.deletingLastPathComponent().appendingPathComponent("rustup.log"), encoding: .utf8)
        #expect(rustup.split(separator: "\n").map(String.init).contains("target add --toolchain 1.97.0 aarch64-apple-darwin"))
    }

    @Test func buildWithFakeCargoMakesAnIOSApp() async throws {
        let f = try fixture(.ios, toolchain: false)
        let app = try await CargoBuilder.build(ctx: f.ctx)
        let exe = try Data(contentsOf: app.appendingPathComponent("Hello"))
        #expect(!MachO.isFat(exe))
        #expect(try MachO.sliceArchitectures(in: exe).map(\.name) == ["arm64"])
        let calls = try String(contentsOf: f.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.count == 2)
        #expect(calls[1].hasSuffix("|hi|[]|build --release --locked -p hello-mobile --bin hello-mobile --target aarch64-apple-ios"))
        #expect(calls[1].hasPrefix("|"), "no RUSTUP_TOOLCHAIN without rust.toolchain: \(calls[1])")
        // rust-objcopy must not strip the Mach-O: cargo is told not to, and the linker wrapper drops local symbols.
        #expect(try String(contentsOf: f.log.deletingLastPathComponent().appendingPathComponent("strip.log"), encoding: .utf8) == "false\n")
        let wrapper = try String(contentsOf: f.ctx.workRoot.appendingPathComponent(".xless/bin/xless-ios-cc"), encoding: .utf8)
        #expect(wrapper.contains(" -Wl,-x "))
        // The wrapper's debug link, with the SDK toolset's dsymutil; without debug info, no dSYM.
        #expect(wrapper.contains("'\(f.ctx.sdk.dsymutil.path)'"))
        #expect(wrapper.contains("'\(f.ctx.workRoot.appendingPathComponent(".xless/dsym/aarch64-apple-ios").path)'"))
        #expect(!fm.fileExists(atPath: f.ctx.paths.dSYMs.path))
    }

    /// With debug info, the dSYM of each architecture's debug link, renamed after the app and given the UUID of the
    /// executable it ships: one universal dSYM on macOS, a thin one on iOS.
    @Test func buildKeepsTheDSYMsOfTheDebugLinks() async throws {
        for (platform, dwarf, slices) in [(Platform.macos, "Hello.app.dSYM/Contents/Resources/DWARF/Hello", 2),
                                          (.ios, "Hello.app.dSYM/Contents/Resources/DWARF/Hello", 1)] {
            let f = try fixture(platform, debugInfo: true)
            _ = try await CargoBuilder.build(ctx: f.ctx)
            let kept = try Data(contentsOf: f.ctx.paths.dSYMs.appendingPathComponent(dwarf))
            #expect(MachO.isFat(kept) == (slices == 2))
            #expect(try MachO.uuids(in: kept) == Array(repeating: "11111111-1111-1111-1111-111111111111", count: slices))
        }
    }

    /// An SDK whose toolset has no dsymutil: the wrapper is the one without a debug link, and there is no dSYM.
    @Test func buildWithoutDsymutilKeepsNoDSYM() async throws {
        let f = try fixture(.ios, debugInfo: true, dsymutil: false)
        _ = try await CargoBuilder.build(ctx: f.ctx)
        let wrapper = try String(contentsOf: f.ctx.workRoot.appendingPathComponent(".xless/bin/xless-ios-cc"), encoding: .utf8)
        #expect(!wrapper.contains("dsymutil"))
        #expect(!fm.fileExists(atPath: f.ctx.paths.dSYMs.path))
    }

    /// The first build with a debug link: an executable cargo already linked, with no record in the debug directory,
    /// is removed from `deps/` so that cargo links it again through the wrapper.
    @Test func buildRemovesALinkedExecutableTheDebugDirectoryHasNoRecordOf() async throws {
        let f = try fixture(.ios)
        let deps = f.ctx.workRoot.deletingLastPathComponent().appendingPathComponent("target/aarch64-apple-ios/release/deps")
        try write("old", deps.appendingPathComponent("hello_mobile-0a1b2c"))
        try write("", deps.appendingPathComponent("hello_mobile-0a1b2c.d"))
        _ = try await CargoBuilder.build(ctx: f.ctx)
        #expect(!fm.fileExists(atPath: deps.appendingPathComponent("hello_mobile-0a1b2c").path))
        #expect(fm.fileExists(atPath: deps.appendingPathComponent("hello_mobile-0a1b2c.d").path))
    }

    @Test func prepareSyncsInstallsTheToolchainAndRecordsTheInputs() async throws {
        let f = try fixture(.macos)
        try fm.removeItem(at: f.ctx.inputsRecord)
        let work = try await CargoBuilder.prepare(ctx: f.ctx)
        #expect(work == f.ctx.workRoot)
        #expect(fm.fileExists(atPath: work.appendingPathComponent("src/main.rs").path))
        let record = try JSONDecoder().decode(CargoBuilder.InputsRecord.self, from: Data(contentsOf: f.ctx.inputsRecord))
        let fonts = f.ctx.workRoot.deletingLastPathComponent().appendingPathComponent("fonts").path
        #expect(record == .init(env: ["FONTS_DIR": fonts], paths: ["craft-fonts": fonts]))
        let rustup = try String(contentsOf: f.log.deletingLastPathComponent().appendingPathComponent("rustup.log"), encoding: .utf8)
        #expect(rustup.split(separator: "\n").map(String.init) == [
            "toolchain install 1.97.0 --profile minimal",
            "target add --toolchain 1.97.0 aarch64-apple-darwin x86_64-apple-darwin",
            "component add --toolchain 1.97.0 llvm-tools",
        ])
    }

    @Test func buildWithoutPrepareNamesTheStage() async throws {
        let f = try fixture(.ios)
        try fm.removeItem(at: f.ctx.inputsRecord)
        do { _ = try await CargoBuilder.build(ctx: f.ctx); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("cargo-inputs.json")) }
    }

    @Test func buildOutsideAGitCheckoutIsABuildError() async throws {
        var f = try fixture(.ios)
        f.ctx.sourceRoot = scratch("nogit")
        try fm.createDirectory(at: f.ctx.sourceRoot, withIntermediateDirectories: true)
        do { _ = try await CargoBuilder.build(ctx: f.ctx); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("git commit")) }
    }
}
