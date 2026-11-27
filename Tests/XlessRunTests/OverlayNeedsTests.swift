import Foundation
import Testing
import XlessCore
import XlessImages
@testable import XlessRun

/// What an overlay's build needs natively off a Mac, told by what is installed (`ProjectRun.missingForOverlay`), and the refusal of a
/// native run that lacks some of it.
@Suite struct OverlayNeedsTests {
    private static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-needs-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// An environment that sees nothing of this machine: its own home, an empty store and share, no shims.
    private func bare() throws -> [String: String] {
        for name in ["home", "xcodes", "share"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        return ["HOME": root.appendingPathComponent("home").path, "PATH": "/nowhere", "XLESS_XCODES": root.appendingPathComponent("xcodes").path,
                "XLESS_SHARE": root.appendingPathComponent("share").path]
    }

    /// A pack in the store with `parts`, Swift Build's `swbuild` among its files when it has that part.
    private func pack(_ parts: [String: String]) throws {
        let pack = XcodePack(root: root.appendingPathComponent("xcodes/\(XcodePack.name(xcode: "26.2", build: "17C52", arch: Self.arch))"),
                             manifest: PackManifest(format: 1, xcode: "26.2", build: "17C52", arch: Self.arch, swift: "6.2.3", mode: .separate, parts: parts))
        try FileManager.default.createDirectory(at: pack.sdkBundle, withIntermediateDirectories: true)
        if pack.has(.swiftBuild) {
            try FileManager.default.createDirectory(at: pack.swiftBuild, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: pack.swiftBuild.appendingPathComponent("swbuild"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pack.swiftBuild.appendingPathComponent("swbuild").path)
        }
        try pack.manifest.write(to: pack.manifestFile)
    }

    private func shims() throws -> String {
        let shims = root.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        return shims.path
    }

    @Test func bareLinuxHostListsWhatIsMissing() throws {
        let env = try bare()
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: env) { _ in nil }
            == ["Swift Build (no pack with it: xless setup)", "the Xcode tool shims (XLESS_SHIM_DIR)", "node", "rustup-init or rustup"])
        #expect(ProjectRun.missingForOverlay(kind: .reactNative, env: env) { _ in nil }
            == ["Swift Build (no pack with it: xless setup)", "the Xcode tool shims (XLESS_SHIM_DIR)", "node", "ruby", "bundle", "hermesc"])
        // a pack without Swift Build (as a native setup on a bare host prepares one), and a shim directory that is not one
        try pack(["sdk": "h"])
        var some = env
        some["XLESS_SHIM_DIR"] = root.appendingPathComponent("no-such-dir").path
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: some) { $0 == "node" || $0 == "rustup" ? "/bin/\($0)" : nil }
            == ["Swift Build (no pack with it: xless setup)", "the Xcode tool shims (XLESS_SHIM_DIR)"])
        #expect(ProjectRun.missingForOverlay(kind: .reactNative, env: some) { $0 == "hermesc" ? nil : "/bin/\($0)" }
            == ["Swift Build (no pack with it: xless setup)", "the Xcode tool shims (XLESS_SHIM_DIR)", "hermesc"])
    }

    @Test func everythingInstalledIsEmpty() throws {
        var env = try bare()
        try pack(["sdk": "h", "swift-build": "h"])
        env["XLESS_SHIM_DIR"] = try shims()
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: env) { "/bin/\($0)" }.isEmpty)
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: env) { $0 == "rustup-init" ? nil : "/bin/\($0)" }.isEmpty) // rustup alone does
        #expect(ProjectRun.missingForOverlay(kind: .reactNative, env: env) { "/bin/\($0)" }.isEmpty)
        // the pack named by XLESS_XCODE, wherever it is mounted, as in a container of a kit's image
        let moved = root.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: root.appendingPathComponent("xcodes"), to: moved)
        env["XLESS_XCODES"] = moved.path
        env["XLESS_XCODE"] = moved.appendingPathComponent(XcodePack.name(xcode: "26.2", build: "17C52", arch: Self.arch)).path
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: env) { "/bin/\($0)" }.isEmpty)
        // one that has Swift Build but was prepared by another recipe lacks nothing: the build says that, and what prepares it again
        let share = root.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: share.appendingPathComponent("scripts/pack-swift-build.sh"))
        try Data(["XCODE_RELEASES=17C52", "XCODE_SHORT_17C52=26.2", "XCODE_SWIFT_17C52=6.2.3", "SWB_TAG=swift-6.2.3-RELEASE", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64=a",
                  "SWIFT_TOOLCHAIN_6_2_3_SHA256_X86_64=b", "SWIFT_IMAGE=swift:6.4.0-jammy@sha256:0123", ""].joined(separator: "\n").utf8)
            .write(to: share.appendingPathComponent("versions.env"))
        #expect((try? XcodeEnvironment.current(env: env, needs: [.swiftBuild])) == nil)
        #expect(ProjectRun.missingForOverlay(kind: .tauri, env: env) { "/bin/\($0)" }.isEmpty)
    }

    /// The run itself: refused natively off a Mac with what is missing and `xless run --docker`; nothing else is run. On a Mac, and in
    /// containers, nothing is looked for.
    @Test func macIsUnchanged() throws {
        let home = try RunHome()
        let lacks: @Sendable (Kit, [String: String]) -> [String] = { kind, _ in kind == .tauri ? ["node", "rustup-init or rustup"] : ["hermesc"] }
        let linux = FakeRunHost(answer: home.answer())
        #expect(throws: XlessError.self) { try home.run(["--config", home.overlay, "--to", "finalize"], docker: false, host: linux, overlayLacks: lacks) }
        do { _ = try home.run(["--config", home.overlay, "--to", "finalize"], docker: false, host: linux, overlayLacks: lacks) } catch let error as XlessError {
            #expect(error.cause == "the overlay \(home.overlay) needs, and this machine lacks: node, rustup-init or rustup")
            #expect(error.fix.hasPrefix("`xless run --docker` has them all") && error.fix.contains("--with tauri") && error.exitCode == 2)
        }
        #expect(linux.allSteps.isEmpty)
        // WSL keeps its own rules, and is refused the same way
        #expect(throws: XlessError.self) { try home.run(["--config", home.overlay], docker: false, host: FakeRunHost(isWSL: true, answer: home.answer()), overlayLacks: lacks) }
        // nothing lacking: it builds here, natively
        let installed = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay, "--to", "finalize", "--build-number", "1"], docker: false, host: installed, overlayLacks: { _, _ in [] }) == 0)
        #expect(installed.allSteps.contains { $0.line.contains("ship") && $0.line.contains("--to finalize") && !$0.isContainer })
        // a Mac builds with its own Xcode, in its sandbox, as before
        let notes = Notes(), mac = FakeRunHost(isMac: true, answer: home.answer())
        #expect(try home.run(["--config", home.overlay, "--to", "finalize", "--build-number", "1"], docker: false, host: mac, prepareMac: { _, _, _ in notes.add("mac") }, overlayLacks: lacks) == 0)
        #expect(notes.lines == ["mac"] && mac.allSteps.contains { $0.line.contains("--to finalize") })
        // in containers nothing is looked for
        let docker = FakeRunHost(answer: home.answer())
        #expect(try home.run(["--config", home.overlay, "--to", "finalize"], docker: true, host: docker, overlayLacks: lacks) == 0)
        // nor for a project directory
        #expect(try home.run([home.project, "--to", "finalize", "--build-number", "1"], docker: false, host: FakeRunHost(answer: home.answer()), overlayLacks: lacks) == 0)
    }
}
