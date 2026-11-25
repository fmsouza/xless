import ArgumentParser
import Foundation
import XlessAgent
import XlessCore
import XlessVault

@main
enum Main {
    static func main() async {
        // `xless __agent`, which xless starts itself (`xless unlock`): before anything else, with nothing of the environment.
        if let status = AgentHost.runIfAsked(CommandLine.arguments) { exit(status) }
        // `--no-input`, of any command: also for the processes it becomes or starts.
        let (arguments, noInput) = InputGate.taking(CommandLine.arguments)
        if noInput { setenv(InputGate.variable, "1", 1) }
        ScriptProcess.path = ProcessInfo.processInfo.environment["PATH"]
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
            var command = try Xless.parseAsRoot(Array(HoldArguments.withDefaults(arguments).dropFirst()))
            RunningCommand.set(type(of: command))
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            forgetUnlock()
            end(error)
        }
        forgetUnlock()
        end(nil)
    }

    /// Ends the process for `error`. A question `--no-input` refused is the command's outcome, whatever the command made
    /// of it (a step it skipped, an error of its own).
    private static func end(_ error: (any Error)?) {
        func say(_ error: XlessError) { FileHandle.standardError.write(Data("error: \(error.description)\n".utf8)) }
        let refused = InputGate.refused
        if let refused {
            if let error = error as? XlessError, error != refused { say(error) }
            say(refused)
            exit(refused.stage.exitCode)
        }
        guard let error else { return }
        guard let error = error as? XlessError else { Xless.exit(withError: error) }
        say(error)
        exit(error.stage.exitCode)
    }
}
