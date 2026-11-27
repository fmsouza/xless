import ArgumentParser
import Foundation
import XlessAssets
import XlessCore
import XlessIB
import XlessPackage
import XlessReactNative
import XlessXcode

struct ShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shim", abstract: "Xcode tool shims for Linux builds (internal).",
                                                    shouldDisplay: false, subcommands: [XcrunShimCommand.self, ActoolShimCommand.self, IbtoolShimCommand.self,
                                                                  PlistBuddyShimCommand.self, DmgBuildShimCommand.self,
                                                                  XcodebuildShimCommand.self, StripShimCommand.self, LinkerShimCommand.self,
                                                                  EmbeddedBinaryValidationShimCommand.self, DittoShimCommand.self,
                                                                  CopyPNGShimCommand.self, PrepareClangShimCommand.self])
}

/// Runs a tool with inherited stdin/stdout/stderr and exits with its status.
private func execTool(_ path: String, _ args: [String]) throws -> Never {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    Foundation.exit(p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus)
}

/// A refused call: its description on stderr, exit 70 (the shims' "unsupported" status).
private func refuse(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    Foundation.exit(70)
}

/// `xcodebuild` (docker/shims/xcodebuild; XcodebuildShim): `-version`, and Swift package builds run from build phases.
struct XcodebuildShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "xcodebuild")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let command: XcodebuildShim.Command
        do { command = try XcodebuildShim.parse(args) } catch { refuse(error) }
        switch command {
        case .version:
            do { print(XcodebuildShim.versionText(try ToolchainMeta.load(from: XcodeEnvironment.current().meta)), terminator: "") }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); Foundation.exit(1) }
        case .buildPackage(let build):
            let summary: SwiftBuildOutput.Summary
            do {
                let env = try SwiftBuildEnvironment.fromProcess(stage: .build)
                summary = try XcodebuildShim.buildPackage(build, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: env)
            } catch let e as XcodebuildShim.Unsupported {
                refuse(e)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n** BUILD FAILED **\n".utf8)); Foundation.exit(65)
            }
            var report = summary.warnings.map { "warning: \($0)\n" }.joined() + summary.errors.map { "error: \($0)\n" }.joined()
            if !summary.succeeded, summary.errors.isEmpty { report += summary.failedTasks.map { "error: failed: \($0)\n" }.joined() }
            // The nested build's shim refusals, verbatim: the calling phase's task output carries them to ruling R4.
            report += summary.shimRefusals.map { "\($0)\n" }.joined()
            FileHandle.standardError.write(Data(report.utf8))
            if !build.quiet { print(summary.succeeded ? "** BUILD SUCCEEDED **" : "** BUILD FAILED **") }
            Foundation.exit(summary.succeeded ? 0 : 65)
        }
    }
}

/// `clang` during a React Native prepare (docker/shims/prepare/clang; PrepareClangShim): Darwin-only stub compiles
/// retargeted to iOS, everything else passed to the host clang unchanged.
struct PrepareClangShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prepare-clang")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let mapped: [String], xcode: XcodeEnvironment
        do {
            xcode = try XcodeEnvironment.current()
            mapped = try PrepareClangShim.arguments(args, sdk: DarwinSDK(bundle: xcode.sdkBundle))
        } catch { refuse(error) }
        try execTool(PrepareClangShim.executable(args, swift: xcode.toolchain), mapped)
    }
}

/// `strip` where Swift Build looks for it first (docker/shims/swift-build/strip; StripShim): LLVM's `llvm-strip`,
/// then the string pool alignment dyld requires.
struct StripShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "strip")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let llvmStrip = ProcessInfo.processInfo.environment["XLESS_LLVM_STRIP"] ?? Self.llvmStrip(shims: ProcessInfo.processInfo.environment["XLESS_SHIM_DIR"])
        let status: Int32
        do { status = try StripShim.run(args, llvmStrip: llvmStrip) } catch let e as ToolShimUnsupported { refuse(e) }
        Foundation.exit(status)
    }

    /// The image installs LLVM's tools beside its shims: `<XLESS_SHIM_DIR>/../llvm/bin/llvm-strip`; without shims, the
    /// `llvm-strip` on PATH.
    static func llvmStrip(shims: String?) -> String {
        guard let shims, !shims.isEmpty else { return "llvm-strip" }
        return URL(fileURLWithPath: shims).deletingLastPathComponent().appendingPathComponent("llvm/bin/llvm-strip").path
    }
}

/// The linker in Swift Build's toolset (docker/shims/xless-ld64; LinkerShim): the SDK's `ld64.lld` trampoline,
/// with archives that stand for `-r` objects force-loaded.
struct LinkerShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ld64")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let mapped = try LinkerShim.arguments(args, isArchive: LinkerShim.isArchive, readFileList: { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw XlessError(.build, "cannot read the link file list \(path)", fix: "re-run the build")
            }
            return text.split(separator: "\n").map(String.init)
        }, writeFileList: { path, lines in
            let out = path + ".xless"
            try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            return out
        }, fileExists: { FileManager.default.fileExists(atPath: $0) },
           readFile: { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped) })
        try execTool(DarwinSDK(bundle: try XcodeEnvironment.current().sdkBundle).ld64.path, mapped)
    }
}

