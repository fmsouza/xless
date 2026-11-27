import Foundation
import XlessCore

/// `xless shim ibtool`: the `ibtool` command lines Swift Build runs for storyboards on Linux
/// (`SWBApplePlatform/Specs/IBStoryboardCompiler.xcspec`, `IBStoryboardLinker.xcspec`; Xcode's own lines in
/// docs/research/ib-invocation.md). Compiling goes through `StoryboardCompiler`, so a storyboard outside its subset
/// fails the build with the compiler's refusal. Linking copies the compiled `.storyboardc` (byte-identical for a
/// single storyboard, ib-invocation.md). Any flag or value outside that subset is refused with exit 70 and the argv.
///
/// The shim answers as the image's Xcode's ibtool (`XcodeToolsProfile`, from its toolchain metadata, `XcodeEnvironment.meta`, read once
/// per call): its `--version` and its nib encoding. An image whose Xcode has no profile is refused with exit 70.
public enum IbtoolShim {
    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "ibtool shim: unsupported call (\(reason)): ibtool \(argv.joined(separator: " "))" }
    }

    public struct Result: Equatable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
    }

    enum Invocation: Equatable {
        case version
        /// `--compile <out>.storyboardc` or `--compilation-directory <dir>` (output `<dir>/<name>.storyboardc`).
        case compile(input: URL, output: URL, partialInfoPlist: URL?, options: IBCompileOptions)
        case link(directory: URL, inputs: [URL])
    }

    static func parse(_ args: [String], cwd: URL) throws(Unsupported) -> Invocation {
        func refuse(_ reason: String) -> Unsupported { Unsupported(argv: args, reason: reason) }
        func path(_ p: String) -> URL { URL(fileURLWithPath: p, relativeTo: cwd).standardizedFileURL }
        var values: [String: String] = [:], flags = Set<String>(), devices: [String] = [], inputs: [URL] = []
        let valued: Set<String> = ["--output-format", "--module", "--output-partial-info-plist", "--minimum-deployment-target",
                                   "--compile", "--compilation-directory", "--link"]
        let boolean: Set<String> = ["--version", "--errors", "--warnings", "--notices", "--auto-activate-custom-fonts"]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--target-device" {
                guard i + 1 < args.count else { throw refuse("--target-device needs a value") }
                devices.append(args[i + 1]); i += 2; continue
            }
            if valued.contains(a) {
                guard i + 1 < args.count else { throw refuse("\(a) needs a value") }
                guard values[a] == nil else { throw refuse("\(a) given twice") }
                values[a] = args[i + 1]; i += 2; continue
            }
            if boolean.contains(a) { flags.insert(a); i += 1; continue }
            guard !a.hasPrefix("-") else { throw refuse("unknown option \(a)") }
            inputs.append(path(a)); i += 1
        }

        if flags.contains("--version") {
            guard args.count == 1 || (args.count == 3 && values["--output-format"] == "xml1") else { throw refuse("--version takes only --output-format xml1") }
            return .version
        }
        guard values["--output-format"] == "human-readable-text" else { throw refuse("--output-format must be human-readable-text") }
        let outputs = ["--compile", "--compilation-directory", "--link"].filter { values[$0] != nil }
        guard outputs.count == 1 else { throw refuse("exactly one of --compile, --compilation-directory, --link is needed") }
        if let dir = values["--link"] {
            guard !inputs.isEmpty, inputs.allSatisfy({ $0.pathExtension == "storyboardc" }) else { throw refuse("--link takes compiled .storyboardc inputs") }
            guard values["--output-partial-info-plist"] == nil, !flags.contains("--auto-activate-custom-fonts") else {
                throw refuse("--output-partial-info-plist and --auto-activate-custom-fonts are compile options")
            }
            for input in inputs where input.deletingLastPathComponent().pathExtension == "lproj" {
                throw refuse("localized storyboard \(input.path) (.lproj) is not supported")
            }
            return .link(directory: path(dir), inputs: inputs)
        }
        guard inputs.count == 1, let input = inputs.first, input.pathExtension == "storyboard" else { throw refuse("compiling takes one .storyboard input") }
        guard let target = values["--minimum-deployment-target"] else { throw refuse("no --minimum-deployment-target") }
        let output: URL
        if let out = values["--compile"] {
            guard path(out).pathExtension == "storyboardc" else { throw refuse("--compile must name a .storyboardc") }
            output = path(out)
        } else {
            output = path(values["--compilation-directory"]!).appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".storyboardc")
        }
        // Device and deployment-target values are checked by the compiler runner, with its own wording (exit 1).
        return .compile(input: input, output: output, partialInfoPlist: values["--output-partial-info-plist"].map(path),
                        options: IBCompileOptions(targetDevices: devices, minimumDeploymentTarget: target))
    }

    /// `profile` gives the image's tools profile (default: from the image's toolchain metadata); it is asked once.
    public static func run(_ args: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                           profile loadProfile: () throws -> XcodeToolsProfile = { try XcodeToolsProfile.forImage(stage: .ib) }) -> Result {
        let invocation: Invocation
        do { invocation = try parse(args, cwd: cwd) } catch {
            return Result(stdout: "", stderr: "\(error)\n", exitCode: 70)
        }
        let profile: XcodeToolsProfile
        do { profile = try loadProfile() } catch {
            return Result(stdout: "", stderr: "\(error)\n", exitCode: 70)
        }
        switch invocation {
        case .version:
            return Result(stdout: """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                \t<key>com.apple.ibtool.version</key>
                \t<dict>
                \t\t<key>bundle-version</key>
                \t\t<string>\(profile.ibtoolBundleVersion)</string>
                \t\t<key>short-bundle-version</key>
                \t\t<string>\(profile.ibtoolShortVersion)</string>
                \t</dict>
                </dict>
                </plist>

                """, stderr: "", exitCode: 0)
        case let .compile(input, output, partial, options):
            do {
                let checked = try StoryboardCompileRunner.options(devices: options.targetDevices, minimumDeploymentTarget: options.minimumDeploymentTarget)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try StoryboardCompileRunner.run(input: input, out: output, options: checked, profile: profile, force: true)
                if let partial {
                    // ibtool 27.0 and 26.2 wrote `<dict/>` for every storyboard measured (ib-invocation.md seeds, Expo's
                    // SplashScreen.storyboard, the corpus); the compiler's subset has nothing that would add keys.
                    try Data("""
                        <?xml version="1.0" encoding="UTF-8"?>
                        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                        <plist version="1.0">
                        <dict/>
                        </plist>

                        """.utf8).write(to: partial)
                }
                return Result(stdout: "", stderr: "", exitCode: 0)
            } catch {
                return failure(error, file: input)
            }
        case let .link(directory, inputs):
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for input in inputs {
                    let dst = directory.appendingPathComponent(input.lastPathComponent)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: input, to: dst)
                }
                return Result(stdout: "", stderr: "", exitCode: 0)
            } catch {
                return failure(XlessError(.ib, "cannot link \(inputs.map(\.path).joined(separator: ", ")) into \(directory.path): \(error.localizedDescription)",
                                          fix: "check that the compiled storyboards exist and the directory is writable"), file: inputs[0])
            }
        }
    }

    /// A failure as ibtool reports one (stdout, parsed by Swift Build into a build error), with xless's full refusal
    /// (cause and fix) on stderr.
    static func failure(_ error: Error, file: URL) -> Result {
        let e = (error as? XlessError) ?? XlessError(.ib, "\(error)", fix: "check the storyboard file; re-save it in Xcode if needed")
        return Result(stdout: "/* com.apple.ibtool.errors */\n\(file.path): error: \(e.cause)\n",
                      stderr: "xless ibtool shim: \(e)\n", exitCode: 1)
    }
}
