import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// The linker wrapper run as cargo runs it, with a stand-in `clang` (first on PATH) that logs its arguments and writes
/// its last `-o`, and a stand-in `dsymutil` that logs its arguments and makes the `-o` directory.
private struct WrapperRun {
    let root: URL
    let bin: URL
    let log: URL
    let debug: URL
    let dsymutil: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("wrap-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        log = root.appendingPathComponent("calls.log")
        debug = root.appendingPathComponent("work/.xless/dsym/aarch64-apple-darwin", isDirectory: true)
        dsymutil = root.appendingPathComponent("toolset/bin/dsymutil")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: dsymutil.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.script("""
            #!/bin/sh
            echo "clang $*" >> '\(log.path)'
            out= prev=
            for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
            [ -z "${FAIL_LINK:-}" ] || exit 7
            mkdir -p "$(dirname "$out")" && echo linked > "$out"
            """, to: bin.appendingPathComponent("clang"))
        try Self.script("""
            #!/bin/sh
            echo "dsymutil $*" >> '\(log.path)'
            [ -z "${FAIL_DSYMUTIL:-}" ] || exit 1
            mkdir -p "$3/Contents/Resources/DWARF"
            """, to: dsymutil)
    }

    static func script(_ text: String, to url: URL) throws {
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// An object file: with `dwarf`, one that names a `__debug_info` section, as rustc's are with debug info.
    func object(_ name: String, dwarf: Bool) throws -> String {
        let url = root.appendingPathComponent("deps/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(count: 60)
        d.append(contentsOf: Array((dwarf ? "__debug_info\0\0\0\0__DWARF" : "__text\0\0\0\0\0\0\0\0\0\0__TEXT").utf8))
        try d.write(to: url)
        return url.path
    }

    /// Runs `wrapper` with `args`; returns its exit status, its stderr and the logged calls.
    func run(_ wrapper: URL, _ args: [String], env: [String: String] = [:]) throws -> (status: Int32, stderr: String, calls: [String]) {
        let p = Process()
        p.executableURL = wrapper
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let err = Pipe()
        p.standardError = err
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (p.terminationStatus, stderr, calls)
    }
}

/// A Darwin SDK bundle stand-in with the MacOSX 27.0 SDK, libclang_rt.osx.a and the toolset's dsymutil.
private func macSDK(dsymutil: URL? = nil) throws -> DarwinSDK {
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

@Suite struct LinkerWrapperDebugLinkTests {
    @Test func theSDKsDsymutilIsTheToolsetOne() {
        let sdk = DarwinSDK(bundle: URL(fileURLWithPath: "/opt/sdk/darwin.artifactbundle"))
        #expect(sdk.dsymutil.path == "/opt/sdk/darwin.artifactbundle/toolset/bin/dsymutil")
    }

    /// Debug info in the crate's objects: the link cargo asked for, with -Wl,-x, then the same link without it into the
    /// debug directory, and dsymutil on that.
    @Test func macWrapperLinksAgainWithoutXAndRunsDsymutilWhenTheCratesObjectsCarryDWARF() throws {
        let w = try WrapperRun()
        let sdk = try macSDK()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: sdk, workRoot: w.root.appendingPathComponent("work"),
                                                          debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let symbols = try w.object("rustcXyz/symbols.o", dwarf: false), crate = try w.object("hello-1.hello.abc-cgu.0.rcgu.o", dwarf: true)
        let out = w.root.appendingPathComponent("deps/hello-1").path
        let r = try w.run(wrapper, [symbols, crate, "-lSystem", "-o", out, "-Wl,-dead_strip"])
        #expect(r.status == 0)
        let rt = try sdk.clangRuntime(platform: "osx").path
        let head = "clang --target=arm64-apple-macos13.0 -isysroot \(try sdk.sdkPath("macosx").path) -fuse-ld=\(sdk.ld64.path) -mlinker-version=907 -Wl,-framework,Foundation"
        #expect(r.calls == [
            "\(head) -Wl,-x \(symbols) \(crate) -lSystem -o \(out) -Wl,-dead_strip \(rt)",
            "\(head) \(symbols) \(crate) -lSystem -o \(out) -Wl,-dead_strip -o \(w.debug.path)/hello-1 \(rt)",
            "dsymutil \(w.debug.path)/hello-1 -o \(w.debug.path)/hello-1.dSYM",
        ])
        #expect(try String(contentsOf: URL(fileURLWithPath: out), encoding: .utf8) == "linked\n")
    }

    /// No DWARF in the crate's objects (the release profile has no debug info): exactly today's link, nothing else.
    @Test func macWrapperWithoutDWARFLinksOnceAsToday() throws {
        let w = try WrapperRun()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "x86_64-apple-darwin", minOS: "13.0", sdk: try macSDK(), workRoot: w.root.appendingPathComponent("work"),
                                                          debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let r = try w.run(wrapper, [try w.object("hello-1.o", dwarf: false), "-o", w.root.appendingPathComponent("deps/hello-1").path])
        #expect(r.status == 0)
        #expect(r.calls.count == 1)
        #expect(r.calls[0].contains(" -Wl,-x "))
        // The record that this link had no debug info.
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.debug.path) == ["hello-1.nodebug"])
    }

    /// cargo relinks an executable only when it changed, so the debug directory is kept between builds; any link of the
    /// crate removes the debug links earlier builds left for it, whatever cargo's hash (it changes with the profile), so
    /// a link without debug info leaves none that could pass for its dSYM.
    @Test func macWrapperWithoutDWARFRemovesTheEarlierDebugLinksOfTheSameCrate() throws {
        let w = try WrapperRun()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: try macSDK(), workRoot: w.root.appendingPathComponent("work"),
                                                          debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let fm = FileManager.default
        for stale in ["hello-1", "hello-1.dSYM/Contents/Resources/DWARF/hello-1", "hello-0", "hello-0.dSYM/Contents/Info.plist", "hello-0.failed",
                      "hello_x-3", "other-2"] {
            try fm.createDirectory(at: w.debug.appendingPathComponent(stale).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: w.debug.appendingPathComponent(stale))
        }
        let r = try w.run(wrapper, [try w.object("hello-1.o", dwarf: false), "-o", w.root.appendingPathComponent("deps/hello-1").path])
        #expect(r.status == 0)
        #expect(try fm.contentsOfDirectory(atPath: w.debug.path).sorted() == ["hello-1.nodebug", "hello_x-3", "other-2"])
    }

    /// A dependency's cdylib goes through the same wrapper: it ships nowhere, so it gets no debug link.
    @Test func macWrapperGivesADylibNoDebugLink() throws {
        let w = try WrapperRun()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: try macSDK(), workRoot: w.root.appendingPathComponent("work"),
                                                          debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let r = try w.run(wrapper, [try w.object("dep.o", dwarf: true), "-dynamiclib", "-o", w.root.appendingPathComponent("deps/libdep.dylib").path])
        #expect(r.status == 0)
        #expect(r.calls.count == 1)
    }

    /// The debug link never fails the build; the link cargo asked for does.
    @Test func macWrapperFailuresOfTheDebugLinkAreOnlyReported() throws {
        let w = try WrapperRun()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: try macSDK(), workRoot: w.root.appendingPathComponent("work"),
                                                          debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let args = [try w.object("hello-1.o", dwarf: true), "-o", w.root.appendingPathComponent("deps/hello-1").path]
        let failed = try w.run(wrapper, args, env: ["FAIL_DSYMUTIL": "1"])
        #expect(failed.status == 0)
        #expect(failed.stderr.contains("xless: no dSYM for hello-1"))
        // Recorded, so the build can say why (rustc shows a linker's stderr only as a warning).
        #expect(FileManager.default.fileExists(atPath: w.debug.appendingPathComponent("hello-1.failed").path))

        try? FileManager.default.removeItem(at: w.log)
        let broken = try w.run(wrapper, args, env: ["FAIL_LINK": "1"])
        #expect(broken.status == 7)
        #expect(broken.calls.count == 1)
    }

    /// Without a debug link the wrapper is the one xless wrote before dSYMs: the link is the same, byte for byte.
    @Test func macWrapperWithoutDebugLinkIsUnchanged() throws {
        let w = try WrapperRun()
        let sdk = try macSDK()
        let wrapper = try RustApple.writeMacLinkerWrapper(target: "aarch64-apple-darwin", minOS: "13.0", sdk: sdk, workRoot: w.root.appendingPathComponent("work"))
        #expect(try String(contentsOf: wrapper, encoding: .utf8) == """
            #!/bin/sh
            # Generated by xless: cargo's linker for aarch64-apple-darwin.
            exec clang --target=arm64-apple-macos13.0 -isysroot '\(try sdk.sdkPath("macosx").path)' -fuse-ld='\(sdk.ld64.path)' -mlinker-version=907 -Wl,-framework,Foundation -Wl,-x "$@" '\(try sdk.clangRuntime(platform: "osx").path)'

            """)
        let iosSDK = try fakeSDK()
        let ios = try RustApple.writeIOSLinkerWrapper(minOS: "16.0", sdk: iosSDK, workRoot: w.root.appendingPathComponent("ios"))
        #expect(try String(contentsOf: ios, encoding: .utf8) == """
            #!/bin/sh
            # Generated by xless: cargo's linker for aarch64-apple-ios (dependencies that declare a cdylib crate type).
            exec clang -target arm64-apple-ios16.0 -isysroot '\(try iosSDK.sdkPath("iphoneos").path)' -fuse-ld='\(iosSDK.ld64.path)' -mlinker-version=907 "$@" '\(try iosSDK.clangRuntime(platform: "ios").path)'

            """)
    }

    /// cargo links an executable only when it changed. When the debug directory has no record of a binary's crate (the
    /// first build with dSYMs, or the directory was removed), cargo's linked output is removed so that it links it again,
    /// through the wrapper; with a record (a debug link, or a link without debug info), nothing is removed.
    @Test func linkAgainWithoutARecordRemovesCargosLinkedExecutable() throws {
        let w = try WrapperRun()
        let fm = FileManager.default
        let deps = w.root.appendingPathComponent("target/aarch64-apple-darwin/release/deps", isDirectory: true)
        try fm.createDirectory(at: deps, withIntermediateDirectories: true)
        for f in ["hello_app-0f1e", "hello_app-0f1e.d", "libhello_app-77.rlib", "hello_app_ext-9", "other-3"] {
            try Data().write(to: deps.appendingPathComponent(f))
        }
        let link = RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil)
        #expect(RustApple.linkAgainWithoutRecord(bin: "hello-app", release: deps.deletingLastPathComponent(), debugLink: link) == ["hello_app-0f1e"])
        #expect(try fm.contentsOfDirectory(atPath: deps.path).sorted() == ["hello_app-0f1e.d", "hello_app_ext-9", "libhello_app-77.rlib", "other-3"])

        try Data().write(to: deps.appendingPathComponent("hello_app-0f1e"))
        for record in ["hello_app-0f1e.nodebug", "hello_app-0f1e", "hello_app-0f1e.failed"] {
            try fm.createDirectory(at: w.debug, withIntermediateDirectories: true)
            try Data().write(to: w.debug.appendingPathComponent(record))
            #expect(RustApple.linkAgainWithoutRecord(bin: "hello-app", release: deps.deletingLastPathComponent(), debugLink: link).isEmpty)
            try fm.removeItem(at: w.debug.appendingPathComponent(record))
        }
    }

    /// A plain cargo iOS app: its executable is linked by cargo through the iOS wrapper, with -Wl,-x and the debug link.
    @Test func iosCargoWrapperLinksAgainWithoutXWhenTheCratesObjectsCarryDWARF() throws {
        let w = try WrapperRun()
        let work = w.root.appendingPathComponent("work")
        let env = try RustApple.iosCargoEnv(minOS: "17.0", sdk: fakeSDK(), workRoot: work, host: nil,
                                            debugLink: RustApple.DebugLink(dir: w.debug, dsymutil: w.dsymutil))
        let wrapper = URL(fileURLWithPath: try #require(env["CARGO_TARGET_AARCH64_APPLE_IOS_LINKER"]))
        let r = try w.run(wrapper, [try w.object("hello-1.o", dwarf: true), "-o", w.root.appendingPathComponent("deps/hello-1").path])
        #expect(r.status == 0)
        #expect(r.calls.count == 3)
        #expect(r.calls[0].contains(" -Wl,-x "))
        #expect(!r.calls[1].contains("-Wl,-x"))
        #expect(r.calls[1].contains("-o \(w.debug.path)/hello-1 "))
    }
}
