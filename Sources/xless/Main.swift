import ArgumentParser
import Foundation
import XlessCore
import XlessVault

@main
enum Main {
    static func main() async {
        // A native install's xtool, rcodesign and Swift, first on PATH for this process and every child.
        NativeLayout.activate()
        // A secret missing from the environment comes from the encrypted store, when it holds one (`xless secrets`).
        // XLESS_NO_SECRET_STORE=1 (scripts/testflight.sh's native build step, which runs the app's build code): xless
        // never opens the store, and it and the build tools leave the session keyring, so a remembered unlock
        // (`xless secrets unlock --remember`) is out of the build code's reach.
        if ProcessInfo.processInfo.environment["XLESS_NO_SECRET_STORE"] == "1" {
            KernelKeyring.leaveSession()
        } else {
            Secrets.install(VaultResolver(store: VaultStore(location: .standard()), prompter: { try? TerminalPrompter.forSecretStore() }))
        }
        do {
            var command = try Xless.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as XlessError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exit(error.stage.exitCode)
        } catch {
            Xless.exit(withError: error)
        }
    }
}
