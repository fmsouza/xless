import ArgumentParser
import Foundation
import XlessCore
import XlessIB

struct NibCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "nib", abstract: "Inspect compiled .nib files.", subcommands: [NibDumpCommand.self])
}

struct NibDumpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump", abstract: "Print a canonical text dump of a NIBArchive .nib.")
    @Argument var file: String
    func run() async throws {
        print(NIBDump.render(try NIBArchiveReader.read(url: URL(fileURLWithPath: file))), terminator: "")
    }
}

struct StoryboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "storyboard", abstract: "Compile storyboards without ibtool.", subcommands: [StoryboardCompileCommand.self])
}

struct StoryboardCompileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compile", abstract: "Compile a launch-screen .storyboard into a .storyboardc, byte-identical to ibtool.")
    @Argument(help: "The .storyboard to compile.") var input: String
    @Option(help: "Output .storyboardc directory.") var out: String
    @Option(help: "Minimum iOS deployment target (15.0 to 27.x).") var minimumDeploymentTarget: String
    @Option(name: .customLong("target-device"), help: "Target device family: iphone or ipad. Repeat for both.") var targetDevices: [String] = []
    @Option(help: "The Xcode build whose ibtool output to reproduce (default: that of the Xcode this build uses, from its pack's toolchain metadata).") var xcodeBuild: String?
    @Flag(help: "Replace --out if it exists.") var force = false

    func run() async throws {
        let options = try StoryboardCompileRunner.options(devices: targetDevices, minimumDeploymentTarget: minimumDeploymentTarget)
        let profile = try xcodeBuild.map { try XcodeToolsProfile.named($0, stage: .ib) } ?? XcodeToolsProfile.forImage(stage: .ib)
        try StoryboardCompileRunner.run(input: URL(fileURLWithPath: input), out: URL(fileURLWithPath: out), options: options, profile: profile, force: force)
    }
}