/// `embeddedBinaryValidationUtility` where Swift Build looks for it first
/// (docker/shims/swift-build/embeddedBinaryValidationUtility; EmbeddedBinaryValidation).
struct EmbeddedBinaryValidationShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "embedded-binary-validation")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let r: EmbeddedBinaryValidation.Result
        do { r = try EmbeddedBinaryValidation.run(args) } catch { refuse(error) }
        finish(stdout: "", stderr: r.stderr, exitCode: r.exitCode)
    }
}

/// `ditto <source> <destination>` for build phases (docker/shims/ditto; DittoShim).
struct DittoShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ditto")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        do { try DittoShim.run(args) }
        catch let e as DittoShim.Unsupported { refuse(e) }
        catch { finish(stdout: "", stderr: "\(error)\n", exitCode: 1) }
    }
}

/// `copypng` for Swift Build's CopyPNGFile rule (docker/shims/copypng; CopyPNGShim).
struct CopyPNGShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "copypng")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        do {
            let p = try CopyPNGShim.parse(args)
            guard let data = FileManager.default.contents(atPath: p.input) else {
                finish(stdout: "", stderr: "ERROR: Can't find \(p.input)\n", exitCode: 1)
            }
            let r = try CopyPNGShim.convert(data, compress: p.compress, stripText: p.stripText, argv: args)
            try r.output.write(to: URL(fileURLWithPath: p.output), options: .atomic)
            finish(stdout: "", stderr: r.stderr, exitCode: 0)
        } catch let e as CopyPNGShim.Unsupported { refuse(e) }
    }
}

struct XcrunShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "xcrun")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let shimDir = env["XLESS_SHIM_DIR"]
        let which: (String) -> String? = { name in
            for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) where dir != shimDir {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            return nil
        }
        // actool lives in the shim directory itself (XcrunShim.shimTools).
        let shim: (String) -> String? = { name in
            guard let shimDir, !shimDir.isEmpty else { return nil }
            let p = "\(shimDir)/\(name)"
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        // A fat file's architectures, for `lipo -remove` (`llvm-lipo -archs`).
        let lipoArchs: (String) -> [String]? = { file in
            guard let lipo = which("llvm-lipo") else { return nil }
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: lipo)
            p.arguments = ["-archs", file]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let action: XcrunShim.Action
        do { action = try XcrunShim.resolve(args, sdk: DarwinSDK(), which: which, shim: shim, lipoArchs: lipoArchs) }
        catch let e as XcrunShim.Unsupported { FileHandle.standardError.write(Data("\(e)\n".utf8)); Foundation.exit(70) }
        switch action {
        case .output(let text):
            print(text, terminator: "")
        case let .exec(path, toolArgs):
            // The tool inherits stdin/stdout/stderr; its exit status becomes ours.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = toolArgs
            try p.run()
            p.waitUntilExit()
            Foundation.exit(p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus)
        }
    }
}

/// Writes a shim's captured output and exits with its status.
private func finish(stdout: String, stderr: String, exitCode: Int32) -> Never {
    FileHandle.standardOutput.write(Data(stdout.utf8))
    FileHandle.standardError.write(Data(stderr.utf8))
    Foundation.exit(exitCode)
}

/// `actool` for Swift Build on Linux (docker/shims/actool; ActoolShim).
struct ActoolShimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "actool")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() async throws {
        let r = await ActoolShim.run(args)
        finish(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode)
    }
}

/// `ibtool` for Swift Build on Linux (docker/shims/ibtool; IbtoolShim).
struct IbtoolShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ibtool")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let r = IbtoolShim.run(args)
        finish(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode)
    }
}

/// `/usr/libexec/PlistBuddy` for build phases on Linux (docker/shims/PlistBuddy; PlistBuddyShim).
struct PlistBuddyShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plistbuddy")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let r = PlistBuddyShim.run(args)
        finish(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode)
    }
}

/// An unsigned, unnotarized DMG of an app, for the Linux parity test (scripts/test-tauri-linux.sh --platform macos). No secrets.
struct DmgBuildShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dmg-build")
    @Argument var app: String
    @Argument var outputDir: String
    @Option(name: .customLong("volume-name")) var volumeName: String
    @Option(name: .customLong("app-version")) var version: String
    func run() throws {
        let dmg = try DmgBuilder.build(signedApp: URL(fileURLWithPath: app), volumeName: volumeName, version: version, outputDir: URL(fileURLWithPath: outputDir))
        print(dmg.path)
    }
}
