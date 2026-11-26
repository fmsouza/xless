import ArgumentParser
import XlessCore

struct Xless: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xless",
        abstract: "Set up, manage, build and ship Apple apps from the terminal.",
        discussion: """
        Every command takes --no-input (or XLESS_NO_INPUT=1): instead of asking for a passphrase, a sign-in or a \
        confirmation it fails at once, with exit code 23. `xless auth status --json` says what is held, and until when.
        """,
        version: XlessVersion.current,
        subcommands: [ShipCommand.self, PrepareCommand.self, BuildCommand.self, AssetsCommand.self, FinalizeCommand.self, SignCommand.self,
                      PackageCommand.self, UploadCommand.self, InspectCommand.self, NextBuildCommand.self, SDKCommand.self, NibCommand.self, StoryboardCommand.self, ShimCommand.self, TauriCommand.self, CargoCommand.self, XcodeCommand.self, SetupCommand.self, RunCommand.self, DockerCommand.self, CleanCommand.self, LiveCheckCommand.self],
        groupedSubcommands: [
            // M7: the Apple developer account and App Store Connect from the terminal (docs/apple-account.md).
            CommandGroup(name: "Apple account", subcommands: [UnlockCommand.self, LockCommand.self, SessionCommand.self, AuthCommand.self, TeamCommand.self, SecretsCommand.self, DevicesCommand.self, BundleIDsCommand.self,
                                                             MerchantIDsCommand.self, CertsCommand.self, ProfilesCommand.self, AppGroupsCommand.self,
                                                             ICloudContainersCommand.self, KeysCommand.self, AppsCommand.self, StoreCommand.self, BuildsCommand.self, UsersCommand.self, TestFlightCommand.self, ReleaseCommand.self, IAPCommand.self, SubscriptionsCommand.self, SandboxTestersCommand.self, ReviewsCommand.self, ReportsCommand.self, WebhooksCommand.self, ProvisionCommand.self, APICommand.self]),
        ]
    )
}
