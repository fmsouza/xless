#if os(Windows) || XLESS_WINDOWS_TARGETS
import ArgumentParser
import XlessCore

// The commands that Windows does not have: in the tree, so that each says so itself, and in no help.

protocol CommandNotHere {
    static var name: String { get }
    static var why: XlessError { get }
}

extension CommandNotHere {
    static var why: XlessError {
        XlessError(.config, "`xless \(name)`: builds do not run on Windows", fix: "run it inside WSL2 (wsl --install, then xless for Linux there) or on a Mac or Linux (docs/native-install.md#windows)")
    }
}

/// Whatever its arguments: nothing of them is parsed.
struct NotHere<Command: CommandNotHere>: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(commandName: String(Command.name.split(separator: " ").last ?? ""), shouldDisplay: false) }

    @Argument(parsing: .captureForPassthrough) var rest: [String] = []

    func run() throws { throw Command.why }
}

enum NotHereName {
    enum Ship: CommandNotHere { static let name = "ship" }
    enum Prepare: CommandNotHere { static let name = "prepare" }
    enum Build: CommandNotHere { static let name = "build" }
    enum Assets: CommandNotHere { static let name = "assets" }
    enum Finalize: CommandNotHere { static let name = "finalize" }
    enum Sign: CommandNotHere { static let name = "sign" }
    enum Package: CommandNotHere { static let name = "package" }
    enum Upload: CommandNotHere { static let name = "upload" }
    enum Inspect: CommandNotHere { static let name = "inspect" }
    enum NextBuild: CommandNotHere { static let name = "next-build" }
    enum SDK: CommandNotHere { static let name = "sdk" }
    enum Nib: CommandNotHere { static let name = "nib" }
    enum Storyboard: CommandNotHere { static let name = "storyboard" }
    enum Shim: CommandNotHere { static let name = "shim" }
    enum Tauri: CommandNotHere { static let name = "tauri" }
    enum Cargo: CommandNotHere { static let name = "cargo" }
    enum Xcode: CommandNotHere { static let name = "xcode" }
    enum Setup: CommandNotHere { static let name = "setup" }
    enum Run: CommandNotHere { static let name = "run" }
    enum Docker: CommandNotHere { static let name = "docker" }
    enum Clean: CommandNotHere { static let name = "clean" }
    enum LiveCheck: CommandNotHere { static let name = "live-check" }
    enum Session: CommandNotHere {
        static let name = "session"
        static let why = XlessError(.config, "`xless session`: nothing can be kept unlocked on Windows yet", fix: "run the commands without it: each asks; in CI, set the variables (docs/secrets.md)")
    }
    enum ImportEnv: CommandNotHere {
        static let name = "secrets import-env"
        static let why = XlessError(.config, "`xless secrets import-env` reads the file of `xless run`, and builds do not run on Windows",
                                    fix: "import each key by itself: xless secrets import <name> --file <file>")
    }
    enum Materialize: CommandNotHere { static let name = "secrets materialize" }
}

typealias ShipCommand = NotHere<NotHereName.Ship>
typealias PrepareCommand = NotHere<NotHereName.Prepare>
typealias BuildCommand = NotHere<NotHereName.Build>
typealias AssetsCommand = NotHere<NotHereName.Assets>
typealias FinalizeCommand = NotHere<NotHereName.Finalize>
typealias SignCommand = NotHere<NotHereName.Sign>
typealias PackageCommand = NotHere<NotHereName.Package>
typealias UploadCommand = NotHere<NotHereName.Upload>
typealias InspectCommand = NotHere<NotHereName.Inspect>
typealias NextBuildCommand = NotHere<NotHereName.NextBuild>
typealias SDKCommand = NotHere<NotHereName.SDK>
typealias NibCommand = NotHere<NotHereName.Nib>
typealias StoryboardCommand = NotHere<NotHereName.Storyboard>
typealias ShimCommand = NotHere<NotHereName.Shim>
typealias TauriCommand = NotHere<NotHereName.Tauri>
typealias CargoCommand = NotHere<NotHereName.Cargo>
typealias XcodeCommand = NotHere<NotHereName.Xcode>
typealias SetupCommand = NotHere<NotHereName.Setup>
typealias RunCommand = NotHere<NotHereName.Run>
typealias DockerCommand = NotHere<NotHereName.Docker>
typealias CleanCommand = NotHere<NotHereName.Clean>
typealias LiveCheckCommand = NotHere<NotHereName.LiveCheck>
typealias SessionCommand = NotHere<NotHereName.Session>
typealias SecretsImportEnvCommand = NotHere<NotHereName.ImportEnv>
typealias SecretsMaterializeCommand = NotHere<NotHereName.Materialize>
#endif
