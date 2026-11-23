import ArgumentParser
import Foundation
import XlessCore
import XlessVault

@main
enum Main {
    static func main() async {
        // A native install's xtool, rcodesign and Swift, first on PATH for this process and every child.
        NativeLayout.activate()
        // A secret missing from the environment comes from the secret store, when it holds one (`xless secrets`).
        // XLESS_NO_SECRET_STORE=1 (scripts/testflight.sh's native build step, and every tool an xless runs:
        // `ChildProcess`): xless never opens the store, and it and the build tools leave the session keyring, so a
        // remembered unlock (`xless secrets unlock --remember`) is out of the build code's reach.
        let storeOff = ProcessInfo.processInfo.environment["XLESS_NO_SECRET_STORE"] == "1"
        // The unlocked data key (one passphrase per command, shared by every lookup and write) ends with the command.
        func forgetUnlock() { if !storeOff { SecretStoreCLI.forgetUnlock() } }
        if storeOff {
            KernelKeyring.leaveSession()
        } else {
            // The vault, or the credential helper config.yml names (`secrets.backend`).
            Secrets.install(SecretStoreCLI.fallback)
        }
        do {
            var command = try Xless.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as XlessError {
            forgetUnlock()
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exit(error.stage.exitCode)
        } catch {
            forgetUnlock()
            Xless.exit(withError: error)
        }
        forgetUnlock()
    }
}
