import Foundation
import Testing
import XlessCore
@testable import xless

/// What an overlay's build on a Mac gets: made here of directories of its own, and looked at.
@Suite struct NativeOverlayTests {
    let root: String
    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("xless-overlay-\(UUID().uuidString)")
        for path in ["home/.cargo/bin", "home/dev/app/ios", "home/dev/overlays", "home/fonts", "Xcode.app/Contents/Developer", "cache"] {
            try FileManager.default.createDirectory(at: made.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        root = BuildSandbox.real(made.path)
    }

    private func native(_ env: [String: String] = [:], overlay: String = "home/dev/overlays/app.yml", source: String = "home/dev/app") -> NativeOverlay {
        let work = URL(fileURLWithPath: root + "/home/.cache/xless/work/app")
        let xcode = InstalledXcode(app: URL(fileURLWithPath: root + "/Xcode.app"), version: "27.2", build: "27B52", source: "installed")
        return NativeOverlay(source: URL(fileURLWithPath: "\(root)/\(source)"), overlay: URL(fileURLWithPath: "\(root)/\(overlay)"), work: work,
                             paths: StagePaths(project: work, platform: .ios), checkout: ["\(root)/\(source)"], xcode: xcode,
                             env: ["HOME": root + "/home", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"].merging(env) { $1 })
    }
    private let xless = URL(fileURLWithPath: "/opt/xless/bin/xless")

    @Test func itReadsTheProjectAndTheOverlayAndWritesTheWorkCopy() throws {
        var native = native(["XLESS_BUILD_READ": "\(root)/cache"])
        native.inputs = [("fonts", root + "/home/fonts")]
        let box = try native.sandbox(executable: xless, reads: ["/tools"])
        #expect(box.reads == ["home/dev/app", "home/dev/overlays", "cache", "home/fonts"].map { "\(root)/\($0)" } + ["/opt/xless/bin/xless", "\(root)/Xcode.app", "/tools"])
        let cache = root + "/home/.cache/xless", work = cache + "/work/app"
        #expect(box.writes == [work, cache + "/build-home", cache + "/downloads", cache + "/inputs", cache + "/work/.pnpm-store"])
        #expect(box.fixed == [work + "/.xless", work + "/.xless/build", work + "/.xless/build/ios"])
        for path in ["signed", "signed.partial", "out", "out.partial", "out.dSYMs", "upload.json"] { #expect(box.readOnly.contains("\(work)/.xless/build/ios/\(path)")) }
        for path in [".ssh", ".config/xless", ".local/share/xless", "Library/Keychains"] { #expect(box.secrets.contains("\(root)/home/\(path)")) }
        #expect(box.closed.contains(root + "/home") && box.closed.contains("/Users") && BuildSandbox.userHome.map(box.closed.contains) == true)
    }

    @Test func whatWouldOpenAHomeDirectoryIsRefused() throws {
        func refused(_ native: NativeOverlay, _ why: String) {
            do {
                _ = try native.sandbox(executable: xless, reads: [])
                Issue.record("it is not refused: \(why)")
            } catch { #expect("\(error)".contains(why), "\(error)") }
        }
        refused(native(source: "home"), "would open a home directory")
        refused(native(overlay: "home/app.yml"), "would open a home directory")
        refused(native(["XLESS_BUILD_READ": "\(root)/home"]), "XLESS_BUILD_READ is")
        refused(native(["XLESS_BUILD_READ": "/"]), "would open a home directory")
        refused(native(["XLESS_BUILD_READ": "\(root)/cache:relative"]), "not an absolute path")
        var native = native()
        native.inputs = [("all", "/Users")]
        refused(native, "the path input 'all'")
        // what it can write, it could change before the next stage reads it
        refused(self.native(overlay: "home/.cache/xless/build-home/o/app.yml"), "which the app's build code writes")
    }

    @Test func itsEnvironmentHasNoSecretAndAHomeOfItsOwn() throws {
        let native = native(["ASC_KEY_P8": "secret", "XLESS_SESSION": "/agent", "AWS_SECRET_ACCESS_KEY": "secret", "NPM_TOKEN": "secret", "CC": "/evil", "LANG": "pt_PT.UTF-8", "SSH_AUTH_SOCK": "/s"])
        let (out, _) = try native.environment(buildNumber: "7")
        let cache = root + "/home/.cache/xless"
        #expect(out["HOME"] == cache + "/build-home" && out["CFFIXED_USER_HOME"] == out["HOME"] && out["TMPDIR"] == cache + "/build-home/tmp/app")
        #expect(out["XLESS_OVERLAY_HOME"] == root + "/home" && out["XLESS_WORK_ROOT"] == cache + "/work" && out["XLESS_CACHE"] == cache)
        #expect(out["XLESS_BUILD_NUMBER"] == "7" && out["XLESS_TOOLS"] == "xless" && out["XLESS_BUILD_SANDBOX"] == "1" && out["LANG"] == "pt_PT.UTF-8")
        let developer = root + "/Xcode.app/Contents/Developer"
        #expect(out["DEVELOPER_DIR"] == developer && out["PATH"] == "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/bin:/opt/homebrew/bin:\(developer)/usr/bin:/usr/bin:/bin")
        for name in ["ASC_KEY_P8", "XLESS_SESSION", "AWS_SECRET_ACCESS_KEY", "NPM_TOKEN", "CC", "SSH_AUTH_SOCK"] { #expect(out[name] == nil, "\(name)") }
        #expect(!out.values.contains { $0.contains("secret") })
        #expect(try native.environment(buildNumber: nil).variables["XLESS_BUILD_NUMBER"] == nil)
        for tools in ["xcode", "ibtool=xcode", "actool=xcode,ibtool=xless"] {
            #expect(throws: XlessError.self) { try self.native(["XLESS_TOOLS": tools]).environment(buildNumber: nil) }
        }
        #expect(try self.native(["XLESS_TOOLS": "xless"]).environment(buildNumber: nil).variables["XLESS_TOOLS"] == "xless")
    }

    @Test func itsDirectoriesAreTheUsersOwnAndNoLinks() throws {
        let native = native(), fm = FileManager.default
        try native.makeDirectories()
        try native.makeDirectories()
        for url in [native.buildHome, native.temporary] { #expect(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700) }
        #expect(fm.fileExists(atPath: native.paths.root.path))
        // a link that an earlier build could have left
        let build = native.work.appendingPathComponent(".xless/build")
        try fm.removeItem(at: build)
        try fm.createSymbolicLink(at: build, withDestinationURL: URL(fileURLWithPath: root + "/home"))
        #expect(throws: XlessError.self) { try native.makeDirectories() }
        #expect(!fm.fileExists(atPath: root + "/home/ios"))
    }

    @Test func aCheckoutIsOpenedWithItsGitDirectory() throws {
        func git(_ words: String..., in directory: String) throws {
            try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-C", "\(root)/\(directory)"] + words, env: ["HOME": root, "GIT_CONFIG_NOSYSTEM": "1"], stage: .prepare)
        }
        let env = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1"]
        #expect(NativeOverlay.checkout(of: URL(fileURLWithPath: root + "/home/fonts"), env: env) == [root + "/home/fonts"])
        try git("init", "-q", ".", in: "home/dev/app")
        try git("commit", "-q", "--allow-empty", "-m", "x", in: "home/dev/app")
        #expect(NativeOverlay.checkout(of: URL(fileURLWithPath: root + "/home/dev/app/ios"), env: env) == [root + "/home/dev/app"])
        try git("worktree", "add", "-q", "\(root)/home/tree", in: "home/dev/app")
        #expect(NativeOverlay.checkout(of: URL(fileURLWithPath: root + "/home/tree"), env: env) == [root + "/home/tree", root + "/home/dev/app/.git"])
    }

    @Test func whatIsLeftRunningCannotHoldTheOutput() throws {
        let file = URL(fileURLWithPath: root + "/out")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file), relay = OutputRelay(to: output), begin = Date()
        let text = String(repeating: "x", count: 200_000)
        // (a child of its own session, as a tool leaves one: it holds the pipe for longer than this test would wait)
        let tool = try ChildProcess.start("/bin/sh", ["-c", "sleep 20 & echo $!; head -c 200000 /dev/zero | tr '\\0' x; echo done"], environment: ["PATH": "/usr/bin:/bin"], stdout: relay.input, stderr: nil, stage: .build)
        #expect(tool.wait() == 0)
        relay.finish()
        #expect(Date().timeIntervalSince(begin) < 15)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2 && lines.last == text + "done")
        if let pid = lines.first.flatMap({ Int32($0) }), pid > 1, getpgid(pid) == tool.processIdentifier { kill(pid, SIGTERM) }
    }
}
