import ArgumentParser
import XlessCore

struct Xless: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xless",
        abstract: "Build, sign and ship Apple-platform apps from Linux.",
        version: XlessVersion.current,
        subcommands: [ShipCommand.self, PrepareCommand.self, BuildCommand.self, AssetsCommand.self, FinalizeCommand.self, SignCommand.self,
                      PackageCommand.self, UploadCommand.self, InspectCommand.self, NextBuildCommand.self, SDKCommand.self, NibCommand.self, StoryboardCommand.self, ShimCommand.self, TauriCommand.self, CargoCommand.self, XcodeCommand.self, SetupCommand.self, RunCommand.self, DockerCommand.self, CleanCommand.self]
    )
}
